// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest

@testable import SideWave

/// Pins the ITN ordinal revert: discourse ordinals come back to words,
/// genuinely positional ones stay digits ("first, second, and third" must not
/// paste as "1st, 2nd, and 3rd").
final class ProseOrdinalReverterTests: XCTestCase {

    func testDiscourseEnumerationReverts() {
        XCTAssertEqual(
            ProseOrdinalReverter.revert("I'm saying the 1st, 2nd, and 3rd in this context"),
            "I'm saying the first, second, and third in this context")
    }

    func testPositionalUsesKeepDigits() {
        XCTAssertEqual(
            ProseOrdinalReverter.revert("she took 2nd place in the race"),
            "she took 2nd place in the race")
        XCTAssertEqual(
            ProseOrdinalReverter.revert("the meeting is on the 3rd of July"),
            "the meeting is on the 3rd of July")
        XCTAssertEqual(
            ProseOrdinalReverter.revert("go to the 5th floor"),
            "go to the 5th floor")
    }

    func testSentenceStartGetsCapital() {
        XCTAssertEqual(
            ProseOrdinalReverter.revert("Here we go. 1st we plan, then we build"),
            "Here we go. First we plan, then we build")
    }

    func testLargeOrdinalsAndPlainNumbersUntouched() {
        XCTAssertEqual(
            ProseOrdinalReverter.revert("the 21st century has 5,476,234.7 problems"),
            "the 21st century has 5,476,234.7 problems")
        XCTAssertEqual(
            ProseOrdinalReverter.revert("call 555-0134 at 192.168.1.10"),
            "call 555-0134 at 192.168.1.10")
    }

    func testNoDigitsFastPath() {
        let text = "nothing numeric here at all"
        XCTAssertEqual(ProseOrdinalReverter.revert(text), text)
    }

    func testTrailingPunctuationSurvives() {
        XCTAssertEqual(
            ProseOrdinalReverter.revert("we tried the 1st, then stopped."),
            "we tried the first, then stopped.")
    }
}
