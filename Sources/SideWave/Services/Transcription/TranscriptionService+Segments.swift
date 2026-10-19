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
    // MARK: - Custom Filler Phrases Persistence

    /// Load custom filler phrases from UserDefaults (JSON array of strings).
    static func loadCustomFillerPhrases() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: "customFillerPhrases"),
              let phrases = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return phrases
    }



    // MARK: - Profanity Filter

    /// Applies the profanity settings: `removeProfanity` deletes words and `replaceProfanity` swaps
    /// in milder ones. Removal wins when both are on.
    static func filterProfanity(_ text: String) -> String {
        let remove = UserDefaults.standard.bool(forKey: "removeProfanity")
        let replace = UserDefaults.standard.bool(forKey: "replaceProfanity")
        guard remove || replace else { return text }

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var resultWords: [String] = []

        for word in words {
            let original = String(word)
            let leading = original.prefix(while: { $0.isPunctuation })
            let trailing = String(original.reversed().prefix(while: { $0.isPunctuation }).reversed())
            let stripped = String(original.dropFirst(leading.count).dropLast(trailing.count))
            guard !stripped.isEmpty else {
                resultWords.append(original)
                continue
            }
            let lower = stripped.lowercased()

            if profanityWords.contains(lower) {
                if remove {
                    // Redact: keep first letter + asterisks to preserve context
                    let firstLetter = String(stripped.prefix(1))
                    let starCount = max(stripped.count - 1, 2)
                    let redacted = firstLetter + String(repeating: "*", count: starCount)
                    resultWords.append(String(leading) + redacted + trailing)
                } else if replace, let replacement = profanityReplacements[lower] {
                    var adjusted = replacement
                    if let first = stripped.first, first.isUppercase {
                        adjusted = adjusted.prefix(1).uppercased() + adjusted.dropFirst()
                    }
                    resultWords.append(String(leading) + adjusted + String(trailing))
                } else {
                    resultWords.append(original)
                }
            } else {
                resultWords.append(original)
            }
        }

        return resultWords.joined(separator: " ")
    }

    // MARK: - Segment Finalization

    /// Transcribes the current segment (with CTC rescoring when available), freezes its text, and
    /// drops its audio. Runs when:
    /// - the segment reaches segmentDurationSamples (14.8 s), or
    /// - VAD detects the end of speech and the segment has at least 3 s of audio.
    /// A VAD finalize uses the actual length (3 to 14.8 s); a fixed one always uses the full length.
    func finalizeCurrentSegment(
        vadTriggered: Bool = false,
        activeSampleCount: Int? = nil,
        speechEndSample: Int? = nil,
        isFinalStop: Bool = false,
        triggerLabelOverride: String? = nil
    ) async {
        guard isRecording else { return }
        let generation = sessionGeneration

        // Determine the segment size to finalize
        let segmentSize: Int
        if vadTriggered, let activeCount = activeSampleCount {
            // VAD-triggered: finalize exactly the active audio (variable length, capped at ceiling)
            segmentSize = min(activeCount, segmentDurationSamples)
        } else {
            segmentSize = segmentDurationSamples
        }

        let segmentStart = frozenSampleCount
        let segmentEnd = segmentStart + segmentSize

        // Position within the buffer, after samples already dropped.
        let bufferStart = segmentStart - totalDroppedSamples
        let segmentSamples = audioBuffers.sampleRange(from: bufferStart, count: segmentSize)

        // On active recording, require 1s (16k samples) to keep segments clean.
        // On stop (isRecording is false or isFinalStop is true), allow down to 0.2s (3200 samples) to catch short final words.
        let minSamples = (isRecording && !isFinalStop) ? minSamplesForTranscription : 3200
        guard segmentSamples.count >= minSamples else { return }

        guard let manager = pollingAsrManager else { return }

        let triggerLabel = triggerLabelOverride ?? (vadTriggered ? "VAD" : "fixed")

        do {
            // A new decoder state per segment; each segment is transcribed on its own.
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(segmentSamples, decoderState: &decoderState)
            guard sessionGeneration == generation, isRecording, !Task.isCancelled else { return }

            // Reject very low confidence finalization results (likely pure noise).
            // Use a lower threshold than polling (0.05 vs 0.15) since finalization
            // is the last chance to capture text for this segment.
            if result.confidence < 0.05 {
                let safeDrop = audioBuffers.dropFirstSamples(segmentSize)
                frozenSampleCount += safeDrop
                totalDroppedSamples += safeDrop
                volatileText = ""
                return
            }

            // Noise guard: while VAD is running and has heard no speech this session, the segment
            // is the recognizer reacting to noise, and confidence alone doesn't catch it ("I don't
            // know." at 0.81 from a fan). Drop it. Fails open without VAD; the first real speech
            // opens it for the session.
            if UserDefaults.standard.bool(forKey: "phantomNoiseGuardsEnabled"),
               vadManager != nil, vadStreamState != nil, !vadSawSpeechThisSession {
                dictationTraceLog.notice("segment dropped: VAD saw no speech this session (noise guard) trigger=\(triggerLabel, privacy: .public) tail=\(transcriptMetrics(result.text), privacy: .public)")
                let safeDrop = audioBuffers.dropFirstSamples(segmentSize)
                frozenSampleCount += safeDrop
                totalDroppedSamples += safeDrop
                volatileText = ""
                return
            }

            // Per-window guard: a segment with no speech inside it is a pause, and its text is a
            // hallucination. Acts only when VAD has processed the whole window.
            if UserDefaults.standard.bool(forKey: "phantomNoiseGuardsEnabled"),
               vadManager != nil, vadStreamState != nil,
               Self.silenceWindowShouldDrop(
                   vadProcessedThrough: vadConsumedFrontierSampleIndex,
                   lastVadSpeechSample: lastVadSpeechSampleIndex,
                   segmentStart: segmentStart,
                   segmentEnd: segmentEnd
               ) {
                dictationTraceLog.notice("segment dropped: no VAD speech inside window (pause guard) trigger=\(triggerLabel, privacy: .public) tail=\(transcriptMetrics(result.text), privacy: .public)")
                let safeDrop = audioBuffers.dropFirstSamples(segmentSize)
                frozenSampleCount += safeDrop
                totalDroppedSamples += safeDrop
                volatileText = ""
                return
            }

            // Apply CTC vocabulary rescoring before any text processing.
            // This must run on the raw ASRResult (with tokenTimings) and raw audio,
            // before filler removal, ITN, or dictionary substitution alters the text.
            let rescoredText = await applyCtcRescoring(result: result, audioSamples: segmentSamples)
            guard sessionGeneration == generation, isRecording, !Task.isCancelled else { return }

            // Strip words TDT predicted in the silent part of a long segment before they reach the
            // transcript or refine. Runs only when the speech end is known within this segment.
            let filteredText = Self.applyPhantomWordFilter(
                text: rescoredText,
                tokenTimings: result.tokenTimings,
                vadWasSpeaking: false,
                speechEndSample: speechEndSample,
                frozenSampleCount: frozenSampleCount
            )

            var text = filteredText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // Force-advance counters to prevent spin loop on empty/silent segments
                let safeDrop = audioBuffers.dropFirstSamples(segmentSize)
                frozenSampleCount += safeDrop
                totalDroppedSamples += safeDrop
                volatileText = ""
                return
            }

            let preFillerWordCount = text.split(separator: " ").count
            text = Self.removeFillerWords(text)
            let postFillerWordCount = text.split(separator: " ").count
            let removedFillers = preFillerWordCount - postFillerWordCount
            if removedFillers > 0 {
                fillerWordsRemovedCount += removedFillers
            }

            // Inverse text normalization: spoken numbers, dates, and amounts become digits. Runs
            // after filler removal, so "um two hundred" becomes "200". Ordinals used as discourse
            // ("first, second") go back to words; "2nd place" stays. No-op without the NeMo
            // library.
            text = ProseOrdinalReverter.revert(TextNormalizer.shared.normalizeSentence(text))

            text = Self.filterProfanity(text)
            let preDict = text
            text = CustomDictionary.apply(to: text)
            if text != preDict {
                dictionaryReplacementsCount += 1
            }

            guard !text.isEmpty else {
                // Text was only filler words - still advance counters to prevent spin loop
                let safeDrop = audioBuffers.dropFirstSamples(segmentSize)
                frozenSampleCount += safeDrop
                totalDroppedSamples += safeDrop
                volatileText = ""
                return
            }

            let segment = FrozenSegment(
                index: totalFrozenSegmentsCount,
                text: text,
                sampleStart: segmentStart,
                sampleEnd: segmentEnd,
                timestamp: Date()
            )
            frozenSegments.append(segment)
            totalFrozenSegmentsCount += 1
            persistSegment(segment)
            // The segment is now saved in the .jsonl, so clear the sidecar and reset the throttles,
            // which lets the next segment's first poll write and boost right away.
            cleanupVolatileSidecar()
            lastVolatilePersistTime = .distantPast
            lastLiveCtcBoostTime = .distantPast

            // Trim in-memory segment history to cap memory usage.
            // cachedFrozenText already holds the full concatenated text,
            // so old FrozenSegment structs are only needed for session persistence.
            if frozenSegments.count > Self.maxFrozenSegmentsKept {
                frozenSegments.removeFirst(frozenSegments.count - Self.maxFrozenSegmentsKept)
            }

            // Update live stats
            currentSegmentCount = totalFrozenSegmentsCount
            if vadTriggered {
                vadTriggeredSegments += 1
            }
            // Vocab stat covers unrefined output too (skip/raw paths); the
            // refine-apply hop recomputes again after the model's version.
            recomputeVocabOutputStat()

            // Update cached frozen text (O(1) append instead of O(n) rebuild)
            if cachedFrozenText.isEmpty {
                cachedFrozenText = text
            } else {
                cachedFrozenText += " " + text
            }

            // Advance to next segment
            frozenSampleCount = segmentEnd

            // Drop old audio to free memory
            let safeDrop = audioBuffers.dropFirstSamples(segmentSize)
            totalDroppedSamples += safeDrop

            // Clear the volatile text before updating the confirmed text, so the finalized words
            // aren't shown twice for a frame. When EOU drives the overlay, leave its bindings
            // alone; polling still keeps cachedFrozenText for the toggle stop.
            let pollingOwnsOverlay = !dualEngineActive
                || currentEngineForOverlay == .tdt
            if pollingOwnsOverlay {
                volatileText = ""
                confirmedText = cachedFrozenText
            }

            segmentFinalizationFailures = 0

            SWLog.note("[TranscriptionService] Segment \(segment.index) finalized (\(triggerLabel), \(String(format: "%.1f", Double(segmentSize) / 16000.0))s)")
            let segDur = Double(segmentSize) / 16_000.0
            dictationTraceLog.notice("tdt finalize idx=\(segment.index, privacy: .public) words=\(wordCount(text), privacy: .public) dur=\(segDur, format: .fixed(precision: 2), privacy: .public)s trigger=\(triggerLabel, privacy: .public) tail=\(transcriptMetrics(text), privacy: .public)")

            // Multi-stage: add the finalized segment to the staged transcript as a TDT span and
            // optionally queue it for refine. Direct mode commits EOU text from the VAD handler
            // instead, so TDT committing too would duplicate spans.
            if multiStageActive && !directEouRefineActive {
                let spanID = stagedTranscript.ingestTdtCommitted(text)
                if refineRealTimeActive && !isFinalStop {
                    enqueueRefine(spanID: spanID)
                }
            }

        } catch {
            SWLog.note("[TranscriptionService] Segment finalization failed (\(triggerLabel)): \(error)")
            segmentFinalizationFailures += 1
            if segmentFinalizationFailures >= 3 {
                // Use lastVolatileSnapshot first (survives finalization clearing volatileText),
                // fall back to volatileText if snapshot is also empty.
                let snapshotText = lastVolatileSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentVolatile = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackText = snapshotText.isEmpty ? currentVolatile : snapshotText
                if !fallbackText.isEmpty {
                    let segment = FrozenSegment(
                        index: totalFrozenSegmentsCount,
                        text: fallbackText,
                        sampleStart: segmentStart,
                        sampleEnd: segmentEnd,
                        timestamp: Date()
                    )
                    frozenSegments.append(segment)
                    totalFrozenSegmentsCount += 1

                    // Trim in-memory segment history
                    if frozenSegments.count > Self.maxFrozenSegmentsKept {
                        frozenSegments.removeFirst(frozenSegments.count - Self.maxFrozenSegmentsKept)
                    }

                    // Update cached frozen text
                    if cachedFrozenText.isEmpty {
                        cachedFrozenText = fallbackText
                    } else {
                        cachedFrozenText += " " + fallbackText
                    }

                    let pollingOwnsOverlayFail = !dualEngineActive
                        || currentEngineForOverlay == .tdt
                    if pollingOwnsOverlayFail {
                        confirmedText = cachedFrozenText
                    }
                }
                // Advance the counters after 3 failures even without fallback text, or the same
                // segment would be retried forever.
                frozenSampleCount = segmentEnd
                let safeDrop = audioBuffers.dropFirstSamples(segmentSize)
                totalDroppedSamples += safeDrop
                segmentFinalizationFailures = 0
                let pollingOwnsOverlayClear = !dualEngineActive
                    || currentEngineForOverlay == .tdt
                if pollingOwnsOverlayClear {
                    volatileText = ""
                }
            }
        }
    }
}
