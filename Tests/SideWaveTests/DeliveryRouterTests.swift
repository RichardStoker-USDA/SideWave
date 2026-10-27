// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import XCTest
@testable import SideWave

/// Rules the delivery router depends on. Live behavior in real apps was checked on macOS 27 with a
/// separate harness; these pin the logic so it can't drift.
final class DeliveryRouterTests: XCTestCase {

    // MARK: - Terminal keystrokes

    func testSingleLineTextIsTypedPlainly() {
        XCTAssertEqual(TypingService.terminalKeystrokes(for: "run the tests please").joined(), "run the tests please")
    }

    func testLineBreaksGoInsideOneBracketedPasteWithCarriageReturns() {
        XCTAssertEqual(TypingService.terminalKeystrokes(for: "first line\nsecond line").joined(),
                       "\u{1b}[200~first line\rsecond line\u{1b}[201~")
        XCTAssertEqual(TypingService.terminalKeystrokes(for: "a\r\nb").joined(), "\u{1b}[200~a\rb\u{1b}[201~")
    }

    func testDictatedTextCannotEndThePasteEarly() {
        // Without stripping, the text's own end marker would close the paste and run the rest.
        let hostile = "note\n\u{1b}[201~rm -rf ~\n"
        let sent = TypingService.terminalKeystrokes(for: hostile).joined()
        XCTAssertTrue(sent.hasPrefix("\u{1b}[200~"))
        XCTAssertTrue(sent.hasSuffix("\u{1b}[201~"))
        let inner = sent.dropFirst(6).dropLast(6)
        XCTAssertFalse(inner.contains("\u{1b}"), "control characters inside the paste must be removed")
    }

    func testTabsBecomeSpacesSoTheShellDoesNotComplete() {
        XCTAssertEqual(TypingService.terminalKeystrokes(for: "a\tb").joined(), "a b")
    }

    func testChunksStayWithinTheKeyEventLimitAndKeepCharactersWhole() {
        let text = String(repeating: "word 🎙️ ", count: 120) + "\nend"
        let chunks = TypingService.terminalKeystrokes(for: text, chunkLimit: 50)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 50 })
        XCTAssertEqual(chunks.joined(), TypingService.terminalKeystrokes(for: text, chunkLimit: 100_000).joined())
    }

    func testOneOversizedCharacterIsSplitToFitAKeyEvent() {
        // A letter with 300 combining marks is a single Character.
        let heavy = "a" + String(repeating: "\u{0301}", count: 300)
        let chunks = TypingService.terminalKeystrokes(for: heavy)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 200 })
        XCTAssertEqual(chunks.joined().unicodeScalars.count, heavy.unicodeScalars.count)
    }

    // MARK: - Background field insert

    func testInsertAtAPlainCaretIsAllowed() {
        XCTAssertTrue(FieldInsertion.maySend(current: CFRange(location: 6, length: 0), captured: nil))
    }

    func testSelectionTheUserDidNotMakeIsNeverReplaced() {
        // A field without keyboard focus can report all its text as selected.
        XCTAssertFalse(FieldInsertion.maySend(current: CFRange(location: 0, length: 11), captured: nil))
        XCTAssertFalse(FieldInsertion.maySend(current: CFRange(location: 0, length: 11),
                                              captured: CFRange(location: 6, length: 0)))
    }

    func testSelectionFromDictationStartIsReplacedAsTheUserIntended() {
        XCTAssertTrue(FieldInsertion.maySend(current: CFRange(location: 2, length: 4),
                                             captured: CFRange(location: 2, length: 4)))
    }

    func testExpectedValueInsertsAtTheCaretInUTF16Units() {
        XCTAssertEqual(FieldInsertion.expectedValue("alpha omega", inserting: "INSERTED ", at: CFRange(location: 6, length: 0)),
                       "alpha INSERTED omega")
        XCTAssertEqual(FieldInsertion.expectedValue("🎙️ note", inserting: "x", at: CFRange(location: 3, length: 0)),
                       "🎙️x note")
        XCTAssertNil(FieldInsertion.expectedValue("short", inserting: "x", at: CFRange(location: 9, length: 0)))
    }

    func testAWriteThatTimedOutMayStillApply() {
        // The app may still process a timed-out write, so another route could insert twice.
        XCTAssertTrue(FieldInsertion.writeMayStillApply(.cannotComplete))
        // A rejected write: another route must still get the text there.
        XCTAssertFalse(FieldInsertion.writeMayStillApply(.failure))
        XCTAssertFalse(FieldInsertion.writeMayStillApply(.attributeUnsupported))
        XCTAssertFalse(FieldInsertion.writeMayStillApply(.invalidUIElement))
    }

    // MARK: - Caret before typing

    private func pair(_ range: CFRange?) -> [Int]? { range.map { [$0.location, $0.length] } }

    func testSavedCaretComesBackWhenFocusSelectedEverything() {
        let target = DeliveryRouter.caretTarget(current: CFRange(location: 0, length: 11),
                                                saved: CFRange(location: 6, length: 0), characterCount: 11)
        XCTAssertEqual(pair(target), [6, 0])
    }

    func testSavedCaretThatNoLongerFitsBecomesACaretAtTheEnd() {
        // The draft shrank while the user dictated; the old caret is past its end.
        let target = DeliveryRouter.caretTarget(current: CFRange(location: 0, length: 5),
                                                saved: CFRange(location: 20, length: 0), characterCount: 5)
        XCTAssertEqual(pair(target), [5, 0])
    }

    func testCaretAlreadyInPlaceIsLeftAlone() {
        XCTAssertNil(DeliveryRouter.caretTarget(current: CFRange(location: 6, length: 0),
                                                saved: CFRange(location: 6, length: 0), characterCount: 11))
        XCTAssertNil(DeliveryRouter.caretTarget(current: CFRange(location: 3, length: 0),
                                                saved: nil, characterCount: 11))
    }

    func testSelectionOfUnknownLengthIsNotTypedOver() {
        // Nothing safe to set, and maySend refuses the selection, so delivery stops.
        XCTAssertNil(DeliveryRouter.caretTarget(current: CFRange(location: 0, length: 5),
                                                saved: nil, characterCount: nil))
        XCTAssertFalse(FieldInsertion.maySend(current: CFRange(location: 0, length: 5), captured: nil))
    }

    // MARK: - Deadlines

    func testBlockingWorkPastItsDeadlineIsAbandoned() async {
        let start = ContinuousClock.now
        let result: Int? = await DeliveryRouter.blocking(seconds: 0.2) {
            Thread.sleep(forTimeInterval: 2)
            return 1
        }
        XCTAssertNil(result)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testBlockingWorkWithinItsDeadlineReturns() async {
        let result: Int? = await DeliveryRouter.blocking(seconds: 2) { 7 }
        XCTAssertEqual(result, 7)
    }
}
