import SwiftUI
import Textual
import UniformTypeIdentifiers
#if canImport(AVKit)
import AVKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - MarkdownText

struct MarkdownText: View {
    let raw: String
    var selectable: Bool = true

    init(_ raw: String, selectable: Bool = true) {
        self.raw = raw
        self.selectable = selectable
    }

    var body: some View {
        StructuredText(markdown: cappedHeadings)
            .textual.fontScale(0.82)
            .conditionalTextSelection(selectable)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Demotes H1 and H2 headings to H3 so models like Claude can't render
    /// enormous titles that dwarf the surrounding body text.
    private var cappedHeadings: String {
        raw.components(separatedBy: "\n").map { line in
            if line.hasPrefix("# ")  { return "### " + line.dropFirst(2) }
            if line.hasPrefix("## ") { return "### " + line.dropFirst(3) }
            return line
        }.joined(separator: "\n")
    }
}

extension View {
    @ViewBuilder
    func conditionalTextSelection(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            self
        }
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
            let requestedType = UTType(mimeType: media.mimeType) ?? .data
            exportType = ExportedMediaDocument.writableContentTypes.contains(requestedType) ? requestedType : .data
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
            throw AppError.api("No media data available to save.")
        }
        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppError.api("Failed to download media (\(http.statusCode)).")
        }
        return data
    }
}

private struct ExportedMediaDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] {
        [
            .data,
            .plainText,
            .utf8PlainText,
            .commaSeparatedText,
            .json,
            .pdf,
            .jpeg,
            .png,
            .gif,
            .mpeg4Movie,
            .quickTimeMovie,
            .mpeg4Audio,
            .mp3
        ]
    }
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
                .background(AppTheme.surfaceSecondary)
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
                .background(AppTheme.surfaceSecondary)
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
                .background(AppTheme.surfaceGrouped)
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
                .background(AppTheme.surfaceGrouped)
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
                .background(AppTheme.surfaceGrouped)
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
            .fill(AppTheme.surfaceSecondary)
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
                .fill(AppTheme.surfaceSecondary)
            Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

struct MessageAttachmentView: View {
    let attachment: AttachmentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isImage, let previewData {
#if os(macOS)
                if let image = NSImage(data: previewData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    fallbackRow
                }
#elseif os(iOS)
                if let image = UIImage(data: previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    fallbackRow
                }
#else
                fallbackRow
#endif
            } else {
                fallbackRow
            }

            Text(attachment.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isImage: Bool {
        attachment.mimeType?.hasPrefix("image/") ?? false
    }

    private var previewData: Data? {
        guard let base64 = attachment.previewBase64Data else { return nil }
        return Data(base64Encoded: base64)
    }

    private var fallbackRow: some View {
        HStack(spacing: 6) {
            Image(systemName: isImage ? "photo" : "doc")
            Text("Attachment")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - PDF Export button

/// Drop-in button that builds PDF data on tap and presents the native macOS share sheet.
struct PDFExportButton: View {
    let filename: String
    let buildData: () -> Data

#if os(iOS)
    @State private var shareURL: URL?
    @State private var isShowingShare = false
#endif

    var body: some View {
        Button { presentShareSheet() } label: {
            Image(systemName: "square.and.arrow.up")
                .offset(y: -2)
        }
        .help("Share / Export PDF")
#if os(iOS)
        .sheet(isPresented: $isShowingShare) {
            if let url = shareURL {
                ActivityView(items: [url])
                    .ignoresSafeArea()
            }
        }
#endif
    }

    private func presentShareSheet() {
#if os(macOS)
        let data = buildData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard (try? data.write(to: url)) != nil else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let contentView = window.contentView else { return }
            let picker = NSSharingServicePicker(items: [url])
            let anchor = CGRect(x: contentView.bounds.midX,
                                y: contentView.bounds.midY,
                                width: 1, height: 1)
            picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
        }
#elseif os(iOS)
        let data = buildData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard (try? data.write(to: url)) != nil else { return }
        shareURL = url
        isShowingShare = true
#endif
    }
}

#if os(iOS)
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - PDF builder (Core Text, A4, multi-page)

enum PDFBuilder {

    // A4 in points
    private static let pageW:  CGFloat = 595.28
    private static let pageH:  CGFloat = 841.89
    private static let margin: CGFloat = 50

    // MARK: Public entry points

    static func compareResponse(provider: AIProvider, runs: [CompareRun]) -> Data {
        render(composeCompare(provider: provider, runs: runs))
    }

    static func synthesisResult(_ result: SynthesisResult) -> Data {
        render(composeSynthesis(result))
    }

    // MARK: Content composers

    private static func composeCompare(provider: AIProvider, runs: [CompareRun]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out <<< heading("\(provider.displayName) — AI Compare")
        out <<< gap()

        let modelID = runs
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { $0.results[provider]?.modelID }
            .last(where: { !$0.isEmpty }) ?? ""
        if !modelID.isEmpty {
            out <<< secondary("Model: \(modelID)\n")
            out <<< gap(small: true)
        }
        out <<< gap()

        for run in runs.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let result = run.results[provider],
                  result.state == .success,
                  !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            out <<< bold("Q: \(run.prompt)\n")
            out <<< gap(small: true)
            out <<< parseMarkdown(result.text)
            out <<< gap()
            out <<< rule()
            out <<< gap()
        }
        return out
    }

    private static func composeSynthesis(_ r: SynthesisResult) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out <<< heading("Synthesis — AI Compare")
        out <<< gap()
        out <<< gap()

        if !r.consensus.isEmpty {
            out <<< sectionLabel("CONSENSUS")
            out <<< gap(small: true)
            r.consensus.forEach { out <<< inlineFormatted("• \($0.text)\n", size: 12, boldBase: false) }
            out <<< gap()
        }
        if !r.disagreements.isEmpty {
            out <<< sectionLabel("DISAGREEMENTS")
            out <<< gap(small: true)
            for d in r.disagreements {
                out <<< bold(d.topic + "\n")
                d.positions.forEach { pos in out <<< secondary("  \(pos.model): \(pos.position)\n") }
                out <<< gap(small: true)
            }
            out <<< gap()
        }
        if !r.unique.isEmpty {
            out <<< sectionLabel("UNIQUE POINTS")
            out <<< gap(small: true)
            r.unique.forEach { out <<< body("[\($0.source)]  \($0.claim)\n") }
            out <<< gap()
        }
        if !r.suspicious.isEmpty {
            out <<< sectionLabel("SUSPICIOUS CLAIMS")
            out <<< gap(small: true)
            r.suspicious.forEach { out <<< inlineFormatted("• \($0.text)\n", size: 12, boldBase: false) }
        }
        return out
    }

    // MARK: Markdown → attributed string

    /// Converts a markdown string into a styled NSAttributedString for PDF rendering.
    /// Block structure (headings, bullets, code fences, tables) is handled line-by-line;
    /// inline formatting (**bold**, *italic*, `code`) is delegated to Foundation's
    /// built-in AttributedString markdown parser.
    private static func parseMarkdown(_ raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inCodeBlock = false
        var tableLines: [String] = []

        func flushTable() {
            guard !tableLines.isEmpty else { return }
            result <<< buildTable(from: tableLines)
            result <<< gap(small: true)
            tableLines = []
        }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") { flushTable(); inCodeBlock.toggle(); continue }

            if inCodeBlock {
                result <<< styledSpan(line + "\n", size: 10, bold: false, italic: false, code: true)
                continue
            }

            // Accumulate table rows (lines that start with |)
            if trimmed.hasPrefix("|") {
                tableLines.append(trimmed)
                continue
            } else {
                flushTable()
            }

            if trimmed.isEmpty { result <<< gap(small: true); continue }

            if trimmed.hasPrefix("### ") {
                result <<< inlineFormatted(String(trimmed.dropFirst(4)) + "\n", size: 13, boldBase: true)
            } else if trimmed.hasPrefix("## ") {
                result <<< inlineFormatted(String(trimmed.dropFirst(3)) + "\n", size: 15, boldBase: true)
            } else if trimmed.hasPrefix("# ") {
                result <<< inlineFormatted(String(trimmed.dropFirst(2)) + "\n", size: 17, boldBase: true)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                result <<< inlineFormatted("• " + String(trimmed.dropFirst(2)) + "\n", size: 12, boldBase: false)
            } else {
                result <<< inlineFormatted(line + "\n", size: 12, boldBase: false)
            }
        }
        flushTable()
        return result
    }

    /// Renders a markdown table as a box-drawing monospace attributed string so it
    /// stays searchable text within the PDF and works with the existing CTFramesetter.
    private static func buildTable(from lines: [String]) -> NSAttributedString {
        // Parse rows, skipping separator lines (|---|---|)
        var parsedRows: [[String]] = []
        for line in lines {
            let stripped = line
                .replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: " ", with: "")
            if stripped.isEmpty { continue }  // separator row
            let cells = line
                .components(separatedBy: "|")
                .dropFirst()   // leading |
                .dropLast()    // trailing |
                .map { $0.trimmingCharacters(in: .whitespaces) }
            parsedRows.append(Array(cells))
        }
        guard !parsedRows.isEmpty else { return NSAttributedString() }

        let colCount = parsedRows[0].count

        // Natural column widths from content
        var colWidths = Array(repeating: 0, count: colCount)
        for row in parsedRows {
            for (i, cell) in row.enumerated() where i < colCount {
                colWidths[i] = max(colWidths[i], cell.count)
            }
        }

        // Fit to ~74 mono chars (≈ 495pt at 9pt mono)
        let overhead = colCount * 3 + 1   // borders + padding per column
        let available = 74 - overhead
        let natural = colWidths.reduce(0, +)
        if natural > available {
            let scale = Double(available) / Double(natural)
            colWidths = colWidths.map { max(4, Int((Double($0) * scale).rounded())) }
        }

        func pad(_ text: String, _ width: Int) -> String {
            text.count > width
                ? String(text.prefix(width - 1)) + "…"
                : text + String(repeating: " ", count: width - text.count)
        }
        func border(_ l: String, _ m: String, _ r: String) -> String {
            l + colWidths.map { String(repeating: "─", count: $0 + 2) }.joined(separator: m) + r + "\n"
        }

        var out = border("┌", "┬", "┐")
        for (rowIdx, row) in parsedRows.enumerated() {
            let isHeader = rowIdx == 0
            let cells = (0..<colCount).map { i -> String in
                let cell = i < row.count ? row[i] : ""
                return " " + pad(cell, colWidths[i]) + " "
            }
            out += "│" + cells.joined(separator: "│") + "│\n"
            if isHeader && parsedRows.count > 1 {
                out += border("├", "┼", "┤")
            }
        }
        out += border("└", "┴", "┘")

#if os(macOS)
        return NSAttributedString(string: out, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
#else
        return NSAttributedString(string: out, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: UIColor.label
        ])
#endif
    }

    /// Parses inline markdown (**bold**, *italic*, `code`) using Foundation's
    /// AttributedString parser, then maps the presentation intents to our custom fonts.
    private static func inlineFormatted(_ text: String, size: CGFloat, boldBase: Bool) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return styledSpan(text, size: size, bold: boldBase, italic: false, code: false)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let str = String(parsed[run.range].characters)
            guard !str.isEmpty else { continue }
            let intent = run.inlinePresentationIntent
            let isBold   = boldBase || (intent?.contains(.stronglyEmphasized) ?? false)
            let isItalic = intent?.contains(.emphasized) ?? false
            let isCode   = intent?.contains(.code) ?? false
            result <<< styledSpan(str, size: size, bold: isBold, italic: isItalic, code: isCode)
        }
        return result
    }

    private static func styledSpan(_ text: String, size: CGFloat, bold: Bool, italic: Bool, code: Bool) -> NSAttributedString {
#if os(macOS)
        let font: NSFont
        if code {
            font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        } else {
            let weight: NSFont.Weight = bold ? .bold : .regular
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            font = italic
                ? (NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base)
                : base
        }
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: code ? NSColor.systemBrown : NSColor.labelColor
        ])
#else
        let font: UIFont
        if code {
            font = UIFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        } else {
            let weight: UIFont.Weight = bold ? .bold : .regular
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            if italic, let desc = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: desc, size: size)
            } else {
                font = base
            }
        }
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: code ? UIColor.systemBrown : UIColor.label
        ])
#endif
    }

    // MARK: Attributed string helpers

    private static func heading(_ s: String) -> NSAttributedString {
        #if os(macOS)
        return NSAttributedString(string: s + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.labelColor])
        #else
        return NSAttributedString(string: s + "\n", attributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: UIColor.label])
        #endif
    }

    private static func bold(_ s: String) -> NSAttributedString {
        #if os(macOS)
        return NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor])
        #else
        return NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.label])
        #endif
    }

    private static func body(_ s: String) -> NSAttributedString {
        #if os(macOS)
        return NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor])
        #else
        return NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: 12),
            .foregroundColor: UIColor.label])
        #endif
    }

    private static func secondary(_ s: String) -> NSAttributedString {
        #if os(macOS)
        return NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor])
        #else
        return NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.secondaryLabel])
        #endif
    }

    private static func sectionLabel(_ s: String) -> NSAttributedString {
        #if os(macOS)
        return NSAttributedString(string: s + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor])
        #else
        return NSAttributedString(string: s + "\n", attributes: [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.secondaryLabel])
        #endif
    }

    private static func rule() -> NSAttributedString {
        #if os(macOS)
        return NSAttributedString(string: String(repeating: "─", count: 60) + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 3),
            .foregroundColor: NSColor.separatorColor])
        #else
        return NSAttributedString(string: String(repeating: "─", count: 60) + "\n", attributes: [
            .font: UIFont.systemFont(ofSize: 3),
            .foregroundColor: UIColor.separator])
        #endif
    }

    private static func gap(small: Bool = false) -> NSAttributedString {
        #if os(macOS)
        return NSAttributedString(string: small ? "\n" : "\n\n",
                                  attributes: [.font: NSFont.systemFont(ofSize: 6)])
        #else
        return NSAttributedString(string: small ? "\n" : "\n\n",
                                  attributes: [.font: UIFont.systemFont(ofSize: 6)])
        #endif
    }

    // MARK: Core Text renderer (A4, paginated)

    private static func render(_ content: NSAttributedString) -> Data {
        let data = NSMutableData()
        let contentRect = CGRect(x: margin, y: margin,
                                 width: pageW - 2 * margin,
                                 height: pageH - 2 * margin)
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageW, height: pageH))

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }

        let setter = CTFramesetterCreateWithAttributedString(content as CFAttributedString)
        var charIdx: CFIndex = 0
        let total  = CFIndex(content.length)

        repeat {
            ctx.beginPDFPage(nil)

            let path = CGMutablePath()
            path.addRect(contentRect)
            let frame = CTFramesetterCreateFrame(setter, CFRangeMake(charIdx, 0), path, nil)
            CTFrameDraw(frame, ctx)

            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { ctx.endPDFPage(); break }
            charIdx += visible.length

            ctx.endPDFPage()
        } while charIdx < total

        ctx.closePDF()
        return data as Data
    }
}

// Convenience append operator used only within PDFBuilder
infix operator <<<: AdditionPrecedence
private func <<< (lhs: NSMutableAttributedString, rhs: NSAttributedString) {
    lhs.append(rhs)
}
