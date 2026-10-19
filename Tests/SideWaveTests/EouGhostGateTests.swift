// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import XCTest
@testable import SideWave

/// Tests for the EOU ghost-word gate's pure pieces: the monotonic-prefix
/// truncation the gate hands the staged transcript, and the adaptive speech
/// detector in AudioBufferStore. The gate freezes the visible EOU tail while
/// the mic is silent so streaming-ASR hallucinations never reach the preview
/// or the paste; these pin the arithmetic that must never regress into a
/// shrink (which would trip the coverage-epoch model).
final class EouGhostGateTests: XCTestCase {

    // MARK: - prefixWords (monotonic prefix)

    func testPrefixWordsTruncatesToCount() {
        XCTAssertEqual(TranscriptionService.prefixWords("one two three four", 2), "one two")
    }

    func testPrefixWordsReturnsWholeWhenCountExceedsLength() {
        XCTAssertEqual(TranscriptionService.prefixWords("one two", 5), "one two")
    }

    func testPrefixWordsZeroIsEmpty() {
        XCTAssertEqual(TranscriptionService.prefixWords("one two three", 0), "")
    }

    func testPrefixWordsIsAPrefixOfTheInput() {
        // The gate's contract: the frozen tail is always a prefix of the raw
        // accumulator, so the staged transcript never sees a non-prefix shrink.
        let raw = "the quick brown fox jumps"
        for n in 0...6 {
            let out = TranscriptionService.prefixWords(raw, n)
            XCTAssertTrue(raw.hasPrefix(out) || out == raw, "\(out) not a prefix of \(raw)")
        }
    }

    func testPrefixWordsCollapsesInternalWhitespace() {
        // split(omittingEmptySubsequences:) drops runs of spaces; the rejoin is
        // single-spaced. Prefix identity holds word-wise, which is what matters.
        XCTAssertEqual(TranscriptionService.prefixWords("a   b   c", 2), "a b")
    }

    // MARK: - Adaptive speech detector

    func testSilenceNeverAdvancesSpeech() {
        let store = AudioBufferStore()
        store.resetSpeechDetector()
        // Reset seeds lastSpeechAt to NOW as a bootstrap trust window (the
        // hangover covers the first words instead of the gate arriving fully
        // engaged at partial #1). The invariant silence must uphold is that it
        // never ADVANCES the stamp past that seed.
        let seededAt = store.lastSpeechAt
        XCTAssertGreaterThan(seededAt, 0, "reset must seed the bootstrap stamp")
        // Digital-zero-ish silence across a second of buffers, using future
        // wall-clock times so an (incorrect) advance would be detectable.
        let base = Date().timeIntervalSince1970 + 10
        for i in 0..<60 {
            store.noteAudioLevel(0.0002, peak: 0.0005, at: base + Double(i) * 0.016)
        }
        XCTAssertEqual(store.lastSpeechAt, seededAt, accuracy: 1e-9,
                       "pure silence must not advance the speech stamp")
    }

    func testClearSpeechMarksSpeech() {
        let store = AudioBufferStore()
        store.resetSpeechDetector()
        store.noteAudioLevel(0.08, peak: 0.2, at: 1.0)
        XCTAssertEqual(store.lastSpeechAt, 1.0, accuracy: 1e-9, "loud speech must stamp")
    }

    func testSteadyRoomToneDoesNotCountAsSpeech() {
        let store = AudioBufferStore()
        store.resetSpeechDetector()
        // Steady fan/hum above the absolute silence floor but well below speech.
        // The adaptive background rises to meet it, so the margin test rejects it.
        var last = 0.0
        for i in 0..<200 {
            let t = Double(i) * 0.016
            store.noteAudioLevel(0.009, peak: 0.012, at: t)
            last = store.lastSpeechAt
        }
        // After the background has settled onto the tone, it stops counting.
        XCTAssertLessThan(last, 200 * 0.016 - 0.5,
                          "steady room tone should stop reading as speech once background adapts")
    }

    func testQuietTalkerAboveFloorStillCountsInAQuietRoom() {
        let store = AudioBufferStore()
        store.resetSpeechDetector()
        // Quiet room (near silence) then a soft but clear voice at ~0.02 RMS.
        for i in 0..<30 { store.noteAudioLevel(0.001, peak: 0.002, at: Double(i) * 0.016) }
        store.noteAudioLevel(0.02, peak: 0.05, at: 1.0)
        XCTAssertEqual(store.lastSpeechAt, 1.0, accuracy: 1e-9,
                       "a soft voice well above a quiet-room background must count")
    }

    // MARK: - Per-window silence guard (mid-dictation pause hallucinations)

    // Pins the drop decision for segments whose window contains no
    // VAD-classified speech ("So, I'm not sure what I" committed from an
    // 8-second thinking pause between two real sentences).

    func testSilenceWindowDropsWhenNoSpeechInWindow() {
        // Speech last seen before the window began; VAD has consumed past
        // the window end; the window is a pause, drop.
        XCTAssertTrue(TranscriptionService.silenceWindowShouldDrop(
            vadProcessedThrough: 260_000,
            lastVadSpeechSample: 90_000,
            segmentStart: 100_000,
            segmentEnd: 250_000
        ))
    }

    func testSilenceWindowKeepsWhenSpeechInsideWindow() {
        XCTAssertTrue(!TranscriptionService.silenceWindowShouldDrop(
            vadProcessedThrough: 260_000,
            lastVadSpeechSample: 150_000,
            segmentStart: 100_000,
            segmentEnd: 250_000
        ))
    }

    func testSilenceWindowFailsOpenWhenVadLagsBehindWindow() {
        // VAD hasn't consumed the whole window; it must not veto audio it
        // hasn't seen, even though its last speech stamp predates the window.
        XCTAssertTrue(!TranscriptionService.silenceWindowShouldDrop(
            vadProcessedThrough: 200_000,
            lastVadSpeechSample: 90_000,
            segmentStart: 100_000,
            segmentEnd: 250_000
        ))
    }

    func testSilenceWindowKeepsSpeechAtWindowStartBoundary() {
        // Stamp exactly at segmentStart counts as inside (>= keeps).
        XCTAssertTrue(!TranscriptionService.silenceWindowShouldDrop(
            vadProcessedThrough: 260_000,
            lastVadSpeechSample: 100_000,
            segmentStart: 100_000,
            segmentEnd: 250_000
        ))
    }

    func testSilenceWindowDropsWithinOneChunkMargin() {
        // VAD frontier one sub-chunk (<=1600 samples) short of the window end
        // still counts as full coverage; the stop-path drain always leaves a
        // partial chunk unconsumed.
        XCTAssertTrue(TranscriptionService.silenceWindowShouldDrop(
            vadProcessedThrough: 249_000,
            lastVadSpeechSample: 90_000,
            segmentStart: 100_000,
            segmentEnd: 250_000
        ))
    }

    func testSilenceWindowNeverSpeechSentinelDropsFullyConsumedWindow() {
        // -1 sentinel (no speech ever) with a fully consumed window drops.
        XCTAssertTrue(TranscriptionService.silenceWindowShouldDrop(
            vadProcessedThrough: 250_000,
            lastVadSpeechSample: -1,
            segmentStart: 0,
            segmentEnd: 250_000
        ))
    }

    // MARK: - Phantom word filter (TDT hallucination strip)

    // Pins the filter arithmetic alongside the ghost-gate math above: the
    // speech-end cutoff (+300ms pad), the suffix strip, and the all-phantom
    // case where the whole segment falls past speech end and the correct
    // output is empty.

    private func timing(_ token: String, start: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: start + 0.1, confidence: 0.9)
    }

    @MainActor
    func testPhantomFilterStripsTrailingTokensPastCutoff() {
        // Speech ends 1.0s into the segment; cutoff = 1.3s. Tokens at 1.6s+
        // are phantom fill and must strip; earlier tokens stay.
        let timings = [
            timing("hello", start: 0.2),
            timing(" world", start: 0.6),
            timing(" I", start: 1.6),
            timing(" guess", start: 1.8),
        ]
        let out = TranscriptionService.applyPhantomWordFilter(
            text: "hello world I guess",
            tokenTimings: timings,
            vadWasSpeaking: false,
            speechEndSample: 16_000,   // 1.0s at 16kHz
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "hello world")
    }

    @MainActor
    func testPhantomFilterStripsEntireSegmentWhenAllTokensArePhantom() {
        // Field case: every token starts after speech end ("Updating whatever
        // the last year." with 12/12 tokens past cutoff). Empty is the correct
        // output; the caller's empty-text guard drops the segment. The old
        // guard refused the strip and shipped the whole hallucination.
        let timings = [
            timing("I", start: 1.6),
            timing(" don't", start: 1.8),
            timing(" know.", start: 2.1),
        ]
        let out = TranscriptionService.applyPhantomWordFilter(
            text: "I don't know.",
            tokenTimings: timings,
            vadWasSpeaking: false,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "")
    }

    @MainActor
    func testPhantomFilterKeepsTokensInsidePad() {
        // Tokens inside the +300ms pad (trailing consonants) are NOT phantoms.
        let timings = [
            timing("hello", start: 0.2),
            timing(" there", start: 1.2),
        ]
        let out = TranscriptionService.applyPhantomWordFilter(
            text: "hello there",
            tokenTimings: timings,
            vadWasSpeaking: false,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "hello there")
    }

    @MainActor
    func testPhantomFilterBailsWithoutSpeechEnd() {
        let out = TranscriptionService.applyPhantomWordFilter(
            text: "kept as-is",
            tokenTimings: [timing("kept", start: 5.0)],
            vadWasSpeaking: false,
            speechEndSample: nil,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "kept as-is")
    }

    @MainActor
    func testPhantomFilterBailsWhileVadStillSpeaking() {
        let out = TranscriptionService.applyPhantomWordFilter(
            text: "kept as-is",
            tokenTimings: [timing("kept", start: 5.0)],
            vadWasSpeaking: true,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "kept as-is")
    }

    @MainActor
    func testPhantomFilterBailsOnSuffixMismatch() {
        // Post-processing altered the tail so the phantom tokens no longer
        // form a literal suffix; the filter must not garble, return as-is.
        let timings = [
            timing("hello", start: 0.2),
            timing(" wrld", start: 1.6),
        ]
        let out = TranscriptionService.applyPhantomWordFilter(
            text: "hello world",
            tokenTimings: timings,
            vadWasSpeaking: false,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "hello world")
    }
}
