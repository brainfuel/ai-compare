import Foundation

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

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
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

struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    let text: String
    let attachments: [AttachmentSummary]
    let generatedImages: [GeneratedImage]

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        attachments: [AttachmentSummary],
        generatedImages: [GeneratedImage] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.generatedImages = generatedImages
    }
}

extension ChatMessage: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decode([AttachmentSummary].self, forKey: .attachments)
        generatedImages = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
    }
}

enum ModelPreset: String, CaseIterable, Identifiable {
    case gemini31ProPreview = "gemini-3.1-pro-preview"
    case gemini3FlashPreview = "gemini-3-flash-preview"
    case gemini3ProPreview = "gemini-3-pro-preview"
    case geminiFlash = "gemini-2.5-flash"
    case geminiPro = "gemini-2.5-pro"
    case geminiFlashLite = "gemini-2.5-flash-lite"
    case nanaanoBanana = "nanaano-banana"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini31ProPreview: return "Gemini 3.1 Pro Preview"
        case .gemini3FlashPreview: return "Gemini 3 Flash Preview"
        case .gemini3ProPreview: return "Gemini 3 Pro Preview (Deprecated)"
        case .geminiFlash: return "Gemini 2.5 Flash"
        case .geminiPro: return "Gemini 2.5 Pro"
        case .geminiFlashLite: return "Gemini 2.5 Flash Lite"
        case .nanaanoBanana: return "Nanaano Banana"
        case .custom: return "Custom"
        }
    }

    var modelID: String {
        switch self {
        case .custom: return ""
        default: return rawValue
        }
    }
}

struct SavedConversation: Identifiable, Codable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var modelID: String
    var messages: [ChatMessage]

    var searchBlob: String {
        let body = messages.map(\.text).joined(separator: "\n")
        return "\(title)\n\(body)"
    }
}

struct ModelReply {
    let text: String
    let generatedImages: [GeneratedImage]
}
