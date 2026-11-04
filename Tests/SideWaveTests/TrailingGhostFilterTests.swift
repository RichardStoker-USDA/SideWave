// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import XCTest
@testable import SideWave

/// The stop's trailing-word check. TDT can add a short word after the speaker stopped ("Yeah.",
/// "a little bit."); it goes only when the streaming engine didn't hear it and VAD heard no speech
/// from where it starts. Words either check vouches for stay.
final class TrailingGhostFilterTests: XCTestCase {

    private func timing(_ token: String, _ start: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: start + 0.08, confidence: 0.9)
    }

    private func run(
        _ text: String,
        _ timings: [TokenTiming],
        heard: String,
        voicedEnd: Double?,
        vadThrough: Double = 10
    ) -> String {
        let words = TrailingGhostFilter.words(from: timings)
        let heardWords = heard.split(separator: " ").map(String.init)
        let count = TrailingGhostFilter.ghostCount(
            words: words, heard: heardWords, voicedEnd: voicedEnd, vadThrough: vadThrough
        )
        return TrailingGhostFilter.strip(text, words: words, count: count)
    }

    private let endsWithYeah = [
        ("Keep", 0.10), (" it", 0.30), (" short", 0.50), (".", 0.70), (" Yeah", 1.30), (".", 1.50),
    ]

    private func timings(_ pairs: [(String, Double)]) -> [TokenTiming] {
        pairs.map { timing($0.0, $0.1) }
    }

    // MARK: - Removed

    func testRemovesTrailingWordStreamingNeverHeardAfterSpeechEnds() {
        let out = run("Keep it short. Yeah.", timings(endsWithYeah),
                      heard: "keep it short", voicedEnd: 0.77)
        XCTAssertEqual(out, "Keep it short.")
    }

    func testRemovesMultiWordGhostAndKeepsTheSentenceEnd() {
        let pairs = [
            ("We'll", 0.10), (" label", 0.30), (" the", 0.50), (" tray", 0.70),
            (" a", 1.20), (" little", 1.30), (" bit", 1.50), (".", 1.60),
        ]
        let out = run("We'll label the tray a little bit.", timings(pairs),
                      heard: "we will label the tray", voicedEnd: 0.90)
        XCTAssertEqual(out, "We'll label the tray.")
    }

    func testRemovesRepeatOfTheLastWordInTheSilence() {
        // TDT can repeat the last word from the quiet after it; streaming heard it once.
        let pairs = [("Right", 0.10), (" on", 0.30), (" time", 0.50), (".", 0.70), (" Time", 1.40), (".", 1.50)]
        let out = run("Right on time. Time.", timings(pairs), heard: "right on time", voicedEnd: 0.77)
        XCTAssertEqual(out, "Right on time.")
    }

    func testRemovesEveryWordWhenTheWholeSegmentIsAGhost() {
        let out = run("Yeah.", timings([(" Yeah", 0.60), (".", 0.70)]), heard: "", voicedEnd: 0.26)
        XCTAssertEqual(out, "")
    }

    // MARK: - Kept

    func testKeepsTrailingWordStreamingAlsoHeard() {
        let out = run("Keep it short. Yeah.", timings(endsWithYeah),
                      heard: "keep it short yeah", voicedEnd: 0.77)
        XCTAssertEqual(out, "Keep it short. Yeah.")
    }

    func testKeepsUnheardWordsInsideVoicedAudio() {
        // Real speech the streaming engine missed: VAD heard it, so it stays.
        let pairs = [("Check", 0.10), (" the", 0.30), (" freezer", 0.50), (".", 0.70), (" Thank", 1.00), (" you", 1.20), (".", 1.30)]
        let out = run("Check the freezer. Thank you.", timings(pairs), heard: "check the freezer", voicedEnd: 1.54)
        XCTAssertEqual(out, "Check the freezer. Thank you.")
    }

    func testKeepsWordStartingInsideTheTimingAllowance() {
        let pairs = [("Keep", 0.10), (" it", 0.30), (" short", 0.50), (" now", 0.80)]
        let out = run("Keep it short now", timings(pairs), heard: "keep it short", voicedEnd: 0.77)
        XCTAssertEqual(out, "Keep it short now")
    }

    func testKeepsWordsVadHasNotProcessed() {
        let out = run("Keep it short. Yeah.", timings(endsWithYeah),
                      heard: "keep it short", voicedEnd: 0.77, vadThrough: 1.0)
        XCTAssertEqual(out, "Keep it short. Yeah.")
    }

    func testKeepsEverythingWhenVadHeardNoSpeechInTheSegment() {
        let out = run("Keep it short. Yeah.", timings(endsWithYeah), heard: "keep it short", voicedEnd: nil)
        XCTAssertEqual(out, "Keep it short. Yeah.")
    }

    func testKeepsAnUnheardRunLongerThanTheLimit() {
        var pairs = [("Done", 0.10), (".", 0.30)]
        for (index, word) in [" one", " two", " three", " four", " five", " six"].enumerated() {
            pairs.append((word, 1.0 + Double(index) * 0.2))
        }
        let text = "Done. one two three four five six"
        XCTAssertEqual(run(text, timings(pairs), heard: "done", voicedEnd: 0.5), text)
    }

    func testDifferentEndingOfAHeardWordCountsAsHeard() {
        let pairs = [("Sort", 0.10), (" samples", 0.30), (".", 0.90)]
        let out = run("Sort samples.", timings(pairs), heard: "sort sample", voicedEnd: 0.0)
        XCTAssertEqual(out, "Sort samples.")
    }

    func testLeavesRescoredTextAloneWhenItsEndingDiffersFromTheTokens() {
        let out = run("Keep it short. Yea.", timings(endsWithYeah), heard: "keep it short", voicedEnd: 0.77)
        XCTAssertEqual(out, "Keep it short. Yea.")
    }

    // MARK: - Pieces

    func testWordsJoinSubwordPiecesAndPunctuation() {
        let words = TrailingGhostFilter.words(from: timings([
            ("Cent", 0.10), ("ri", 0.20), ("fuge", 0.30), (".", 0.40), (" Yeah", 0.90),
        ]))
        XCTAssertEqual(words, [
            TrailingGhostFilter.Word(text: "Centrifuge.", start: 0.10),
            TrailingGhostFilter.Word(text: "Yeah", start: 0.90),
        ])
    }

    func testLastHeardIndexSkipsWordsOnlyOneEngineHas() {
        let index = TrailingGhostFilter.lastHeardIndex(
            segment: ["So", "the", "plan", "is", "done.", "Yeah."],
            heard: ["so", "um", "the", "plan", "is", "done"]
        )
        XCTAssertEqual(index, 4)
    }
}
