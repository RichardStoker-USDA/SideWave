// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import Foundation
import os

/// The carried anti-hallucination math, verbatim from the original app
/// where weeks of live logs tuned it. Everything here is pure: evidence
/// in, decision out, no side effects beyond tracing.
enum EvidenceGates {

    private static let log = Logger(subsystem: "com.sidewave.kit", category: "gates")

    /// Silence guard for a whole window: if every sample VAD saw is silence, the text is a
    /// hallucination and is dropped. Acts only when VAD has processed the whole window, and any
    /// speech in the window keeps it.
    static func silenceWindowShouldDrop(
        vadProcessedThrough: Int,
        lastVadSpeechSample: Int,
        segmentStart: Int,
        segmentEnd: Int
    ) -> Bool {
        // VAD works in fixed chunks, so its frontier can end up to one chunk short. Allow 1600
        // samples (100 ms at 16 kHz).
        guard vadProcessedThrough >= segmentEnd - 1_600 else { return false }
        return lastVadSpeechSample < segmentStart
    }

    /// Removes words the decoder predicted after VAD's speech end, cutting them from the end of the
    /// text instead of rebuilding from tokens, so earlier corrections survive. Returns the input
    /// unchanged if any precondition fails.
    static func applyPhantomWordFilter(
        text: String,
        tokenTimings: [TokenTiming]?,
        vadWasSpeaking: Bool,
        speechEndSample: Int?,
        frozenSampleCount: Int
    ) -> String {
        guard !vadWasSpeaking else {
            log.notice("phantom filter bail: VAD still speaking")
            return text
        }
        guard let speechEnd = speechEndSample, speechEnd > frozenSampleCount else {
            log.notice("phantom filter bail: no usable speechEnd")
            return text
        }
        guard let timings = tokenTimings, !timings.isEmpty else {
            log.notice("phantom filter bail: no token timings")
            return text
        }

        let speechEndTimeInSegment = Double(speechEnd - frozenSampleCount) / 16_000.0
        // 300ms padding captures trailing consonants/plosives without being
        // so wide that phantom words (400ms+ after speech) slip through.
        let cutoffTime = speechEndTimeInSegment + 0.3

        let droppedTokens = timings.filter { $0.startTime > cutoffTime }
        guard !droppedTokens.isEmpty else { return text }

        let phantomSuffix = droppedTokens.map(\.token).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phantomSuffix.isEmpty else { return text }

        let trimmedOriginal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOriginal.hasSuffix(phantomSuffix) {
            let result = String(trimmedOriginal.dropLast(phantomSuffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // An EMPTY result is valid: a segment whose every token started
            // after speech end is pure hallucination. Empty flows back to
            // the caller's empty-text guard, which drops the segment.
            log.notice("phantom filter: stripped \(droppedTokens.count, privacy: .public) token(s) past speech end at \(speechEndTimeInSegment, format: .fixed(precision: 2), privacy: .public)s\(result.isEmpty ? " (entire segment)" : "", privacy: .public)")
            return result
        }

        log.notice("phantom filter bail: suffix mismatch (\(droppedTokens.count, privacy: .public) tokens)")
        return text
    }

    /// Display tidy for the raw (unrefined) paste path: capitalize the
    /// first letter and close with a sentence-terminal mark when the
    /// engine didn't emit one. Chinese and Japanese get their own period.
    static func tidyFinalTranscript(_ text: String, detectedLanguage: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        var result = trimmed
        if let first = result.first, first.isLowercase {
            result = result.prefix(1).uppercased() + result.dropFirst()
        }
        let terminals: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ":", ";"]
        if let last = result.last, !terminals.contains(last) {
            let lang = (detectedLanguage ?? "").lowercased()
            let mark = (lang.hasPrefix("zh") || lang.hasPrefix("ja")) ? "。" : "."
            result += mark
        }
        return result
    }
}

/// Adaptive speech-energy detector, with its tuning from the original app. Not used in the live
/// path yet; the finish-time gates cover the paste. Its tests keep the math fixed until the input
/// meter or live preview uses it.
final class AdaptiveSpeechDetector: @unchecked Sendable {
    private let lock = NSLock()

    /// Upper bound for the silence floor (-45 dBFS). Once the background level is known, the
    /// effective floor adapts down to it, since a quiet mic chain can carry speech at 0.002 to
    /// 0.005 RMS.
    static let silenceFloorRMS: Double = 0.0056
    /// Hard lower bound (-58 dBFS): true digital silence stays classified
    /// as silence no matter how low the background drifts.
    private static let minFloorRMS: Double = 0.0012
    /// Adaptive floor = background * this margin, clamped to
    /// [minFloorRMS, silenceFloorRMS].
    private static let floorMarginOverBackground: Double = 3.0
    /// Speech must exceed the background estimate by this factor: steady
    /// room tone (fan, HVAC, hum) never reads as speech, quiet talkers do.
    private static let speechMargin: Double = 2.2
    /// Cap on the background estimate so continuous speech can't slowly
    /// pull the "background" up into the talker's own level.
    private static let backgroundCeilingRMS: Double = 0.02
    /// Buffers (~85ms each) before the background estimate is trusted
    /// enough to adapt the floor below the fixed cap.
    private static let establishedBufferCount = 12

    private var _backgroundRMS: Double = 0.001
    private var _lastSpeechAt: Double = 0
    private var _levelBufferCount = 0
    private var _quietChainMode = false

    /// Advance the detector with one buffer's RMS. `now` only ever feeds
    /// delta comparisons, so any monotonic-enough clock works.
    func noteAudioLevel(_ rms: Double, peak: Double, at now: Double) {
        lock.lock()
        defer { lock.unlock() }
        _levelBufferCount += 1
        // Background tracks quiet fast (drops toward true silence) and
        // rises slowly, clamped, so it represents room tone, not speech.
        if rms < _backgroundRMS {
            _backgroundRMS = _backgroundRMS * 0.90 + rms * 0.10
        } else {
            _backgroundRMS = min(Self.backgroundCeilingRMS, _backgroundRMS * 0.997 + rms * 0.003)
        }
        let established = _levelBufferCount >= Self.establishedBufferCount
        let effectiveFloor: Double
        if established || _quietChainMode {
            effectiveFloor = min(
                Self.silenceFloorRMS,
                max(Self.minFloorRMS, _backgroundRMS * Self.floorMarginOverBackground))
        } else {
            effectiveFloor = Self.silenceFloorRMS
        }
        let speechThreshold = max(effectiveFloor, _backgroundRMS * Self.speechMargin)
        if rms > speechThreshold { _lastSpeechAt = now }
    }

    /// Time of the most recent buffer classified as speech.
    var lastSpeechAt: Double {
        lock.lock()
        defer { lock.unlock() }
        return _lastSpeechAt
    }

    /// The chain proved quieter than the fixed floor: commit to the
    /// adaptive floor and treat this instant as speech.
    func relaxFloorForQuietChain(at now: Double) {
        lock.lock()
        defer { lock.unlock() }
        _quietChainMode = true
        _lastSpeechAt = now
    }

    /// Clears the detector between sessions. `lastSpeechAt` starts at `now`, not zero, so the
    /// hangover window gives the first words a trust period.
    func reset(at now: Double) {
        lock.lock()
        defer { lock.unlock() }
        _backgroundRMS = 0.001
        _lastSpeechAt = now
        _levelBufferCount = 0
        _quietChainMode = false
    }
}
