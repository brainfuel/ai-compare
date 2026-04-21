import Foundation

// MARK: - Synthesis models

struct SynthesisItem: Identifiable, Codable {
    let id: UUID
    let text: String

    init(text: String) {
        self.id   = UUID()
        self.text = text
    }
}

// Named struct replaces the non-Codable tuple (model: String, position: String)
struct SynthesisPosition: Codable {
    let model: String
    let position: String
}

struct SynthesisDisagreement: Identifiable, Codable {
    let id: UUID
    let topic: String
    let positions: [SynthesisPosition]

    init(topic: String, positions: [SynthesisPosition]) {
        self.id        = UUID()
        self.topic     = topic
        self.positions = positions
    }
}

struct SynthesisUniquePoint: Identifiable, Codable {
    let id: UUID
    let claim: String
    let source: String

    init(claim: String, source: String) {
        self.id     = UUID()
        self.claim  = claim
        self.source = source
    }
}

struct SynthesisResult: Codable {
    let consensus:     [SynthesisItem]
    let disagreements: [SynthesisDisagreement]
    let unique:        [SynthesisUniquePoint]
    let suspicious:    [SynthesisItem]

    var isEmpty: Bool {
        consensus.isEmpty && disagreements.isEmpty && unique.isEmpty && suspicious.isEmpty
    }
}

// Snapshot of a synthesis result attached to a conversation.
struct CachedSynthesis: Codable {
    let result:         SynthesisResult
    /// IDs of the CompareRuns that were present when this synthesis ran.
    let runIDs:         Set<UUID>
    let synthesisedAt:  Date
    let provider:       AIProvider
}

enum SynthesisState {
    case idle
    case synthesizing
    case success(SynthesisResult)
    case failed(String)
}

// MARK: - Compare models

enum CompareResultState: String, Codable {
    case loading
    case success
    case failed
    case skipped
}

struct CompareProviderResult: Codable {
    var state: CompareResultState
    var modelID: String
    var text: String
    var generatedMedia: [GeneratedMedia]
    var inputTokens: Int
    var outputTokens: Int
    var errorMessage: String?
}

struct CompareRun: Identifiable, Codable {
    let id: UUID
    let prompt: String
    let attachments: [AttachmentSummary]
    let createdAt: Date
    var results: [AIProvider: CompareProviderResult]
}

struct CompareConversation: Identifiable, Codable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var runs: [CompareRun]
    var cachedSynthesis: CachedSynthesis?

    var searchBlob: String {
        let prompts = runs.map(\.prompt).joined(separator: "\n")
        let replies = runs.flatMap { run in
            run.results.values.map(\.text)
        }.joined(separator: "\n")
        return "\(title)\n\(prompts)\n\(replies)"
    }
}
