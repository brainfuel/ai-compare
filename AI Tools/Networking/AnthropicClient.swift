import Foundation

struct AnthropicClient: GeminiServicing {
    let apiKey: String
    private let apiVersion = "2023-06-01"

    func listGenerateContentModels() async throws -> [String] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Model list request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
        return decoded.data.map(\.id)
    }

    func generateReply(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) async throws -> ModelReply {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 120

        var payloadMessages = messages.map { message in
            AnthropicMessage(
                role: message.role == .assistant ? "assistant" : "user",
                content: [.text(message.text)]
            )
        }

        if !latestUserAttachments.isEmpty {
            payloadMessages.append(
                AnthropicMessage(
                    role: "user",
                    content: [.text("Note: \(latestUserAttachments.count) attachment(s) were selected but are not yet sent for Anthropic in this app.")]
                )
            )
        }

        let payload = AnthropicMessagesRequest(
            model: modelID,
            maxTokens: 1024,
            system: systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : systemInstruction,
            messages: payloadMessages
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
        let text = decoded.content
            .compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            throw GeminiError.emptyReply
        }
        return ModelReply(text: text, generatedMedia: [])
    }
}

private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModel]
}

private struct AnthropicModel: Decodable {
    let id: String
}

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct AnthropicMessage: Codable {
    let role: String
    let content: [AnthropicContentBlock]
}

private enum AnthropicContentBlock: Codable {
    case text(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        default:
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        }
    }
}

private struct AnthropicMessagesResponse: Decodable {
    let content: [AnthropicContentBlock]
}

private struct AnthropicErrorEnvelope: Decodable {
    let error: AnthropicErrorBody
}

private struct AnthropicErrorBody: Decodable {
    let message: String
}
