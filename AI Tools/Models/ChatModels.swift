import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case gemini
    case chatGPT
    case anthropic
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .chatGPT: return "ChatGPT"
        case .anthropic: return "Anthropic"
        case .grok: return "Grok"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .gemini: return "Gemini API Key"
        case .chatGPT: return "OpenAI API Key"
        case .anthropic: return "Anthropic API Key"
        case .grok: return "xAI API Key"
        }
    }

    var isImplemented: Bool {
        switch self {
        case .gemini, .chatGPT, .anthropic, .grok: return true
        }
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant

    var label: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Assistant"
        }
    }
}

struct AttachmentSummary: Identifiable, Codable {
    let id: UUID
    let name: String
    let mimeType: String?
    let previewBase64Data: String?

    init(
        id: UUID = UUID(),
        name: String,
        mimeType: String? = nil,
        previewBase64Data: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.previewBase64Data = previewBase64Data
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mimeType
        case previewBase64Data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        previewBase64Data = try container.decodeIfPresent(String.self, forKey: .previewBase64Data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(previewBase64Data, forKey: .previewBase64Data)
    }
}

struct GeneratedImage: Identifiable {
    let id: UUID
    let mimeType: String
    let base64Data: String?
    let remoteURL: URL?

    init(id: UUID = UUID(), mimeType: String, base64Data: String? = nil, remoteURL: URL? = nil) {
        self.id = id
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.remoteURL = remoteURL
    }
}

enum GeneratedMediaKind: String, Codable {
    case image
    case audio
    case video
    case pdf
    case text
    case json
    case csv
    case file
}

struct GeneratedMedia: Identifiable, Codable {
    let id: UUID
    let kind: GeneratedMediaKind
    let mimeType: String
    let base64Data: String?
    let remoteURL: URL?

    init(
        id: UUID = UUID(),
        kind: GeneratedMediaKind,
        mimeType: String,
        base64Data: String? = nil,
        remoteURL: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.remoteURL = remoteURL
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    let text: String
    let createdAt: Date?
    let attachments: [AttachmentSummary]
    let generatedMedia: [GeneratedMedia]
    let inputTokens: Int
    let outputTokens: Int
    let modelID: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        createdAt: Date? = Date(),
        attachments: [AttachmentSummary],
        generatedMedia: [GeneratedMedia] = [],
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        modelID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.generatedMedia = generatedMedia
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.modelID = modelID
    }
}

extension ChatMessage: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
        case attachments
        case generatedMedia
        case inputTokens
        case outputTokens
        case modelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        attachments = try container.decode([AttachmentSummary].self, forKey: .attachments)
        generatedMedia = try container.decodeIfPresent([GeneratedMedia].self, forKey: .generatedMedia) ?? []
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(generatedMedia, forKey: .generatedMedia)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encodeIfPresent(modelID, forKey: .modelID)
    }
}

struct SavedConversation: Identifiable, Codable {
    var id: UUID
    var provider: AIProvider
    var title: String
    var updatedAt: Date
    var modelID: String
    var messages: [ChatMessage]

    var searchBlob: String {
        let body = messages.map(\.text).joined(separator: "\n")
        return "\(title)\n\(body)"
    }

    init(
        id: UUID,
        provider: AIProvider,
        title: String,
        updatedAt: Date,
        modelID: String,
        messages: [ChatMessage]
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.updatedAt = updatedAt
        self.modelID = modelID
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case title
        case updatedAt
        case modelID
        case messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(AIProvider.self, forKey: .provider)
        title = try container.decode(String.self, forKey: .title)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        modelID = try container.decode(String.self, forKey: .modelID)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(title, forKey: .title)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(messages, forKey: .messages)
    }
}

struct ModelReply {
    let text: String
    let generatedMedia: [GeneratedMedia]
    let inputTokens: Int
    let outputTokens: Int

    init(
        text: String,
        generatedMedia: [GeneratedMedia],
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) {
        self.text = text
        self.generatedMedia = generatedMedia
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

// MARK: - Token cost calculator

struct TokenCost {
    let inputPerMillion: Double
    let outputPerMillion: Double

    func cost(inputTokens: Int, outputTokens: Int) -> Double {
        Double(inputTokens) / 1_000_000 * inputPerMillion +
        Double(outputTokens) / 1_000_000 * outputPerMillion
    }
}

enum TokenCostCalculator {
    static func cost(for modelID: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let pricing = pricing(for: modelID) else { return nil }
        return pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    // Prices in USD per 1 million tokens (as of early 2026)
    private static func pricing(for modelID: String) -> TokenCost? {
        // Gemini
        if modelID.hasPrefix("gemini-2.5-pro")    { return TokenCost(inputPerMillion: 1.25,  outputPerMillion: 10.00) }
        if modelID.hasPrefix("gemini-2.5-flash")   { return TokenCost(inputPerMillion: 0.075, outputPerMillion: 0.30)  }
        if modelID.hasPrefix("gemini-2.0-flash")   { return TokenCost(inputPerMillion: 0.10,  outputPerMillion: 0.40)  }
        if modelID.hasPrefix("gemini-1.5-pro")     { return TokenCost(inputPerMillion: 1.25,  outputPerMillion: 5.00)  }
        if modelID.hasPrefix("gemini-1.5-flash")   { return TokenCost(inputPerMillion: 0.075, outputPerMillion: 0.30)  }

        // OpenAI
        if modelID == "gpt-4.1"                    { return TokenCost(inputPerMillion: 2.00,  outputPerMillion: 8.00)  }
        if modelID.hasPrefix("gpt-4.1-mini")       { return TokenCost(inputPerMillion: 0.40,  outputPerMillion: 1.60)  }
        if modelID.hasPrefix("gpt-4o-mini")        { return TokenCost(inputPerMillion: 0.15,  outputPerMillion: 0.60)  }
        if modelID.hasPrefix("gpt-4o")             { return TokenCost(inputPerMillion: 2.50,  outputPerMillion: 10.00) }
        if modelID.hasPrefix("o1-mini")            { return TokenCost(inputPerMillion: 1.10,  outputPerMillion: 4.40)  }
        if modelID.hasPrefix("o1")                 { return TokenCost(inputPerMillion: 15.00, outputPerMillion: 60.00) }
        if modelID.hasPrefix("o3-mini")            { return TokenCost(inputPerMillion: 1.10,  outputPerMillion: 4.40)  }
        if modelID.hasPrefix("o3")                 { return TokenCost(inputPerMillion: 10.00, outputPerMillion: 40.00) }
        if modelID.hasPrefix("o4-mini")            { return TokenCost(inputPerMillion: 1.10,  outputPerMillion: 4.40)  }

        // Anthropic
        if modelID.hasPrefix("claude-3-opus")      { return TokenCost(inputPerMillion: 15.00, outputPerMillion: 75.00) }
        if modelID.hasPrefix("claude-3-7-sonnet")  { return TokenCost(inputPerMillion: 3.00,  outputPerMillion: 15.00) }
        if modelID.hasPrefix("claude-3-5-sonnet")  { return TokenCost(inputPerMillion: 3.00,  outputPerMillion: 15.00) }
        if modelID.hasPrefix("claude-3-5-haiku")   { return TokenCost(inputPerMillion: 0.80,  outputPerMillion: 4.00)  }
        if modelID.hasPrefix("claude-3-haiku")     { return TokenCost(inputPerMillion: 0.25,  outputPerMillion: 1.25)  }

        return nil
    }
}
