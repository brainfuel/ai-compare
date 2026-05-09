import Foundation
import SwiftData

@MainActor
final class CompareConversationStore {
    private let context: ModelContext
    private let mediaStoreDirectoryURL: URL?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(context: ModelContext, mediaStoreDirectoryURL: URL? = nil) {
        self.context = context
        self.mediaStoreDirectoryURL = mediaStoreDirectoryURL
        if let url = mediaStoreDirectoryURL {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        migrateFromAppStorageIfNeeded()
    }

    // MARK: - Public API

    func loadConversations() throws -> [CompareConversation] {
        let descriptor = FetchDescriptor<CompareConversationRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map { $0.toStruct(decoder: decoder) }
    }

    func saveConversations(_ conversations: [CompareConversation]) throws -> [CompareConversation] {
        let existing    = try context.fetch(FetchDescriptor<CompareConversationRecord>())
        let byID        = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let snapshotIDs = Set(conversations.map(\.id))

        for record in existing where !snapshotIDs.contains(record.id) {
            context.delete(record) // cascades to CompareRunRecords
        }
        for conversation in conversations {
            if let record = byID[conversation.id] {
                upsertRecord(record, from: conversation)
            } else {
                context.insert(makeRecord(from: conversation))
            }
        }
        try context.save()
        return try loadConversations()
    }

    func normalizeMedia(_ mediaItems: [GeneratedMedia]) -> [GeneratedMedia] {
        guard let dir = mediaStoreDirectoryURL else { return mediaItems }
        return persistGeneratedMediaInPlace(mediaItems, directory: dir)
    }

    // MARK: - Record construction

    private func makeRecord(from conversation: CompareConversation) -> CompareConversationRecord {
        let record = CompareConversationRecord(
            id: conversation.id, title: conversation.title, updatedAt: conversation.updatedAt
        )
        record.runs = conversation.runs.map { makeRunRecord(from: $0) }
        record.cachedSynthesisData = conversation.cachedSynthesis.flatMap { try? encoder.encode($0) }
        record.cachedCustomResultsData = conversation.cachedCustomResults.flatMap { try? encoder.encode($0) }
        return record
    }

    private func makeRunRecord(from run: CompareRun) -> CompareRunRecord {
        CompareRunRecord(
            id: run.id,
            prompt: run.prompt,
            attachmentsData: (try? encoder.encode(run.attachments)) ?? Data(),
            createdAt: run.createdAt,
            resultsData: (try? encoder.encode(run.results)) ?? Data()
        )
    }

    private func upsertRecord(_ record: CompareConversationRecord, from conversation: CompareConversation) {
        record.title     = conversation.title
        record.updatedAt = conversation.updatedAt
        record.cachedSynthesisData = conversation.cachedSynthesis.flatMap { try? encoder.encode($0) }
        record.cachedCustomResultsData = conversation.cachedCustomResults.flatMap { try? encoder.encode($0) }

        let existingByID = Dictionary(uniqueKeysWithValues: record.runs.map { ($0.id, $0) })
        let newIDs       = Set(conversation.runs.map(\.id))

        for run in record.runs where !newIDs.contains(run.id) {
            context.delete(run)
        }
        for run in conversation.runs {
            if let existing = existingByID[run.id] {
                existing.resultsData = (try? encoder.encode(run.results)) ?? existing.resultsData
            } else {
                let runRecord = makeRunRecord(from: run)
                runRecord.conversation = record
                context.insert(runRecord)
            }
        }
    }

    // MARK: - Media persistence

    private func persistGeneratedMediaInPlace(_ mediaItems: [GeneratedMedia], directory: URL) -> [GeneratedMedia] {
        mediaItems.map { media in
            guard let base64 = media.base64Data, !base64.isEmpty,
                  let data = Data(base64Encoded: base64) else { return media }
            let fileURL = directory
                .appendingPathComponent(media.id.uuidString)
                .appendingPathExtension(media.mimeType.fileExtensionHint)
            do {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try data.write(to: fileURL, options: .atomic)
                }
                return GeneratedMedia(id: media.id, kind: media.kind, mimeType: media.mimeType,
                                     base64Data: nil, remoteURL: fileURL)
            } catch {
                return media
            }
        }
    }

    // MARK: - One-time migration from AppStorage / UserDefaults

    private func migrateFromAppStorageIfNeeded() {
        let key = "compare_conversations_v1"
        guard let json  = UserDefaults.standard.string(forKey: key), !json.isEmpty,
              let data  = json.data(using: .utf8),
              let saved = try? decoder.decode([CompareConversation].self, from: data) else { return }

        for conversation in saved {
            context.insert(makeRecord(from: conversation))
        }
        try? context.save()
        UserDefaults.standard.removeObject(forKey: key)
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
