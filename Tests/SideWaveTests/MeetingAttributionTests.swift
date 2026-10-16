// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import XCTest
@testable import SideWave

/// Pins the R4 attribution invariants: words go to the speaker they actually
/// overlap (not the earlier-starting one), short interjections land on the
/// interjector, quiet audio with no diarizer output still keeps the ASR text,
/// and word grouping never splits a word across speakers.
final class MeetingAttributionTests: XCTestCase {

    private func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 1.0)
    }

    // MARK: - Word grouping

    func testTokensGroupIntoWordsAtSpaceBoundaries() {
        // Leading space marks a word start; continuations have none.
        let timings = [
            token("Hel", 0.0, 0.1),
            token("lo", 0.1, 0.2),
            token(" wor", 0.3, 0.4),
            token("ld", 0.4, 0.5),
        ]
        let words = MeetingMerge.groupTokensIntoWords(timings)
        XCTAssertEqual(words.map(\.text), ["Hello", "world"])
    }

    // MARK: - Max-overlap attribution

    func testInterjectionGoesToTheInterjectorNotTheEarlierSpeaker() {
        // Speaker 0 holds the floor 0-50s; Speaker 1 interjects 10-20s.
        let diar = [
            MeetingDiarSeg(speakerId: "Speaker 0", start: 0, end: 50),
            MeetingDiarSeg(speakerId: "Speaker 1", start: 10, end: 20),
        ]
        // "hey" is spoken inside the interjection window; "world" later, in the clear.
        let timings = [
            token("hey", 12.0, 13.0),
            token(" world", 30.0, 31.0),
        ]
        let segments = MeetingMerge.buildRawSegments(
            diarSegs: diar, timings: timings, fullText: "", totalDuration: 50)

        let interjection = segments.first { $0.speakerId == "Speaker 1" }
        XCTAssertNotNil(interjection, "The interjector must get a segment")
        XCTAssertEqual(interjection?.rawText, "hey")

        let floor = segments.first { $0.speakerId == "Speaker 0" }
        XCTAssertEqual(floor?.rawText, "world",
                       "The interjector's word must not leak to the earlier-starting speaker")
    }

    // MARK: - Zero-diarizer fallback

    func testZeroDiarizerSegmentsFallBackToSingleSpeaker() {
        let segments = MeetingMerge.buildRawSegments(
            diarSegs: [], timings: [], fullText: "the whole recognized transcript", totalDuration: 12)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.speakerId, "Speaker 0")
        XCTAssertEqual(segments.first?.rawText, "the whole recognized transcript")
    }

    func testZeroDiarizerWithNoTextProducesNothing() {
        let segments = MeetingMerge.buildRawSegments(
            diarSegs: [], timings: [], fullText: "   ", totalDuration: 5)
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - Proportional last resort (no timings)

    func testProportionalFallbackWhenTimingsMissing() {
        let diar = [
            MeetingDiarSeg(speakerId: "Speaker 0", start: 0, end: 4),
            MeetingDiarSeg(speakerId: "Speaker 1", start: 4, end: 8),
        ]
        let segments = MeetingMerge.buildRawSegments(
            diarSegs: diar, timings: [], fullText: "one two three four", totalDuration: 8)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].rawText, "one two")
        XCTAssertEqual(segments[1].rawText, "three four")
    }

    // MARK: - Same-speaker merge

    func testAdjacentSameSpeakerSegmentsMerge() {
        let diar = [
            MeetingDiarSeg(speakerId: "Speaker 0", start: 0, end: 5),
            MeetingDiarSeg(speakerId: "Speaker 0", start: 5, end: 9),
        ]
        let merged = MeetingMerge.mergeSameSpeaker(diar)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.start, 0)
        XCTAssertEqual(merged.first?.end, 9)
    }
}
