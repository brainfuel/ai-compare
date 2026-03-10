import XCTest
@testable import AI_Tools

@MainActor
final class PlaygroundViewModelTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let storageKeys = [
        "ai_provider",
        "gemini_model_id",
        "openai_model_id",
        "anthropic_model_id",
        "grok_model_id",
        "gemini_models_cache_v1",
        "openai_models_cache_v1",
        "anthropic_models_cache_v1",
        "grok_models_cache_v1",
        "gemini_system_instruction"
    ]

    private var previousDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        previousDefaults = [:]

        for key in storageKeys {
            if let value = defaults.object(forKey: key) {
                previousDefaults[key] = value
            }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in storageKeys {
            defaults.removeObject(forKey: key)
        }

        for (key, value) in previousDefaults {
            defaults.set(value, forKey: key)
        }
        previousDefaults = [:]
        super.tearDown()
    }

    func testSelectingConversationUsesCachedModelsImmediatelyWithoutFetch() async {
        let recorder = ModelListRecorder()
        let modelMap: [AIProvider: [String]] = [
            .chatGPT: ["gpt-4.1-mini", "o3-mini"]
        ]

        defaults.set(encode(["gpt-4.1-mini", "o3-mini"]), forKey: "openai_models_cache_v1")

        let viewModel = makeViewModel(modelMap: modelMap, recorder: recorder)
        let conversation = SavedConversation(
            id: UUID(),
            provider: .chatGPT,
            title: "OpenAI chat",
            updatedAt: Date(),
            modelID: "gpt-4.1-mini",
            messages: [
                ChatMessage(role: .user, text: "hello", attachments: [])
            ]
        )

        viewModel.savedConversations = [conversation]
        viewModel.selectConversation(conversation.id)

        XCTAssertEqual(viewModel.selectedProvider, .chatGPT)
        XCTAssertEqual(viewModel.modelID, "gpt-4.1-mini")
        XCTAssertEqual(viewModel.availableModels, ["gpt-4.1-mini", "o3-mini"])

        let calls = await recorder.snapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    func testSelectingProviderUsesCachedModelsWithoutNetworkFetch() async {
        let recorder = ModelListRecorder()
        let modelMap: [AIProvider: [String]] = [
            .anthropic: ["claude-3-5-sonnet-latest", "claude-3-7-sonnet-latest"]
        ]

        defaults.set(encode(["claude-3-5-sonnet-latest", "claude-3-7-sonnet-latest"]), forKey: "anthropic_models_cache_v1")

        let viewModel = makeViewModel(modelMap: modelMap, recorder: recorder)
        await viewModel.selectProvider(.anthropic)

        XCTAssertEqual(viewModel.availableModels, ["claude-3-5-sonnet-latest", "claude-3-7-sonnet-latest"])
        let calls = await recorder.snapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    func testSelectingGrokProviderUsesCachedModelsWithoutNetworkFetch() async {
        let recorder = ModelListRecorder()
        let modelMap: [AIProvider: [String]] = [
            .grok: ["grok-3-mini", "grok-3"]
        ]

        defaults.set(encode(["grok-3-mini", "grok-3"]), forKey: "grok_models_cache_v1")

        let viewModel = makeViewModel(modelMap: modelMap, recorder: recorder)
        await viewModel.selectProvider(.grok)

        XCTAssertEqual(viewModel.availableModels, ["grok-3-mini", "grok-3"])
        let calls = await recorder.snapshot()
        XCTAssertTrue(calls.isEmpty)
    }

    func testLoadOnLaunchPrefetchesForProvidersWithKeysAndOnlyOnce() async {
        let recorder = ModelListRecorder()
        let modelMap: [AIProvider: [String]] = [
            .gemini: ["gemini-2.5-flash", "gemini-2.5-pro"],
            .chatGPT: ["gpt-4.1-mini", "o3-mini"],
            .anthropic: ["claude-3-5-sonnet-latest"],
            .grok: ["grok-3-mini", "grok-3"]
        ]

        let viewModel = makeViewModel(modelMap: modelMap, recorder: recorder)
        viewModel.updateCurrentAPIKey("gemini-key")
        await viewModel.selectProvider(.chatGPT)
        viewModel.updateCurrentAPIKey("openai-key")
        await viewModel.selectProvider(.grok)
        viewModel.updateCurrentAPIKey("grok-key")
        await viewModel.selectProvider(.gemini)

        await viewModel.loadOnLaunchIfNeeded()

        var calls = await recorder.snapshot()
        XCTAssertEqual(calls[.gemini], 1)
        XCTAssertEqual(calls[.chatGPT], 1)
        XCTAssertEqual(calls[.grok], 1)
        XCTAssertNil(calls[.anthropic])

        XCTAssertEqual(viewModel.availableModels, ["gemini-2.5-flash", "gemini-2.5-pro"])

        await viewModel.loadOnLaunchIfNeeded()
        calls = await recorder.snapshot()
        XCTAssertEqual(calls[.gemini], 1)
        XCTAssertEqual(calls[.chatGPT], 1)
        XCTAssertEqual(calls[.grok], 1)
    }

    func testSelectingProviderWithNoCacheDoesNotInjectStaleModelIntoAvailableModels() async {
        defaults.set("nano-banana-pro-preview", forKey: "anthropic_model_id")
        defaults.set("", forKey: "anthropic_models_cache_v1")

        let recorder = ModelListRecorder()
        let viewModel = makeViewModel(modelMap: [:], recorder: recorder)
        await viewModel.selectProvider(.anthropic)

        XCTAssertEqual(viewModel.modelID, "nano-banana-pro-preview")
        XCTAssertTrue(viewModel.availableModels.isEmpty)
    }

    func testSelectingConversationDoesNotPersistConversationModelAsProviderDefault() async {
        defaults.set("claude-3-5-sonnet-latest", forKey: "anthropic_model_id")

        let recorder = ModelListRecorder()
        let viewModel = makeViewModel(modelMap: [:], recorder: recorder)

        let conversation = SavedConversation(
            id: UUID(),
            provider: .anthropic,
            title: "legacy",
            updatedAt: Date(),
            modelID: "nano-banana-pro-preview",
            messages: [ChatMessage(role: .user, text: "hello", attachments: [])]
        )

        viewModel.savedConversations = [conversation]
        viewModel.selectConversation(conversation.id)

        await viewModel.selectProvider(.gemini)
        await viewModel.selectProvider(.anthropic)

        XCTAssertEqual(viewModel.modelID, "claude-3-5-sonnet-latest")
    }

    func testUsageTimeWindowsAggregateRollingTokenAndCostTotals() async {
        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let recorder = ModelListRecorder()
        let viewModel = makeViewModel(modelMap: [:], recorder: recorder, nowProvider: { now })

        viewModel.savedConversations = [
            SavedConversation(
                id: UUID(),
                provider: .chatGPT,
                title: "usage",
                updatedAt: now,
                modelID: "gpt-4.1-mini",
                messages: [
                    ChatMessage(
                        role: .assistant,
                        text: "recent",
                        createdAt: now.addingTimeInterval(-2 * 60 * 60),
                        attachments: [],
                        inputTokens: 1_000,
                        outputTokens: 2_000,
                        modelID: "gpt-4.1-mini"
                    ),
                    ChatMessage(
                        role: .assistant,
                        text: "week",
                        createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
                        attachments: [],
                        inputTokens: 2_000,
                        outputTokens: 1_000,
                        modelID: "gpt-4.1-mini"
                    ),
                    ChatMessage(
                        role: .assistant,
                        text: "month",
                        createdAt: now.addingTimeInterval(-20 * 24 * 60 * 60),
                        attachments: [],
                        inputTokens: 3_000,
                        outputTokens: 3_000,
                        modelID: "gpt-4.1-mini"
                    ),
                    ChatMessage(
                        role: .assistant,
                        text: "old",
                        createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60),
                        attachments: [],
                        inputTokens: 4_000,
                        outputTokens: 4_000,
                        modelID: "gpt-4.1-mini"
                    )
                ]
            )
        ]

        let windows = viewModel.usageTimeWindows
        XCTAssertEqual(windows.map(\.label), ["24h", "7d", "30d"])

        XCTAssertEqual(windows[0].inputTokens, 1_000)
        XCTAssertEqual(windows[0].outputTokens, 2_000)
        XCTAssertEqual(windows[0].estimatedCost, 0.0036, accuracy: 0.0000001)

        XCTAssertEqual(windows[1].inputTokens, 3_000)
        XCTAssertEqual(windows[1].outputTokens, 3_000)
        XCTAssertEqual(windows[1].estimatedCost, 0.0060, accuracy: 0.0000001)

        XCTAssertEqual(windows[2].inputTokens, 6_000)
        XCTAssertEqual(windows[2].outputTokens, 6_000)
        XCTAssertEqual(windows[2].estimatedCost, 0.0120, accuracy: 0.0000001)
    }

    func testUsageTimeWindowsFallbackToConversationUpdatedAtWhenMessageTimestampIsMissing() async {
        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let recorder = ModelListRecorder()
        let viewModel = makeViewModel(modelMap: [:], recorder: recorder, nowProvider: { now })

        viewModel.savedConversations = [
            SavedConversation(
                id: UUID(),
                provider: .anthropic,
                title: "legacy",
                updatedAt: now.addingTimeInterval(-60 * 60),
                modelID: "claude-3-5-sonnet-latest",
                messages: [
                    ChatMessage(
                        role: .assistant,
                        text: "legacy msg",
                        createdAt: nil,
                        attachments: [],
                        inputTokens: 500,
                        outputTokens: 500,
                        modelID: nil
                    )
                ]
            )
        ]

        let windows = viewModel.usageTimeWindows
        XCTAssertEqual(windows[0].inputTokens, 500)
        XCTAssertEqual(windows[0].outputTokens, 500)
        XCTAssertEqual(windows[0].estimatedCost, 0.0090, accuracy: 0.0000001)
    }

    func testUsageTimeWindowsIncludeCurrentUnsavedConversation() async {
        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let recorder = ModelListRecorder()
        let viewModel = makeViewModel(modelMap: [:], recorder: recorder, nowProvider: { now })

        await viewModel.selectProvider(.chatGPT)
        viewModel.selectModel("gpt-4.1-mini")
        viewModel.messages = [
            ChatMessage(role: .user, text: "hi", createdAt: now, attachments: []),
            ChatMessage(
                role: .assistant,
                text: "hello",
                createdAt: now,
                attachments: [],
                inputTokens: 200,
                outputTokens: 300,
                modelID: "gpt-4.1-mini"
            )
        ]

        let windows = viewModel.usageTimeWindows
        XCTAssertEqual(windows[0].inputTokens, 200)
        XCTAssertEqual(windows[0].outputTokens, 300)
        XCTAssertEqual(windows[0].estimatedCost, 0.00056, accuracy: 0.0000001)
    }

    private func makeViewModel(
        modelMap: [AIProvider: [String]],
        recorder: ModelListRecorder,
        nowProvider: @escaping () -> Date = Date.init
    ) -> PlaygroundViewModel {
        let keychainService = "com.moosia.AI-ToolsTests.\(UUID().uuidString)"
        return PlaygroundViewModel(
            serviceFactory: { provider, _ in
                MockService(provider: provider, modelMap: modelMap, recorder: recorder)
            },
            keychainStore: KeychainStore(service: keychainService),
            conversationStoreFactory: { nil },
            nowProvider: nowProvider
        )
    }

    private func encode(_ models: [String]) -> String {
        guard let data = try? JSONEncoder().encode(models),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}

final class OpenAIClientAttachmentEncodingTests: XCTestCase {
    func testMakeChatRequestBodyIncludesImageDataURLForLatestUserAttachment() throws {
        let client = OpenAIClient(apiKey: "test-key")
        let imageBase64 = Data([0x01, 0x02, 0x03]).base64EncodedString()
        let attachments = [
            PendingAttachment(
                name: "photo.jpg",
                mimeType: "image/jpeg",
                base64Data: imageBase64,
                previewJPEGData: nil
            )
        ]
        let messages = [
            ChatMessage(role: .user, text: "what is in this image?", attachments: []),
            ChatMessage(role: .assistant, text: "Previous response", attachments: []),
            ChatMessage(role: .user, text: "identify this", attachments: [])
        ]

        let body = try client.makeChatRequestBody(
            modelID: "gpt-5.3-chat-latest",
            systemInstruction: "",
            messages: messages,
            latestUserAttachments: attachments
        )

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let payloadMessages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        let lastMessage = try XCTUnwrap(payloadMessages.last)
        let content = try XCTUnwrap(lastMessage["content"] as? [[String: Any]])

        let imagePart = try XCTUnwrap(content.first(where: { ($0["type"] as? String) == "image_url" }))
        let imageURL = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
        let url = try XCTUnwrap(imageURL["url"] as? String)
        XCTAssertEqual(url, "data:image/jpeg;base64,\(imageBase64)")

        let encoded = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(encoded.contains("were selected but are not yet sent for ChatGPT"))
    }
}

private actor ModelListRecorder {
    private var calls: [AIProvider: Int] = [:]

    func record(provider: AIProvider) {
        calls[provider, default: 0] += 1
    }

    func snapshot() -> [AIProvider: Int] {
        calls
    }
}

private struct MockService: GeminiServicing {
    let provider: AIProvider
    let modelMap: [AIProvider: [String]]
    let recorder: ModelListRecorder

    func listGenerateContentModels() async throws -> [String] {
        await recorder.record(provider: provider)
        return modelMap[provider] ?? []
    }

    func generateReplyStream(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> AsyncThrowingStream<ModelReply, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ModelReply(text: "ok", generatedMedia: []))
            continuation.finish()
        }
    }
}
