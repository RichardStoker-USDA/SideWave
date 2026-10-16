// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import WebKit
import XCTest
@testable import SideWave

final class MeetingMarkdownTests: XCTestCase {
    func testDocumentLineBreaksPreserveSignoffsAndAddressesWithoutChangingLists() {
        let text = "Hello Sam,\n\nSend the notes to:\nField Office\nRoom 12\n\n- Schedule\n- Open questions\n\nThanks,\nAlex"
        let document = MeetingMarkdown.html(text, preservesLineBreaks: true)
        XCTAssertTrue(document.contains("<p>Send the notes to:<br>Field Office<br>Room 12</p>"))
        XCTAssertTrue(document.contains("<p>Thanks,<br>Alex</p>"))
        XCTAssertTrue(document.contains("<ul><li><p>Schedule</p></li><li><p>Open questions</p></li></ul>"))
        XCTAssertFalse(MeetingMarkdown.html(text).contains("<br>"), "Meeting Markdown retains normal paragraph wrapping")
        XCTAssertEqual(MeetingMarkdown.html("```text\nA\nB\n```", preservesLineBreaks: true), "<pre><code>A\nB\n</code></pre>")
    }

    func testTablesNestedListsAndTasksRenderAsStructure() {
        let html = MeetingMarkdown.html("""
        | Owner | Due |
        | :--- | ---: |
        | Speaker 1 | Friday |

        3. Review
           - Samples
           - Records

        - [x] Send the report
        - [ ] Check labels
        """)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">Due</th>"))
        XCTAssertTrue(html.contains("<td>Speaker 1</td>"))
        XCTAssertTrue(html.contains("<ol start=\"3\">"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("disabled checked"))
        XCTAssertTrue(html.contains("disabled>"))
    }

    func testCodeStaysLiteralAndHeadingsKeepInlineFormatting() {
        let html = MeetingMarkdown.html("# **Report**\n\n`**literal** <key>`\n\n```swift\nif a < b { print(\"value\") }\n```")
        XCTAssertTrue(html.contains("<h1><strong>Report</strong></h1>"))
        XCTAssertTrue(html.contains("<code>**literal** &lt;key&gt;</code>"))
        XCTAssertTrue(html.contains("if a &lt; b"))
        XCTAssertFalse(html.contains("<key>"))
    }

    func testUnclosedCodeFenceAndUnicodeSurviveStreaming() {
        let html = MeetingMarkdown.html("日本語 café 🌿\n\n```text\n**keep this literal** & done")
        XCTAssertTrue(html.contains("日本語 café 🌿"))
        XCTAssertTrue(html.contains("**keep this literal** &amp; done"))
        XCTAssertTrue(html.hasSuffix("</code></pre>"))
    }

    func testRawHTMLLinksAndImagesCannotLoadContent() {
        let html = MeetingMarkdown.html("""
        <script>window.noteScriptRan = true</script>

        [open](javascript:alert%281%29) ![chart](https://example.invalid/chart.png)

        <iframe src="https://example.invalid"></iframe>
        """)
        for tag in ["<script", "<iframe", "<img", "<a "] { XCTAssertFalse(html.contains(tag)) }
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("chart"))
    }
}

@MainActor
final class MeetingMarkdownWebViewTests: XCTestCase {
    func testDocumentBreaksRenderOnSeparateLinesAndCanReturnToMeetingWrapping() async throws {
        let coordinator = MarkdownWebView.Coordinator()
        let webView = MarkdownWebView.makeWebView(coordinator: coordinator)
        webView.frame = NSRect(x: 0, y: 0, width: 600, height: 380)
        defer { coordinator.cancel(); webView.stopLoading() }
        let markdown = "Hello Sam,\n\nField Office\nRoom 12\n\n- Schedule\n- Open questions\n\nThanks,\nAlex"
        coordinator.update(markdown: markdown, isDark: true, followsStreamingOutput: false, preservesLineBreaks: true)
        try await waitForText("Alex", in: webView)
        let document = try await webView.callAsyncJavaScript("return {text:document.body.innerText, breaks:document.querySelectorAll('br').length, overflow:document.documentElement.scrollWidth > innerWidth};", arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertTrue((document?["text"] as? String)?.contains("Thanks,\nAlex") == true)
        XCTAssertEqual(document?["breaks"] as? Int, 2)
        XCTAssertEqual(document?["overflow"] as? Bool, false)
        coordinator.update(markdown: markdown, isDark: true, followsStreamingOutput: false, preservesLineBreaks: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var count = 2
        while count != 0 && ContinuousClock.now < deadline {
            count = try await webView.callAsyncJavaScript("return document.querySelectorAll('br').length;", arguments: [:], in: nil, contentWorld: .defaultClient) as? Int ?? -1
            if count != 0 { try await Task.sleep(for: .milliseconds(30)) }
        }
        XCTAssertEqual(count, 0, "Changing rendering mode must invalidate the cached HTML")
    }

    private func attach(_ snapshot: NSImage, name: String, background: NSColor) {
        let rendered = NSImage(size: snapshot.size)
        rendered.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: snapshot.size).fill()
        snapshot.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        rendered.unlockFocus()
        let attachment = XCTAttachment(image: rendered)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForText(_ text: String, in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let body = try? await webView.callAsyncJavaScript("return document.body.innerText;", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
            if body?.contains(text) == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Rendered notes did not update")
        throw NSError(domain: "MeetingMarkdownWebViewTests", code: 1)
    }

    func testStreamingKeepsDocumentBlocksAndReadersScrollPosition() async throws {
        let coordinator = MarkdownWebView.Coordinator()
        let webView = MarkdownWebView.makeWebView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { coordinator.cancel(); webView.stopLoading(); window.contentView = nil; window.close() }
        let markdown = "# Trial notes\n\n| Owner | Deadline |\n| --- | --- |\n| Speaker 1 | Friday |\n\n- [x] Labels\n- [ ] Samples\n\n`<literal>`\n\n" + (1...80).map { "Paragraph \($0). Review the greenhouse results." }.joined(separator: "\n\n")
        coordinator.update(markdown: markdown, isDark: false, followsStreamingOutput: false)
        try await waitForText("Paragraph 80", in: webView)
        _ = try await webView.callAsyncJavaScript("window.documentMarker = 'kept'; document.querySelector('h1').blockMarker = 'kept'; window.scrollTo(0, 0); return true;", arguments: [:], in: nil, contentWorld: .defaultClient)
        let light = try await webView.takeSnapshot(configuration: nil)
        attach(light, name: "meeting_notes_light", background: .white)

        coordinator.update(markdown: markdown + "\n\nFinal streamed sentence.", isDark: true, followsStreamingOutput: true)
        try await waitForText("Final streamed sentence.", in: webView)
        let status = try await webView.callAsyncJavaScript("return {document:window.documentMarker, block:document.querySelector('h1').blockMarker, scroll:window.scrollY, appearance:document.documentElement.dataset.appearance, tables:document.querySelectorAll('table').length};", arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(status?["document"] as? String, "kept", "A stream update must not reload the page")
        XCTAssertEqual(status?["block"] as? String, "kept", "Completed blocks must keep their DOM identity")
        XCTAssertEqual(status?["scroll"] as? Double, 0)
        XCTAssertEqual(status?["appearance"] as? String, "dark")
        XCTAssertEqual(status?["tables"] as? Int, 1)
        let dark = try await webView.takeSnapshot(configuration: nil)
        attach(dark, name: "meeting_notes_dark", background: NSColor(white: 0.12, alpha: 1))
    }
}
