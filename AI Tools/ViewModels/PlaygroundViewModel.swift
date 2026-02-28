import Foundation
import SwiftUI
import Combine

@MainActor
final class PlaygroundViewModel: ObservableObject {
    @AppStorage("ai_provider") private var providerStore = AIProvider.gemini.rawValue
    @AppStorage("gemini_api_key") private var geminiAPIKey = ""
    @AppStorage("openai_api_key") private var openAIAPIKey = ""
    @AppStorage("anthropic_api_key") private var anthropicAPIKey = ""

    @AppStorage("gemini_model_id") private var geminiModelID = ModelPreset.geminiFlash.modelID
    @AppStorage("openai_model_id") private var openAIModelID = "gpt-4.1-mini"
    @AppStorage("anthropic_model_id") private var anthropicModelID = "claude-3-5-sonnet-latest"

    @AppStorage("gemini_system_instruction") var systemInstruction = ""
    @AppStorage("gemini_chat_history_v1") private var chatHistoryStore = ""

    @Published var messages: [ChatMessage] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var selectedProvider: AIProvider = .gemini
    @Published var modelID: String = ModelPreset.geminiFlash.modelID
    @Published var selectedPreset: ModelPreset = .geminiFlash
    @Published var availableModels: [String] = []
    @Published var savedConversations: [SavedConversation] = []
    @Published var selectedConversationID: UUID?

    private let serviceFactory: (AIProvider, String) -> GeminiServicing
    private var didAutoLoadModels = false

    init(serviceFactory: @escaping (AIProvider, String) -> GeminiServicing = { provider, key in
        switch provider {
        case .gemini:
            return GeminiClient(apiKey: key)
        case .chatGPT:
            return OpenAIClient(apiKey: key)
        case .anthropic:
            return AnthropicClient(apiKey: key)
        }
    }) {
        self.serviceFactory = serviceFactory
        let provider = AIProvider(rawValue: providerStore) ?? .gemini
        selectedProvider = provider
        modelID = providerModelID(provider)
        selectedPreset = ModelPreset(rawValue: modelID) ?? .custom
        loadSavedConversations()
    }

    var providerAPIKeyPlaceholder: String {
        selectedProvider.apiKeyPlaceholder
    }

    var currentAPIKey: String {
        switch selectedProvider {
        case .gemini:
            return geminiAPIKey
        case .chatGPT:
            return openAIAPIKey
        case .anthropic:
            return anthropicAPIKey
        }
    }

    var canSendRequests: Bool {
        selectedProvider.isImplemented
    }

    var canLoadModels: Bool {
        selectedProvider == .gemini || selectedProvider == .chatGPT || selectedProvider == .anthropic
    }

    func updateCurrentAPIKey(_ value: String) {
        switch selectedProvider {
        case .gemini:
            geminiAPIKey = value
        case .chatGPT:
            openAIAPIKey = value
        case .anthropic:
            anthropicAPIKey = value
        }
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
        selectedPreset = ModelPreset(rawValue: modelID) ?? .custom
        availableModels = []
        errorMessage = nil
        await autoLoadModelsIfPossible()
    }

    func applyPreset(_ preset: ModelPreset) {
        if preset != .custom {
            modelID = preset.modelID
            persistCurrentModelID()
        }
    }

    func modelIDDidChange() {
        persistCurrentModelID()
        selectedPreset = ModelPreset(rawValue: modelID) ?? .custom
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

        modelID = conversation.modelID
        selectedPreset = ModelPreset(rawValue: modelID) ?? .custom
        persistCurrentModelID()
        messages = conversation.messages
        errorMessage = nil
    }

    func deleteSelectedConversation() {
        guard let id = selectedConversationID else { return }
        savedConversations.removeAll { $0.id == id }
        selectedConversationID = nil
        messages.removeAll()
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
            errorMessage = "Model loading is currently implemented for Gemini."
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
                selectedPreset = .custom
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
            messages.append(ChatMessage(
                role: .assistant,
                text: reply.text,
                attachments: [],
                generatedMedia: reply.generatedMedia
            ))
            upsertCurrentConversation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func autoLoadModelsIfPossible() async {
        guard canLoadModels else { return }
        guard !currentAPIKey.isEmpty else { return }
        await refreshModels()
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
            title: inferredConversationTitle(),
            updatedAt: Date(),
            modelID: modelID,
            messages: messages
        )
        selectedConversationID = conversation.id
        savedConversations.insert(conversation, at: 0)
        persistSavedConversations()
    }

    private func updateConversation(id: UUID) {
        guard let index = savedConversations.firstIndex(where: { $0.id == id }) else { return }
        savedConversations[index].updatedAt = Date()
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

    private func loadSavedConversations() {
        guard !chatHistoryStore.isEmpty,
              let data = chatHistoryStore.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SavedConversation].self, from: data) else {
            savedConversations = []
            return
        }
        savedConversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistSavedConversations() {
        guard let data = try? JSONEncoder().encode(savedConversations),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        chatHistoryStore = string
    }
}
