// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Markdown
import SwiftUI
import WebKit

/// Local notes and documents. Streaming updates preserve blocks and scroll position.
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    var followsStreamingOutput = false
    var preservesLineBreaks = false
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(markdown: markdown, isDark: colorScheme == .dark,
                                   followsStreamingOutput: followsStreamingOutput,
                                   preservesLineBreaks: preservesLineBreaks)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        webView.loadHTMLString(documentHTML(), baseURL: nil)
        return webView
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var pending = (markdown: "", isDark: false, follows: false, preservesLineBreaks: false)
        private var displayed: (markdown: String, isDark: Bool, preservesLineBreaks: Bool)?
        private var updateTask: Task<Void, Never>?
        private var isReady = false
        private var usesReloadFallback = false

        func update(markdown: String, isDark: Bool, followsStreamingOutput: Bool, preservesLineBreaks: Bool = false) {
            pending = (markdown, isDark, followsStreamingOutput, preservesLineBreaks)
            scheduleUpdate()
        }

        func cancel() {
            updateTask?.cancel()
            updateTask = nil
        }

        private func scheduleUpdate() {
            guard isReady, updateTask == nil else { return }
            updateTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { return }
                guard let self, let webView = self.webView, !Task.isCancelled else { return }
                let value = self.pending
                if self.displayed?.markdown == value.markdown, self.displayed?.isDark == value.isDark,
                   self.displayed?.preservesLineBreaks == value.preservesLineBreaks {
                    self.updateTask = nil
                    return
                }
                let html = MeetingMarkdown.html(value.markdown, preservesLineBreaks: value.preservesLineBreaks)
                if self.usesReloadFallback {
                    self.isReady = false
                    self.displayed = (value.markdown, value.isDark, value.preservesLineBreaks)
                    webView.loadHTMLString(MarkdownWebView.documentHTML(body: html, isDark: value.isDark), baseURL: nil)
                } else {
                    do {
                        _ = try await webView.callAsyncJavaScript(Self.updateScript,
                            arguments: ["html": html, "isDark": value.isDark, "follow": value.follows],
                            in: nil, contentWorld: .defaultClient)
                        guard !Task.isCancelled else { return }
                        self.displayed = (value.markdown, value.isDark, value.preservesLineBreaks)
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.usesReloadFallback = true
                        self.isReady = false
                        self.displayed = (value.markdown, value.isDark, value.preservesLineBreaks)
                        webView.loadHTMLString(MarkdownWebView.documentHTML(body: html, isDark: value.isDark), baseURL: nil)
                    }
                }
                self.updateTask = nil
                if self.pending.markdown != value.markdown || self.pending.isDark != value.isDark
                    || self.pending.preservesLineBreaks != value.preservesLineBreaks {
                    self.scheduleUpdate()
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            scheduleUpdate()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            cancel()
            isReady = false
            displayed = nil
            webView.loadHTMLString(MarkdownWebView.documentHTML(), baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Notes contain no active links, external resources, or page scripts.
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }

        // Trusted app code runs in its own content world. All note text arrives as data.
        private static let updateScript = """
        const root = document.querySelector('main');
        const atBottom = window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 48;
        const hadContent = root.childNodes.length > 0;
        const template = document.createElement('template');
        template.innerHTML = html;
        const incoming = Array.from(template.content.childNodes);
        let shared = 0;
        while (shared < root.childNodes.length && shared < incoming.length && root.childNodes[shared].isEqualNode(incoming[shared])) shared++;
        while (root.childNodes.length > shared) root.lastChild.remove();
        for (let i = shared; i < incoming.length; i++) root.appendChild(incoming[i]);
        document.documentElement.dataset.appearance = isDark ? 'dark' : 'light';
        if (follow && hadContent && atBottom) window.scrollTo(0, document.documentElement.scrollHeight);
        return true;
        """
    }

    static func documentHTML(body: String = "", isDark: Bool = false) -> String {
        """
        <!doctype html>
        <html data-appearance="\(isDark ? "dark" : "light")"><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme:light; --text:#1c1c1e; --secondary:#626267; --border:#d1d1d6; --code:#f2f2f7; }
        :root[data-appearance=dark] { color-scheme:dark; --text:#e5e5e7; --secondary:#aaaab0; --border:#48484a; --code:#2c2c2e; }
        * { box-sizing:border-box; }
        body { margin:0; padding:20px; font:\(Int(Size.documentText))px/1.6 -apple-system,BlinkMacSystemFont,sans-serif; color:var(--text); background:transparent; overflow-wrap:anywhere; -webkit-font-smoothing:antialiased; }
        h1,h2,h3,h4,h5,h6 { line-height:1.3; margin:16px 0 8px; }
        h1 { font-size:1.47em; } h2 { font-size:1.27em; } h3 { font-size:1.13em; }
        h4,h5,h6 { font-size:1em; } main>:first-child { margin-top:0; }
        p { margin:0 0 9px; } ul,ol { margin:0 0 9px; padding-left:22px; }
        li { margin:3px 0; } li>p { margin:0 0 3px; } strong { font-weight:600; }
        li.task-item { list-style:none; position:relative; }
        li.task-item>input { position:absolute; left:-22px; top:3px; }
        li.task-item>input+p { display:inline; }
        code { font:0.93em/1.5 "SF Mono",Menlo,monospace; background:var(--code); padding:1px 4px; border-radius:3px; }
        pre { background:var(--code); padding:10px 12px; border-radius:6px; overflow-x:auto; margin:10px 0; }
        pre code { background:none; padding:0; overflow-wrap:normal; }
        blockquote { border-left:3px solid var(--border); padding-left:12px; color:var(--secondary); margin:10px 0; }
        .table-scroll { overflow-x:auto; margin:10px 0; }
        table { border-collapse:collapse; width:100%; font-size:0.93em; }
        th,td { border:1px solid var(--border); padding:6px 10px; text-align:left; min-width:70px; }
        th { font-weight:600; background:var(--code); }
        hr { border:0; border-top:1px solid var(--border); margin:14px 0; }
        input[type=checkbox] { vertical-align:middle; margin-right:6px; }
        </style></head><body><main>\(body)</main></body></html>
        """
    }
}

/// The parser owns Markdown syntax; this renderer emits a small, passive HTML vocabulary.
enum MeetingMarkdown {
    static func html(_ markdown: String, preservesLineBreaks: Bool = false) -> String {
        var renderer = Renderer(preservesLineBreaks: preservesLineBreaks)
        return renderer.visit(Document(parsing: markdown))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private struct Renderer: MarkupVisitor {
        var preservesLineBreaks: Bool
        var isTableHead = false
        var column = 0
        var alignments: [Markdown.Table.ColumnAlignment?] = []

        mutating func defaultVisit(_ markup: any Markup) -> String {
            markup.children.map { visit($0) }.joined()
        }

        mutating func wrap(_ node: any Markup, in tag: String) -> String {
            "<\(tag)>\(defaultVisit(node))</\(tag)>"
        }

        mutating func visitText(_ text: Markdown.Text) -> String { MeetingMarkdown.escape(text.string) }
        mutating func visitParagraph(_ paragraph: Paragraph) -> String { wrap(paragraph, in: "p") }
        mutating func visitHeading(_ heading: Heading) -> String { wrap(heading, in: "h\(heading.level)") }
        mutating func visitStrong(_ strong: Strong) -> String { wrap(strong, in: "strong") }
        mutating func visitEmphasis(_ emphasis: Emphasis) -> String { wrap(emphasis, in: "em") }
        mutating func visitStrikethrough(_ text: Strikethrough) -> String { wrap(text, in: "del") }
        mutating func visitBlockQuote(_ quote: BlockQuote) -> String { wrap(quote, in: "blockquote") }
        mutating func visitUnorderedList(_ list: UnorderedList) -> String { wrap(list, in: "ul") }
        mutating func visitOrderedList(_ list: OrderedList) -> String {
            "<ol start=\"\(list.startIndex)\">\(defaultVisit(list))</ol>"
        }
        mutating func visitListItem(_ item: ListItem) -> String {
            let checkbox = item.checkbox.map { "<input type=\"checkbox\" disabled\($0 == .checked ? " checked" : "")>" } ?? ""
            let attributes = item.checkbox == nil ? "" : " class=\"task-item\""
            return "<li\(attributes)>\(checkbox)\(defaultVisit(item))</li>"
        }
        mutating func visitInlineCode(_ code: InlineCode) -> String { "<code>\(MeetingMarkdown.escape(code.code))</code>" }
        mutating func visitCodeBlock(_ code: CodeBlock) -> String { "<pre><code>\(MeetingMarkdown.escape(code.code))</code></pre>" }
        mutating func visitHTMLBlock(_ html: HTMLBlock) -> String { "<pre>\(MeetingMarkdown.escape(html.rawHTML))</pre>" }
        mutating func visitInlineHTML(_ html: InlineHTML) -> String { MeetingMarkdown.escape(html.rawHTML) }
        mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { preservesLineBreaks ? "<br>" : "\n" }
        mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>" }
        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String { "<hr>" }
        mutating func visitLink(_ link: Markdown.Link) -> String {
            defaultVisit(link) + (link.destination.map { " (\(MeetingMarkdown.escape($0)))" } ?? "")
        }
        mutating func visitImage(_ image: Markdown.Image) -> String {
            "[Image: \(defaultVisit(image))]" + (image.source.map { " (\(MeetingMarkdown.escape($0)))" } ?? "")
        }
        mutating func visitTable(_ table: Markdown.Table) -> String {
            alignments = table.columnAlignments
            return "<div class=\"table-scroll\">\(wrap(table, in: "table"))</div>"
        }
        mutating func visitTableHead(_ head: Markdown.Table.Head) -> String {
            isTableHead = true
            column = 0
            let result = "<thead><tr>\(defaultVisit(head))</tr></thead>"
            isTableHead = false
            return result
        }
        mutating func visitTableBody(_ body: Markdown.Table.Body) -> String { wrap(body, in: "tbody") }
        mutating func visitTableRow(_ row: Markdown.Table.Row) -> String {
            column = 0
            return wrap(row, in: "tr")
        }
        mutating func visitTableCell(_ cell: Markdown.Table.Cell) -> String {
            let tag = isTableHead ? "th" : "td"
            let alignment = column < alignments.count ? alignments[column] : nil
            column += 1
            let style: String
            switch alignment {
            case .center: style = " style=\"text-align:center\""
            case .right: style = " style=\"text-align:right\""
            default: style = ""
            }
            return "<\(tag)\(style)>\(defaultVisit(cell))</\(tag)>"
        }
    }
}
