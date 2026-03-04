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

    func generateReplyStream(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> AsyncThrowingStream<ModelReply, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                        throw GeminiError.invalidRequest
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 120

                    let payloadMessages = normalizedPayloadMessages(
                        from: messages,
                        latestUserAttachments: latestUserAttachments
                    )
                    guard !payloadMessages.isEmpty else {
                        throw GeminiError.api("Cannot send an empty conversation to Anthropic.")
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
                        if let raw = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !raw.isEmpty {
                            throw GeminiError.api(raw)
                        }
                        throw GeminiError.api("Anthropic request failed with status \(http.statusCode).")
                    }

                    let decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
                    let responseText = decoded.content.compactMap(\.text).joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if responseText.isEmpty {
                        throw GeminiError.emptyReply
                    }

                    continuation.yield(
                        ModelReply(
                            text: responseText,
                            generatedMedia: [],
                            inputTokens: decoded.usage?.inputTokens ?? 0,
                            outputTokens: decoded.usage?.outputTokens ?? 0
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func normalizedPayloadMessages(
        from messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> [AnthropicMessage] {
        var collapsed: [(role: String, text: String)] = []

        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let role = message.role == .assistant ? "assistant" : "user"
            if let last = collapsed.last, last.role == role {
                collapsed[collapsed.count - 1].text += "\n\n\(text)"
            } else {
                collapsed.append((role: role, text: text))
            }
        }

        if !latestUserAttachments.isEmpty {
            let note = "Note: \(latestUserAttachments.count) attachment(s) were selected but are not yet sent for Anthropic in this app."
            if let last = collapsed.last, last.role == "user" {
                collapsed[collapsed.count - 1].text += "\n\n\(note)"
            } else {
                collapsed.append((role: "user", text: note))
            }
        }

        return collapsed.map { pair in
            AnthropicMessage(role: pair.role, content: [.text(pair.text)])
        }
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
    let content: [AnthropicResponseContentBlock]
    let usage: AnthropicUsage?
}

private struct AnthropicResponseContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct AnthropicErrorEnvelope: Decodable {
    let error: AnthropicErrorBody
}

private struct AnthropicErrorBody: Decodable {
    let message: String
}
