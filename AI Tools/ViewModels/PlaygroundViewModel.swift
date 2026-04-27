import Foundation
import SwiftUI
import Combine

struct UsageTimeWindowSummary: Identifiable {
    let label: String
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCost: Double

    var id: String { label }
}

@MainActor
final class PlaygroundViewModel: ObservableObject {
    @AppStorage("ai_provider") private var providerStore = AIProvider.gemini.rawValue
    @AppStorage("gemini_system_instruction") var systemInstruction = ""

    @Published var messages: [ChatMessage] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var streamingText: String = ""
    @Published var selectedProvider: AIProvider = .gemini
    @Published var modelID: String = "gemini-2.5-flash"
    @Published var availableModels: [String] = []
    @Published var savedConversations: [SavedConversation] = []
    @Published var selectedConversationID: UUID?
    @Published var pendingAttachments: [PendingAttachment] = []

    /// True while `importConversation` is mutating published state. Views can
    /// check this in their `.onChange` handlers to avoid reacting to programmatic
    /// changes (e.g. the provider Picker would otherwise overwrite the imported
    /// modelID with the default model for that provider).
    private(set) var isImportingConversation = false

    private let apiKeyManager: APIKeyManager
    private let modelService: ModelService
    private let serviceFactory: (AIProvider, String) -> GeminiServicing
    private let conversationStore: ConversationStore?
    private let nowProvider: () -> Date
    private var didAutoLoadModels = false
    private var pendingConversationSaveTask: Task<Void, Never>?

    init(
        apiKeyManager: APIKeyManager? = nil,
        modelService: ModelService? = nil,
        serviceFactory: @escaping (AIProvider, String) -> GeminiServicing = { provider, key in
            switch provider {
            case .gemini:    return GeminiClient(apiKey: key)
            case .chatGPT:   return OpenAIClient(apiKey: key)
            case .anthropic: return AnthropicClient(apiKey: key)
            case .grok:      return GrokClient(apiKey: key)
            }
        },
        conversationStoreFactory: (() -> ConversationStore?)? = nil,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        let resolvedAPIKeyManager = apiKeyManager ?? APIKeyManager()
        let resolvedModelService = modelService ?? ModelService()

        self.apiKeyManager = resolvedAPIKeyManager
        self.modelService = resolvedModelService
        self.serviceFactory = serviceFactory
        self.nowProvider = nowProvider

        self.conversationStore = conversationStoreFactory?()

        resolvedAPIKeyManager.loadFromSecureStorage()
        resolvedAPIKeyManager.onPersistError = { [weak self] message in
            self?.errorMessage = message
        }

        let provider = AIProvider(rawValue: providerStore) ?? .gemini
        selectedProvider = provider
        modelID = resolvedModelService.selectedModelID(for: provider)
        availableModels = resolvedModelService.availableModels(for: provider, including: modelID)

        Task { [weak self] in
            await self?.loadSavedConversations()
        }
    }

    deinit {
        pendingConversationSaveTask?.cancel()
    }

    // MARK: - Public interface

    var providerAPIKeyPlaceholder: String { selectedProvider.apiKeyPlaceholder }
    var currentAPIKey: String { apiKeyManager.key(for: selectedProvider) }
    var canSendRequests: Bool { selectedProvider.isImplemented }
    var canLoadModels: Bool { selectedProvider.isImplemented }

    func updateCurrentAPIKey(_ value: String) {
        apiKeyManager.updateKey(value, for: selectedProvider)
    }

    func loadOnLaunchIfNeeded() async {
        guard !didAutoLoadModels else { return }
        didAutoLoadModels = true
        await prefetchModelsOnLaunch()
    }

    func selectProvider(_ provider: AIProvider) async {
        selectedProvider = provider
        providerStore = provider.rawValue
        modelID = modelService.selectedModelID(for: provider)
        availableModels = modelService.availableModels(for: provider, including: modelID)
        errorMessage = nil
    }

    func selectModel(_ model: String) {
        if modelID != model { modelID = model }
        modelService.selectModel(model, for: selectedProvider)
    }

    func clearMessages() {
        messages.removeAll()
        errorMessage = nil
        if let selectedConversationID {
            updateConversation(id: selectedConversationID)
        }
    }

    func startNewChat() {
        selectedConversationID = nil
        messages.removeAll()
        errorMessage = nil
    }

    func selectConversation(_ id: UUID?) {
        selectedConversationID = id
        guard let id, let conversation = savedConversations.first(where: { $0.id == id }) else {
            messages.removeAll()
            errorMessage = nil
            return
        }
        selectedProvider = conversation.provider
        providerStore = conversation.provider.rawValue
        modelID = conversation.modelID
        // Insert the conversation's model into the picker without persisting it as the new default.
        availableModels = modelService.availableModels(for: conversation.provider, including: conversation.modelID)
        messages = conversation.messages
        errorMessage = nil
    }

    func deleteSelectedConversation() {
        guard let id = selectedConversationID else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            savedConversations.removeAll { $0.id == id }
            selectedConversationID = nil
            messages.removeAll()
        }
        persistSavedConversations()
    }

    func importConversation(_ conversation: SavedConversation) {
        var imported = conversation
        imported.updatedAt = Date()

        if let existingIndex = savedConversations.firstIndex(where: { $0.id == imported.id }) {
            savedConversations[existingIndex] = imported
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                savedConversations.insert(imported, at: 0)
            }
        }

        savedConversations.sort { $0.updatedAt > $1.updatedAt }

        // Raise the flag so the Picker's `.onChange(of: selectedProvider)`
        // in ContentWorkspaceViews doesn't overwrite our freshly-set modelID.
        isImportingConversation = true
        selectedConversationID = imported.id
        selectedProvider = imported.provider
        providerStore = imported.provider.rawValue
        modelID = imported.modelID
        availableModels = modelService.availableModels(for: imported.provider, including: imported.modelID)
        messages = imported.messages
        errorMessage = nil
        // Lower the flag on the next runloop tick, after SwiftUI has processed
        // the onChange callbacks triggered by the mutations above.
        DispatchQueue.main.async { [weak self] in
            self?.isImportingConversation = false
        }
        persistSavedConversations()
    }

    func filteredConversations(query: String) -> [SavedConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return savedConversations }
        return savedConversations.filter { $0.searchBlob.localizedCaseInsensitiveContains(needle) }
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func addAttachments(fromResult result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = "Attachment import failed: \(error.localizedDescription)"
        case .success(let urls):
            for url in urls {
                do {
                    let attachment = try PendingAttachment.fromFileURL(url)
                    pendingAttachments.append(attachment)
                } catch {
                    errorMessage = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshModels() async {
        guard canLoadModels else {
            errorMessage = "Model loading is not available for this provider."
            return
        }
        guard !currentAPIKey.isEmpty else {
            errorMessage = "Missing API key."
            return
        }
        await fetchModels(for: selectedProvider, reportErrorsForSelectedProvider: true)
    }

    func send(text: String) async {
        errorMessage = nil
        let attachments = pendingAttachments
        pendingAttachments = []
        guard canSendRequests else {
            errorMessage = "\(selectedProvider.displayName) is not wired yet. Switch to Gemini to send."
            return
        }
        guard !currentAPIKey.isEmpty else {
            errorMessage = "Missing API key."
            return
        }
        guard !modelID.isEmpty else {
            errorMessage = "Model ID cannot be empty."
            return
        }

        messages.append(ChatMessage(
            role: .user,
            text: text.isEmpty ? "(Attachment only)" : text,
            attachments: attachments.map {
                AttachmentSummary(name: $0.name, mimeType: $0.mimeType,
                                  previewBase64Data: $0.previewJPEGData?.base64EncodedString())
            }
        ))
        isLoading = true
        streamingText = ""
        defer {
            isLoading = false
            streamingText = ""
        }

        var chunks: [String] = []
        var accumulatedMedia: [GeneratedMedia] = []
        var inputTokens = 0
        var outputTokens = 0

        do {
            let stream = serviceFactory(selectedProvider, currentAPIKey).generateReplyStream(
                modelID: modelID,
                systemInstruction: systemInstruction,
                messages: messages,
                latestUserAttachments: attachments
            )
            var lastUIUpdate = Date.distantPast
            for try await chunk in stream {
                chunks.append(chunk.text)
                accumulatedMedia += chunk.generatedMedia
                if chunk.inputTokens > 0 { inputTokens = chunk.inputTokens }
                if chunk.outputTokens > 0 { outputTokens = chunk.outputTokens }
                let now = Date()
                if now.timeIntervalSince(lastUIUpdate) >= 0.05 {
                    lastUIUpdate = now
                    streamingText = chunks.joined()
                }
            }
            let accumulatedText = chunks.joined()
            let persistedMedia = conversationStore?.normalizeMedia(accumulatedMedia) ?? accumulatedMedia
            messages.append(ChatMessage(
                role: .assistant,
                text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                attachments: [],
                generatedMedia: persistedMedia,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                modelID: modelID
            ))
            upsertCurrentConversation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var sessionInputTokens: Int {
        messages.filter { $0.role == .assistant }.reduce(0) { $0 + $1.inputTokens }
    }

    var sessionOutputTokens: Int {
        messages.filter { $0.role == .assistant }.reduce(0) { $0 + $1.outputTokens }
    }

    var usageTimeWindows: [UsageTimeWindowSummary] {
        let now = nowProvider()
        let conversations = conversationsSnapshotForUsage(at: now)
        return [
            usageSummary(label: "24h", since: now.addingTimeInterval(-24 * 60 * 60),        now: now, conversations: conversations),
            usageSummary(label: "7d",  since: now.addingTimeInterval(-7 * 24 * 60 * 60),   now: now, conversations: conversations),
            usageSummary(label: "30d", since: now.addingTimeInterval(-30 * 24 * 60 * 60),  now: now, conversations: conversations),
        ]
    }

    // MARK: - Private: model fetching

    private func prefetchModelsOnLaunch() async {
        for provider in AIProvider.allCases where provider.isImplemented {
            guard !apiKeyManager.key(for: provider).isEmpty else { continue }
            await fetchModels(for: provider, reportErrorsForSelectedProvider: provider == selectedProvider)
        }
    }

    private func fetchModels(for provider: AIProvider, reportErrorsForSelectedProvider: Bool) async {
        let apiKey = apiKeyManager.key(for: provider)
        guard !apiKey.isEmpty else { return }
        do {
            let fetched = try await serviceFactory(provider, apiKey).listGenerateContentModels()
            modelService.updateCache(fetched, for: provider)
            if provider == selectedProvider {
                modelID = modelService.selectedModelID(for: provider)
                availableModels = modelService.availableModels(for: provider, including: modelID)
            }
        } catch {
            if reportErrorsForSelectedProvider && provider == selectedProvider {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Private: conversation persistence

    private func upsertCurrentConversation() {
        guard !messages.isEmpty else { return }
        if let id = selectedConversationID {
            updateConversation(id: id)
            return
        }
        let conversation = SavedConversation(
            id: UUID(),
            provider: selectedProvider,
            title: inferredConversationTitle(),
            updatedAt: Date(),
            modelID: modelID,
            messages: messages
        )
        selectedConversationID = conversation.id
        withAnimation(.easeInOut(duration: 0.2)) {
            savedConversations.insert(conversation, at: 0)
        }
        persistSavedConversations()
    }

    private func updateConversation(id: UUID) {
        guard let index = savedConversations.firstIndex(where: { $0.id == id }) else { return }
        savedConversations[index].updatedAt = Date()
        savedConversations[index].provider = selectedProvider
        savedConversations[index].modelID = modelID
        savedConversations[index].messages = messages
        savedConversations[index].title = inferredConversationTitle(fallback: savedConversations[index].title)
        savedConversations.sort { $0.updatedAt > $1.updatedAt }
        persistSavedConversations()
    }

    private func inferredConversationTitle(fallback: String = "Untitled Chat") -> String {
        guard let text = messages.first(where: { $0.role == .user })?.text else { return fallback }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(48))
    }

    private func loadSavedConversations() async {
        guard let conversationStore else {
            savedConversations = []
            return
        }
        do {
            let loaded = try conversationStore.loadConversations()
            savedConversations = loaded.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            savedConversations = []
            errorMessage = "Failed to load conversations: \(error.localizedDescription)"
        }
    }

    private func persistSavedConversations() {
        guard let conversationStore else {
            errorMessage = "Unable to initialize conversation storage."
            return
        }
        let snapshot = savedConversations
        pendingConversationSaveTask?.cancel()
        pendingConversationSaveTask = Task { [weak self, snapshot] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                let normalized = try conversationStore.saveConversations(snapshot)
                guard !Task.isCancelled else { return }
                self.savedConversations = normalized.sorted { $0.updatedAt > $1.updatedAt }
                self.pendingConversationSaveTask = nil
            } catch {
                self.errorMessage = "Failed to persist conversations: \(error.localizedDescription)"
                self.pendingConversationSaveTask = nil
            }
        }
    }

    // MARK: - Private: usage calculations

    private func conversationsSnapshotForUsage(at now: Date) -> [SavedConversation] {
        var snapshot = savedConversations
        guard !messages.isEmpty else { return snapshot }

        if let selectedConversationID,
           let index = snapshot.firstIndex(where: { $0.id == selectedConversationID }) {
            snapshot[index].provider = selectedProvider
            snapshot[index].modelID = modelID
            snapshot[index].updatedAt = now
            snapshot[index].messages = messages
            return snapshot
        }

        snapshot.insert(SavedConversation(
            id: selectedConversationID ?? UUID(),
            provider: selectedProvider,
            title: inferredConversationTitle(),
            updatedAt: now,
            modelID: modelID,
            messages: messages
        ), at: 0)
        return snapshot
    }

    private func usageSummary(
        label: String,
        since: Date,
        now: Date,
        conversations: [SavedConversation]
    ) -> UsageTimeWindowSummary {
        var inputTokens = 0
        var outputTokens = 0
        var estimatedCost = 0.0

        for conversation in conversations {
            for message in conversation.messages where message.role == .assistant {
                let timestamp = message.createdAt ?? conversation.updatedAt
                guard timestamp >= since && timestamp <= now else { continue }
                let input  = max(0, message.inputTokens)
                let output = max(0, message.outputTokens)
                inputTokens  += input
                outputTokens += output
                let modelForMessage = message.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let effectiveModel  = modelForMessage.isEmpty ? conversation.modelID : modelForMessage
                if let cost = TokenCostCalculator.cost(for: effectiveModel, inputTokens: input, outputTokens: output) {
                    estimatedCost += cost
                }
            }
        }
        return UsageTimeWindowSummary(label: label, inputTokens: inputTokens,
                                      outputTokens: outputTokens, estimatedCost: estimatedCost)
    }

}
