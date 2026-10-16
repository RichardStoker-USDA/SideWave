// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWaveKit

final class PasteVerificationTests: XCTestCase {

    func testFastPasteIsComparedWithValueBeforeDelivery() {
        XCTAssertEqual(PasteEngine.comparePasteValues(
            before: "Notes: ", after: "Notes: Check the figures.", expected: "Check the figures."
        ), .landed)
    }

    func testDroppedRepeatedPhraseDoesNotCountAsDelivered() {
        XCTAssertEqual(PasteEngine.comparePasteValues(
            before: "Check the figures.", after: "Check the figures.", expected: "Check the figures."
        ), .notLanded)
        XCTAssertEqual(PasteEngine.comparePasteValues(
            before: "Check the figures.", after: "Check the figures. Check the figures.", expected: "Check the figures."
        ), .landed)
    }

    func testReplacingIdenticalSelectionMustNotTriggerSecondPaste() {
        XCTAssertEqual(PasteEngine.comparePasteValues(
            before: "Check the figures.", after: "Check the figures.", expected: "Check the figures.",
            selectedText: "Check the figures."
        ), .unverifiable)
    }

    func testUnreadableValueCannotJustifyRetry() {
        XCTAssertEqual(PasteEngine.comparePasteValues(before: nil, after: "Text", expected: "Text"), .unverifiable)
        XCTAssertEqual(PasteEngine.comparePasteValues(before: "", after: nil, expected: "Text"), .unverifiable)
    }

    func testSmartPunctuationAndLineBreaksVerify() {
        XCTAssertEqual(PasteEngine.comparePasteValues(
            before: "", after: "She said “ready.”\nNext step…", expected: "She said \"ready.\" Next step..."
        ), .landed)
    }
    func testPartialInsertionMustNotTriggerSecondPaste() {
        XCTAssertEqual(PasteEngine.comparePasteValues(
            before: "", after: "Check", expected: "Check the figures."
        ), .unverifiable)
    }

    func testDeliveryRequiresTheOriginalTargetToKeepFocus() {
        XCTAssertTrue(PasteEngine.targetMatches(expectedPID: 42, frontmostPID: 42, focusedPID: 42))
        XCTAssertTrue(PasteEngine.targetMatches(expectedPID: 42, frontmostPID: 42, focusedPID: nil))
        XCTAssertFalse(PasteEngine.targetMatches(expectedPID: 42, frontmostPID: 43, focusedPID: 43))
        XCTAssertFalse(PasteEngine.targetMatches(expectedPID: 42, frontmostPID: 42, focusedPID: 43))
        XCTAssertFalse(PasteEngine.targetMatches(expectedPID: 42, frontmostPID: nil, focusedPID: nil))
        XCTAssertFalse(PasteEngine.targetMatches(expectedPID: 0, frontmostPID: 0, focusedPID: 0))
    }

}
