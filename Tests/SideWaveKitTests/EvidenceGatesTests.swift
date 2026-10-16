// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import XCTest

@testable import SideWaveKit

/// Port of the original app's EouGhostGateTests for the carried gate math.
/// Each row exists because a specific field hallucination shipped without
/// it; the numbers are the tuned values, not examples.
final class EvidenceGatesTests: XCTestCase {

    // MARK: Per-window silence guard

    func testSilenceWindowDropsWhenNoSpeechInWindow() {
        XCTAssertTrue(
            EvidenceGates.silenceWindowShouldDrop(
                vadProcessedThrough: 260_000,
                lastVadSpeechSample: 90_000,
                segmentStart: 100_000,
                segmentEnd: 250_000
            ))
    }

    func testSilenceWindowKeepsWhenSpeechInsideWindow() {
        XCTAssertFalse(
            EvidenceGates.silenceWindowShouldDrop(
                vadProcessedThrough: 260_000,
                lastVadSpeechSample: 150_000,
                segmentStart: 100_000,
                segmentEnd: 250_000
            ))
    }

    func testSilenceWindowFailsOpenWhenVadLagsBehindWindow() {
        // VAD must never veto audio it hasn't seen.
        XCTAssertFalse(
            EvidenceGates.silenceWindowShouldDrop(
                vadProcessedThrough: 200_000,
                lastVadSpeechSample: 90_000,
                segmentStart: 100_000,
                segmentEnd: 250_000
            ))
    }

    func testSilenceWindowKeepsSpeechAtWindowStartBoundary() {
        XCTAssertFalse(
            EvidenceGates.silenceWindowShouldDrop(
                vadProcessedThrough: 260_000,
                lastVadSpeechSample: 100_000,
                segmentStart: 100_000,
                segmentEnd: 250_000
            ))
    }

    func testSilenceWindowDropsWithinOneChunkMargin() {
        // Frontier <=1600 samples short of the window end still counts as
        // full coverage (the stop drain leaves a partial chunk).
        XCTAssertTrue(
            EvidenceGates.silenceWindowShouldDrop(
                vadProcessedThrough: 249_000,
                lastVadSpeechSample: 90_000,
                segmentStart: 100_000,
                segmentEnd: 250_000
            ))
    }

    func testSilenceWindowNeverSpeechSentinelDropsFullyConsumedWindow() {
        XCTAssertTrue(
            EvidenceGates.silenceWindowShouldDrop(
                vadProcessedThrough: 250_000,
                lastVadSpeechSample: -1,
                segmentStart: 0,
                segmentEnd: 250_000
            ))
    }

    // MARK: Phantom word filter

    private func timing(_ token: String, start: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: start + 0.1, confidence: 0.9)
    }

    func testPhantomFilterStripsTrailingTokensPastCutoff() {
        // Speech ends 1.0s in; cutoff = 1.3s. Tokens at 1.6s+ are fill.
        let timings = [
            timing("hello", start: 0.2),
            timing(" world", start: 0.6),
            timing(" I", start: 1.6),
            timing(" guess", start: 1.8),
        ]
        let out = EvidenceGates.applyPhantomWordFilter(
            text: "hello world I guess",
            tokenTimings: timings,
            vadWasSpeaking: false,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "hello world")
    }

    func testPhantomFilterStripsEntireSegmentWhenAllTokensArePhantom() {
        // Field case: 12/12 tokens past cutoff; empty is the correct
        // output and flows to the caller's empty guard.
        let timings = [
            timing("I", start: 1.6),
            timing(" don't", start: 1.8),
            timing(" know.", start: 2.1),
        ]
        let out = EvidenceGates.applyPhantomWordFilter(
            text: "I don't know.",
            tokenTimings: timings,
            vadWasSpeaking: false,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "")
    }

    func testPhantomFilterKeepsTokensInsidePad() {
        // The +300ms pad protects trailing consonants.
        let timings = [
            timing("hello", start: 0.2),
            timing(" there", start: 1.2),
        ]
        let out = EvidenceGates.applyPhantomWordFilter(
            text: "hello there",
            tokenTimings: timings,
            vadWasSpeaking: false,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "hello there")
    }

    func testPhantomFilterBailsWithoutSpeechEnd() {
        let out = EvidenceGates.applyPhantomWordFilter(
            text: "kept as-is",
            tokenTimings: [timing("kept", start: 5.0)],
            vadWasSpeaking: false,
            speechEndSample: nil,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "kept as-is")
    }

    func testPhantomFilterBailsWhileVadStillSpeaking() {
        let out = EvidenceGates.applyPhantomWordFilter(
            text: "kept as-is",
            tokenTimings: [timing("kept", start: 5.0)],
            vadWasSpeaking: true,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "kept as-is")
    }

    func testPhantomFilterBailsOnSuffixMismatch() {
        // Post-processing changed the tail: never garble, return as-is.
        let timings = [
            timing("hello", start: 0.2),
            timing(" wrld", start: 1.6),
        ]
        let out = EvidenceGates.applyPhantomWordFilter(
            text: "hello world",
            tokenTimings: timings,
            vadWasSpeaking: false,
            speechEndSample: 16_000,
            frozenSampleCount: 0
        )
        XCTAssertEqual(out, "hello world")
    }

    // MARK: Adaptive speech detector

    func testSilenceNeverAdvancesSpeech() {
        let detector = AdaptiveSpeechDetector()
        detector.reset(at: 100.0)
        XCTAssertEqual(detector.lastSpeechAt, 100.0, "reset must seed the bootstrap stamp")
        let base = 110.0
        for i in 0..<60 {
            detector.noteAudioLevel(0.0002, peak: 0.0005, at: base + Double(i) * 0.016)
        }
        XCTAssertEqual(detector.lastSpeechAt, 100.0, accuracy: 1e-9,
                       "pure silence must not advance the speech stamp")
    }

    func testClearSpeechMarksSpeech() {
        let detector = AdaptiveSpeechDetector()
        detector.reset(at: 0)
        detector.noteAudioLevel(0.08, peak: 0.2, at: 1.0)
        XCTAssertEqual(detector.lastSpeechAt, 1.0, accuracy: 1e-9)
    }

    func testSteadyRoomToneDoesNotCountAsSpeech() {
        let detector = AdaptiveSpeechDetector()
        detector.reset(at: 0)
        var last = 0.0
        for i in 0..<200 {
            let t = Double(i) * 0.016
            detector.noteAudioLevel(0.009, peak: 0.012, at: t)
            last = detector.lastSpeechAt
        }
        XCTAssertLessThan(last, 200 * 0.016 - 0.5,
                          "steady room tone should stop reading as speech once background adapts")
    }

    func testQuietTalkerAboveFloorStillCountsInAQuietRoom() {
        let detector = AdaptiveSpeechDetector()
        detector.reset(at: 0)
        for i in 0..<30 {
            detector.noteAudioLevel(0.001, peak: 0.002, at: Double(i) * 0.016)
        }
        detector.noteAudioLevel(0.02, peak: 0.05, at: 1.0)
        XCTAssertEqual(detector.lastSpeechAt, 1.0, accuracy: 1e-9,
                       "a soft voice well above a quiet-room background must count")
    }

    // MARK: Final tidy

    func testTidyCapitalizesAndCloses() {
        XCTAssertEqual(
            EvidenceGates.tidyFinalTranscript("hello world", detectedLanguage: "en"),
            "Hello world.")
    }

    func testTidyLeavesClosedTextAlone() {
        XCTAssertEqual(
            EvidenceGates.tidyFinalTranscript("Hello world!", detectedLanguage: "en"),
            "Hello world!")
    }

    func testTidyUsesCJKPeriodForChinese() {
        XCTAssertEqual(
            EvidenceGates.tidyFinalTranscript("你好", detectedLanguage: "zh-CN"),
            "你好。")
    }

    func testTidyEmptyStaysEmpty() {
        XCTAssertEqual(EvidenceGates.tidyFinalTranscript("   ", detectedLanguage: nil), "")
    }
}

/// The single-stream overlay model: settled never shrinks, settling is
/// the newest delta, non-append updates degrade honestly.
final class TranscriptAssemblyTests: XCTestCase {

    func testAppendFlowSettlesPreviousText() {
        var assembly = TranscriptAssembly()
        let first = assembly.ingest("hello")
        XCTAssertEqual(first?.settled, "")
        XCTAssertEqual(first?.settling, "hello")

        let second = assembly.ingest("hello world")
        XCTAssertEqual(second?.settled, "hello")
        XCTAssertEqual(second?.settling, " world")
    }

    func testUnchangedUpdateIsNil() {
        var assembly = TranscriptAssembly()
        _ = assembly.ingest("hello")
        XCTAssertNil(assembly.ingest("hello"))
    }

    func testNonAppendUpdatePresentsEverythingSettled() {
        var assembly = TranscriptAssembly()
        _ = assembly.ingest("hello world")
        let rewrite = assembly.ingest("goodbye")
        XCTAssertEqual(rewrite?.settled, "goodbye")
        XCTAssertEqual(rewrite?.settling, "")
    }

    func testFinalizeSettlesEverything() {
        var assembly = TranscriptAssembly()
        _ = assembly.ingest("hello wor")
        let final = assembly.finalize("hello world.")
        XCTAssertEqual(final.settled, "hello world.")
        XCTAssertEqual(final.settling, "")
    }
}
