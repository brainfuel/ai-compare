import Foundation

struct OpenAIClient: GeminiServicing {
    let apiKey: String
    private let explicitlyUnsupportedPrefixes: [String] = [
        "gpt-audio",
        "gpt-realtime",
        "gpt-4o-audio",
        "gpt-4o-mini-audio",
        "gpt-4o-mini-realtime",
        "gpt-4o-mini-search",
        "omni-moderation",
        "text-embedding",
        "tts-",
        "whisper-",
        "sora-",
        "computer-use-",
        "babbage-",
        "davinci-"
    ]

    func listGenerateContentModels() async throws -> [String] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
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
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Model list request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let supported = decoded.data
            .map(\.id)
            .filter { modelKind(for: $0) != .unsupported }
        return Array(Set(supported)).sorted()
    }

    func generateReply(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) async throws -> ModelReply {
        switch modelKind(for: modelID) {
        case .imageGeneration:
            return try await generateImageReply(modelID: modelID, messages: messages)
        case .chatText:
            break
        case .unsupported:
            throw GeminiError.api("Model '\(modelID)' is not supported by this app yet.")
        }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var payloadMessages: [OpenAIChatMessage] = []
        if !systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloadMessages.append(OpenAIChatMessage(role: "system", content: systemInstruction))
        }
        payloadMessages.append(contentsOf: messages.map { message in
            OpenAIChatMessage(
                role: message.role == .assistant ? "assistant" : "user",
                content: message.text
            )
        })

        if !latestUserAttachments.isEmpty {
            payloadMessages.append(OpenAIChatMessage(
                role: "user",
                content: "Note: \(latestUserAttachments.count) attachment(s) were selected but are not yet sent for ChatGPT in this app."
            ))
        }

        let payload = OpenAIChatRequest(model: modelID, messages: payloadMessages)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            throw GeminiError.emptyReply
        }
        return ModelReply(text: text, generatedMedia: [])
    }

    private func generateImageReply(modelID: String, messages: [ChatMessage]) async throws -> ModelReply {
        guard let prompt = messages.last(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            throw GeminiError.api("Image generation requires a user prompt.")
        }

        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let payload = OpenAIImageRequest(model: modelID, prompt: prompt)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Image request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIImageResponse.self, from: data)
        let media = decoded.data.compactMap { item -> GeneratedMedia? in
            if let b64 = item.base64JSON, !b64.isEmpty {
                return GeneratedMedia(kind: .image, mimeType: "image/png", base64Data: b64)
            }
            if let urlString = item.url, let remoteURL = URL(string: urlString) {
                return GeneratedMedia(kind: .image, mimeType: "image/png", remoteURL: remoteURL)
            }
            return nil
        }

        if media.isEmpty {
            throw GeminiError.emptyReply
        }

        return ModelReply(text: "", generatedMedia: media)
    }

    private func modelKind(for modelID: String) -> OpenAIModelKind {
        if explicitlyUnsupportedPrefixes.contains(where: { modelID.hasPrefix($0) }) {
            return .unsupported
        }

        if modelID.hasPrefix("gpt-image-") || modelID.hasPrefix("dall-e-") || modelID == "chatgpt-image-latest" {
            return .imageGeneration
        }

        if modelID.hasPrefix("gpt-") || modelID.hasPrefix("o1") || modelID.hasPrefix("o3") || modelID.hasPrefix("o4") {
            return .chatText
        }

        return .unsupported
    }
}

private enum OpenAIModelKind {
    case chatText
    case imageGeneration
    case unsupported
}

private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
}

private struct OpenAIModel: Decodable {
    let id: String
}

private struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
}

private struct OpenAIImageRequest: Encodable {
    let model: String
    let prompt: String
}

private struct OpenAIImageResponse: Decodable {
    let data: [OpenAIImageData]
}

private struct OpenAIImageData: Decodable {
    let url: String?
    let base64JSON: String?

    enum CodingKeys: String, CodingKey {
        case url
        case base64JSON = "b64_json"
    }
}

private struct OpenAIChatMessage: Codable {
    let role: String
    let content: String
}

private struct OpenAIChatResponse: Decodable {
    let choices: [OpenAIChatChoice]
}

private struct OpenAIChatChoice: Decodable {
    let message: OpenAIChatMessage
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: OpenAIErrorBody
}

private struct OpenAIErrorBody: Decodable {
    let message: String
}
