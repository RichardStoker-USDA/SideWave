// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
import AppKit
@preconcurrency import AVFAudio
import CoreAudio
import FluidAudio
import Foundation
import os

@MainActor
extension TranscriptionService {
    // MARK: - Polling-based Live Preview

    /// Polls accumulated audio with adaptive intervals and runs batch transcription for live preview.
    /// Uses segment-based architecture: when active segment reaches ~14s, finalize it and start fresh.
    /// Only the current active segment gets re-transcribed, so polling stays fast regardless of session length.
    func startPollingLoop(pollManager: AsrManager) {
        let bufs = audioBuffers
        let minSamples = self.minSamplesForTranscription
        let generation = sessionGeneration

        pollingTask = Task { [weak self] in
            // First poll after about 0.6 s, close to minSamples (1 s of audio at 16 kHz). Polling
            // earlier fails that check and ends up slower.
            do {
                try await Task.sleep(nanoseconds: UInt64(0.6 * 1_000_000_000))
            } catch {
                return
            }

            while !Task.isCancelled {
                var currentCount = bufs.sampleCount()

                // Skip this cycle if previous transcription is still running.
                // Prevents poll pile-up when transcription takes longer than the interval.
                guard let self, !self.isPollingInProgress else {
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms re-check
                    } catch {
                        break
                    }
                    continue
                }

                // Don't start new transcription work after recording stops.
                guard self.isRecording else {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(0.6 * 1_000_000_000))
                    } catch {
                        break
                    }
                    continue
                }

                // Feed new audio to VAD for speech boundary detection
                await self.drainVadWithinLimit()

                // Check if segment finalization is needed.
                // Two triggers: VAD-detected speech end (natural pause) or fixed ceiling (safety net).
                let totalSamples = currentCount + self.totalDroppedSamples
                let activeSampleCount = totalSamples - self.frozenSampleCount

                // ASR-only modes confirm at natural pauses. Refine cadence only
                // controls sessions that actually run the live language model.
                let cadence = UserDefaults.standard.string(forKey: "refineCadence") ?? "standard"
                let allowVadFinalizeInMultiStage = !self.refineRealTimeActive || cadence != "standard"

                let vadTriggered: Bool
                let speechEndForFilter: Int?
                if (!self.multiStageActive || allowVadFinalizeInMultiStage),
                   let speechEnd = self.lastSpeechEndSampleIndex,
                   speechEnd > self.frozenSampleCount,
                   activeSampleCount >= Self.minSamplesForVadFinalization {
                    vadTriggered = true
                    speechEndForFilter = speechEnd
                    self.lastSpeechEndSampleIndex = nil
                } else {
                    vadTriggered = false
                    // Fixed-length finalize: keep the latest speech end if it falls in this
                    // segment, so the phantom filter can still strip words TDT predicted in the
                    // silence.
                    if let speechEnd = self.lastSpeechEndSampleIndex,
                       speechEnd > self.frozenSampleCount
                    {
                        speechEndForFilter = speechEnd
                    } else {
                        speechEndForFilter = nil
                    }
                }

                let fixedTriggered = activeSampleCount >= self.segmentDurationSamples

                // Experimental fixed-interval refine: finalize every N seconds since the last
                // finalize, pauses or not. minSamples still applies.
                let intervalTriggered: Bool = {
                    guard self.refineRealTimeActive,
                          UserDefaults.standard.bool(forKey: "refineFixedIntervalEnabled")
                    else { return false }
                    guard activeSampleCount >= Self.minSamplesForVadFinalization else { return false }
                    let intervalSeconds = max(3, min(12, UserDefaults.standard.integer(forKey: "refineFixedIntervalSeconds")))
                    let now = CFAbsoluteTimeGetCurrent()
                    guard self.lastFinalizeWallTime > 0,
                          (now - self.lastFinalizeWallTime) >= Double(intervalSeconds)
                    else { return false }
                    // An interval finalize runs a TDT decode, CTC, and refine prefill, which
                    // compete with the streaming preview if they land mid-word. Wait for a short
                    // lull (no EOU partial for 1 s). The 14.8 s limit still covers someone who
                    // never pauses.
                    if let lastEmit = self.lastEouEmitAt,
                       Date().timeIntervalSince(lastEmit) < 1.0 {
                        return false
                    }
                    return true
                }()

                if vadTriggered || fixedTriggered || intervalTriggered {
                    self.isPollingInProgress = true
                    if vadTriggered {
                        await self.finalizeCurrentSegment(
                            vadTriggered: true,
                            activeSampleCount: activeSampleCount,
                            speechEndSample: speechEndForFilter
                        )
                    } else if intervalTriggered {
                        // Finalize at the current active length, like a VAD trigger, rather than
                        // the 14.8 s default. The trace labels it as an interval finalize.
                        await self.finalizeCurrentSegment(
                            vadTriggered: true,
                            activeSampleCount: activeSampleCount,
                            speechEndSample: speechEndForFilter,
                            triggerLabelOverride: "interval"
                        )
                    } else {
                        await self.finalizeCurrentSegment(
                            speechEndSample: speechEndForFilter
                        )
                    }
                    self.lastFinalizeWallTime = CFAbsoluteTimeGetCurrent()
                    self.isPollingInProgress = false

                    // Count again after finalizing, which dropped samples; the old count would
                    // overstate the active range.
                    currentCount = bufs.sampleCount()

                    // Finalizing takes 500 to 1000 ms. If enough audio arrived meanwhile, poll
                    // again after 100 ms instead of the full interval.
                    let newActiveStart = self.frozenSampleCount - self.totalDroppedSamples
                    let newActiveCount = currentCount - newActiveStart
                    if newActiveCount < minSamples {
                        do {
                            try await Task.sleep(nanoseconds: 100_000_000)
                        } catch {
                            break
                        }
                    }
                    continue
                }

                // Transcribe only the active segment (from frozenSampleCount to end of buffer)
                let activeStart = self.frozenSampleCount - self.totalDroppedSamples
                let activeCount = currentCount - activeStart
                guard activeCount >= minSamples else {
                    // Not enough active audio yet, wait and retry
                    do {
                        try await Task.sleep(nanoseconds: UInt64(0.6 * 1_000_000_000))
                    } catch {
                        break
                    }
                    continue
                }

                self.isPollingInProgress = true
                let samples = bufs.sampleRange(from: activeStart, count: activeCount)

                // Use self.pollingAsrManager (not the captured pollManager local) so
                // that AsrManager reinitialization in the error-recovery path takes effect.
                guard let activePollManager = self.pollingAsrManager else {
                    self.isPollingInProgress = false
                    break
                }

                do {
                    // A new decoder state each poll: the loop transcribes the active segment from
                    // scratch every cycle, and carried state would duplicate text.
                    var decoderState = try TdtDecoderState()
                    let result = try await activePollManager.transcribe(samples, decoderState: &decoderState)
                    // Transcription succeeded (even if text is empty), reset error counter
                    self.consecutivePollingErrors = 0

                    // Update live stats for dashboard
                    self.currentConfidence = Double(result.confidence)
                    if result.processingTime > 0 && result.duration > 0 {
                        // Standard RTFx: processingTime / audioDuration
                        // < 1.0 = faster than real-time (good), >= 1.0 = slower (bad)
                        self.currentRtfx = result.processingTime / result.duration
                    }

                    #if DEBUG
                    if result.processingTime > 0 && result.duration > 0 {
                        let rtfx = result.processingTime / result.duration
                        if rtfx > 0.8 {
                            SWLog.note("[TranscriptionService] Slow poll: \(String(format: "%.2f", rtfx))x RT (\(String(format: "%.2f", result.processingTime))s for \(String(format: "%.1f", result.duration))s audio)")
                        }
                    }
                    #endif

                    guard self.sessionGeneration == generation else { return }
                    guard !Task.isCancelled, self.isRecording else {
                        self.isPollingInProgress = false
                        break
                    }
                    let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Skip very low confidence transcriptions (likely noise/silence artifacts).
                    // Skip very low confidence transcriptions (likely noise/silence artifacts)
                    if result.confidence < 0.15 && !rawText.isEmpty {
                        self.isPollingInProgress = false
                        continue
                    }

                    guard !rawText.isEmpty else {
                        self.isPollingInProgress = false
                        do {
                            let interval = self.adaptiveInterval(for: activeCount)
                            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        } catch { break }
                        continue
                    }

                    // Remove filler words (um, uh, etc.) if enabled
                    let cleanedText = Self.removeFillerWords(rawText)
                    guard !cleanedText.isEmpty else {
                        self.isPollingInProgress = false
                        do {
                            let interval = self.adaptiveInterval(for: activeCount)
                            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        } catch { break }
                        continue
                    }

                    // Filter profanity if enabled
                    let filteredText = Self.filterProfanity(cleanedText)

                    // Apply custom dictionary replacements
                    let dictText = CustomDictionary.apply(to: filteredText)
                    let safeText = dictText

                    // Stabilize active segment text with smart diff to reduce visual bouncing
                    var stableText = self.smartDiffUpdate(previous: self.volatileText, current: safeText)
                    if stableText != safeText {
                        let suppressed = wordCount(safeText) - wordCount(stableText)
                        dictationTraceLog.notice("tdt smartdiff suppressed=\(suppressed, privacy: .public) candidate_words=\(wordCount(safeText), privacy: .public) accepted_words=\(wordCount(stableText), privacy: .public)")
                    }

                    // Throttled CTC boost for the live preview, at most every 1.5 s, so a
                    // vocabulary term matching the audio appears in the preview before the segment
                    // finalizes. Skipped without vocabulary. The rescoring is acoustic, so terms
                    // not in the audio aren't inserted.
                    if self.shouldRunLiveCtcBoost(),
                       self.ctcBooster != nil
                    {
                        self.lastLiveCtcBoostTime = Date()
                        let boosted = await self.applyCtcRescoring(result: result, audioSamples: samples)
                        let trimmedBoosted = boosted.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedBoosted.isEmpty && trimmedBoosted != safeText {
                            // Apply the same cleanup as the live preview, so substitutions stay
                            // consistent.
                            let postCleaned = Self.removeFillerWords(trimmedBoosted)
                            let postFiltered = Self.filterProfanity(postCleaned)
                            let postDict = CustomDictionary.apply(to: postFiltered)
                            let postSafe = postDict
                            stableText = self.smartDiffUpdate(previous: self.volatileText, current: postSafe)
                        }
                    }

                    guard self.sessionGeneration == generation else { return }
                    guard !Task.isCancelled, self.isRecording else {
                        self.isPollingInProgress = false
                        break
                    }

                    // In dual-engine sessions EOU drives the overlay until AppState decides the
                    // press is a toggle, so polling doesn't write the preview while undecided or in
                    // EOU mode. cachedFrozenText still accumulates for the toggle stop.
                    //
                    // Noise guard, matching the commit guards in finalizeCurrentSegment: don't show
                    // TDT text while VAD has heard no speech this session, or none since this
                    // window began. It's the recognizer reacting to noise. The pause check needs
                    // VAD to have processed past the window start, and preview updates resume
                    // within one chunk of new speech.
                    let noiseSuppressed = UserDefaults.standard.bool(forKey: "phantomNoiseGuardsEnabled")
                        && self.vadManager != nil
                        && self.vadStreamState != nil
                        && (!self.vadSawSpeechThisSession
                            || (self.lastVadSpeechSampleIndex < self.frozenSampleCount
                                && self.vadConsumedFrontierSampleIndex > self.frozenSampleCount))
                    let pollingOwnsOverlay = (!self.dualEngineActive
                        || self.currentEngineForOverlay == .tdt)
                        && !noiseSuppressed
                    let prevWordsPoll = wordCount(self.volatileText)
                    let newWordsPoll = wordCount(stableText)
                    let deltaPoll = newWordsPoll - prevWordsPoll
                    let droppedToFilter = wordCount(rawText) - newWordsPoll
                    dictationTraceLog.notice("tdt poll words=\(newWordsPoll, privacy: .public) delta=\(deltaPoll, privacy: .public) painted=\(pollingOwnsOverlay, privacy: .public) postProcDrop=\(droppedToFilter, privacy: .public) conf=\(result.confidence, format: .fixed(precision: 2), privacy: .public) tail=\(transcriptMetrics(stableText), privacy: .public)")
                    if pollingOwnsOverlay {
                        self.volatileText = stableText
                        self.lastVolatileSnapshot = stableText

                        // Multi-stage: give the staged transcript this segment's TDT text, so the
                        // preview shows corrected words in the confirmed zone instead of restyled
                        // EOU words. Not used in direct mode.
                        if self.multiStageActive && !self.directEouRefineActive {
                            self.stagedTranscript.ingestTdtStreaming(stableText)
                        }

                        // Write the active segment's text to a sidecar about every 1.5 s, so a
                        // crash mid-segment can be recovered on next launch. Throttled inside.
                        self.maybeWriteVolatileSnapshot(stableText)
                    }

                } catch {
                    self.consecutivePollingErrors += 1
                    SWLog.note("[TranscriptionService] Polling transcription error (\(self.consecutivePollingErrors) consecutive): \(error)")

                    // After 5 consecutive failures, try reinitializing the AsrManager.
                    // CoreML models can occasionally enter a bad state after extended use.
                    // Guard with isReinitializingAsrManager to prevent concurrent reinit attempts.
                    if self.consecutivePollingErrors >= 5, self.isRecording, !self.isReinitializingAsrManager {
                        self.isReinitializingAsrManager = true
                        SWLog.note("[TranscriptionService] Attempting AsrManager reinitialization after \(self.consecutivePollingErrors) consecutive errors")
                        do {
                            guard !Task.isCancelled, self.isRecording else {
                                self.isReinitializingAsrManager = false
                                break
                            }
                            let version = self.storedModelVersion()
                            let models: AsrModels
                            if let cached = self.cachedModels, self.cachedModelVersion == version.rawValue {
                                models = cached
                            } else {
                                models = try await version.loadModels()
                                guard !Task.isCancelled, self.isRecording else {
                                    self.isReinitializingAsrManager = false
                                    break
                                }
                                self.cachedModels = models
                                self.cachedModelVersion = version.rawValue
                            }
                            let newManager = AsrManager(config: ASRConfig.default)
                            try await newManager.loadModels(models)
                            guard !Task.isCancelled, self.isRecording else {
                                self.isReinitializingAsrManager = false
                                break
                            }
                            self.pollingAsrManager = newManager
                            self.consecutivePollingErrors = 0
                            SWLog.note("[TranscriptionService] AsrManager reinitialized successfully")
                        } catch {
                            SWLog.note("[TranscriptionService] AsrManager reinitialization failed: \(error)")
                        }
                        self.isReinitializingAsrManager = false
                    }
                }
                self.isPollingInProgress = false

                // Adaptive polling interval based on active segment size (always stays fast)
                do {
                    let interval = self.adaptiveInterval(for: activeCount)
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
            }
        }
    }

    /// Returns an adaptive polling interval based on the active segment sample count.
    /// Polls faster as the segment fills, since more audio means more text the user expects to see.
    private func adaptiveInterval(for sampleCount: Int) -> Double {
        switch sampleCount {
        case ..<32_000:    return 0.8   // <2s: not enough audio yet
        case ..<80_000:    return 0.6   // 2-5s: standard cadence
        case ..<160_000:   return 0.5   // 5-10s: slightly faster
        default:           return 0.4   // >10s: fast updates before finalization
        }
    }

    // MARK: - Text Stabilization

    /// Stabilizes display text by keeping a common word prefix between consecutive
    /// transcriptions, reducing visual bouncing when the ASR model re-transcribes
    /// the same audio with slightly different wording.
    private func smartDiffUpdate(previous: String, current: String) -> String {
        guard !previous.isEmpty else { return current }
        // Zero-work short-circuit when the model re-emits identical text.
        // Avoids two splits + join in the common steady-state poll.
        if previous == current { return current }

        let prevWords = previous.split(separator: " ")
        let currWords = current.split(separator: " ")

        guard !prevWords.isEmpty, !currWords.isEmpty else { return current }

        // Find longest common prefix (case-insensitive)
        var commonLen = 0
        for i in 0..<min(prevWords.count, currWords.count) {
            if prevWords[i].lowercased() == currWords[i].lowercased() {
                commonLen = i + 1
            } else {
                break
            }
        }

        // If significant overlap (>40%), keep stable prefix from previous + new tail from current
        if commonLen > currWords.count * 2 / 5 {
            let stablePrefix = prevWords[0..<commonLen].joined(separator: " ")
            if commonLen < currWords.count {
                // Current extends previous → grow the display.
                let newTail = currWords[commonLen...].joined(separator: " ")
                return stablePrefix + " " + newTail
            } else if commonLen < prevWords.count {
                // Current is a prefix of previous: the model dropped trailing words this poll. Keep
                // previous so the preview doesn't shrink; a real change falls through to the
                // replace branch.
                return previous
            } else {
                // commonLen == currWords.count == prevWords.count.
                // Identical content (handled above by the short-circuit but
                // covered defensively for the empty-string edge case).
                return current
            }
        } else {
            // Transcriptions diverged too much, accept the new one wholesale
            return current
        }
    }

    /// Per-window silence guard (pure; pinned by EouGhostGateTests). A segment with no VAD speech
    /// in its window is a pause, and its text is dropped as a hallucination. It acts only when VAD
    /// has processed the whole window, and any speech in the window keeps the segment.
    nonisolated static func silenceWindowShouldDrop(
        vadProcessedThrough: Int,
        lastVadSpeechSample: Int,
        segmentStart: Int,
        segmentEnd: Int
    ) -> Bool {
        // VAD works in fixed chunks, so its frontier can end up to one chunk short of the window.
        // Allow 1600 samples (100 ms at 16 kHz).
        guard vadProcessedThrough >= segmentEnd - 1_600 else { return false }
        return lastVadSpeechSample < segmentStart
    }

    /// Removes words the TDT decoder predicted after speech ended, using VAD's speech-end sample
    /// and per-token timings. Strips them from the end of the (possibly CTC-rescored) text rather
    /// than rebuilding it from tokens, which would lose rescoring corrections. Returns the text
    /// unchanged if any precondition fails.
    static func applyPhantomWordFilter(
        text: String,
        tokenTimings: [TokenTiming]?,
        vadWasSpeaking: Bool,
        speechEndSample: Int?,
        frozenSampleCount: Int
    ) -> String {
        // Filter only when VAD says speech ended. Each early return is traced, so a filter that did
        // nothing can be told apart from one that found nothing.
        guard !vadWasSpeaking else {
            dictationTraceLog.notice("phantom filter bail: VAD still speaking (trigger latch hangover)")
            return text
        }
        guard let speechEnd = speechEndSample, speechEnd > frozenSampleCount else {
            dictationTraceLog.notice("phantom filter bail: no usable speechEnd (nil or before segment start)")
            return text
        }
        guard let timings = tokenTimings, !timings.isEmpty else {
            dictationTraceLog.notice("phantom filter bail: no token timings on result")
            return text
        }

        let speechEndTimeInSegment = Double(speechEnd - frozenSampleCount) / 16000.0
        // 300ms padding captures trailing consonants/plosives without being so wide
        // that phantom words (which appear 400ms+ after speech) slip through
        let cutoffTime = speechEndTimeInSegment + 0.3

        // Identify tokens that fall after the speech end (phantom predictions)
        let droppedTokens = timings.filter { $0.startTime > cutoffTime }
        guard !droppedTokens.isEmpty else { return text }

        // Phantom words at the end aren't CTC-rescored, so their token text matches the end of
        // result.text.
        let phantomSuffix = droppedTokens.map(\.token).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phantomSuffix.isEmpty else { return text }

        // Strip the phantom suffix from the end of the original text.
        // This preserves any CTC vocabulary rescoring applied to earlier tokens.
        let trimmedOriginal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOriginal.hasSuffix(phantomSuffix) {
            let result = String(trimmedOriginal.dropLast(phantomSuffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty result is valid: when every token started after speech ended, the whole
            // segment was hallucinated. The caller drops empty segments.
            if result.isEmpty {
                dictationTraceLog.notice("phantom filter: stripped entire segment (\(droppedTokens.count, privacy: .public) tokens past speech end at \(speechEndTimeInSegment, format: .fixed(precision: 2), privacy: .public)s)")
            } else {
                SWLog.note("[TranscriptionService] Phantom word filter: stripped \(droppedTokens.count) trailing token(s) after speech end at \(String(format: "%.2f", speechEndTimeInSegment))s")
            }
            return result
        }

        // Suffix didn't match (rare: could happen if text was heavily post-processed).
        // Fall back to original text rather than risk garbling it.
        dictationTraceLog.notice("phantom filter bail: suffix mismatch dropped=\(droppedTokens.count, privacy: .public) suffix=\"\(phantomSuffix, privacy: .public)\"")
        return text
    }

    /// Removes common filler words (um, uh, etc.) and custom filler phrases from transcribed text.
    /// Custom phrases are matched first (phrase-level, case-insensitive) before single-word fillers.
    /// Controlled by the removeFillerWords UserDefaults setting.
    static func removeFillerWords(_ text: String) -> String {
        guard UserDefaults.standard.bool(forKey: "removeFillerWords") else { return text }

        // Fast path: empty/whitespace input skips regex compile + word split.
        if text.isEmpty { return text }

        var result = text

        // Phase 1: Remove custom filler phrases (multi-word matches before word-level).
        // Uses the cached compiled regexes; avoids compiling N regexes per poll.
        let regexes = customFillerRegexes()
        for regex in regexes {
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Phase 2: Remove default single-word fillers. Scan for any filler
        // before paying the O(n) split + alloc cost; if there's no filler
        // byte-substring, the split is wasted.
        let lowered = result.lowercased()
        let hasAnyFiller = Self.defaultFillers.contains(where: { lowered.contains($0) })
        guard hasAnyFiller else { return result }

        let words = result.split(separator: " ", omittingEmptySubsequences: true)
        let filtered = words.filter { word in
            let cleaned = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !Self.defaultFillers.contains(cleaned)
        }

        return filtered.joined(separator: " ")
    }

    /// Compiled custom filler regexes, keyed on the stored phrase list so edits invalidate them.
    private static let customFillerCacheLock = NSLock()
    private static var customFillerCache: (dataHash: Int, regexes: [NSRegularExpression])?

    private static func customFillerRegexes() -> [NSRegularExpression] {
        let data = UserDefaults.standard.data(forKey: "customFillerPhrases")
        let hash = data?.hashValue ?? 0

        customFillerCacheLock.lock()
        if let cache = customFillerCache, cache.dataHash == hash {
            customFillerCacheLock.unlock()
            return cache.regexes
        }
        customFillerCacheLock.unlock()

        let phrases = loadCustomFillerPhrases()
        let built: [NSRegularExpression] = phrases.compactMap { phrase in
            guard !phrase.isEmpty else { return nil }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
            return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }

        customFillerCacheLock.lock()
        customFillerCache = (hash, built)
        customFillerCacheLock.unlock()
        return built
    }
}
