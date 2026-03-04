import Foundation
import SwiftUI
import Combine

@MainActor
final class PlaygroundViewModel: ObservableObject {
    @AppStorage("ai_provider") private var providerStore = AIProvider.gemini.rawValue

    @AppStorage("gemini_model_id") private var geminiModelID = "gemini-2.5-flash"
    @AppStorage("openai_model_id") private var openAIModelID = "gpt-4.1-mini"
    @AppStorage("anthropic_model_id") private var anthropicModelID = "claude-3-5-sonnet-latest"
    @AppStorage("gemini_models_cache_v1") private var geminiModelsCache = ""
    @AppStorage("openai_models_cache_v1") private var openAIModelsCache = ""
    @AppStorage("anthropic_models_cache_v1") private var anthropicModelsCache = ""

    @AppStorage("gemini_system_instruction") var systemInstruction = ""

    @Published var messages: [ChatMessage] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var selectedProvider: AIProvider = .gemini
    @Published var modelID: String = "gemini-2.5-flash"
    @Published var availableModels: [String] = []
    @Published var savedConversations: [SavedConversation] = []
    @Published var selectedConversationID: UUID?

    private let serviceFactory: (AIProvider, String) -> GeminiServicing
    private let keychainStore: KeychainStore
    private let conversationStore: ConversationStore?
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
            }
        },
        keychainStore: KeychainStore = KeychainStore()
        ) {
        self.serviceFactory = serviceFactory
        self.keychainStore = keychainStore
        if let mediaStoreDirectoryURL = Self.makeMediaStoreDirectoryURL() {
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
        selectedProvider == .gemini || selectedProvider == .chatGPT || selectedProvider == .anthropic
    }

    func updateCurrentAPIKey(_ value: String) {
        let provider = selectedProvider
        apiKeysByProvider[provider] = value
        queueAPIKeyPersist(value, for: provider)
    }

    func loadOnLaunchIfNeeded() async {
        guard !didAutoLoadModels else { return }
        didAutoLoadModels = true
        await autoLoadModelsIfPossible()
    }

    func selectProvider(_ provider: AIProvider) async {
        selectedProvider = provider
        providerStore = provider.rawValue
        modelID = providerModelID(provider)
        availableModels = []
        errorMessage = nil
        await autoLoadModelsIfPossible()
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

        let providerChanged = selectedProvider != conversation.provider
        selectedProvider = conversation.provider
        providerStore = conversation.provider.rawValue
        if providerChanged {
            availableModels = []
        }
        modelID = conversation.modelID
        persistCurrentModelID()
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

    func filteredConversations(query: String) -> [SavedConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return savedConversations }
        return savedConversations.filter { conversation in
            conversation.searchBlob.localizedCaseInsensitiveContains(needle)
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

        do {
            availableModels = try await serviceFactory(selectedProvider, currentAPIKey).listGenerateContentModels()
            if !availableModels.contains(modelID), let first = availableModels.first {
                modelID = first
                persistCurrentModelID()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(text: String, attachments: [PendingAttachment]) async {
        errorMessage = nil
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
            attachments: attachments.map { AttachmentSummary(name: $0.name) }
        ))
        isLoading = true
        defer { isLoading = false }

        do {
            let reply = try await serviceFactory(selectedProvider, currentAPIKey).generateReply(
                modelID: modelID,
                systemInstruction: systemInstruction,
                messages: messages,
                latestUserAttachments: attachments
            )
            let persistedMedia: [GeneratedMedia]
            if let conversationStore {
                persistedMedia = conversationStore.normalizeMedia(reply.generatedMedia)
            } else {
                persistedMedia = reply.generatedMedia
            }
            messages.append(ChatMessage(
                role: .assistant,
                text: reply.text,
                attachments: [],
                generatedMedia: persistedMedia
            ))
            upsertCurrentConversation()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        switch selectedProvider {
        case .gemini:
            geminiModelID = modelID
        case .chatGPT:
            openAIModelID = modelID
        case .anthropic:
            anthropicModelID = modelID
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
}
