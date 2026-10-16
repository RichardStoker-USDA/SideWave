// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Tests for `TypingService.escapeForAppleScript`, the escaping that keeps
/// dictated/relay text from breaking out of the AppleScript double-quoted
/// string literal used to inject into Terminal.app / iTerm2 (relay mode).
/// A missed escape here is an AppleScript-injection vector (the string could
/// close early and run arbitrary `do shell script`), so it gets direct
/// coverage.
final class TypingServiceTests: XCTestCase {

    private let svc = TypingService()

    func testPlainTextUnchanged() {
        XCTAssertEqual(svc.escapeForAppleScript("hello world"), "hello world")
    }

    func testQuotesAreEscaped() {
        // Input:  She said "hi"
        // Output: She said \"hi\"
        XCTAssertEqual(svc.escapeForAppleScript("She said \"hi\""), "She said \\\"hi\\\"")
    }

    func testBackslashEscapedFirst() {
        // A literal backslash must double so it can't combine with a following
        // escape. Input: path\to  ->  path\\to
        XCTAssertEqual(svc.escapeForAppleScript("path\\to"), "path\\\\to")
    }

    func testNewlinesCollapseToSpaces() {
        // Newlines must NOT survive into the AppleScript string in any form:
        // a raw newline terminates the script line, and an escaped \n gets
        // decoded back to a real newline by AppleScript inside `do script` /
        // `write text` — which executes each line of a multi-line dictation
        // as a separate terminal command. They collapse to single spaces so
        // the injected text is always exactly one command line.
        XCTAssertEqual(svc.escapeForAppleScript("a\nb"), "a b")
        XCTAssertEqual(svc.escapeForAppleScript("a\r\nb"), "a b")
    }

    func testInjectionAttemptCannotBreakOutOfStringLiteral() {
        // The security invariant: after escaping, there is NO unescaped double
        // quote (every " is preceded by a backslash), so the payload can never
        // close the surrounding "\(escaped)" literal and start new AppleScript.
        let payload = "x\" & (do shell script \"rm -rf ~\") & \""
        let escaped = svc.escapeForAppleScript(payload)
        // Remove every escaped-quote sequence; nothing bare should remain.
        let withoutEscapedQuotes = escaped.replacingOccurrences(of: "\\\"", with: "")
        XCTAssertFalse(withoutEscapedQuotes.contains("\""),
                       "found an unescaped quote in: \(escaped)")
        XCTAssertFalse(escaped.contains("\n"), "raw newline survived escaping")
    }
    func testFastPasteIsComparedWithValueBeforeDelivery() {
        XCTAssertEqual(TypingService.comparePasteValues(
            before: "Notes: ", after: "Notes: Check the figures.", expected: "Check the figures."
        ), .landed)
    }

    func testDroppedRepeatedPhraseDoesNotCountAsDelivered() {
        XCTAssertEqual(TypingService.comparePasteValues(
            before: "Check the figures.", after: "Check the figures.", expected: "Check the figures."
        ), .notLanded)
        XCTAssertEqual(TypingService.comparePasteValues(
            before: "Check the figures.", after: "Check the figures. Check the figures.", expected: "Check the figures."
        ), .landed)
    }

    func testReplacingIdenticalSelectionMustNotTriggerSecondPaste() {
        XCTAssertEqual(TypingService.comparePasteValues(
            before: "Check the figures.", after: "Check the figures.", expected: "Check the figures.",
            selectedText: "Check the figures."
        ), .unverifiable)
    }

    func testUnreadableValueCannotJustifyRetry() {
        XCTAssertEqual(TypingService.comparePasteValues(before: nil, after: "Text", expected: "Text"), .unverifiable)
        XCTAssertEqual(TypingService.comparePasteValues(before: "", after: nil, expected: "Text"), .unverifiable)
    }

    func testSmartPunctuationAndLineBreaksVerify() {
        XCTAssertEqual(TypingService.comparePasteValues(
            before: "", after: "She said “ready.”\nNext step…", expected: "She said \"ready.\" Next step..."
        ), .landed)
    }

    func testPartialInsertionMustNotTriggerSecondPaste() {
        XCTAssertEqual(TypingService.comparePasteValues(
            before: "", after: "Check", expected: "Check the figures."
        ), .unverifiable)
    }

    func testDeliveryRequiresTheOriginalTargetToKeepFocus() {
        XCTAssertTrue(TypingService.targetMatches(expectedPID: 42, frontmostPID: 42, focusedPID: 42))
        XCTAssertTrue(TypingService.targetMatches(expectedPID: 42, frontmostPID: 42, focusedPID: nil))
        XCTAssertFalse(TypingService.targetMatches(expectedPID: 42, frontmostPID: 43, focusedPID: 43))
        XCTAssertFalse(TypingService.targetMatches(expectedPID: 42, frontmostPID: 42, focusedPID: 43))
        XCTAssertFalse(TypingService.targetMatches(expectedPID: 42, frontmostPID: nil, focusedPID: nil))
        XCTAssertFalse(TypingService.targetMatches(expectedPID: 0, frontmostPID: 0, focusedPID: 0))
    }

}
