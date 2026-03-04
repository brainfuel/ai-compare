import Foundation
import SwiftData

@MainActor
final class ConversationStore {
    private let mediaStoreDirectoryURL: URL
    private let legacyStoreURL: URL
    private let modelContainer: ModelContainer
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init?(legacyStoreURL: URL, mediaStoreDirectoryURL: URL) {
        self.legacyStoreURL = legacyStoreURL
        self.mediaStoreDirectoryURL = mediaStoreDirectoryURL

        do {
            self.modelContainer = try ModelContainer(for: ConversationRecord.self)
        } catch {
            return nil
        }
    }

    func loadConversations() throws -> [SavedConversation] {
        let context = modelContainer.mainContext
        var records = try context.fetch(fetchDescriptor)
        if records.isEmpty {
            try migrateLegacyJSONIfNeeded(context: context)
            records = try context.fetch(fetchDescriptor)
        }

        var didChange = false
        var conversations: [SavedConversation] = []
        conversations.reserveCapacity(records.count)

        for record in records {
            guard let decoded = decodeMessages(from: record.messagesData) else { continue }
            let normalizedMessages = normalizeMessages(decoded)
            let provider = AIProvider(rawValue: record.providerRawValue) ?? AIProvider.inferredProvider(for: record.modelID)
            let conversation = SavedConversation(
                id: record.id,
                provider: provider,
                title: record.title,
                updatedAt: record.updatedAt,
                modelID: record.modelID,
                messages: normalizedMessages.messages
            )
            conversations.append(conversation)

            if normalizedMessages.didChange {
                apply(conversation: conversation, to: record)
                didChange = true
            }
        }

        if didChange {
            try context.save()
        }

        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveConversations(_ conversations: [SavedConversation]) throws -> [SavedConversation] {
        let normalizedResult = normalizeConversations(conversations)
        let normalizedConversations = normalizedResult.conversations
        let context = modelContainer.mainContext
        let existingRecords = try context.fetch(FetchDescriptor<ConversationRecord>())
        var recordsByID = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.id, $0) })

        for conversation in normalizedConversations {
            if let record = recordsByID[conversation.id] {
                apply(conversation: conversation, to: record)
            } else {
                let record = ConversationRecord(
                    id: conversation.id,
                    providerRawValue: conversation.provider.rawValue,
                    title: conversation.title,
                    updatedAt: conversation.updatedAt,
                    modelID: conversation.modelID,
                    searchBlob: conversation.searchBlob,
                    messagesData: try encodeMessages(conversation.messages)
                )
                context.insert(record)
                recordsByID[conversation.id] = record
            }
        }

        let keepIDs = Set(normalizedConversations.map(\.id))
        for record in existingRecords where !keepIDs.contains(record.id) {
            context.delete(record)
        }

        if context.hasChanges {
            try context.save()
        }
        return normalizedConversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func normalizeMedia(_ mediaItems: [GeneratedMedia]) -> [GeneratedMedia] {
        persistGeneratedMediaInPlace(mediaItems).media
    }

    private var fetchDescriptor: FetchDescriptor<ConversationRecord> {
        FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
    }

    private func migrateLegacyJSONIfNeeded(context: ModelContext) throws {
        guard FileManager.default.fileExists(atPath: legacyStoreURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyStoreURL),
              let decoded = try? JSONDecoder().decode([SavedConversation].self, from: data),
              !decoded.isEmpty else {
            return
        }

        let normalized = normalizeConversations(decoded).conversations
        for conversation in normalized {
            let record = ConversationRecord(
                id: conversation.id,
                providerRawValue: conversation.provider.rawValue,
                title: conversation.title,
                updatedAt: conversation.updatedAt,
                modelID: conversation.modelID,
                searchBlob: conversation.searchBlob,
                messagesData: try encodeMessages(conversation.messages)
            )
            context.insert(record)
        }
        if context.hasChanges {
            try context.save()
        }
    }

    private func apply(conversation: SavedConversation, to record: ConversationRecord) {
        record.providerRawValue = conversation.provider.rawValue
        record.title = conversation.title
        record.updatedAt = conversation.updatedAt
        record.modelID = conversation.modelID
        record.searchBlob = conversation.searchBlob
        record.messagesData = (try? encodeMessages(conversation.messages)) ?? record.messagesData
    }

    private func decodeMessages(from data: Data) -> [ChatMessage]? {
        try? decoder.decode([ChatMessage].self, from: data)
    }

    private func encodeMessages(_ messages: [ChatMessage]) throws -> Data {
        try encoder.encode(messages)
    }

    private func normalizeConversations(_ conversations: [SavedConversation]) -> (conversations: [SavedConversation], didChange: Bool) {
        var didChange = false
        let normalized = conversations.map { conversation in
            var mutable = conversation
            let normalizedMessages = normalizeMessages(conversation.messages)
            mutable.messages = normalizedMessages.messages
            didChange = didChange || normalizedMessages.didChange
            return mutable
        }
        return (normalized, didChange)
    }

    private func normalizeMessages(_ messages: [ChatMessage]) -> (messages: [ChatMessage], didChange: Bool) {
        var didChange = false
        let normalized = messages.map { message in
            let normalizedMedia = persistGeneratedMediaInPlace(message.generatedMedia)
            didChange = didChange || normalizedMedia.didChange
            if normalizedMedia.didChange {
                return ChatMessage(
                    id: message.id,
                    role: message.role,
                    text: message.text,
                    attachments: message.attachments,
                    generatedMedia: normalizedMedia.media
                )
            }
            return message
        }
        return (normalized, didChange)
    }

    private func persistGeneratedMediaInPlace(_ mediaItems: [GeneratedMedia]) -> (media: [GeneratedMedia], didChange: Bool) {
        guard !mediaItems.isEmpty else { return (mediaItems, false) }

        var didChange = false
        var normalized: [GeneratedMedia] = []
        normalized.reserveCapacity(mediaItems.count)

        for media in mediaItems {
            guard let base64 = media.base64Data, !base64.isEmpty else {
                normalized.append(media)
                continue
            }

            guard let data = Data(base64Encoded: base64) else {
                normalized.append(media)
                continue
            }

            let fileURL = mediaStoreDirectoryURL
                .appendingPathComponent(media.id.uuidString)
                .appendingPathExtension(media.mimeType.fileExtensionHint)

            do {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try data.write(to: fileURL, options: .atomic)
                }
                normalized.append(
                    GeneratedMedia(
                        id: media.id,
                        kind: media.kind,
                        mimeType: media.mimeType,
                        base64Data: nil,
                        remoteURL: fileURL
                    )
                )
                didChange = true
            } catch {
                normalized.append(media)
            }
        }

        return (normalized, didChange)
    }
}

@Model
final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var providerRawValue: String
    var title: String
    var updatedAt: Date
    var modelID: String
    var searchBlob: String
    var messagesData: Data

    init(
        id: UUID,
        providerRawValue: String,
        title: String,
        updatedAt: Date,
        modelID: String,
        searchBlob: String,
        messagesData: Data
    ) {
        self.id = id
        self.providerRawValue = providerRawValue
        self.title = title
        self.updatedAt = updatedAt
        self.modelID = modelID
        self.searchBlob = searchBlob
        self.messagesData = messagesData
    }
}

private extension String {
    var fileExtensionHint: String {
        let parts = split(separator: "/")
        guard let last = parts.last else { return "bin" }
        let cleaned = String(last).replacingOccurrences(of: "+xml", with: "")
        return cleaned.isEmpty ? "bin" : cleaned
    }
}
