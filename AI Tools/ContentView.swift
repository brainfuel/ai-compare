//
//  ContentView.swift
//  AI Tools
//
//  Created by Ben Milford on 27/02/2026.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var viewModel = PlaygroundViewModel()
    @State private var prompt = ""
    @State private var isKeyHidden = true
    @State private var historySearch = ""
    @State private var showingFileImporter = false
    @State private var pendingAttachments: [PendingAttachment] = []
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 12) {
                configurationSection
                Divider()
                messagesSection
                composerSection
            }
            .padding()
            .navigationTitle("AI Playground")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset Chat") {
                        viewModel.clearMessages()
                    }
                }
            }
        }
#if os(macOS)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
#endif
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("New Chat") {
                    viewModel.startNewChat()
                }
                .buttonStyle(.borderedProminent)

                Button("Delete") {
                    viewModel.deleteSelectedConversation()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedConversationID == nil)

                Spacer()
            }

            TextField("Search History", text: $historySearch)
                .textFieldStyle(.roundedBorder)

            List {
                Button {
                    viewModel.selectConversation(nil)
                } label: {
                    HStack {
                        Image(systemName: "plus.bubble")
                        Text("Current Chat")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .listRowBackground(viewModel.selectedConversationID == nil ? Color.accentColor.opacity(0.14) : Color.clear)

                ForEach(viewModel.filteredConversations(query: historySearch)) { conversation in
                    Button {
                        viewModel.selectConversation(conversation.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .lineLimit(1)
                            Text(conversation.updatedAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .listRowBackground(viewModel.selectedConversationID == conversation.id ? Color.accentColor.opacity(0.14) : Color.clear)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var configurationSection: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if isKeyHidden {
                        SecureField("Gemini API Key", text: $viewModel.apiKey)
                    } else {
                        TextField("Gemini API Key", text: $viewModel.apiKey)
                    }
                    Button(isKeyHidden ? "Show" : "Hide") {
                        isKeyHidden.toggle()
                    }
                }

                Picker("Preset", selection: $viewModel.selectedPreset) {
                    ForEach(ModelPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.selectedPreset) { _, newValue in
                    viewModel.applyPreset(newValue)
                }

                HStack {
                    TextField("Model ID", text: $viewModel.modelID)
                    Button("Load Models") {
                        Task {
                            await viewModel.refreshModels()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isLoading || viewModel.apiKey.isEmpty)
                }

                if !viewModel.availableModels.isEmpty {
                    Picker("Available Models", selection: $viewModel.modelID) {
                        ForEach(viewModel.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                }

                TextField("System Instructions (optional)", text: $viewModel.systemInstruction, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }

    private var messagesSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if viewModel.isLoading {
                        HStack {
                            ProgressView()
                            Text("Thinking...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { attachment in
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    AttachmentPreview(attachment: attachment)
                                        .frame(width: 120, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Button {
                                        pendingAttachments.removeAll { $0.id == attachment.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, .black.opacity(0.65))
                                            .padding(4)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Text(attachment.name)
                                    .lineLimit(1)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            TextEditor(text: $prompt)
                .frame(minHeight: 90, maxHeight: 150)
                .focused($inputFocused)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                }

            HStack {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text("Ready")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Attach") {
                    showingFileImporter = true
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading)

                Button("Send") {
                    sendMessage()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty))
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.label)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !message.text.isEmpty {
                Group {
                    if message.role == .assistant {
                        MarkdownText(message.text)
                    } else {
                        Text(message.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !message.attachments.isEmpty {
                ForEach(message.attachments) { attachment in
                    Text("Attachment: \(attachment.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !message.generatedImages.isEmpty {
                ForEach(message.generatedImages) { image in
                    AssistantImageView(image: image)
                        .frame(maxWidth: 360, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func sendMessage() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        let attachments = pendingAttachments
        prompt = ""
        pendingAttachments = []
        inputFocused = false
        Task {
            await viewModel.send(text: text, attachments: attachments)
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            viewModel.errorMessage = "Attachment import failed: \(error.localizedDescription)"
        case .success(let urls):
            for url in urls {
                do {
                    let attachment = try PendingAttachment.fromFileURL(url)
                    pendingAttachments.append(attachment)
                } catch {
                    viewModel.errorMessage = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }
}

struct MarkdownText: View {
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(buildSegments(parseBlocks(raw)).enumerated()), id: \.offset) { _, segment in
                renderSegment(segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderSegment(_ segment: MarkdownSegment) -> some View {
        switch segment {
        case .text(let text):
            markdownText(text)
        case .code(let text):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Button("Copy") {
                        Clipboard.copy(text)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.black.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .full
            )
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func buildSegments(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var textBuffer: [String] = []

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else { return }
            segments.append(.text(textBuffer.joined(separator: "\n")))
            textBuffer.removeAll()
        }

        for block in blocks {
            switch block {
            case .heading(let level, let text):
                textBuffer.append(String(repeating: "#", count: max(1, min(6, level))) + " " + text)
            case .bullet(let text):
                textBuffer.append("- " + text)
            case .numbered(let number, let text):
                textBuffer.append("\(number). " + text)
            case .quote(let text):
                textBuffer.append("> " + text)
            case .rule:
                textBuffer.append("---")
            case .paragraph(let text):
                textBuffer.append(text)
            case .blank:
                textBuffer.append("")
            case .code(let text):
                flushTextBuffer()
                segments.append(.code(text))
            }
        }

        flushTextBuffer()
        return segments
    }

    private func parseBlocks(_ input: String) -> [MarkdownBlock] {
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var inCodeFence = false
        var codeLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.code(text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCodeFence = false
                } else {
                    inCodeFence = true
                }
                continue
            }

            if inCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                blocks.append(.blank)
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix("# ") {
                blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("## ") {
                blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
                continue
            }
            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
                continue
            }
            if trimmed.hasPrefix("> ") {
                blocks.append(.quote(text: String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(text: String(trimmed.dropFirst(2))))
                continue
            }
            if let numbered = parseNumbered(trimmed) {
                blocks.append(.numbered(number: numbered.number, text: numbered.text))
                continue
            }

            blocks.append(.paragraph(text: line))
        }

        if !codeLines.isEmpty {
            blocks.append(.code(text: codeLines.joined(separator: "\n")))
        }

        return blocks
    }

    private func parseNumbered(_ line: String) -> (number: Int, text: String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let lhs = line[..<dotIndex]
        let rhsStart = line.index(after: dotIndex)
        guard rhsStart < line.endIndex else { return nil }
        let rhs = line[rhsStart...].trimmingCharacters(in: .whitespaces)
        guard let number = Int(lhs), !rhs.isEmpty else { return nil }
        return (number, rhs)
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case numbered(number: Int, text: String)
    case quote(text: String)
    case code(text: String)
    case rule
    case paragraph(text: String)
    case blank
}

enum MarkdownSegment {
    case text(String)
    case code(String)
}

enum Clipboard {
    static func copy(_ text: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#elseif os(iOS)
        UIPasteboard.general.string = text
#endif
    }
}

enum MessageRole: String {
    case user
    case assistant

    var label: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Assistant"
        }
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

struct AttachmentSummary: Identifiable {
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

struct AssistantImageView: View {
    let image: GeneratedImage

    var body: some View {
        Group {
#if os(macOS)
            if let base64 = image.base64Data,
               let data = Data(base64Encoded: base64),
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .background(Color.secondary.opacity(0.08))
            } else if let remoteURL = image.remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let loaded):
                        loaded.resizable().scaledToFit()
                    case .empty:
                        ProgressView()
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
#elseif os(iOS)
            if let base64 = image.base64Data,
               let data = Data(base64Encoded: base64),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .background(Color.secondary.opacity(0.08))
            } else if let remoteURL = image.remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let loaded):
                        loaded.resizable().scaledToFit()
                    case .empty:
                        ProgressView()
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
#else
            fallback
#endif
        }
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                Text("Unsupported image output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

@MainActor
final class PlaygroundViewModel: ObservableObject {
    @AppStorage("gemini_api_key") var apiKey = ""
    @AppStorage("gemini_model_id") var modelID = ModelPreset.geminiFlash.modelID
    @AppStorage("gemini_system_instruction") var systemInstruction = ""
    @AppStorage("gemini_chat_history_v1") private var chatHistoryStore = ""
    @Published var messages: [ChatMessage] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var selectedPreset: ModelPreset = .geminiFlash
    @Published var availableModels: [String] = []
    @Published var savedConversations: [SavedConversation] = []
    @Published var selectedConversationID: UUID?

    init() {
        selectedPreset = ModelPreset(rawValue: modelID) ?? .custom
        loadSavedConversations()
    }

    func applyPreset(_ preset: ModelPreset) {
        if preset != .custom {
            modelID = preset.modelID
        }
    }

    func clearMessages() {
        messages.removeAll()
        errorMessage = nil
        if let selectedConversationID {
            updateConversation(id: selectedConversationID)
        }
    }

    func startNewChat() {
        selectedConversationID = nil
        messages.removeAll()
        errorMessage = nil
    }

    func selectConversation(_ id: UUID?) {
        selectedConversationID = id
        guard let id, let conversation = savedConversations.first(where: { $0.id == id }) else {
            messages.removeAll()
            errorMessage = nil
            return
        }

        modelID = conversation.modelID
        selectedPreset = ModelPreset(rawValue: modelID) ?? .custom
        messages = conversation.messages
        errorMessage = nil
    }

    func deleteSelectedConversation() {
        guard let id = selectedConversationID else { return }
        savedConversations.removeAll { $0.id == id }
        selectedConversationID = nil
        messages.removeAll()
        persistSavedConversations()
    }

    func filteredConversations(query: String) -> [SavedConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return savedConversations }
        return savedConversations.filter { conversation in
            conversation.searchBlob.localizedCaseInsensitiveContains(needle)
        }
    }

    func refreshModels() async {
        guard !apiKey.isEmpty else {
            errorMessage = "Missing API key."
            return
        }

        do {
            availableModels = try await GeminiClient(apiKey: apiKey).listGenerateContentModels()
            if !availableModels.contains(modelID), let first = availableModels.first {
                modelID = first
                selectedPreset = .custom
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(text: String, attachments: [PendingAttachment]) async {
        errorMessage = nil
        guard !apiKey.isEmpty else {
            errorMessage = "Missing API key."
            return
        }
        guard !modelID.isEmpty else {
            errorMessage = "Model ID cannot be empty."
            return
        }

        messages.append(ChatMessage(
            role: .user,
            text: text.isEmpty ? "(Attachment only)" : text,
            attachments: attachments.map { AttachmentSummary(name: $0.name) }
        ))
        isLoading = true
        defer { isLoading = false }

        do {
            let reply = try await GeminiClient(apiKey: apiKey).generateReply(
                modelID: modelID,
                systemInstruction: systemInstruction,
                messages: messages,
                latestUserAttachments: attachments
            )
            messages.append(ChatMessage(
                role: .assistant,
                text: reply.text,
                attachments: [],
                generatedImages: reply.generatedImages
            ))
            upsertCurrentConversation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upsertCurrentConversation() {
        guard !messages.isEmpty else { return }
        if let id = selectedConversationID {
            updateConversation(id: id)
            return
        }

        let conversation = SavedConversation(
            id: UUID(),
            title: inferredConversationTitle(),
            updatedAt: Date(),
            modelID: modelID,
            messages: messages
        )
        selectedConversationID = conversation.id
        savedConversations.insert(conversation, at: 0)
        persistSavedConversations()
    }

    private func updateConversation(id: UUID) {
        guard let index = savedConversations.firstIndex(where: { $0.id == id }) else { return }
        savedConversations[index].updatedAt = Date()
        savedConversations[index].modelID = modelID
        savedConversations[index].messages = messages
        savedConversations[index].title = inferredConversationTitle(fallback: savedConversations[index].title)
        savedConversations.sort { $0.updatedAt > $1.updatedAt }
        persistSavedConversations()
    }

    private func inferredConversationTitle(fallback: String = "Untitled Chat") -> String {
        guard let firstUserText = messages.first(where: { $0.role == .user })?.text else {
            return fallback
        }
        let cleaned = firstUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        return String(cleaned.prefix(48))
    }

    private func loadSavedConversations() {
        guard !chatHistoryStore.isEmpty,
              let data = chatHistoryStore.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SavedConversation].self, from: data) else {
            savedConversations = []
            return
        }
        savedConversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistSavedConversations() {
        guard let data = try? JSONEncoder().encode(savedConversations),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        chatHistoryStore = string
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

struct AttachmentPreview: View {
    let attachment: PendingAttachment

    var body: some View {
        Group {
            if attachment.mimeType.hasPrefix("image/") {
#if os(macOS)
                if let image = attachment.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    fallback
                }
#elseif os(iOS)
                if let image = attachment.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    fallback
                }
#else
                fallback
#endif
            } else {
                fallback
            }
        }
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.2))
            Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

struct GeminiClient {
    let apiKey: String

    private let transientNetworkErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost, // -1005
        NSURLErrorTimedOut,              // -1001
        NSURLErrorCannotFindHost,        // -1003
        NSURLErrorCannotConnectToHost    // -1004
    ]

    func listGenerateContentModels() async throws -> [String] {
        var collected: [String] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")
            components?.queryItems = [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "pageSize", value: "50")
            ]
            if let token = pageToken, !token.isEmpty {
                components?.queryItems?.append(URLQueryItem(name: "pageToken", value: token))
            }
            guard let url = components?.url else {
                throw GeminiError.invalidRequest
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 25

            let (data, response) = try await performWithRetry(request: request, maxAttempts: 3)
            guard let http = response as? HTTPURLResponse else {
                throw GeminiError.invalidResponse
            }
            if !(200...299).contains(http.statusCode) {
                if let apiError = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data) {
                    throw GeminiError.api(apiError.error.message)
                }
                throw GeminiError.api("Model list request failed with status \(http.statusCode).")
            }

            let decoded = try JSONDecoder().decode(GeminiListModelsResponse.self, from: data)
            let pageModels: [String] = decoded.models.compactMap { model in
                guard model.supportedGenerationMethods.contains("generateContent") else { return nil }
                if model.name.hasPrefix("models/") {
                    return String(model.name.dropFirst("models/".count))
                }
                return model.name
            }
            collected.append(contentsOf: pageModels)
            pageToken = decoded.nextPageToken
        } while pageToken != nil && !(pageToken?.isEmpty ?? true)

        return Array(Set(collected)).sorted()
    }

    func generateReply(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) async throws -> ModelReply {
        let escapedModel = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escapedModel):generateContent?key=\(apiKey)") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let lastUserIndex = messages.lastIndex { $0.role == .user }
        let payload = GeminiGenerateRequest(
            contents: messages.enumerated().map { index, message in
                var parts = [GeminiPart(text: message.text)]
                if let lastUserIndex, index == lastUserIndex, !latestUserAttachments.isEmpty {
                    parts.append(contentsOf: latestUserAttachments.map { attachment in
                        GeminiPart(
                            text: nil,
                            inlineData: GeminiInlineData(
                                mimeType: attachment.mimeType,
                                data: attachment.base64Data
                            )
                        )
                    })
                }
                return GeminiContent(
                    role: message.role == .user ? "user" : "model",
                    parts: parts
                )
            },
            systemInstruction: systemInstruction.isEmpty ? nil : GeminiContent(
                role: "user",
                parts: [GeminiPart(text: systemInstruction)]
            ),
            generationConfig: GeminiGenerationConfig(responseModalities: ["TEXT", "IMAGE"])
        )

        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 120

        let (data, response) = try await performWithRetry(request: request, maxAttempts: 3)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        guard let parts = decoded.candidates.first?.content.parts else {
            throw GeminiError.emptyReply
        }

        let text = parts.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let images = parts.compactMap { part -> GeneratedImage? in
            if let inline = part.inlineData,
               inline.mimeType.hasPrefix("image/"),
               !inline.data.isEmpty {
                return GeneratedImage(mimeType: inline.mimeType, base64Data: inline.data)
            }
            if let file = part.fileData,
               file.mimeType.hasPrefix("image/"),
               let url = URL(string: file.fileURI) {
                return GeneratedImage(mimeType: file.mimeType, remoteURL: url)
            }
            return nil
        }

        if text.isEmpty && images.isEmpty {
            throw GeminiError.emptyReply
        }

        return ModelReply(text: text, generatedImages: images)
    }

    private func performWithRetry(request: URLRequest, maxAttempts: Int) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
                guard shouldRetry(error: error), attempt < maxAttempts else {
                    throw error
                }

                let delayNanos = UInt64(attempt) * 700_000_000
                try? await Task.sleep(nanoseconds: delayNanos)
            }
        }

        throw lastError ?? GeminiError.invalidResponse
    }

    private func shouldRetry(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return transientNetworkErrorCodes.contains(urlError.errorCode)
    }
}

enum GeminiError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case emptyReply
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid request configuration."
        case .invalidResponse: return "Invalid server response."
        case .emptyReply: return "No text returned by the model."
        case .api(let message): return message
        }
    }
}

struct GeminiGenerateRequest: Encodable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiContent?
    let generationConfig: GeminiGenerationConfig?

    enum CodingKeys: String, CodingKey {
        case contents
        case systemInstruction = "system_instruction"
        case generationConfig = "generation_config"
    }
}

struct GeminiGenerationConfig: Codable {
    let responseModalities: [String]

    enum CodingKeys: String, CodingKey {
        case responseModalities = "response_modalities"
    }
}

struct GeminiContent: Codable {
    let role: String
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    let fileData: GeminiFileData?

    init(text: String? = nil, inlineData: GeminiInlineData? = nil, fileData: GeminiFileData? = nil) {
        self.text = text
        self.inlineData = inlineData
        self.fileData = fileData
    }

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
        case inlineDataCamel = "inlineData"
        case fileData = "file_data"
        case fileDataCamel = "fileData"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        if let snake = try container.decodeIfPresent(GeminiInlineData.self, forKey: .inlineData) {
            inlineData = snake
        } else {
            inlineData = try container.decodeIfPresent(GeminiInlineData.self, forKey: .inlineDataCamel)
        }
        if let snake = try container.decodeIfPresent(GeminiFileData.self, forKey: .fileData) {
            fileData = snake
        } else {
            fileData = try container.decodeIfPresent(GeminiFileData.self, forKey: .fileDataCamel)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(inlineData, forKey: .inlineData)
        try container.encodeIfPresent(fileData, forKey: .fileData)
    }
}

struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String

    init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snake = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let camel = try container.decodeIfPresent(String.self, forKey: .mimeTypeCamel)
        mimeType = snake ?? camel ?? "application/octet-stream"
        data = try container.decode(String.self, forKey: .data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(data, forKey: .data)
    }
}

struct GeminiFileData: Codable {
    let mimeType: String
    let fileURI: String

    init(mimeType: String, fileURI: String) {
        self.mimeType = mimeType
        self.fileURI = fileURI
    }

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case fileURI = "file_uri"
        case fileURICamel = "fileUri"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snakeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let camelType = try container.decodeIfPresent(String.self, forKey: .mimeTypeCamel)
        mimeType = snakeType ?? camelType ?? "application/octet-stream"

        let snakeURI = try container.decodeIfPresent(String.self, forKey: .fileURI)
        let camelURI = try container.decodeIfPresent(String.self, forKey: .fileURICamel)
        fileURI = snakeURI ?? camelURI ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(fileURI, forKey: .fileURI)
    }
}

struct GeminiGenerateResponse: Decodable {
    let candidates: [GeminiCandidate]
}

struct GeminiCandidate: Decodable {
    let content: GeminiContent
}

struct GeminiAPIErrorEnvelope: Decodable {
    let error: GeminiAPIError
}

struct GeminiAPIError: Decodable {
    let message: String
}

struct GeminiListModelsResponse: Decodable {
    let models: [GeminiModel]
    let nextPageToken: String?
}

struct GeminiModel: Decodable {
    let name: String
    let supportedGenerationMethods: [String]
}

extension MessageRole: Codable {}
extension AttachmentSummary: Codable {}

struct ModelReply {
    let text: String
    let generatedImages: [GeneratedImage]
}

struct PendingAttachment: Identifiable {
    let id = UUID()
    let name: String
    let mimeType: String
    let base64Data: String
    let previewJPEGData: Data?

    static func fromFileURL(_ url: URL) throws -> PendingAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        if data.count > 18_000_000 {
            throw GeminiError.api("File '\(url.lastPathComponent)' is too large (limit 18MB).")
        }

        let originalMimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let processed = try preprocessIfImage(data: data, mimeType: originalMimeType)

        return PendingAttachment(
            name: processed.fileNameOverride ?? url.lastPathComponent,
            mimeType: processed.mimeType,
            base64Data: processed.data.base64EncodedString(),
            previewJPEGData: makePreviewData(data: processed.data, mimeType: processed.mimeType)
        )
    }

    private static func preprocessIfImage(data: Data, mimeType: String) throws -> (data: Data, mimeType: String, fileNameOverride: String?) {
        guard mimeType.hasPrefix("image/") else {
            return (data, mimeType, nil)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return (data, mimeType, nil)
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return (data, mimeType, nil)
        }

        let side = min(width, height)
        let x = (width - side) / 2
        let y = (height - side) / 2
        let cropRect = CGRect(x: x, y: y, width: side, height: side)
        guard let cropped = image.cropping(to: cropRect) else {
            return (data, mimeType, nil)
        }

        let maxSide = 1280
        let targetSide = min(side, maxSide)
        guard let context = CGContext(
            data: nil,
            width: targetSide,
            height: targetSide,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (data, mimeType, nil)
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetSide, height: targetSide))
        guard let outputImage = context.makeImage() else {
            return (data, mimeType, nil)
        }

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return (data, mimeType, nil)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.72
        ]
        CGImageDestinationAddImage(destination, outputImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return (data, mimeType, nil)
        }

        return (outputData as Data, "image/jpeg", nil)
    }

    private static func makePreviewData(data: Data, mimeType: String) -> Data? {
        guard mimeType.hasPrefix("image/"),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 220,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumb, [
            kCGImageDestinationLossyCompressionQuality: 0.65
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return out as Data
    }

#if os(macOS)
    var previewImage: NSImage? {
        guard let previewJPEGData else { return nil }
        return NSImage(data: previewJPEGData)
    }
#elseif os(iOS)
    var previewImage: UIImage? {
        guard let previewJPEGData else { return nil }
        return UIImage(data: previewJPEGData)
    }
#endif
}
