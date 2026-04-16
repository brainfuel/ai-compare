import Foundation
import SwiftUI
import Combine

@MainActor
final class CompareViewModel: ObservableObject {
    @AppStorage("gemini_model_id") private var geminiModelID = "gemini-2.5-flash"
    @AppStorage("openai_model_id") private var openAIModelID = "gpt-4.1-mini"
    @AppStorage("anthropic_model_id") private var anthropicModelID = "claude-3-5-sonnet-latest"
    @AppStorage("grok_model_id") private var grokModelID = "grok-3-mini"
    @AppStorage("gemini_models_cache_v1") private var geminiModelsCache = ""
    @AppStorage("openai_models_cache_v1") private var openAIModelsCache = ""
    @AppStorage("anthropic_models_cache_v1") private var anthropicModelsCache = ""
    @AppStorage("grok_models_cache_v1") private var grokModelsCache = ""
    @AppStorage("compare_conversations_v1") private var compareConversationsStore = ""

    @Published var savedConversations: [CompareConversation] = []
    @Published var selectedConversationID: UUID?
    @Published var runs: [CompareRun] = []
    @Published var errorMessage: String?
    @Published private(set) var isSending = false
    @Published var pendingAttachments: [PendingAttachment] = []

    @Published private var selectedModelsByProvider: [AIProvider: String] = [:]
    @Published private var availableModelsByProvider: [AIProvider: [String]] = [:]
    @Published private var apiKeysByProvider: [AIProvider: String] = [:]
    @Published private var providerStatusByProvider: [AIProvider: String] = [:]
    private var didAutoLoadModels = false

    private let serviceFactory: (AIProvider, String) -> GeminiServicing
    private let keychainStore: KeychainStore

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
        keychainStore: KeychainStore = KeychainStore()
    ) {
        self.serviceFactory = serviceFactory
        self.keychainStore = keychainStore
        loadSavedConversations()
        reloadFromStorage(includeSecureStorage: true)
    }

    var composerStatusLabel: String {
        let ready = readyProviders
        if ready.isEmpty {
            return "No providers ready. Add keys in Single mode."
        }
        let names = ready.map(\.displayName).joined(separator: ", ")
        return "Ready: \(names)"
    }

    var readyProviders: [AIProvider] {
        AIProvider.allCases.filter { provider in
            hasAPIKey(for: provider) && !selectedModel(for: provider).isEmpty
        }
    }

    var runsChronological: [CompareRun] {
        runs.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func loadOnLaunchIfNeeded() async {
        guard !didAutoLoadModels else { return }
        didAutoLoadModels = true
        reloadFromStorage()
        for provider in AIProvider.allCases where hasAPIKey(for: provider) {
            await fetchModels(for: provider, reportErrors: false)
        }
    }

    func reloadFromStorage(includeSecureStorage: Bool = false) {
        if includeSecureStorage {
            loadAPIKeysFromSecureStorage()
        }
        loadSelectedModelsFromStorage()
        loadModelCachesFromStorage()
        if let selectedConversationID {
            if let conversation = savedConversations.first(where: { $0.id == selectedConversationID }) {
                runs = conversation.runs
            } else {
                self.selectedConversationID = nil
            }
        }
    }

    func startNewThread() {
        selectedConversationID = nil
        runs.removeAll()
        errorMessage = nil
    }

    func selectConversation(_ id: UUID?) {
        selectedConversationID = id
        guard let id,
              let conversation = savedConversations.first(where: { $0.id == id }) else {
            runs.removeAll()
            errorMessage = nil
            return
        }
        runs = conversation.runs
        errorMessage = nil
    }

    func deleteSelectedConversation() {
        guard let id = selectedConversationID else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            savedConversations.removeAll { $0.id == id }
            selectedConversationID = nil
            runs.removeAll()
        }
        persistSavedConversations()
    }

    func filteredConversations(query: String) -> [CompareConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return savedConversations }
        return savedConversations.filter { conversation in
            conversation.searchBlob.localizedCaseInsensitiveContains(needle)
        }
    }

    func selectedModel(for provider: AIProvider) -> String {
        selectedModelsByProvider[provider] ?? ""
    }

    func selectModel(_ model: String, for provider: AIProvider) {
        selectedModelsByProvider[provider] = model
        persistSelectedModel(model, for: provider)
    }

    func modelsForPicker(for provider: AIProvider) -> [String] {
        let cached = availableModelsByProvider[provider] ?? []
        let selected = selectedModel(for: provider)
        guard !selected.isEmpty else { return cached }
        if cached.contains(selected) {
            return cached
        }
        return [selected] + cached
    }

    func providerStatusMessage(_ provider: AIProvider) -> String? {
        if let status = providerStatusByProvider[provider], !status.isEmpty {
            return status
        }
        if !hasAPIKey(for: provider) {
            return "Set \(provider.displayName) API key in Single mode."
        }
        return nil
    }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        !(apiKeysByProvider[provider] ?? "").isEmpty
    }

    func canContinueInSingle(for provider: AIProvider) -> Bool {
        let selected = selectedModel(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return false }
        return !singleChatMessages(for: provider).isEmpty
    }

    func makeSingleConversation(for provider: AIProvider) -> SavedConversation? {
        let messages = singleChatMessages(for: provider)
        guard !messages.isEmpty else { return nil }

        let selected = selectedModel(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackModel = runs
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { run -> String? in
                guard let result = run.results[provider] else { return nil }
                let model = result.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty else { return nil }
                return model
            }
            .last
        let modelID = !selected.isEmpty ? selected : (fallbackModel ?? "")
        guard !modelID.isEmpty else {
            return nil
        }

        let titleSeed = messages.first(where: { $0.role == .user })?.text ?? "\(provider.displayName) Thread"
        return SavedConversation(
            id: UUID(),
            provider: provider,
            title: makeTitle(from: titleSeed),
            updatedAt: Date(),
            modelID: modelID,
            messages: messages
        )
    }

    func refreshModels(for provider: AIProvider) async {
        await fetchModels(for: provider, reportErrors: true)
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

    func sendCompare(text: String) async {
        errorMessage = nil
        let attachments = pendingAttachments
        pendingAttachments = []

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !attachments.isEmpty else { return }

        let providers = readyProviders
        guard !providers.isEmpty else {
            errorMessage = "No provider is ready. Add at least one API key in Single mode."
            return
        }

        let prompt = normalizedText.isEmpty ? "(Attachment only)" : normalizedText
        let summaries = attachments.map { attachment in
            AttachmentSummary(
                name: attachment.name,
                mimeType: attachment.mimeType,
                previewBase64Data: attachment.previewJPEGData?.base64EncodedString()
            )
        }

        var initialResults: [AIProvider: CompareProviderResult] = [:]
        for provider in AIProvider.allCases {
            if providers.contains(provider) {
                initialResults[provider] = CompareProviderResult(
                    state: .loading,
                    modelID: selectedModel(for: provider),
                    text: "",
                    generatedMedia: [],
                    inputTokens: 0,
                    outputTokens: 0,
                    errorMessage: nil
                )
            } else {
                let skippedReason = hasAPIKey(for: provider)
                    ? "No model selected."
                    : "Missing API key."
                initialResults[provider] = CompareProviderResult(
                    state: .skipped,
                    modelID: selectedModel(for: provider),
                    text: "",
                    generatedMedia: [],
                    inputTokens: 0,
                    outputTokens: 0,
                    errorMessage: skippedReason
                )
            }
        }

        let run = CompareRun(
            id: UUID(),
            prompt: prompt,
            attachments: summaries,
            createdAt: Date(),
            results: initialResults
        )
        runs.insert(run, at: 0)
        upsertCurrentConversation()

        let runID = run.id
        isSending = true

        let tasks = providers.map { provider in
            Task { [weak self] in
                await self?.executeRun(for: provider, runID: runID, prompt: prompt, attachments: attachments)
            }
        }
        for task in tasks {
            await task.value
        }

        isSending = false
        upsertCurrentConversation()
    }

    private func executeRun(
        for provider: AIProvider,
        runID: UUID,
        prompt: String,
        attachments: [PendingAttachment]
    ) async {
        let apiKey = apiKeysByProvider[provider] ?? ""
        let model = selectedModel(for: provider)

        var accumulatedText = ""
        var accumulatedMedia: [GeneratedMedia] = []
        var inputTokens = 0
        var outputTokens = 0

        do {
            let priorRunsOldestFirst = runs.filter { $0.id != runID }.reversed()
            var messages: [ChatMessage] = []
            for priorRun in priorRunsOldestFirst {
                messages.append(ChatMessage(role: .user, text: priorRun.prompt, attachments: priorRun.attachments))
                if let result = priorRun.results[provider], result.state == .success, !result.text.isEmpty {
                    messages.append(ChatMessage(role: .assistant, text: result.text, attachments: []))
                }
            }
            messages.append(ChatMessage(
                role: .user,
                text: prompt,
                attachments: attachments.map {
                    AttachmentSummary(
                        name: $0.name,
                        mimeType: $0.mimeType,
                        previewBase64Data: $0.previewJPEGData?.base64EncodedString()
                    )
                }
            ))

            let stream = serviceFactory(provider, apiKey).generateReplyStream(
                modelID: model,
                systemInstruction: "",
                messages: messages,
                latestUserAttachments: attachments
            )

            for try await chunk in stream {
                accumulatedText += chunk.text
                accumulatedMedia += chunk.generatedMedia
                if chunk.inputTokens > 0 { inputTokens = chunk.inputTokens }
                if chunk.outputTokens > 0 { outputTokens = chunk.outputTokens }

                updateRun(
                    runID: runID,
                    provider: provider,
                    result: CompareProviderResult(
                        state: .loading,
                        modelID: model,
                        text: accumulatedText,
                        generatedMedia: accumulatedMedia,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        errorMessage: nil
                    )
                )
            }

            updateRun(
                runID: runID,
                provider: provider,
                result: CompareProviderResult(
                    state: .success,
                    modelID: model,
                    text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                    generatedMedia: accumulatedMedia,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    errorMessage: nil
                )
            )
        } catch {
            updateRun(
                runID: runID,
                provider: provider,
                result: CompareProviderResult(
                    state: .failed,
                    modelID: model,
                    text: "",
                    generatedMedia: [],
                    inputTokens: 0,
                    outputTokens: 0,
                    errorMessage: error.localizedDescription
                )
            )
        }
    }

    private func updateRun(
        runID: UUID,
        provider: AIProvider,
        result: CompareProviderResult
    ) {
        guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { return }
        var run = runs[runIndex]
        run.results[provider] = result
        runs[runIndex] = run
    }

    private func fetchModels(for provider: AIProvider, reportErrors: Bool) async {
        let apiKey = apiKeysByProvider[provider] ?? ""
        guard !apiKey.isEmpty else {
            if reportErrors {
                providerStatusByProvider[provider] = "Missing API key."
            }
            return
        }

        do {
            let models = try await serviceFactory(provider, apiKey).listGenerateContentModels()
            let uniqueSorted = Array(Set(models)).sorted()
            availableModelsByProvider[provider] = uniqueSorted
            persistModelCache(uniqueSorted, for: provider)

            if !uniqueSorted.contains(selectedModel(for: provider)) {
                if let first = uniqueSorted.first {
                    selectModel(first, for: provider)
                }
            }

            providerStatusByProvider[provider] = uniqueSorted.isEmpty
                ? "No models returned."
                : "Loaded \(uniqueSorted.count) model(s)."
        } catch {
            if reportErrors {
                providerStatusByProvider[provider] = error.localizedDescription
            }
        }
    }

    private func loadAPIKeysFromSecureStorage() {
        for provider in AIProvider.allCases {
            let account = "api-key.\(provider.rawValue)"
            if let secureValue = try? keychainStore.string(for: account),
               !secureValue.isEmpty {
                apiKeysByProvider[provider] = secureValue
            } else {
                apiKeysByProvider[provider] = ""
            }
        }
    }

    private func loadSelectedModelsFromStorage() {
        selectedModelsByProvider[.gemini] = geminiModelID
        selectedModelsByProvider[.chatGPT] = openAIModelID
        selectedModelsByProvider[.anthropic] = anthropicModelID
        selectedModelsByProvider[.grok] = grokModelID
    }

    private func persistSelectedModel(_ model: String, for provider: AIProvider) {
        switch provider {
        case .gemini:
            geminiModelID = model
        case .chatGPT:
            openAIModelID = model
        case .anthropic:
            anthropicModelID = model
        case .grok:
            grokModelID = model
        }
    }

    private func loadModelCachesFromStorage() {
        availableModelsByProvider[.gemini] = decodeModelCache(geminiModelsCache)
        availableModelsByProvider[.chatGPT] = decodeModelCache(openAIModelsCache)
        availableModelsByProvider[.anthropic] = decodeModelCache(anthropicModelsCache)
        availableModelsByProvider[.grok] = decodeModelCache(grokModelsCache)
    }

    private func persistModelCache(_ models: [String], for provider: AIProvider) {
        guard let data = try? JSONEncoder().encode(models),
              let encoded = String(data: data, encoding: .utf8) else { return }
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

    private func decodeModelCache(_ value: String) -> [String] {
        guard !value.isEmpty,
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private func singleChatMessages(for provider: AIProvider) -> [ChatMessage] {
        let orderedRuns = runs.sorted { $0.createdAt < $1.createdAt }
        var messages: [ChatMessage] = []

        for run in orderedRuns {
            guard let result = run.results[provider], result.state != .skipped else {
                continue
            }

            messages.append(
                ChatMessage(
                    role: .user,
                    text: run.prompt,
                    createdAt: run.createdAt,
                    attachments: run.attachments
                )
            )

            let responseText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasAssistantPayload = !responseText.isEmpty ||
                !result.generatedMedia.isEmpty ||
                result.inputTokens > 0 ||
                result.outputTokens > 0
            guard hasAssistantPayload else {
                continue
            }

            messages.append(
                ChatMessage(
                    role: .assistant,
                    text: responseText,
                    createdAt: run.createdAt.addingTimeInterval(0.001),
                    attachments: [],
                    generatedMedia: result.generatedMedia,
                    inputTokens: result.inputTokens,
                    outputTokens: result.outputTokens,
                    modelID: result.modelID.isEmpty ? nil : result.modelID
                )
            )
        }

        return messages
    }

    private func upsertCurrentConversation() {
        guard !runs.isEmpty else { return }

        let title = makeTitle(from: runs.first?.prompt ?? "Compare")
        let now = Date()

        if let id = selectedConversationID,
           let index = savedConversations.firstIndex(where: { $0.id == id }) {
            savedConversations[index].runs = runs
            savedConversations[index].title = title
            savedConversations[index].updatedAt = now
        } else {
            let id = UUID()
            let conversation = CompareConversation(
                id: id,
                title: title,
                updatedAt: now,
                runs: runs
            )
            savedConversations.insert(conversation, at: 0)
            selectedConversationID = id
        }

        savedConversations.sort { $0.updatedAt > $1.updatedAt }
        persistSavedConversations()
    }

    private func makeTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Compare Thread" }
        let compact = trimmed.replacingOccurrences(of: "\n", with: " ")
        return compact.count > 44 ? String(compact.prefix(44)) + "..." : compact
    }

    private func loadSavedConversations() {
        guard !compareConversationsStore.isEmpty,
              let data = compareConversationsStore.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CompareConversation].self, from: data) else {
            savedConversations = []
            return
        }
        savedConversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistSavedConversations() {
        guard let data = try? JSONEncoder().encode(savedConversations),
              let encoded = String(data: data, encoding: .utf8) else { return }
        compareConversationsStore = encoded
    }
}
