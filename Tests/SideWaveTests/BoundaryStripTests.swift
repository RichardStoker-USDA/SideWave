// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Tests for the two pure de-dup primitives that keep duplicate / ghost words
/// out of the dictation overlay and the pasted text at a TDT segment boundary. Both are sim-tuned edit-distance routines; these pin the
/// load-bearing INVARIANTS (clear echoes are stripped, unrelated tails are
/// left alone, and the minMatchLen guard stops short coincidental matches from
/// eating resumed speech).
@MainActor
final class BoundaryStripTests: XCTestCase {

    // MARK: - stripBoundaryOverlap

    func testExactMultiWordEchoIsStripped() {
        // The live tail re-transcribed words TDT already confirmed at the
        // boundary ("the system" echoes the end of the confirmed span); the
        // exact-match path drops that leading echo so it isn't shown twice.
        let tail = "the system now".split(whereSeparator: \.isWhitespace)
        let result = StagedTranscript.stripBoundaryOverlap(
            tailWords: tail,
            confirmedTail: "run a test of the system"
        )
        XCTAssertEqual(result.map(String.init), ["now"])
    }

    func testMinMatchLenGuardLeavesShortMatch() {
        // A 1-word boundary overlap ("the") with a high minMatchLen must NOT be
        // stripped: post-pause resumed speech often starts with a common word
        // that coincidentally matches the prior span.
        let tail = "the next big thing today".split(whereSeparator: \.isWhitespace)
        let result = StagedTranscript.stripBoundaryOverlap(
            tailWords: tail,
            confirmedTail: "we mentioned the",
            minMatchLen: 5
        )
        XCTAssertEqual(result.map(String.init), ["the", "next", "big", "thing", "today"],
                       "short coincidental match must survive when minMatchLen is high")
    }

    func testShortMatchStrippedAtDefaultMinMatchLen() {
        // Same input, default minMatchLen (1): the 1-word echo IS stripped.
        // Contrast with the guard test above to pin the threshold behavior.
        let tail = "the next big thing today".split(whereSeparator: \.isWhitespace)
        let result = StagedTranscript.stripBoundaryOverlap(
            tailWords: tail,
            confirmedTail: "we mentioned the"
        )
        XCTAssertEqual(result.first.map(String.init), "next",
                       "default minMatchLen strips the leading 1-word echo; result was \(result)")
    }

    func testEmptyConfirmedTailLeavesTailUnchanged() {
        let tail = "brand new words".split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(
            StagedTranscript.stripBoundaryOverlap(tailWords: tail, confirmedTail: "").map(String.init),
            ["brand", "new", "words"]
        )
    }

    func testEmptyTailReturnsEmpty() {
        XCTAssertTrue(
            StagedTranscript.stripBoundaryOverlap(tailWords: [], confirmedTail: "anything").isEmpty
        )
    }

    // MARK: - findEouCoverage

    func testExactWordAlignmentCoversAll() {
        let eou = "the system is working".split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(
            StagedTranscript.findEouCoverage(tdtText: "the system is working", eouWords: eou),
            4
        )
    }

    func testAlignmentDoesNotDecideWhetherToRemoveFillers() {
        // Alignment only covers confirmed speech. The text pipeline owns
        // filler filtering and honors the user's preference.
        let eou = "hello world um uh".split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(
            StagedTranscript.findEouCoverage(tdtText: "hello world", eouWords: eou),
            2
        )
    }

    func testLargeTrailingTailLeftAsLookahead() {
        // TDT confirmed 2 words; EOU has 5 extra trailing words (> 4) = lookahead
        // for the next segment, so coverage stays at the 2 aligned words and the
        // lookahead keeps streaming in the live tail.
        let eou = "hello world this is a longer tail".split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(
            StagedTranscript.findEouCoverage(tdtText: "hello world", eouWords: eou),
            2
        )
    }

    func testEmptyInputsCoverNothing() {
        XCTAssertEqual(StagedTranscript.findEouCoverage(tdtText: "", eouWords: ["a", "b"]), 0)
        XCTAssertEqual(StagedTranscript.findEouCoverage(tdtText: "hello", eouWords: []), 0)
    }

    func testFuzzyBoundaryOverlapStripping() {
        // tail has 10 words, with a difference where "system" becomes "sys tem".
        // allowedErrors = min(5, 10 / 3) = 3.
        // Actual edit distance is 2, which is <= 3. It should match and strip the 9 words.
        let tail = "run a test of the sys tem now here extra".split(whereSeparator: \.isWhitespace)
        let result = StagedTranscript.stripBoundaryOverlap(
            tailWords: tail,
            confirmedTail: "run a test of the system now here"
        )
        XCTAssertEqual(result.map(String.init), ["extra"])
    }

    func testEouCoverageCatastrophicDistanceFallback() {
        // TDT has 3 words ("one two three"), EOU has 1 completely different word ("a").
        // DP distance will be 13, which is >= n * 4 (12).
        // It should hit the catastrophic distance fallback and return min(3, 1) = 1.
        let eou = "a".split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(
            StagedTranscript.findEouCoverage(tdtText: "one two three", eouWords: eou),
            1
        )
    }

    func testEouCoverageDanglingPrevention() {
        // TDT has 5 words, EOU has 3 words. expectedMin = 3.
        // dp[5][3] finds alignment:
        // "one" (j=1) matching "one" (i=1), and "four five" (j=2, 3) matching "four five" (i=4, 5).
        // This is a common case of a word deletion.
        let eou = "one four five".split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(
            StagedTranscript.findEouCoverage(tdtText: "one two three four five", eouWords: eou),
            3
        )
    }

    func testShortLookaheadRemainsUncommitted() {
        for suffix in ["tomorrow", "before lunch", "then check again", "and review the results"] {
            let words = ("hello world " + suffix).split(whereSeparator: \.isWhitespace)
            XCTAssertEqual(
                StagedTranscript.findEouCoverage(tdtText: "Hello world.", eouWords: words),
                2,
                "New words must survive the segment boundary: \(suffix)"
            )
        }
    }
}
