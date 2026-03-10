import Foundation

struct GrokClient: GeminiServicing {
    let apiKey: String

    func listGenerateContentModels() async throws -> [String] {
        guard let url = URL(string: "https://api.x.ai/v1/models") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(GrokErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Model list request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(GrokModelsResponse.self, from: data)
        let uniqueSorted = Array(Set(decoded.data.map(\.id))).sorted()
        return uniqueSorted
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
                    try await streamChatReply(
                        modelID: modelID,
                        systemInstruction: systemInstruction,
                        messages: messages,
                        latestUserAttachments: latestUserAttachments,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamChatReply(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment],
        continuation: AsyncThrowingStream<ModelReply, Error>.Continuation
    ) async throws {
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try makeChatRequestBody(
            modelID: modelID,
            systemInstruction: systemInstruction,
            messages: messages,
            latestUserAttachments: latestUserAttachments
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        if !(200...299).contains(http.statusCode) {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 4096 { break }
            }

            if let apiError = try? JSONDecoder().decode(GrokErrorEnvelope.self, from: errorData) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Request failed with status \(http.statusCode).")
        }

        var yieldedAnything = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }
            guard let data = jsonString.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(GrokStreamChunk.self, from: data) else {
                continue
            }

            let content = chunk.choices.first?.delta.content ?? ""
            let inputTokens = chunk.usage?.promptTokens ?? 0
            let outputTokens = chunk.usage?.completionTokens ?? 0
            if !content.isEmpty || inputTokens > 0 || outputTokens > 0 {
                continuation.yield(
                    ModelReply(
                        text: content,
                        generatedMedia: [],
                        inputTokens: inputTokens,
                        outputTokens: outputTokens
                    )
                )
                if !content.isEmpty { yieldedAnything = true }
            }
        }

        if !yieldedAnything {
            throw GeminiError.emptyReply
        }
        continuation.finish()
    }

    private func makeChatRequestBody(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) throws -> Data {
        let payload = GrokChatStreamRequest(
            model: modelID,
            messages: buildChatPayloadMessages(
                systemInstruction: systemInstruction,
                messages: messages,
                latestUserAttachments: latestUserAttachments
            )
        )
        return try JSONEncoder().encode(payload)
    }

    private func buildChatPayloadMessages(
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> [GrokChatMessage] {
        var payloadMessages: [GrokChatMessage] = []

        if !systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloadMessages.append(GrokChatMessage(role: "system", content: systemInstruction))
        }

        let lastUserIndex = messages.lastIndex { $0.role == .user }
        for (index, message) in messages.enumerated() {
            let role = message.role == .assistant ? "assistant" : "user"
            guard let lastUserIndex,
                  index == lastUserIndex,
                  !latestUserAttachments.isEmpty else {
                payloadMessages.append(GrokChatMessage(role: role, content: message.text))
                continue
            }

            var parts: [GrokChatContentPart] = []
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(GrokChatContentPart(text: message.text))
            }

            let imageAttachments = latestUserAttachments.filter {
                $0.mimeType.hasPrefix("image/") && !$0.base64Data.isEmpty
            }
            parts.append(contentsOf: imageAttachments.map { attachment in
                GrokChatContentPart(imageDataURL: "data:\(attachment.mimeType);base64,\(attachment.base64Data)")
            })

            let unsupportedCount = latestUserAttachments.count - imageAttachments.count
            if unsupportedCount > 0 {
                parts.append(
                    GrokChatContentPart(
                        text: "Note: \(unsupportedCount) non-image attachment(s) were skipped for Grok in this app."
                    )
                )
            }

            if parts.isEmpty {
                parts.append(GrokChatContentPart(text: "(Attachment only)"))
            }

            payloadMessages.append(GrokChatMessage(role: role, contentParts: parts))
        }

        if lastUserIndex == nil, !latestUserAttachments.isEmpty {
            let parts = latestUserAttachments
                .filter { $0.mimeType.hasPrefix("image/") && !$0.base64Data.isEmpty }
                .map { attachment in
                    GrokChatContentPart(imageDataURL: "data:\(attachment.mimeType);base64,\(attachment.base64Data)")
                }

            if parts.isEmpty {
                payloadMessages.append(GrokChatMessage(role: "user", content: "(Attachment only)"))
            } else {
                payloadMessages.append(GrokChatMessage(role: "user", contentParts: parts))
            }
        }

        return payloadMessages
    }
}

private struct GrokModelsResponse: Decodable {
    let data: [GrokModel]
}

private struct GrokModel: Decodable {
    let id: String
}

private struct GrokChatStreamRequest: Encodable {
    let model: String
    let messages: [GrokChatMessage]
    let stream: Bool = true
    let streamOptions: GrokStreamOptions = GrokStreamOptions()

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case streamOptions = "stream_options"
    }
}

private struct GrokStreamOptions: Encodable {
    let includeUsage: Bool = true

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct GrokChatMessage: Encodable {
    let role: String
    private let contentValue: GrokChatContentValue

    init(role: String, content: String) {
        self.role = role
        self.contentValue = .text(content)
    }

    init(role: String, contentParts: [GrokChatContentPart]) {
        self.role = role
        self.contentValue = .parts(contentParts)
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        switch contentValue {
        case .text(let text):
            try container.encode(text, forKey: .content)
        case .parts(let parts):
            try container.encode(parts, forKey: .content)
        }
    }
}

private enum GrokChatContentValue {
    case text(String)
    case parts([GrokChatContentPart])
}

private struct GrokChatContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: GrokImageURLPart?

    init(text: String) {
        self.type = "text"
        self.text = text
        self.imageURL = nil
    }

    init(imageDataURL: String) {
        self.type = "image_url"
        self.text = nil
        self.imageURL = GrokImageURLPart(url: imageDataURL)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

private struct GrokImageURLPart: Encodable {
    let url: String
}

private struct GrokStreamChunk: Decodable {
    let choices: [GrokStreamChoice]
    let usage: GrokUsage?
}

private struct GrokStreamChoice: Decodable {
    let delta: GrokStreamDelta
}

private struct GrokStreamDelta: Decodable {
    let content: String?
}

private struct GrokUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

private struct GrokErrorEnvelope: Decodable {
    let error: GrokErrorBody
}

private struct GrokErrorBody: Decodable {
    let message: String
}
