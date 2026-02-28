import SwiftUI
import UniformTypeIdentifiers
#if canImport(AVKit)
import AVKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case numbered(number: Int, text: String)
    case quote(text: String)
    case code(text: String)
    case rule
    case paragraph(text: String)
    case blank
}

private enum MarkdownSegment {
    case text(String)
    case code(String)
}

private enum Clipboard {
    static func copy(_ text: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#elseif os(iOS)
        UIPasteboard.general.string = text
#endif
    }
}

struct AssistantMediaView: View {
    let media: GeneratedMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(media.mimeType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                AssistantMediaSaveButton(media: media)
            }

            switch media.kind {
            case .image:
                AssistantGeneratedImageView(media: media)
            case .audio:
                AssistantAudioView(media: media)
            case .video:
                AssistantVideoView(media: media)
            case .pdf:
                AssistantPDFView(media: media)
            case .text:
                AssistantTextView(media: media)
            case .json:
                AssistantJSONView(media: media)
            case .csv:
                AssistantCSVView(media: media)
            case .file:
                AssistantFileFallbackView(media: media)
            }
        }
    }
}

private struct AssistantMediaSaveButton: View {
    let media: GeneratedMedia

    @State private var isPreparing = false
    @State private var isExporterPresented = false
    @State private var exportDocument = ExportedMediaDocument(data: Data())
    @State private var exportType: UTType = .data
    @State private var exportFilename = "attachment.bin"
    @State private var errorMessage: String?

    var body: some View {
        Button {
            Task {
                await prepareExport()
            }
        } label: {
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Save")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isPreparing)
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Save Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    @MainActor
    private func prepareExport() async {
        isPreparing = true
        defer { isPreparing = false }

        do {
            let data = try await resolvedData()
            exportDocument = ExportedMediaDocument(data: data)
            exportType = UTType(mimeType: media.mimeType) ?? .data
            exportFilename = media.suggestedFilename
            isExporterPresented = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolvedData() async throws -> Data {
        if let base64 = media.base64Data, let data = Data(base64Encoded: base64) {
            return data
        }
        guard let remoteURL = media.remoteURL else {
            throw GeminiError.api("No media data available to save.")
        }
        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GeminiError.api("Failed to download media (\(http.statusCode)).")
        }
        return data
    }
}

private struct ExportedMediaDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct AssistantGeneratedImageView: View {
    let media: GeneratedMedia

    var body: some View {
#if os(macOS)
        if let base64 = media.base64Data,
           let data = Data(base64Encoded: base64),
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .background(Color.secondary.opacity(0.08))
        } else if let remoteURL = media.remoteURL {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let loaded):
                    loaded.resizable().scaledToFit()
                case .empty:
                    ProgressView()
                case .failure:
                    AssistantFileFallbackView(media: media)
                @unknown default:
                    AssistantFileFallbackView(media: media)
                }
            }
        } else {
            AssistantFileFallbackView(media: media)
        }
#elseif os(iOS)
        if let base64 = media.base64Data,
           let data = Data(base64Encoded: base64),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .background(Color.secondary.opacity(0.08))
        } else if let remoteURL = media.remoteURL {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let loaded):
                    loaded.resizable().scaledToFit()
                case .empty:
                    ProgressView()
                case .failure:
                    AssistantFileFallbackView(media: media)
                @unknown default:
                    AssistantFileFallbackView(media: media)
                }
            }
        } else {
            AssistantFileFallbackView(media: media)
        }
#else
        AssistantFileFallbackView(media: media)
#endif
    }
}

private struct AssistantAudioView: View {
    let media: GeneratedMedia
    @State private var localURL: URL?

    var body: some View {
#if canImport(AVKit)
        Group {
            if let url = resolvedURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 56)
            } else {
                AssistantFileFallbackView(media: media)
            }
        }
        .task {
            localURL = writeInlineDataToTempFileIfNeeded()
        }
#else
        AssistantFileFallbackView(media: media)
#endif
    }

    private var resolvedURL: URL? {
        localURL ?? media.remoteURL
    }

    private func writeInlineDataToTempFileIfNeeded() -> URL? {
        guard let base64 = media.base64Data,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(media.id.uuidString)
            .appendingPathExtension(media.mimeType.fileExtensionHint)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return fileURL
    }
}

private struct AssistantVideoView: View {
    let media: GeneratedMedia
    @State private var localURL: URL?

    var body: some View {
#if canImport(AVKit)
        Group {
            if let url = resolvedURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(minHeight: 180)
            } else {
                AssistantFileFallbackView(media: media)
            }
        }
        .task {
            localURL = writeInlineDataToTempFileIfNeeded()
        }
#else
        AssistantFileFallbackView(media: media)
#endif
    }

    private var resolvedURL: URL? {
        localURL ?? media.remoteURL
    }

    private func writeInlineDataToTempFileIfNeeded() -> URL? {
        guard let base64 = media.base64Data,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(media.id.uuidString)
            .appendingPathExtension(media.mimeType.fileExtensionHint)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return fileURL
    }
}

private struct AssistantPDFView: View {
    let media: GeneratedMedia
    @State private var data: Data?

    var body: some View {
#if canImport(PDFKit)
        Group {
            if let inlineData = data {
                PDFContainerView(data: inlineData)
                    .frame(minHeight: 280)
            } else if let remoteURL = media.remoteURL {
                Link("Open PDF", destination: remoteURL)
                    .font(.callout.weight(.semibold))
            } else {
                AssistantFileFallbackView(media: media)
            }
        }
        .task {
            guard data == nil, let base64 = media.base64Data else { return }
            data = Data(base64Encoded: base64)
        }
#else
        AssistantFileFallbackView(media: media)
#endif
    }
}

private struct AssistantTextView: View {
    let media: GeneratedMedia
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120)
                .padding(8)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let remoteURL = media.remoteURL {
                Link("Open Text File", destination: remoteURL)
                    .font(.callout.weight(.semibold))
            } else {
                AssistantFileFallbackView(media: media)
            }
        }
        .onAppear {
            guard text == nil else { return }
            text = decodeTextData(from: media)
        }
    }
}

private struct AssistantJSONView: View {
    let media: GeneratedMedia
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 140)
                .padding(8)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let remoteURL = media.remoteURL {
                Link("Open JSON File", destination: remoteURL)
                    .font(.callout.weight(.semibold))
            } else {
                AssistantFileFallbackView(media: media)
            }
        }
        .onAppear {
            guard text == nil else { return }
            text = decodePrettyJSON(from: media)
        }
    }
}

private struct AssistantCSVView: View {
    let media: GeneratedMedia
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120)
                .padding(8)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let remoteURL = media.remoteURL {
                Link("Open CSV File", destination: remoteURL)
                    .font(.callout.weight(.semibold))
            } else {
                AssistantFileFallbackView(media: media)
            }
        }
        .onAppear {
            guard text == nil else { return }
            text = decodeTextData(from: media)
        }
    }
}

private struct AssistantFileFallbackView: View {
    let media: GeneratedMedia

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.12))
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attachment returned")
                        .font(.subheadline.weight(.semibold))
                    Text(media.mimeType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let url = media.remoteURL {
                        Link("Open", destination: url)
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(12)
            }
    }
}

#if canImport(PDFKit)
#if os(macOS)
private struct PDFContainerView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = PDFDocument(data: data)
    }
}
#elseif os(iOS)
private struct PDFContainerView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = PDFDocument(data: data)
    }
}
#endif
#endif

private extension String {
    var fileExtensionHint: String {
        let parts = split(separator: "/")
        guard let last = parts.last else { return "bin" }
        let cleaned = String(last).replacingOccurrences(of: "+xml", with: "")
        return cleaned.isEmpty ? "bin" : cleaned
    }
}

private extension GeneratedMedia {
    var suggestedFilename: String {
        if let remoteURL, !remoteURL.lastPathComponent.isEmpty {
            return remoteURL.lastPathComponent
        }
        return "assistant-output-\(id.uuidString.prefix(8)).\(mimeType.fileExtensionHint)"
    }
}

private func decodeTextData(from media: GeneratedMedia) -> String? {
    guard let base64 = media.base64Data,
          let data = Data(base64Encoded: base64) else {
        return nil
    }
    if let utf8 = String(data: data, encoding: .utf8) {
        return utf8
    }
    return String(decoding: data, as: UTF8.self)
}

private func decodePrettyJSON(from media: GeneratedMedia) -> String? {
    guard let base64 = media.base64Data,
          let data = Data(base64Encoded: base64) else {
        return nil
    }
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
    return String(data: prettyData, encoding: .utf8) ?? String(decoding: prettyData, as: UTF8.self)
}

struct AssistantImageView: View {
    let image: GeneratedImage

    var body: some View {
        AssistantMediaView(
            media: GeneratedMedia(
                kind: .image,
                mimeType: image.mimeType,
                base64Data: image.base64Data,
                remoteURL: image.remoteURL
            )
        )
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
