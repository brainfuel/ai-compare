import SwiftUI
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
