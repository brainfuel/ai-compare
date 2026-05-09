import SwiftUI
import UniformTypeIdentifiers
import WebKit
#if canImport(AVKit)
import AVKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - MarkdownText (WebKit-backed)
//
// Renders model output by converting markdown to HTML and displaying it in
// a WKWebView. Tables, lists, code blocks and links all get native browser
// rendering, and selection works the way it does in Safari — drag across
// blocks, double-click to select word, triple-click to select paragraph,
// Cmd-A to select the whole message, Cmd-C to copy as rich text or HTML.
//
// The web view auto-sizes to its content via a small JS ResizeObserver
// bridge (see `MarkdownHTML.template`) so it lays out cleanly inside a
// SwiftUI `VStack` with no internal scrolling.

struct MarkdownText: View {
    let raw: String
    var selectable: Bool = true

    init(_ raw: String, selectable: Bool = true) {
        self.raw = raw
        self.selectable = selectable
    }

    @State private var height: CGFloat = 1

    var body: some View {
        MarkdownWebViewBridge(
            html: MarkdownHTML.render(cappedHeadings),
            selectable: selectable,
            height: $height
        )
        .frame(height: max(height, 1))
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

// Used by other views (e.g. ContentWorkspaceViews) to toggle SwiftUI text
// selection on subtrees that don't use MarkdownText.
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

// MARK: - WKWebView bridge

#if canImport(UIKit)
private struct MarkdownWebViewBridge: UIViewRepresentable {
    let html: String
    let selectable: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> MarkdownWebCoordinator {
        MarkdownWebCoordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "height")
        let v = WKWebView(frame: .zero, configuration: config)
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        v.scrollView.isScrollEnabled = false
        v.scrollView.bounces = false
        v.navigationDelegate = context.coordinator
        v.loadHTMLString(MarkdownHTML.template(body: html), baseURL: nil)
        context.coordinator.lastHTML = html
        applySelectable(v, selectable: selectable)
        return v
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if html != context.coordinator.lastHTML {
            context.coordinator.lastHTML = html
            context.coordinator.applyHTML(html, to: webView)
        }
        applySelectable(webView, selectable: selectable)
    }

    private func applySelectable(_ webView: WKWebView, selectable: Bool) {
        let css = selectable ? "auto" : "none"
        webView.evaluateJavaScript(
            "if(document.body){document.body.style.userSelect='\(css)';document.body.style.webkitUserSelect='\(css)';}",
            completionHandler: nil
        )
    }
}
#elseif canImport(AppKit)
private struct MarkdownWebViewBridge: NSViewRepresentable {
    let html: String
    let selectable: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> MarkdownWebCoordinator {
        MarkdownWebCoordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "height")
        let v = ScrollPassthroughWebView(frame: .zero, configuration: config)
        // Undocumented but stable: hides the default opaque page background
        // so the web view blends with the SwiftUI background.
        v.setValue(false, forKey: "drawsBackground")
        v.navigationDelegate = context.coordinator
        v.loadHTMLString(MarkdownHTML.template(body: html), baseURL: nil)
        context.coordinator.lastHTML = html
        return v
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if html != context.coordinator.lastHTML {
            context.coordinator.lastHTML = html
            context.coordinator.applyHTML(html, to: webView)
        }
        let css = selectable ? "auto" : "none"
        webView.evaluateJavaScript(
            "if(document.body){document.body.style.userSelect='\(css)';document.body.style.webkitUserSelect='\(css)';}",
            completionHandler: nil
        )
    }
}
#endif

#if canImport(AppKit)
/// Forwards scroll-wheel events to the next responder so the parent SwiftUI
/// ScrollView handles scrolling. The web view auto-sizes to its content
/// (height binding), so it never needs to scroll internally.
private final class ScrollPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // WKWebView adds its internal WKScrollView (NSScrollView subclass) lazily,
    // after viewDidMoveToWindow fires. didAddSubview is the reliable hook.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let sv = subview as? NSScrollView {
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.autohidesScrollers = false
        }
    }
}
#endif

// MARK: - WebKit coordinator

private final class MarkdownWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let height: Binding<CGFloat>
    var lastHTML: String = ""
    var didFinishLoad = false
    var pendingHTML: String?

    init(height: Binding<CGFloat>) {
        self.height = height
    }

    // ResizeObserver in the page posts content height here.
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "height" else { return }
        let value: CGFloat
        if let n = message.body as? NSNumber { value = CGFloat(truncating: n) }
        else if let d = message.body as? Double { value = CGFloat(d) }
        else { return }
        DispatchQueue.main.async { [height] in
            // Round to half-pixels so sub-pixel observer noise doesn't
            // ping-pong the SwiftUI layout pass.
            let rounded = (value * 2).rounded() / 2
            if abs(height.wrappedValue - rounded) > 0.5 {
                height.wrappedValue = rounded
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
        didFinishLoad = true
        if let pending = pendingHTML {
            applyHTML(pending, to: webView)
            pendingHTML = nil
        }
    }

    /// Replaces page content via JS rather than reloading, so streaming
    /// updates don't trigger a full navigation lifecycle.
    func applyHTML(_ html: String, to webView: WKWebView) {
        guard didFinishLoad else { pendingHTML = html; return }
        // Escape characters that would break the JS template literal.
        let escaped = html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")
        let script = """
        (function(){
          var el = document.getElementById('content');
          if (el) { el.innerHTML = `\(escaped)`; }
          if (typeof __notifyHeight === 'function') { __notifyHeight(); }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // Open clicked links in the system browser instead of navigating
    // the embedded web view.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - Markdown → HTML

/// Converts markdown source into a sanitized HTML fragment, plus a page
/// template that wraps the fragment with chat-tuned CSS and the JS bridge
/// needed for SwiftUI auto-sizing.
///
/// All user text is HTML-escaped before any tag is emitted, so model
/// output cannot inject `<script>` tags or arbitrary markup. Link URLs are
/// allow-listed to `http(s):` and `mailto:` schemes.
enum MarkdownHTML {

    /// Wraps body HTML in the chat page template (CSS + JS height bridge).
    static func template(body: String) -> String {
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
          font-size: 13px;
          line-height: 1.45;
          color: #1c1c1e;
          word-wrap: break-word;
          overflow-wrap: anywhere;
        }
        @media (prefers-color-scheme: dark) {
          body { color: #f2f2f7; }
        }
        h1, h2, h3, h4 { margin: 0.5em 0 0.2em; line-height: 1.2; font-weight: 600; }
        h1 { font-size: 18px; }
        h2 { font-size: 16px; }
        h3 { font-size: 14px; }
        h4 { font-size: 13px; }
        p { margin: 0.4em 0; }
        ul, ol { margin: 0.4em 0; padding-left: 1.4em; }
        li { margin: 0.15em 0; }
        code {
          font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
          font-size: 12px;
          background: rgba(127,127,127,0.18);
          padding: 0.1em 0.3em;
          border-radius: 3px;
        }
        pre {
          background: rgba(127,127,127,0.12);
          padding: 8px 10px;
          border-radius: 6px;
          overflow-x: auto;
          margin: 0.5em 0;
        }
        pre code { background: transparent; padding: 0; font-size: 12px; }
        table {
          border-collapse: collapse;
          margin: 0.5em 0;
          font-size: 12px;
          max-width: 100%;
        }
        th, td {
          border: 1px solid rgba(127,127,127,0.4);
          padding: 4px 8px;
          text-align: left;
          vertical-align: top;
        }
        th { background: rgba(127,127,127,0.12); font-weight: 600; }
        hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); margin: 0.8em 0; }
        a { color: #0a84ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        blockquote {
          margin: 0.4em 0;
          padding-left: 0.8em;
          border-left: 3px solid rgba(127,127,127,0.3);
          color: rgba(60,60,67,0.7);
        }
        @media (prefers-color-scheme: dark) {
          blockquote { color: rgba(235,235,245,0.6); }
        }
        #content > *:first-child { margin-top: 0; }
        #content > *:last-child  { margin-bottom: 0; }
        </style>
        </head><body>
        <div id="content">\(body)</div>
        <script>
        function __notifyHeight() {
          var h = document.documentElement.scrollHeight;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.height) {
            window.webkit.messageHandlers.height.postMessage(h);
          }
        }
        new ResizeObserver(__notifyHeight).observe(document.body);
        window.addEventListener('load', __notifyHeight);
        if (document.fonts && document.fonts.ready) {
          document.fonts.ready.then(__notifyHeight);
        }
        </script>
        </body></html>
        """
    }

    /// Converts a markdown string into a sanitized HTML fragment.
    static func render(_ raw: String) -> String {
        var out: [String] = []
        var inCode = false
        var codeBuffer: [String] = []
        var listType: ListType? = nil
        var listBuffer: [String] = []
        var tableLines: [String] = []
        var paraBuffer: [String] = []

        func flushPara() {
            guard !paraBuffer.isEmpty else { return }
            let joined = paraBuffer.joined(separator: " ")
            out.append("<p>\(inlineHTML(joined))</p>")
            paraBuffer = []
        }
        func flushList() {
            guard let lt = listType, !listBuffer.isEmpty else {
                listBuffer = []; listType = nil; return
            }
            let tag = lt == .ordered ? "ol" : "ul"
            let items = listBuffer.map { "<li>\(inlineHTML($0))</li>" }.joined()
            out.append("<\(tag)>\(items)</\(tag)>")
            listBuffer = []
            listType = nil
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            out.append(buildTableHTML(from: tableLines))
            tableLines = []
        }
        func flushAll() { flushPara(); flushList(); flushTable() }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fence
            if trimmed.hasPrefix("```") {
                if inCode {
                    let body = codeBuffer.joined(separator: "\n")
                    out.append("<pre><code>\(escape(body))</code></pre>")
                    codeBuffer = []
                    inCode = false
                } else {
                    flushAll()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBuffer.append(line)
                continue
            }

            // Table rows
            if trimmed.hasPrefix("|") {
                flushPara(); flushList()
                tableLines.append(trimmed)
                continue
            } else {
                flushTable()
            }

            // Headings
            if trimmed.hasPrefix("### ") {
                flushAll()
                out.append("<h3>\(inlineHTML(String(trimmed.dropFirst(4))))</h3>")
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushAll()
                out.append("<h2>\(inlineHTML(String(trimmed.dropFirst(3))))</h2>")
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushAll()
                out.append("<h1>\(inlineHTML(String(trimmed.dropFirst(2))))</h1>")
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" {
                flushAll()
                out.append("<hr>")
                continue
            }

            // Bullets
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushPara(); flushTable()
                if listType != .unordered { flushList(); listType = .unordered }
                listBuffer.append(String(trimmed.dropFirst(2)))
                continue
            }

            // Ordered list (e.g. "1. ", "12. ")
            if let dot = trimmed.firstIndex(of: "."),
               trimmed.distance(from: trimmed.startIndex, to: dot) <= 3,
               Int(trimmed[trimmed.startIndex..<dot]) != nil,
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                flushPara(); flushTable()
                if listType != .ordered { flushList(); listType = .ordered }
                let body = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
                listBuffer.append(body)
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                flushAll()
                out.append("<blockquote>\(inlineHTML(String(trimmed.dropFirst(2))))</blockquote>")
                continue
            }

            // Blank line — flush block in progress
            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // Default: append to paragraph buffer
            flushList(); flushTable()
            paraBuffer.append(line)
        }

        if inCode {
            let body = codeBuffer.joined(separator: "\n")
            out.append("<pre><code>\(escape(body))</code></pre>")
        }
        flushAll()

        return out.joined()
    }

    private enum ListType { case ordered, unordered }

    // MARK: Inline

    /// Converts inline markdown (`code`, **bold**, *italic*, [text](url))
    /// into HTML. Input is HTML-escaped first, so user content cannot
    /// inject raw markup.
    private static func inlineHTML(_ raw: String) -> String {
        var s = escape(raw)

        // Code spans — process first so contents aren't further parsed.
        s = replaceRegex(s, pattern: "`([^`]+)`") { m in
            "<code>\(m[1])</code>"
        }
        // Bold **text** and __text__
        s = replaceRegex(s, pattern: "\\*\\*([^*]+)\\*\\*") { m in
            "<strong>\(m[1])</strong>"
        }
        s = replaceRegex(s, pattern: "__([^_]+)__") { m in
            "<strong>\(m[1])</strong>"
        }
        // Italic *text* and _text_ (single underscore/asterisk only)
        s = replaceRegex(s, pattern: "(^|[^*])\\*([^*\n]+)\\*") { m in
            "\(m[1])<em>\(m[2])</em>"
        }
        s = replaceRegex(s, pattern: "(^|[^_])_([^_\n]+)_") { m in
            "\(m[1])<em>\(m[2])</em>"
        }
        // Links [text](url) — allow-list http(s) and mailto schemes.
        s = replaceRegex(s, pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)") { m in
            let url = m[2]
            let safe = url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("mailto:")
            return safe
                ? "<a href=\"\(url)\">\(m[1])</a>"
                : m[1]
        }

        return s
    }

    // MARK: Tables

    private static func buildTableHTML(from lines: [String]) -> String {
        var rows: [[String]] = []
        for line in lines {
            // Skip separator rows (only |, -, :, whitespace).
            let stripped = line
                .replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: " ", with: "")
            if stripped.isEmpty { continue }
            let cells = line
                .components(separatedBy: "|")
                .dropFirst()
                .dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            rows.append(Array(cells))
        }
        guard !rows.isEmpty else { return "" }

        var html = "<table>"
        if rows.count == 1 {
            html += "<thead><tr>"
            for cell in rows[0] {
                html += "<th>\(inlineHTML(cell))</th>"
            }
            html += "</tr></thead></table>"
            return html
        }
        // Header row
        html += "<thead><tr>"
        for cell in rows[0] {
            html += "<th>\(inlineHTML(cell))</th>"
        }
        html += "</tr></thead><tbody>"
        // Body rows
        for row in rows.dropFirst() {
            html += "<tr>"
            for cell in row {
                html += "<td>\(inlineHTML(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    // MARK: Helpers

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Runs `pattern` against `input` and replaces every match using
    /// `transform`, which receives the full match at `[0]` and capture
    /// groups at `[1]…[n]`. Missing groups are passed as empty strings.
    private static func replaceRegex(
        _ input: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let ns = input as NSString
        let matches = regex.matches(
            in: input, options: [],
            range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return input }

        var out = ""
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                out += ns.substring(with: NSRange(
                    location: cursor,
                    length: m.range.location - cursor
                ))
            }
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(
                location: cursor,
                length: ns.length - cursor
            ))
        }
        return out
    }
}

// MARK: - ConversationView (single-WKWebView transcript)
//
// Renders the entire conversation in ONE WKWebView so text selection can
// span across user and assistant messages — drag from a green user prompt
// down through the assistant reply just like in a real web page.
//
// Inline images render as <img>. Non-image artefacts (PDF, audio, video,
// JSON, CSV, generic files) render as click-cards that post a JS message
// back to Swift; the parent SwiftUI view then presents the existing native
// `MessageAttachmentView` / `AssistantMediaView` in a sheet.

struct ConversationView: View {
    let messages: [ChatMessage]
    let streamingText: String?
    var onScroll: (() -> Void)? = nil

    @State private var lastScrollY: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    InlineConversationView(messages: messages, streamingText: streamingText)
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newY in
                if abs(newY - lastScrollY) > 1 {
                    lastScrollY = newY
                    onScroll?()
                }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: streamingText ?? "") { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }
}

/// A single WKWebView rendering of a `[ChatMessage]` conversation, sized to
/// its content. Use directly inside another scroll view (e.g. compare cards).
/// Tapping non-image attachments opens a native sheet with the existing
/// `MessageAttachmentView` / `AssistantMediaView`.
struct InlineConversationView: View {
    let messages: [ChatMessage]
    let streamingText: String?

    @State private var height: CGFloat = 1
    @State private var openSheet: ConversationSheet?

    var body: some View {
        ConversationWebViewBridge(
            html: ConversationHTML.render(messages: messages, streamingText: streamingText),
            height: $height,
            onOpen: { kind, id in handleOpen(kind: kind, id: id) }
        )
        .frame(height: max(height, 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $openSheet) { item in
            ConversationSheetView(item: item) { openSheet = nil }
        }
    }

    private func handleOpen(kind: String, id: UUID) {
        if kind == "attachment" {
            for m in messages {
                if let a = m.attachments.first(where: { $0.id == id }) {
                    openSheet = .attachment(a); return
                }
            }
        } else if kind == "media" {
            for m in messages {
                if let g = m.generatedMedia.first(where: { $0.id == id }) {
                    openSheet = .media(g); return
                }
            }
        }
    }
}

enum ConversationSheet: Identifiable {
    case attachment(AttachmentSummary)
    case media(GeneratedMedia)

    var id: UUID {
        switch self {
        case .attachment(let a): return a.id
        case .media(let m): return m.id
        }
    }
}

private struct ConversationSheetView: View {
    let item: ConversationSheet
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done", action: onDismiss).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            ScrollView {
                Group {
                    switch item {
                    case .attachment(let a): MessageAttachmentView(attachment: a)
                    case .media(let m): AssistantMediaView(media: m)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}

// MARK: - Conversation web view bridge

#if canImport(UIKit)
private struct ConversationWebViewBridge: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    var onOpen: (String, UUID) -> Void

    func makeCoordinator() -> ConversationWebCoordinator {
        ConversationWebCoordinator(height: $height, onOpen: onOpen)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "height")
        config.userContentController.add(context.coordinator, name: "open")
        let v = WKWebView(frame: .zero, configuration: config)
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        v.scrollView.isScrollEnabled = false
        v.scrollView.bounces = false
        v.navigationDelegate = context.coordinator
        v.loadHTMLString(ConversationHTML.template(body: html), baseURL: nil)
        context.coordinator.lastHTML = html
        return v
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpen = onOpen
        if html != context.coordinator.lastHTML {
            context.coordinator.lastHTML = html
            context.coordinator.applyHTML(html, to: webView)
        }
    }
}
#elseif canImport(AppKit)
private struct ConversationWebViewBridge: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    var onOpen: (String, UUID) -> Void

    func makeCoordinator() -> ConversationWebCoordinator {
        ConversationWebCoordinator(height: $height, onOpen: onOpen)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "height")
        config.userContentController.add(context.coordinator, name: "open")
        let v = ScrollPassthroughWebView(frame: .zero, configuration: config)
        v.setValue(false, forKey: "drawsBackground")
        v.navigationDelegate = context.coordinator
        v.loadHTMLString(ConversationHTML.template(body: html), baseURL: nil)
        context.coordinator.lastHTML = html
        return v
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpen = onOpen
        if html != context.coordinator.lastHTML {
            context.coordinator.lastHTML = html
            context.coordinator.applyHTML(html, to: webView)
        }
    }
}
#endif

private final class ConversationWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let height: Binding<CGFloat>
    var onOpen: (String, UUID) -> Void
    var lastHTML: String = ""
    var didFinishLoad = false
    var pendingHTML: String?

    init(height: Binding<CGFloat>, onOpen: @escaping (String, UUID) -> Void) {
        self.height = height
        self.onOpen = onOpen
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "height" {
            let value: CGFloat
            if let n = message.body as? NSNumber { value = CGFloat(truncating: n) }
            else if let d = message.body as? Double { value = CGFloat(d) }
            else { return }
            DispatchQueue.main.async { [height] in
                let rounded = (value * 2).rounded() / 2
                if abs(height.wrappedValue - rounded) > 0.5 {
                    height.wrappedValue = rounded
                }
            }
        } else if message.name == "open" {
            guard let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let idStr = body["id"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            DispatchQueue.main.async { [self] in onOpen(kind, id) }
        }
    }

    func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
        didFinishLoad = true
        if let pending = pendingHTML {
            applyHTML(pending, to: webView)
            pendingHTML = nil
        }
    }

    func applyHTML(_ html: String, to webView: WKWebView) {
        guard didFinishLoad else { pendingHTML = html; return }
        let escaped = html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")
        let script = """
        (function(){
          var el = document.getElementById('content');
          if (el) { el.innerHTML = `\(escaped)`; }
          if (typeof __notifyHeight === 'function') { __notifyHeight(); }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - Conversation HTML builder

enum ConversationHTML {
    static func template(body: String) -> String {
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
          font-size: 13px;
          line-height: 1.45;
          color: #1c1c1e;
          word-wrap: break-word;
          overflow-wrap: anywhere;
        }
        @media (prefers-color-scheme: dark) { body { color: #f2f2f7; } }
        .message { padding: 10px 12px; border-radius: 10px; margin: 10px 0; }
        .message.user { background: rgba(120, 200, 130, 0.18); }
        .message.assistant { background: rgba(127, 127, 127, 0.10); }
        .message .role { font-size: 11px; opacity: 0.6; margin-bottom: 4px; text-transform: capitalize; }
        .message > .body > :first-child { margin-top: 0; }
        .message > .body > :last-child { margin-bottom: 0; }
        h1, h2, h3 { margin: 0.7em 0 0.35em; font-weight: 600; }
        h3 { font-size: 14px; }
        p { margin: 0.4em 0; }
        ul, ol { margin: 0.4em 0; padding-left: 1.4em; }
        li { margin: 0.15em 0; }
        code { font-family: "SF Mono", Menlo, monospace; font-size: 12px; background: rgba(127,127,127,0.18); padding: 1px 4px; border-radius: 3px; }
        pre { background: rgba(127,127,127,0.12); padding: 8px 10px; border-radius: 6px; overflow-x: auto; }
        pre code { background: transparent; padding: 0; }
        blockquote { margin: 0.5em 0; padding-left: 10px; border-left: 3px solid rgba(127,127,127,0.3); opacity: 0.85; }
        a { color: #0a84ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        table { border-collapse: collapse; margin: 0.6em 0; }
        th, td { border: 1px solid rgba(127,127,127,0.35); padding: 4px 8px; text-align: left; vertical-align: top; }
        th { background: rgba(127,127,127,0.12); }
        img.inline-image { max-width: 100%; max-height: 320px; display: block; border-radius: 8px; margin: 6px 0; }
        .attachment-card, .media-card {
          display: inline-flex; align-items: center; gap: 8px;
          padding: 8px 12px; margin: 4px 6px 4px 0;
          background: rgba(127,127,127,0.12);
          border: 1px solid rgba(127,127,127,0.25);
          border-radius: 8px;
          cursor: pointer;
          user-select: none;
          font-size: 12px;
        }
        .attachment-card:hover, .media-card:hover { background: rgba(127,127,127,0.20); }
        .icon { font-size: 16px; }
        .token-row { font-size: 11px; opacity: 0.6; margin-top: 6px; }
        </style></head><body>
        <div id="content">\(body)</div>
        <script>
        (function(){
          let lastHeight = 0;
          window.__notifyHeight = function(){
            const h = document.documentElement.scrollHeight;
            if (Math.abs(h - lastHeight) > 0.5) {
              lastHeight = h;
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.height) {
                window.webkit.messageHandlers.height.postMessage(h);
              }
            }
          };
          const ro = new ResizeObserver(function(){ window.__notifyHeight(); });
          ro.observe(document.documentElement);
          window.__notifyHeight();
          document.addEventListener('click', function(e){
            const card = e.target.closest('[data-open-kind]');
            if (card) {
              e.preventDefault();
              const kind = card.dataset.openKind;
              const id = card.dataset.openId;
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.open) {
                window.webkit.messageHandlers.open.postMessage({ kind: kind, id: id });
              }
            }
          });
        })();
        </script></body></html>
        """
    }

    static func render(messages: [ChatMessage], streamingText: String?) -> String {
        var out = ""
        for m in messages { out += renderMessage(m) }
        if let s = streamingText, !s.isEmpty {
            let placeholder = ChatMessage(role: .assistant, text: s, attachments: [])
            out += renderMessage(placeholder)
        }
        return out
    }

    private static func renderMessage(_ m: ChatMessage) -> String {
        let roleClass = (m.role == .user) ? "user" : "assistant"
        let roleLabel = MarkdownHTML.escape(m.role.label)
        let bodyHTML = m.text.isEmpty ? "" : MarkdownHTML.render(capHeadings(m.text))

        var attachments = ""
        for a in m.attachments { attachments += attachmentCard(a) }
        var media = ""
        for g in m.generatedMedia { media += mediaCard(g) }

        var tokenRow = ""
        if m.role == .assistant, m.inputTokens > 0 || m.outputTokens > 0 {
            let model = MarkdownHTML.escape(m.modelID ?? "")
            tokenRow = "<div class=\"token-row\">\(model) · in \(m.inputTokens) · out \(m.outputTokens)</div>"
        }

        return """
        <div class="message \(roleClass)">
          <div class="role">\(roleLabel)</div>
          <div class="body">\(bodyHTML)</div>
          \(attachments)\(media)\(tokenRow)
        </div>
        """
    }

    private static func capHeadings(_ raw: String) -> String {
        raw.components(separatedBy: "\n").map { line in
            if line.hasPrefix("# ")  { return "### " + line.dropFirst(2) }
            if line.hasPrefix("## ") { return "### " + line.dropFirst(3) }
            return line
        }.joined(separator: "\n")
    }

    private static func attachmentCard(_ a: AttachmentSummary) -> String {
        let name = MarkdownHTML.escape(a.name)
        let mime = a.mimeType ?? ""
        if let b64 = a.previewBase64Data, mime.hasPrefix("image/") {
            return "<img class=\"inline-image\" src=\"data:\(mime);base64,\(b64)\" alt=\"\(name)\">"
        }
        let icon = iconForMime(mime)
        return """
        <div class="attachment-card" data-open-kind="attachment" data-open-id="\(a.id.uuidString)">
          <span class="icon">\(icon)</span><span class="name">\(name)</span>
        </div>
        """
    }

    private static func mediaCard(_ g: GeneratedMedia) -> String {
        if g.kind == .image, let b64 = g.base64Data {
            let mime = MarkdownHTML.escape(g.mimeType)
            return "<img class=\"inline-image\" src=\"data:\(mime);base64,\(b64)\" alt=\"image\">"
        }
        let label: String
        switch g.kind {
        case .image: label = "Image"
        case .audio: label = "Audio"
        case .video: label = "Video"
        case .pdf:   label = "PDF"
        case .text:  label = "Text"
        case .json:  label = "JSON"
        case .csv:   label = "CSV"
        case .file:  label = "File"
        }
        let icon = iconForKind(g.kind)
        let mime = MarkdownHTML.escape(g.mimeType)
        return """
        <div class="media-card" data-open-kind="media" data-open-id="\(g.id.uuidString)">
          <span class="icon">\(icon)</span><span class="name">\(label) · \(mime)</span>
        </div>
        """
    }

    private static func iconForMime(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "🖼" }
        if mime.hasPrefix("audio/") { return "🎵" }
        if mime.hasPrefix("video/") { return "🎬" }
        if mime.contains("pdf") { return "📄" }
        return "📎"
    }

    private static func iconForKind(_ k: GeneratedMediaKind) -> String {
        switch k {
        case .image: return "🖼"
        case .audio: return "🎵"
        case .video: return "🎬"
        case .pdf:   return "📄"
        case .text:  return "📄"
        case .json:  return "🧾"
        case .csv:   return "🧾"
        case .file:  return "📎"
        }
    }
}

// MARK: - Selectable text view bridge

/// Cross-platform wrapper that hosts an `NSAttributedString` in a non-editable,
/// fully-selectable text view sized to its content (no internal scrolling).
private struct SelectableAttributedText: View {
    let attributed: NSAttributedString
    let selectable: Bool

    var body: some View {
        SelectableAttributedTextRepresentable(
            attributed: attributed,
            selectable: selectable
        )
    }
}

#if canImport(UIKit)
private struct SelectableAttributedTextRepresentable: UIViewRepresentable {
    let attributed: NSAttributedString
    let selectable: Bool

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.textContainer.widthTracksTextView = true
        v.dataDetectorTypes = [.link]
        v.linkTextAttributes = [
            .foregroundColor: UIColor.tintColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        v.adjustsFontForContentSizeCategory = true
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.attributedText != attributed {
            v.attributedText = attributed
        }
        v.isSelectable = selectable
        v.invalidateIntrinsicContentSize()
    }

    /// Width-constrained sizing. Without this UITextView's intrinsicContentSize
    /// is reported with an unconstrained width, which SwiftUI then squashes to
    /// zero height when laid out in a VStack.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let target = CGSize(width: width, height: .greatestFiniteMagnitude)
        return uiView.sizeThatFits(target)
    }
}
#elseif canImport(AppKit)
private struct SelectableAttributedTextRepresentable: NSViewRepresentable {
    let attributed: NSAttributedString
    let selectable: Bool

    func makeNSView(context: Context) -> NSTextView {
        let v = NSTextView()
        v.isEditable = false
        v.isVerticallyResizable = true
        v.isHorizontallyResizable = false
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = true
        v.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        v.isAutomaticLinkDetectionEnabled = true
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        if v.textStorage?.isEqual(to: attributed) != true {
            v.textStorage?.setAttributedString(attributed)
        }
        v.isSelectable = selectable
        v.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 10_000
        nsView.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        nsView.layoutManager?.glyphRange(for: nsView.textContainer!)
        let used = nsView.layoutManager?.usedRect(for: nsView.textContainer!).size ?? .zero
        return CGSize(width: width, height: ceil(used.height))
    }
}
#endif

// MARK: - Markdown → NSAttributedString (screen-tuned)

/// Lightweight markdown renderer for on-screen display. Mirrors the block
/// structure of `PDFBuilder.parseMarkdown` (headings, bullets, code fences,
/// inline emphasis) but uses larger system fonts suited to chat reading.
/// Tables and other heavyweight constructs fall through as plain text.
enum MarkdownAttributed {

    static func render(_ raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var inCode = false
        var tableLines: [String] = []

        func flushTable() {
            guard !tableLines.isEmpty else { return }
            result.append(buildTable(from: tableLines))
            result.append(NSAttributedString(string: "\n"))
            tableLines = []
        }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushTable()
                inCode.toggle()
                result.append(NSAttributedString(string: "\n"))
                continue
            }

            if inCode {
                result.append(span(line + "\n", size: 12, mono: true))
                continue
            }

            // Accumulate consecutive `|`-prefixed rows into a table.
            if trimmed.hasPrefix("|") {
                tableLines.append(trimmed)
                continue
            } else {
                flushTable()
            }

            if trimmed.isEmpty {
                result.append(NSAttributedString(string: "\n"))
                continue
            }

            if trimmed.hasPrefix("### ") {
                result.append(inline(String(trimmed.dropFirst(4)) + "\n", size: 14, baseBold: true))
            } else if trimmed.hasPrefix("## ") {
                result.append(inline(String(trimmed.dropFirst(3)) + "\n", size: 16, baseBold: true))
            } else if trimmed.hasPrefix("# ") {
                result.append(inline(String(trimmed.dropFirst(2)) + "\n", size: 18, baseBold: true))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let bullet = bulletParagraph()
                let body = inline("•  " + String(trimmed.dropFirst(2)) + "\n", size: 13, baseBold: false)
                let mut = NSMutableAttributedString(attributedString: body)
                mut.addAttribute(.paragraphStyle, value: bullet, range: NSRange(location: 0, length: mut.length))
                result.append(mut)
            } else {
                result.append(inline(line + "\n", size: 13, baseBold: false))
            }
        }
        flushTable()
        return result
    }

    // MARK: Tables
    //
    // Renders pipe-delimited markdown tables as box-drawing monospace text so
    // they stay visually aligned, fully selectable, and copyable as plain text.
    // Mirrors `PDFBuilder.buildTable` but tuned for screen widths.

    private static func buildTable(from lines: [String]) -> NSAttributedString {
        var parsedRows: [[String]] = []
        for line in lines {
            // A separator row contains only |, -, :, and whitespace — skip it.
            let stripped = line
                .replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: " ", with: "")
            if stripped.isEmpty { continue }
            let cells = line
                .components(separatedBy: "|")
                .dropFirst()   // leading pipe
                .dropLast()    // trailing pipe
                .map { $0.trimmingCharacters(in: .whitespaces) }
            parsedRows.append(Array(cells))
        }
        guard !parsedRows.isEmpty else { return NSAttributedString() }

        let colCount = parsedRows.map { $0.count }.max() ?? 0
        guard colCount > 0 else { return NSAttributedString() }

        // Natural column widths from content (Unicode-scalar count keeps
        // emoji/CJK from blowing the layout).
        var colWidths = Array(repeating: 0, count: colCount)
        for row in parsedRows {
            for (i, cell) in row.enumerated() where i < colCount {
                colWidths[i] = max(colWidths[i], cell.count)
            }
        }

        // Fit to ~90 mono columns at 11pt — comfortable for chat width.
        let targetCols = 90
        let overhead = colCount * 3 + 1
        let available = max(targetCols - overhead, colCount * 4)
        let natural = colWidths.reduce(0, +)
        if natural > available {
            let scale = Double(available) / Double(natural)
            colWidths = colWidths.map { max(4, Int((Double($0) * scale).rounded())) }
        }

        func pad(_ text: String, _ width: Int) -> String {
            text.count > width
                ? String(text.prefix(max(width - 1, 0))) + "…"
                : text + String(repeating: " ", count: max(width - text.count, 0))
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

        // Tight paragraph spacing keeps the box rendering as a single block.
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 0
        p.paragraphSpacing = 0
        p.paragraphSpacingBefore = 0

        var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: p]
        #if canImport(UIKit)
        attrs[.font] = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        attrs[.foregroundColor] = UIColor.label
        #else
        attrs[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        attrs[.foregroundColor] = NSColor.labelColor
        #endif
        return NSAttributedString(string: out, attributes: attrs)
    }

    // MARK: Inline

    private static func inline(_ text: String, size: CGFloat, baseBold: Bool) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return span(text, size: size, mono: false, bold: baseBold)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let str = String(parsed[run.range].characters)
            guard !str.isEmpty else { continue }
            let intent = run.inlinePresentationIntent
            let isBold = baseBold || (intent?.contains(.stronglyEmphasized) ?? false)
            let isItalic = intent?.contains(.emphasized) ?? false
            let isCode = intent?.contains(.code) ?? false
            let link = run.link
            out.append(span(str, size: size, mono: isCode, bold: isBold, italic: isItalic, link: link))
        }
        return out
    }

    // MARK: Span

    private static func span(
        _ text: String,
        size: CGFloat,
        mono: Bool,
        bold: Bool = false,
        italic: Bool = false,
        link: URL? = nil
    ) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [:]

        #if canImport(UIKit)
        let font: UIFont
        if mono {
            font = UIFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        } else {
            let weight: UIFont.Weight = bold ? .semibold : .regular
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            if italic, let desc = base.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: desc, size: size)
            } else {
                font = base
            }
        }
        attrs[.font] = font
        attrs[.foregroundColor] = mono ? UIColor.systemBrown : UIColor.label
        if mono {
            attrs[.backgroundColor] = UIColor.secondarySystemFill
        }
        #else
        let font: NSFont
        if mono {
            font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        } else {
            let weight: NSFont.Weight = bold ? .semibold : .regular
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if italic {
                font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base
            } else {
                font = base
            }
        }
        attrs[.font] = font
        attrs[.foregroundColor] = mono ? NSColor.systemBrown : NSColor.labelColor
        if mono {
            attrs[.backgroundColor] = NSColor.tertiaryLabelColor.withAlphaComponent(0.15)
        }
        #endif

        if let link {
            attrs[.link] = link
        }

        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: Paragraph styles

    private static func bulletParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 0
        p.headIndent = 18
        p.paragraphSpacing = 2
        return p
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
