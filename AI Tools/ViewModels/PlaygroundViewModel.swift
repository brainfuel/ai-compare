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

    @AppStorage("gemini_model_id") private var geminiModelID = "gemini-2.5-flash"
    @AppStorage("openai_model_id") private var openAIModelID = "gpt-4.1-mini"
    @AppStorage("anthropic_model_id") private var anthropicModelID = "claude-3-5-sonnet-latest"
    @AppStorage("grok_model_id") private var grokModelID = "grok-3-mini"
    @AppStorage("gemini_models_cache_v1") private var geminiModelsCache = ""
    @AppStorage("openai_models_cache_v1") private var openAIModelsCache = ""
    @AppStorage("anthropic_models_cache_v1") private var anthropicModelsCache = ""
    @AppStorage("grok_models_cache_v1") private var grokModelsCache = ""

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

    private let serviceFactory: (AIProvider, String) -> GeminiServicing
    private let keychainStore: KeychainStore
    private let conversationStore: ConversationStore?
    private let nowProvider: () -> Date
    private var didAutoLoadModels = false
    private var apiKeysByProvider: [AIProvider: String] = [:]
    private var availableModelsByProvider: [AIProvider: [String]] = [:]
    private var pendingAPIKeyPersistTasks: [AIProvider: Task<Void, Never>] = [:]
    private var pendingConversationSaveTask: Task<Void, Never>?

    init(
        serviceFactory: @escaping (AIProvider, String) -> GeminiServicing = { provider, key in
            switch provider {
            case .gemini:
                return GeminiClient(apiKey: key)
            case .chatGPT:
                return OpenAIClient(apiKey: key)
            case .anthropic:
                return AnthropicClient(apiKey: key)
            case .grok:
                return GrokClient(apiKey: key)
            }
        },
        keychainStore: KeychainStore = KeychainStore(),
        conversationStoreFactory: (() -> ConversationStore?)? = nil,
        nowProvider: @escaping () -> Date = Date.init
        ) {
        self.serviceFactory = serviceFactory
        self.keychainStore = keychainStore
        self.nowProvider = nowProvider
        if let conversationStoreFactory {
            self.conversationStore = conversationStoreFactory()
        } else if let mediaStoreDirectoryURL = Self.makeMediaStoreDirectoryURL() {
            self.conversationStore = ConversationStore(
                mediaStoreDirectoryURL: mediaStoreDirectoryURL
            )
        } else {
            self.conversationStore = nil
        }
        loadAPIKeysFromSecureStorage()
        loadModelCachesFromStorage()
        let provider = AIProvider(rawValue: providerStore) ?? .gemini
        selectedProvider = provider
        modelID = providerModelID(provider)
        availableModels = cachedModels(for: provider, including: modelID)
        Task { [weak self] in
            await self?.loadSavedConversations()
        }
    }

    var providerAPIKeyPlaceholder: String {
        selectedProvider.apiKeyPlaceholder
    }

    var currentAPIKey: String {
        apiKeysByProvider[selectedProvider] ?? ""
    }

    var canSendRequests: Bool {
        selectedProvider.isImplemented
    }

    var canLoadModels: Bool {
        supportsModelLoading(selectedProvider)
    }

    func updateCurrentAPIKey(_ value: String) {
        let provider = selectedProvider
        apiKeysByProvider[provider] = value
        queueAPIKeyPersist(value, for: provider)
    }

    func loadOnLaunchIfNeeded() async {
        guard !didAutoLoadModels else { return }
        didAutoLoadModels = true
        await prefetchModelsOnLaunch()
    }

    func selectProvider(_ provider: AIProvider) async {
        selectedProvider = provider
        providerStore = provider.rawValue
        modelID = providerModelID(provider)
        availableModels = cachedModels(for: provider, including: modelID)
        errorMessage = nil
    }

    func selectModel(_ model: String) {
        if modelID != model {
            modelID = model
        }
        persistCurrentModelID()
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
        availableModels = cachedModels(for: conversation.provider, including: conversation.modelID)
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
        selectedConversationID = imported.id
        selectedProvider = imported.provider
        providerStore = imported.provider.rawValue
        modelID = imported.modelID
        availableModels = cachedModels(for: imported.provider, including: imported.modelID)
        messages = imported.messages
        errorMessage = nil
        persistSavedConversations()
    }

    func filteredConversations(query: String) -> [SavedConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return savedConversations }
        return savedConversations.filter { conversation in
            conversation.searchBlob.localizedCaseInsensitiveContains(needle)
        }
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
            attachments: attachments.map { attachment in
                AttachmentSummary(
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    previewBase64Data: attachment.previewJPEGData?.base64EncodedString()
                )
            }
        ))
        isLoading = true
        streamingText = ""
        defer {
            isLoading = false
            streamingText = ""
        }

        var accumulatedText = ""
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
            for try await chunk in stream {
                accumulatedText += chunk.text
                accumulatedMedia += chunk.generatedMedia
                if chunk.inputTokens > 0 { inputTokens = chunk.inputTokens }
                if chunk.outputTokens > 0 { outputTokens = chunk.outputTokens }
                streamingText = accumulatedText
            }
            let persistedMedia: [GeneratedMedia]
            if let conversationStore {
                persistedMedia = conversationStore.normalizeMedia(accumulatedMedia)
            } else {
                persistedMedia = accumulatedMedia
            }
            let snapshotModelID = modelID
            messages.append(ChatMessage(
                role: .assistant,
                text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                attachments: [],
                generatedMedia: persistedMedia,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                modelID: snapshotModelID
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
            usageSummary(
                label: "24h",
                since: now.addingTimeInterval(-24 * 60 * 60),
                now: now,
                conversations: conversations
            ),
            usageSummary(
                label: "7d",
                since: now.addingTimeInterval(-7 * 24 * 60 * 60),
                now: now,
                conversations: conversations
            ),
            usageSummary(
                label: "30d",
                since: now.addingTimeInterval(-30 * 24 * 60 * 60),
                now: now,
                conversations: conversations
            )
        ]
    }

    private func prefetchModelsOnLaunch() async {
        for provider in AIProvider.allCases where supportsModelLoading(provider) {
            guard !(apiKeysByProvider[provider] ?? "").isEmpty else { continue }
            await fetchModels(for: provider, reportErrorsForSelectedProvider: provider == selectedProvider)
        }
    }

    private func loadAPIKeysFromSecureStorage() {
        for provider in AIProvider.allCases {
            let account = keychainAccount(for: provider)

            if let secureValue = try? keychainStore.string(for: account),
               !secureValue.isEmpty {
                apiKeysByProvider[provider] = secureValue
            } else {
                apiKeysByProvider[provider] = ""
            }
        }
    }

    private func queueAPIKeyPersist(_ value: String, for provider: AIProvider) {
        pendingAPIKeyPersistTasks[provider]?.cancel()
        pendingAPIKeyPersistTasks[provider] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistAPIKey(value, for: provider)
            self.pendingAPIKeyPersistTasks[provider] = nil
        }
    }

    private func persistAPIKey(_ value: String, for provider: AIProvider) {
        do {
            if value.isEmpty {
                try keychainStore.removeValue(for: keychainAccount(for: provider))
            } else {
                try keychainStore.setString(value, for: keychainAccount(for: provider))
            }
        } catch {
            errorMessage = "Failed to persist \(provider.displayName) API key to Keychain: \(error.localizedDescription)"
        }
    }

    private func keychainAccount(for provider: AIProvider) -> String {
        "api-key.\(provider.rawValue)"
    }

    private static func makeMediaStoreDirectoryURL() -> URL? {
        do {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let mediaFolder = appSupport
                .appendingPathComponent("AI Tools", isDirectory: true)
                .appendingPathComponent("media", isDirectory: true)
            try fileManager.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            return mediaFolder
        } catch {
            return nil
        }
    }

    private func persistCurrentModelID() {
        persistModelID(modelID, for: selectedProvider)
    }

    private func persistModelID(_ modelID: String, for provider: AIProvider) {
        switch provider {
        case .gemini:
            geminiModelID = modelID
        case .chatGPT:
            openAIModelID = modelID
        case .anthropic:
            anthropicModelID = modelID
        case .grok:
            grokModelID = modelID
        }
    }

    private func providerModelID(_ provider: AIProvider) -> String {
        switch provider {
        case .gemini:
            return geminiModelID
        case .chatGPT:
            return openAIModelID
        case .anthropic:
            return anthropicModelID
        case .grok:
            return grokModelID
        }
    }

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
        guard let firstUserText = messages.first(where: { $0.role == .user })?.text else {
            return fallback
        }
        let cleaned = firstUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(48))
    }

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

        snapshot.insert(
            SavedConversation(
                id: selectedConversationID ?? UUID(),
                provider: selectedProvider,
                title: inferredConversationTitle(),
                updatedAt: now,
                modelID: modelID,
                messages: messages
            ),
            at: 0
        )
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

                let input = max(0, message.inputTokens)
                let output = max(0, message.outputTokens)
                inputTokens += input
                outputTokens += output

                let messageModel = message.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let effectiveModelID = messageModel.isEmpty ? conversation.modelID : messageModel
                if let messageCost = TokenCostCalculator.cost(
                    for: effectiveModelID,
                    inputTokens: input,
                    outputTokens: output
                ) {
                    estimatedCost += messageCost
                }
            }
        }

        return UsageTimeWindowSummary(
            label: label,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: estimatedCost
        )
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

    private func supportsModelLoading(_ provider: AIProvider) -> Bool {
        provider.isImplemented
    }

    private func fetchModels(for provider: AIProvider, reportErrorsForSelectedProvider: Bool) async {
        guard supportsModelLoading(provider) else { return }
        guard let apiKey = apiKeysByProvider[provider], !apiKey.isEmpty else { return }

        do {
            let fetchedModels = try await serviceFactory(provider, apiKey).listGenerateContentModels()
            updateModelCache(fetchedModels, for: provider)

            let currentProviderModelID = providerModelID(provider)
            if !fetchedModels.contains(currentProviderModelID), let first = fetchedModels.first {
                persistModelID(first, for: provider)
                if provider == selectedProvider {
                    modelID = first
                }
            }

            if provider == selectedProvider {
                availableModels = cachedModels(for: provider, including: modelID)
            }
        } catch {
            if reportErrorsForSelectedProvider && provider == selectedProvider {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadModelCachesFromStorage() {
        availableModelsByProvider[.gemini] = decodeModels(geminiModelsCache)
        availableModelsByProvider[.chatGPT] = decodeModels(openAIModelsCache)
        availableModelsByProvider[.anthropic] = decodeModels(anthropicModelsCache)
        availableModelsByProvider[.grok] = decodeModels(grokModelsCache)
    }

    private func updateModelCache(_ models: [String], for provider: AIProvider) {
        var seen = Set<String>()
        let uniqueModels = models.filter { seen.insert($0).inserted }
        availableModelsByProvider[provider] = uniqueModels

        let encoded = encodeModels(uniqueModels)
        switch provider {
        case .gemini:
            geminiModelsCache = encoded
        case .chatGPT:
            openAIModelsCache = encoded
        case .anthropic:
            anthropicModelsCache = encoded
        case .grok:
            grokModelsCache = encoded
        }
    }

    private func cachedModels(for provider: AIProvider, including model: String? = nil) -> [String] {
        var models = availableModelsByProvider[provider] ?? []
        if models.isEmpty {
            return models
        }

        if let model, !model.isEmpty, !models.contains(model) {
            models.insert(model, at: 0)
        }
        return models
    }

    private func decodeModels(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private func encodeModels(_ models: [String]) -> String {
        guard let data = try? JSONEncoder().encode(models),
              let raw = String(data: data, encoding: .utf8) else {
            return ""
        }
        return raw
    }
}
