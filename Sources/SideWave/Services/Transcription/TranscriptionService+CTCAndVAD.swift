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
    // MARK: - CTC Vocabulary Boosting Setup

    /// Initialize CTC vocabulary rescoring components in the background.
    /// Uses CtcKeywordSpotter + VocabularyRescorer as a post-transcription step.
    /// Non-fatal: recording works fine without boosting.
    func startBoostSetup(models: AsrModels) {
        let box = TaskBox<Void, Never>()
        let task = Task { [weak self] in
            guard let self, self.isRecording else { return }

            // Check vocabulary first before expensive model operations
            let vocabTerms = CustomDictionary.buildVocabularyTerms()
            let hasActiveVocabulary = !VocabularyStore.shared.activeEntries().isEmpty
            guard !vocabTerms.isEmpty else {
                if hasActiveVocabulary {
                    self.ctcBoostStatus = .noValidTerms
                    print("[TranscriptionService] Vocabulary has active entries but none passed length filter, CTC boosting skipped")
                } else {
                    self.ctcBoostStatus = .noDictionary
                    print("[TranscriptionService] No vocabulary terms configured, CTC boosting skipped")
                }
                if self.boostSetupTask == box.task {
                    self.boostSetupTask = nil
                }
                return
            }

            self.ctcBoostStatus = .loading

            do {
                // Shared CtcVocabBooster owns the CTC model download + tokenize
                // + spotter/rescorer construction. It downloads ~200MB on first
                // run and returns nil when no term survives CTC tokenization.
                let booster = try await CtcVocabBooster.make(vocabularyTerms: vocabTerms)

                // Recording may have stopped during the download/build. Bail
                // before touching status so the stale status stays .loading,
                // matching the pre-refactor mid-setup cancellation behavior.
                guard self.isRecording else {
                    if self.boostSetupTask == box.task {
                        self.boostSetupTask = nil
                    }
                    return
                }

                guard let booster else {
                    self.ctcBoostStatus = .noValidTerms
                    print("[TranscriptionService] No vocabulary terms survived CTC tokenization")
                    if self.boostSetupTask == box.task {
                        self.boostSetupTask = nil
                    }
                    return
                }

                // Store the booster for use during finalization
                self.ctcBooster = booster
                self.isCtcBoosterReady = true
                self.ctcBoostStatus = .ready
                print("[TranscriptionService] CTC vocabulary boosting ready with \(booster.termCount) terms")
            } catch {
                self.ctcBoostStatus = .failed(error.localizedDescription)
                print("[TranscriptionService] CTC vocabulary boosting setup failed: \(error.localizedDescription)")
            }
            if self.boostSetupTask == box.task {
                self.boostSetupTask = nil
            }
        }
        box.task = task
        boostSetupTask = task
    }

    // MARK: - CTC Vocabulary Rescoring

    /// Apply CTC vocabulary rescoring to a transcription result.
    /// Returns the original text unmodified if rescoring is unavailable or finds no replacements.
    func applyCtcRescoring(result: ASRResult, audioSamples: [Float]) async -> String {
        guard let booster = ctcBooster,
              let tokenTimings = result.tokenTimings,
              !tokenTimings.isEmpty
        else {
            return result.text
        }

        do {
            let outcome = try await booster.rescore(
                transcript: result.text,
                tokenTimings: tokenTimings,
                audioSamples: audioSamples
            )
            if outcome.wasModified {
                print("[TranscriptionService] CTC rescoring applied \(outcome.replacementCount) replacement(s)")
                ctcBoostsApplied += outcome.replacementCount
                return outcome.text
            }
            return result.text
        } catch {
            print("[TranscriptionService] CTC rescoring failed: \(error.localizedDescription)")
            return result.text
        }
    }

    // MARK: - VAD Smart Segment Boundaries Setup

    /// Initialize VadManager for speech-pause-based segment finalization.
    /// Runs on .cpuOnly to avoid ANE contention with TDT.
    /// Non-fatal: recording falls back to fixed 14.8s segments without VAD.
    func startVadSetup() {
        let box = TaskBox<Void, Never>()
        let task = Task { [weak self] in
            guard let self, self.isRecording else { return }

            do {
                let vad = try await VadManager(config: VadConfig(
                    defaultThreshold: 0.75,
                    computeUnits: .cpuOnly
                ))
                guard !Task.isCancelled, self.isRecording else {
                    if self.vadSetupTask == box.task {
                        self.vadSetupTask = nil
                    }
                    return
                }
                self.vadManager = vad
                let streamState = await vad.makeStreamState()
                guard !Task.isCancelled, self.isRecording else {
                    if self.vadSetupTask == box.task {
                        self.vadSetupTask = nil
                    }
                    return
                }
                self.vadStreamState = streamState
                self.vadAccumulationBuffer = []
                self.vadTotalSamplesProcessed = 0
                self.lastSpeechEndSampleIndex = nil
                self.isVadReady = true
                print("[TranscriptionService] VadManager ready for smart segment boundaries")
            } catch {
                print("[TranscriptionService] VAD setup failed (non-fatal): \(error.localizedDescription)")
            }
            if self.vadSetupTask == box.task {
                self.vadSetupTask = nil
            }
        }
        box.task = task
        vadSetupTask = task
    }

    /// Feed new audio samples to VadManager and detect speech end events.
    /// Called from the polling loop before the segment finalization check.
    func processVadChunks() async {
        guard let vadManager = self.vadManager, var state = self.vadStreamState else { return }

        // Calculate how many new samples have arrived since last VAD processing
        let currentTotalSamples = totalDroppedSamples + audioBuffers.sampleCount()
        let newSampleCount = currentTotalSamples - vadTotalSamplesProcessed
        guard newSampleCount > 0 else { return }

        // Figure out where in the buffer the new samples start
        let bufferOffset = vadTotalSamplesProcessed - totalDroppedSamples
        guard bufferOffset >= 0 else {
            // VAD fell behind buffer drops (finalization happened). Reset tracking.
            vadTotalSamplesProcessed = totalDroppedSamples
            vadAccumulationBuffer = []
            return
        }

        let startIdx = max(0, bufferOffset)
        let bufferCount = audioBuffers.sampleCount()
        guard startIdx < bufferCount else { return }

        let sliceCount = bufferCount - startIdx
        let newSamples = audioBuffers.sampleRange(from: startIdx, count: sliceCount)
        vadAccumulationBuffer.append(contentsOf: newSamples)
        vadTotalSamplesProcessed = currentTotalSamples

        // Cap accumulation buffer to prevent unbounded growth. `removeFirst(n)`
        // does an in-place memmove and preserves backing storage, avoiding
        // a full-buffer allocation + copy every cap hit.
        if vadAccumulationBuffer.count > Self.maxVadAccumulationSamples {
            let excess = vadAccumulationBuffer.count - Self.maxVadAccumulationSamples
            vadAccumulationBuffer.removeFirst(excess)
        }

        // Process complete 4096-sample chunks through the streaming VAD.
        // Track consumed offset and slice once at the end to avoid repeated O(n) removeFirst calls.
        let chunkSize = Self.vadChunkSize
        var vadConsumed = 0
        // Reuse one chunk buffer instead of copying a new 4096-sample array per chunk.
        var reusableChunk = [Float](repeating: 0, count: chunkSize)
        while (vadAccumulationBuffer.count - vadConsumed) >= chunkSize {
            vadAccumulationBuffer.withUnsafeBufferPointer { src in
                reusableChunk.withUnsafeMutableBufferPointer { dst in
                    let srcStart = src.baseAddress! + vadConsumed
                    let dstStart = dst.baseAddress!
                    dstStart.update(from: srcStart, count: chunkSize)
                }
            }
            let chunk = reusableChunk
            vadConsumed += chunkSize

            do {
                // Multi-stage waits for 5 s of silence so ordinary thinking pauses don't finalize a
                // segment and reset the live tail. The single-stage path keeps 3 s. The refine
                // cadence setting offers faster options.
                let silenceDuration: Double = {
                    let templateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
                    let isSpecialty = ["emailReady", "instructions", "aiPrompt", "custom"].contains(templateRaw)
                    if isSpecialty {
                        return 5.0
                    } else {
                        switch UserDefaults.standard.string(forKey: "refineCadence") {
                        case "aggressive": return 2.0
                        default:           return 3.0
                        }
                    }
                }()
                let segConfig = VadSegmentationConfig(
                    minSpeechDuration: 0.25,
                    minSilenceDuration: silenceDuration,
                    maxSpeechDuration: 14.0,
                    speechPadding: 0.1
                )
                let result = try await vadManager.processStreamingChunk(
                    chunk, state: state, config: segConfig
                )
                state = result.state
                self.vadStreamState = state
                consecutiveVadErrors = 0
                // Total-space position of the audio this chunk ended at
                // (same derivation as the speech-end stamp below).
                let chunkFrontier = currentTotalSamples - (vadAccumulationBuffer.count - vadConsumed)
                vadConsumedFrontierSampleIndex = chunkFrontier
                if state.triggered {
                    lastVadSpeechSampleIndex = chunkFrontier
                    if !vadSawSpeechThisSession {
                        vadSawSpeechThisSession = true
                        dictationTraceLog.notice("vad first speech this session")
                    }
                }

                if let event = result.event, event.kind == .speechEnd {
                    // Absolute sample index where speech ended: everything not yet consumed comes
                    // after it.
                    let remaining = vadAccumulationBuffer.count - vadConsumed
                    self.lastSpeechEndSampleIndex = currentTotalSamples - remaining
                    let endSec = Double(self.lastSpeechEndSampleIndex ?? 0) / 16_000.0
                    dictationTraceLog.notice("vad speech-end sample=\(self.lastSpeechEndSampleIndex ?? 0, privacy: .public) t=\(endSec, format: .fixed(precision: 2), privacy: .public)s")

                    // Direct mode: VAD speech end is the boundary, since TDT segments aren't used.
                    // Commit EOU text since the last boundary and optionally refine it.
                    if directEouRefineActive {
                        commitEouSegmentForDirectMode()
                    }
                }
            } catch {
                print("[TranscriptionService] VAD chunk error (non-fatal): \(error.localizedDescription)")
                consecutiveVadErrors += 1
                if consecutiveVadErrors >= Self.maxVadErrors {
                    print("[TranscriptionService] VAD disabled after \(consecutiveVadErrors) consecutive errors")
                    self.vadManager = nil
                    self.vadStreamState = nil
                    self.vadAccumulationBuffer = []
                    vadConsumed = 0 // buffer already cleared
                }
                break
            }
        }

        // Remove consumed chunks in place; `removeFirst(n)` keeps the storage.
        if vadConsumed > 0 && !vadAccumulationBuffer.isEmpty {
            vadAccumulationBuffer.removeFirst(vadConsumed)
        }
    }
}
