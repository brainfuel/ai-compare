import SwiftData
import Foundation

// MARK: - Chat conversation models

@Model
final class ConversationRecord {
    var id: UUID
    var providerRaw: String
    var title: String
    var updatedAt: Date
    var modelID: String
    @Relationship(deleteRule: .cascade, inverse: \MessageRecord.conversation)
    var messages: [MessageRecord] = []

    init(id: UUID, providerRaw: String, title: String, updatedAt: Date, modelID: String) {
        self.id = id
        self.providerRaw = providerRaw
        self.title = title
        self.updatedAt = updatedAt
        self.modelID = modelID
    }

    func toStruct(decoder: JSONDecoder) -> SavedConversation {
        let msgs = messages
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            .map { $0.toStruct(decoder: decoder) }
        return SavedConversation(
            id: id,
            provider: AIProvider(rawValue: providerRaw) ?? .gemini,
            title: title,
            updatedAt: updatedAt,
            modelID: modelID,
            messages: msgs
        )
    }
}

@Model
final class MessageRecord {
    var id: UUID
    var roleRaw: String
    var text: String
    var createdAt: Date?
    /// JSON-encoded [AttachmentSummary]
    var attachmentsData: Data
    /// JSON-encoded [GeneratedMedia]
    var generatedMediaData: Data
    var inputTokens: Int
    var outputTokens: Int
    var modelID: String?
    var conversation: ConversationRecord?

    init(
        id: UUID, roleRaw: String, text: String, createdAt: Date?,
        attachmentsData: Data, generatedMediaData: Data,
        inputTokens: Int, outputTokens: Int, modelID: String?
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.text = text
        self.createdAt = createdAt
        self.attachmentsData = attachmentsData
        self.generatedMediaData = generatedMediaData
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.modelID = modelID
    }

    func toStruct(decoder: JSONDecoder) -> ChatMessage {
        let attachments = (try? decoder.decode([AttachmentSummary].self, from: attachmentsData)) ?? []
        let media       = (try? decoder.decode([GeneratedMedia].self,    from: generatedMediaData)) ?? []
        return ChatMessage(
            id: id,
            role: MessageRole(rawValue: roleRaw) ?? .user,
            text: text,
            createdAt: createdAt,
            attachments: attachments,
            generatedMedia: media,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            modelID: modelID
        )
    }
}

// MARK: - Compare conversation models

@Model
final class CompareConversationRecord {
    var id: UUID
    var title: String
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \CompareRunRecord.conversation)
    var runs: [CompareRunRecord] = []

    init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    func toStruct(decoder: JSONDecoder) -> CompareConversation {
        let r = runs
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { $0.toStruct(decoder: decoder) }
        let cachedSynthesis = cachedSynthesisData.flatMap {
            try? decoder.decode(CachedSynthesis.self, from: $0)
        }
        let cachedCustomResults = cachedCustomResultsData.flatMap {
            try? decoder.decode([CachedCustomSynthesis].self, from: $0)
        }
        return CompareConversation(
            id: id, title: title, updatedAt: updatedAt, runs: r,
            cachedSynthesis: cachedSynthesis,
            cachedCustomResults: cachedCustomResults
        )
    }
}

@Model
final class CompareRunRecord {
    var id: UUID
    var prompt: String
    /// JSON-encoded [AttachmentSummary]
    var attachmentsData: Data
    var createdAt: Date
    /// JSON-encoded [AIProvider: CompareProviderResult]
    var resultsData: Data
    var conversation: CompareConversationRecord?

    init(id: UUID, prompt: String, attachmentsData: Data, createdAt: Date, resultsData: Data) {
        self.id = id
        self.prompt = prompt
        self.attachmentsData = attachmentsData
        self.createdAt = createdAt
        self.resultsData = resultsData
    }

    func toStruct(decoder: JSONDecoder) -> CompareRun? {
        let attachments = (try? decoder.decode([AttachmentSummary].self, from: attachmentsData)) ?? []
        guard let results = try? decoder.decode([AIProvider: CompareProviderResult].self, from: resultsData) else {
            return nil
        }
        return CompareRun(id: id, prompt: prompt, attachments: attachments, createdAt: createdAt, results: results)
    }
}
