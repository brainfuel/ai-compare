import Foundation
import SwiftUI
import Combine

@MainActor
final class PlaygroundViewModel: ObservableObject {
    @AppStorage("gemini_api_key") var apiKey = ""
    @AppStorage("gemini_model_id") var modelID = ModelPreset.geminiFlash.modelID
    @AppStorage("gemini_system_instruction") var systemInstruction = ""
    @AppStorage("gemini_chat_history_v1") private var chatHistoryStore = ""

    @Published var messages: [ChatMessage] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var selectedPreset: ModelPreset = .geminiFlash
    @Published var availableModels: [String] = []
    @Published var savedConversations: [SavedConversation] = []
    @Published var selectedConversationID: UUID?

    private let serviceFactory: (String) -> GeminiServicing

    init(serviceFactory: @escaping (String) -> GeminiServicing = { GeminiClient(apiKey: $0) }) {
        self.serviceFactory = serviceFactory
        selectedPreset = ModelPreset(rawValue: modelID) ?? .custom
        loadSavedConversations()
    }

    func applyPreset(_ preset: ModelPreset) {
        if preset != .custom {
            modelID = preset.modelID
        }
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
        guard !apiKey.isEmpty else {
            errorMessage = "Missing API key."
            return
        }

        do {
            availableModels = try await serviceFactory(apiKey).listGenerateContentModels()
            if !availableModels.contains(modelID), let first = availableModels.first {
                modelID = first
                selectedPreset = .custom
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(text: String, attachments: [PendingAttachment]) async {
        errorMessage = nil
        guard !apiKey.isEmpty else {
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
            let reply = try await serviceFactory(apiKey).generateReply(
                modelID: modelID,
                systemInstruction: systemInstruction,
                messages: messages,
                latestUserAttachments: attachments
            )
            messages.append(ChatMessage(
                role: .assistant,
                text: reply.text,
                attachments: [],
                generatedImages: reply.generatedImages
            ))
            upsertCurrentConversation()
        } catch {
            errorMessage = error.localizedDescription
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
