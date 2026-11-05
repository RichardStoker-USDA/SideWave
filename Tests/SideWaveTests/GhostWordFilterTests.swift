// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import XCTest
@testable import SideWave

/// Words TDT produced from silence. A word goes only when the streaming engine didn't hear it and
/// no voiced VAD chunk is near its start. Words either check vouches for stay.
final class GhostWordFilterTests: XCTestCase {

    private func timing(_ token: String, _ start: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: start + 0.08, confidence: 0.9)
    }

    private func timings(_ pairs: [(String, Double)]) -> [TokenTiming] {
        pairs.map { timing($0.0, $0.1) }
    }

    private func run(
        _ text: String,
        _ timings: [TokenTiming],
        heard: String,
        voiced: [Range<Double>],
        vadThrough: Double = 10
    ) -> String {
        let words = GhostWordFilter.words(from: timings)
        let heardWords = heard.split(separator: " ").map(String.init)
        let ghosts = GhostWordFilter.ghostIndices(
            words: words, heard: heardWords, voiced: voiced, vadThrough: vadThrough
        )
        return GhostWordFilter.strip(text, words: words, removing: ghosts)
    }

    private let endsWithYeah = [
        ("Keep", 0.10), (" it", 0.30), (" short", 0.50), (".", 0.70), (" Yeah", 1.30), (".", 1.50),
    ]

    // MARK: - After the speaker stopped

    func testRemovesTrailingWordStreamingNeverHeardAfterSpeechEnds() {
        let out = run("Keep it short. Yeah.", timings(endsWithYeah),
                      heard: "keep it short", voiced: [0..<0.77])
        XCTAssertEqual(out, "Keep it short.")
    }

    func testRemovesMultiWordGhostAndKeepsTheSentenceEnd() {
        let pairs = [
            ("We'll", 0.10), (" label", 0.30), (" the", 0.50), (" tray", 0.70),
            (" a", 1.20), (" little", 1.30), (" bit", 1.50), (".", 1.60),
        ]
        let out = run("We'll label the tray a little bit.", timings(pairs),
                      heard: "we will label the tray", voiced: [0..<0.90])
        XCTAssertEqual(out, "We'll label the tray.")
    }

    func testRemovesRepeatOfTheLastWordInTheSilence() {
        // TDT can repeat the last word from the quiet after it; streaming heard it once.
        let pairs = [("Right", 0.10), (" on", 0.30), (" time", 0.50), (".", 0.70), (" Time", 1.40), (".", 1.50)]
        let out = run("Right on time. Time.", timings(pairs), heard: "right on time", voiced: [0..<0.77])
        XCTAssertEqual(out, "Right on time.")
    }

    func testRemovesEveryWordWhenTheWholeSegmentIsAGhost() {
        let out = run("Yeah.", timings([(" Yeah", 0.60), (".", 0.70)]), heard: "", voiced: [0..<0.26])
        XCTAssertEqual(out, "")
    }

    func testKeepsTrailingWordStreamingAlsoHeard() {
        let out = run("Keep it short. Yeah.", timings(endsWithYeah),
                      heard: "keep it short yeah", voiced: [0..<0.77])
        XCTAssertEqual(out, "Keep it short. Yeah.")
    }

    func testKeepsUnheardWordsInsideVoicedAudio() {
        // Speech the streaming engine missed: VAD heard it, so it stays.
        let pairs = [("Check", 0.10), (" the", 0.30), (" freezer", 0.50), (".", 0.70), (" Thank", 1.00), (" you", 1.20), (".", 1.30)]
        let out = run("Check the freezer. Thank you.", timings(pairs), heard: "check the freezer", voiced: [0..<1.54])
        XCTAssertEqual(out, "Check the freezer. Thank you.")
    }

    func testKeepsWordStartingInsideTheTimingAllowance() {
        let pairs = [("Keep", 0.10), (" it", 0.30), (" short", 0.50), (" now", 0.80)]
        let out = run("Keep it short now", timings(pairs), heard: "keep it short", voiced: [0..<0.77])
        XCTAssertEqual(out, "Keep it short now")
    }

    func testKeepsWordsVadHasNotProcessed() {
        let out = run("Keep it short. Yeah.", timings(endsWithYeah),
                      heard: "keep it short", voiced: [0..<0.77], vadThrough: 1.0)
        XCTAssertEqual(out, "Keep it short. Yeah.")
    }

    func testKeepsEverythingWhenVadHeardNoSpeech() {
        let out = run("Keep it short. Yeah.", timings(endsWithYeah), heard: "keep it short", voiced: [])
        XCTAssertEqual(out, "Keep it short. Yeah.")
    }

    func testKeepsAnUnheardRunLongerThanTheLimit() {
        var pairs = [("Done", 0.10), (".", 0.30)]
        for (index, word) in [" one", " two", " three", " four", " five", " six"].enumerated() {
            pairs.append((word, 1.0 + Double(index) * 0.2))
        }
        let text = "Done. one two three four five six"
        XCTAssertEqual(run(text, timings(pairs), heard: "done", voiced: [0..<0.5]), text)
    }

    func testDifferentEndingOfAHeardWordCountsAsHeard() {
        let pairs = [("Sort", 0.10), (" samples", 0.30), (".", 0.90)]
        let out = run("Sort samples.", timings(pairs), heard: "sort sample", voiced: [0..<0.05])
        XCTAssertEqual(out, "Sort samples.")
    }

    func testLeavesRescoredTextAloneWhenItsEndingDiffersFromTheTokens() {
        let out = run("Keep it short. Yea.", timings(endsWithYeah), heard: "keep it short", voiced: [0..<0.77])
        XCTAssertEqual(out, "Keep it short. Yea.")
    }

    func testRemovesATrailingGhostAfterRescoringMergedEarlierWords() {
        // Rescoring joined two words into a vocabulary term; the trailing ghost still matches.
        let pairs = [("Ask", 0.10), (" Ana", 0.30), (" Lee", 0.45), (".", 0.60), (" Yeah", 1.40), (".", 1.50)]
        let out = run("Ask Analee. Yeah.", timings(pairs), heard: "ask ana lee", voiced: [0..<0.70])
        XCTAssertEqual(out, "Ask Analee.")
    }

    // MARK: - In a pause between words

    func testRemovesAGhostSentenceInAPause() {
        let pairs = [
            ("We", 0.10), (" checked", 0.30), (" it", 0.50), (".", 0.60), (" Yeah", 1.60), (".", 1.70),
            (" Then", 3.00), (" we", 3.20), (" left", 3.40), (".", 3.60),
        ]
        let out = run("We checked it. Yeah. Then we left.", timings(pairs),
                      heard: "we checked it then we left", voiced: [0..<0.80, 2.90..<3.80])
        XCTAssertEqual(out, "We checked it. Then we left.")
    }

    func testRemovesGhostWordsInsideASentence() {
        let pairs = [
            ("so", 0.10), (" we", 0.30), (" checked", 0.50), (" it", 0.70), (" you", 1.70), (" know", 1.85),
            (" and", 3.00), (" then", 3.20), (" left", 3.40),
        ]
        let out = run("so we checked it you know and then left", timings(pairs),
                      heard: "so we checked it and then left", voiced: [0..<0.90, 2.90..<3.70])
        XCTAssertEqual(out, "so we checked it and then left")
    }

    func testAGhostThatEndedASentenceMovesItsMark() {
        let pairs = [("We", 0.10), (" checked", 0.30), (" it", 0.50), (" okay", 1.60), (".", 1.70), (" Then", 3.00), (" left", 3.20)]
        let out = run("We checked it okay. Then left", timings(pairs),
                      heard: "we checked it then left", voiced: [0..<0.70, 2.90..<3.50])
        XCTAssertEqual(out, "We checked it. Then left")
    }

    func testAGhostThatStartedASentencePassesTheCapital() {
        let pairs = [("It", 0.10), (" works", 0.30), (".", 0.50), (" Yeah", 1.60), (",", 1.70), (" so", 3.00), (" ship", 3.20), (" it", 3.40), (".", 3.50)]
        let out = run("It works. Yeah, so ship it.", timings(pairs),
                      heard: "it works so ship it", voiced: [0..<0.70, 2.90..<3.70])
        XCTAssertEqual(out, "It works. So ship it.")
    }

    func testRemovesAGhostBeforeSpeechStarts() {
        let pairs = [("Okay", 0.20), (".", 0.30), (" The", 1.50), (" tubes", 1.70), (" are", 1.90), (" ready", 2.10), (".", 2.30)]
        let out = run("Okay. The tubes are ready.", timings(pairs),
                      heard: "the tubes are ready", voiced: [1.40..<2.50])
        XCTAssertEqual(out, "The tubes are ready.")
    }

    func testKeepsSpeechAfterALongPauseThatStreamingMissed() {
        // Words after a pause are voiced, so they stay even when the streaming engine hasn't
        // caught up with them. Cutting at the pause dropped whole phrases before.
        let pairs = [
            ("We", 0.10), (" checked", 0.30), (" it", 0.50), (".", 0.60),
            (" Then", 4.20), (" we", 4.40), (" labeled", 4.60), (" every", 4.90), (" tube", 5.10), (".", 5.30),
        ]
        let text = "We checked it. Then we labeled every tube."
        XCTAssertEqual(run(text, timings(pairs), heard: "we checked it", voiced: [0..<0.80, 4.10..<5.50]), text)
    }

    func testLeavesTextAloneWhenAPauseGhostCantBePlaced() {
        let pairs = [
            ("We", 0.10), (" checked", 0.30), (" it", 0.50), (".", 0.60), (" Yeah", 1.60), (".", 1.70),
            (" Then", 3.00), (" we", 3.20), (" left", 3.40), (".", 3.60),
        ]
        // Rescoring changed the word count, so the pause word can't be found in the text.
        let text = "We checked it. Yeah. Then we-left."
        XCTAssertEqual(run(text, timings(pairs), heard: "we checked it then we left", voiced: [0..<0.80, 2.90..<3.80]), text)
    }

    // MARK: - Pieces

    func testWordsJoinSubwordPiecesAndPunctuation() {
        let words = GhostWordFilter.words(from: timings([
            ("Cent", 0.10), ("ri", 0.20), ("fuge", 0.30), (".", 0.40), (" Yeah", 0.90),
        ]))
        XCTAssertEqual(words, [
            GhostWordFilter.Word(text: "Centrifuge.", start: 0.10),
            GhostWordFilter.Word(text: "Yeah", start: 0.90),
        ])
    }

    func testHeardIndicesSkipWordsOnlyOneEngineHas() {
        let heard = GhostWordFilter.heardIndices(
            segment: ["So", "the", "plan", "is", "done.", "Yeah."],
            heard: ["so", "um", "the", "plan", "is", "done"]
        )
        XCTAssertEqual(heard, [0, 1, 2, 3, 4])
    }
}
