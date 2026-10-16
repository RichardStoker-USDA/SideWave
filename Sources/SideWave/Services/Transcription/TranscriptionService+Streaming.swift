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
    // MARK: - Dual-Engine (EOU) helpers

    /// 16 kHz mono Float32 format for EOU buffers, built once instead of per tap callback.
    nonisolated private static let pcmBufferFormat16kMono: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )

    /// Optional raw audio capture (`keepSessionAudioRecordings`, default off). Writes the tap's 16
    /// kHz mono samples to a WAV beside the session's segment log, so a real dictation can be
    /// replayed through the same models when checking pipeline changes. Local only, in the 0700
    /// sessions folder.
    final class SessionAudioCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var file: AVAudioFile?
        init?(url: URL) {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false
            ), let f = try? AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            ) else { return nil }
            file = f
        }
        func append(_ samples: [Float]) {
            guard let buf = TranscriptionService.makePCMBuffer16k(samples: samples) else { return }
            lock.lock(); defer { lock.unlock() }
            try? file?.write(from: buf)
        }
        func close() {
            lock.lock(); file = nil; lock.unlock()
        }
    }

    /// Wraps 16 kHz mono samples in a buffer for the streaming actor. Returns nil for empty input
    /// or if the shared format couldn't be created. Called on the audio tap thread.
    nonisolated static func makePCMBuffer16k(samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let format = pcmBufferFormat16kMono else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    /// Give the streaming encoder a silent left context before the first
    /// microphone frame so immediate speech does not begin at a cold edge.
    nonisolated static func prepareEouSession(_ manager: StreamingEouAsrManager) async throws {
        await manager.setPartialTranscriptCallback { _ in }
        await manager.reset()
        guard let buffer = makePCMBuffer16k(samples: [Float](repeating: 0, count: 3_840)) else { return }
        _ = try await manager.process(audioBuffer: buffer)
    }

    /// Loads the Parakeet EOU streaming actor and starts the feeder task. Runs after the polling
    /// manager is up and recording has started. Uses the cached actor when warm-up already loaded
    /// one; a first cold load downloads about 120 MB and warms the Neural Engine.
    func startDualEngineEou() async {
        if streamingAudioQueue == nil {
            streamingAudioQueue = StreamingAudioQueue()
        }
        // Only the ghost-gate counters reset here. The energy detector is armed earlier in
        // startRecording, so this reset can't erase speech heard while the actor loads.
        eouSpeechBackedWordCount = 0
        ghostFreezeBeganAt = 0
        ghostFrozenWordsAtStart = 0

        // Wait for the previous session's teardown reset before touching the shared actor, so it
        // can't land mid-stream and clear this session's text.
        if let pendingReset = eouResetTask {
            eouResetTask = nil
            await pendingReset.value
        }

        let eou: StreamingEouAsrManager
        if let cached = cachedEouAsr {
            DictationTracingService.shared.log(.modelLoad, .info, "Dual-engine EOU: Reusing cached prewarmed model.")
            await cached.reset()
            eou = cached
        } else {
            DictationTracingService.shared.log(.modelLoad, .warning, "Dual-engine EOU: Cold-loading streaming models (download/compilation path)...")
            let startLoad = Date()
            let fresh = StreamingEouAsrManager(
                chunkSize: .ms160,
                eouDebounceMs: 1280
            )
            do {
                try await fresh.loadModels(to: nil, configuration: nil, progressHandler: nil)
                // Fresh install: warm-up never ran, so the next inference would be the cold one, on
                // the user's words. Run it on silence first while the overlay shows the warming
                // state.
                try await runEouWarmupDecode(fresh, context: "session-cold-load")
                let duration = Date().timeIntervalSince(startLoad) * 1000.0
                DictationTracingService.shared.log(.modelLoad, .info, "Dual-engine EOU: Cold-load and ANE prewarm completed successfully.", durationMs: duration)
            } catch {
                let duration = Date().timeIntervalSince(startLoad) * 1000.0
                DictationTracingService.shared.log(.modelLoad, .error, "Dual-engine EOU load failed: \(error.localizedDescription)", durationMs: duration)
                print("[TranscriptionService] Dual-engine EOU load failed (\(error.localizedDescription))")
                streamingAudioQueue?.finish()
                streamingAudioQueue = nil
                eouAsr = nil
                dualEngineActive = false
                // Multi-stage needs EOU as its first stage. Without EOU the live tail would stay
                // empty, so fall back to the single-stage preview.
                multiStageActive = false
                refineRealTimeActive = false
                directEouRefineActive = false
                lastCommittedEouWordCount = 0
                stagedTranscript.reset()
                return
            }
            cachedEouAsr = fresh
            eou = fresh
        }

        // The user cancelled while EOU was loading and cleanup cleared the queue. Release the
        // reference without starting the feeder; the cached actor stays loaded.
        guard streamingAudioQueue != nil, isRecording else {
            return
        }

        do { try await Self.prepareEouSession(eou) }
        catch { print("[TranscriptionService] Streaming input priming failed") }
        guard streamingAudioQueue != nil, isRecording, !Task.isCancelled else { return }
        eouAsr = eou

        // Watermark the ordering gate so only partials delivered after this
        // session starts can apply; any straggler from a prior session sits
        // below the mark and gets dropped by the seq guard below.
        lastAppliedEouPartialSeq = eouPartialSeqGen.peek()

        await eou.setPartialTranscriptCallback { [weak self] (partial: String) in
            // Stamp the partial here, in delivery order. The actor calls this closure serially; the
            // hop to the main actor is what can reorder. `eouPartialSeqGen` is nonisolated, so no
            // hop is needed.
            guard let self else { return }
            let seq = self.eouPartialSeqGen.next()
            Task(priority: .userInitiated) { @MainActor [weak self] in
                // Also accept partials during the stop drain. `isRecording` turns false before
                // `eou.finish()` delivers the last 100 to 300 ms, and those final words would
                // otherwise be lost.
                guard let self, (self.isRecording || self.isStoppingDrain) else { return }
                // Swift doesn't guarantee FIFO order for cross-actor hops at equal priority, so
                // drop anything at or below the high-water mark. The gray preview never moves back
                // to older text.
                guard seq > self.lastAppliedEouPartialSeq else {
                    dictationTraceLog.notice("eou partial drop (stale seq=\(seq, privacy: .public) applied=\(self.lastAppliedEouPartialSeq, privacy: .public))")
                    return
                }
                self.lastAppliedEouPartialSeq = seq
                let rawProcessed = self.dualEngineProcessLive(partial)
                let rawWords = wordCount(rawProcessed)

                // Ghost gate: streaming recognition produces low-confidence tokens from silence,
                // breathing, and room noise. While the mic is quiet, freeze the visible tail at the
                // last speech-backed word count. TDT runs separately and keeps its own phantom
                // filter. Downstream always receives a prefix of the EOU text, never a shorter one.
                let ghostGateOn = self.eouGhostSuppressionActive
                let processed: String
                if ghostGateOn {
                    let sinceSpeech = Date().timeIntervalSince1970 - self.audioBuffers.lastSpeechAt
                    let recentSpeech = sinceSpeech < Self.eouGhostHangoverSeconds
                    // Never freeze during the stop drain. `eou.finish()` decodes the last real
                    // speech, and the accumulator can flush words 2 to 3 s after `lastSpeechAt`,
                    // well past the 0.7 s hangover. The mic is already stopped, so nothing new can
                    // be hallucinated.
                    if recentSpeech || self.isStoppingDrain {
                        self.eouSpeechBackedWordCount = max(self.eouSpeechBackedWordCount, rawWords)
                        processed = rawProcessed
                        self.ghostFreezeBeganAt = 0
                    } else if rawWords > self.eouSpeechBackedWordCount {
                        // Text-growth release: a sustained run of new words is evidence of speech
                        // and overrides the energy check, since silence hallucinations don't keep
                        // that pace but a very quiet mic chain does. When it triggers, open the
                        // gate and keep the detector on its adaptive floor for the session.
                        let now = Date().timeIntervalSince1970
                        if self.ghostFreezeBeganAt == 0 {
                            self.ghostFreezeBeganAt = now
                            self.ghostFrozenWordsAtStart = self.eouSpeechBackedWordCount
                        }
                        if rawWords - self.ghostFrozenWordsAtStart >= 4,
                           now - self.ghostFreezeBeganAt <= 3.0 {
                            self.audioBuffers.relaxFloorForQuietChain(at: now)
                            self.eouSpeechBackedWordCount = rawWords
                            processed = rawProcessed
                            self.ghostFreezeBeganAt = 0
                            dictationTraceLog.notice("eou ghost gate: released by text growth (quiet chain), words=\(rawWords, privacy: .public)")
                        } else {
                            // Window expired without release: re-arm from the
                            // current count so a later burst can still trigger.
                            if now - self.ghostFreezeBeganAt > 3.0 {
                                self.ghostFreezeBeganAt = now
                                self.ghostFrozenWordsAtStart = rawWords
                            }
                            processed = Self.prefixWords(rawProcessed, self.eouSpeechBackedWordCount)
                            dictationTraceLog.notice("eou ghost gate: froze tail at \(self.eouSpeechBackedWordCount, privacy: .public) words (raw=\(rawWords, privacy: .public), silent=\(String(format: "%.1f", sinceSpeech), privacy: .public)s)")
                        }
                    } else {
                        // EOU shrank/revised on its own below the speech mark; let
                        // it through (the accumulator's own correction).
                        processed = rawProcessed
                        self.eouSpeechBackedWordCount = min(self.eouSpeechBackedWordCount, rawWords)
                    }
                } else {
                    processed = rawProcessed
                }

                let painted = self.currentEngineForOverlay == .eou
                // Release-visible partial cadence line (cheap: no O(n) word
                // scans) so gate/contention behavior is verifiable from
                // Console.app on production builds, not just by feel.
                dictationTraceLog.notice("eou partial seq=\(seq, privacy: .public) chars=\(processed.count, privacy: .public) painted=\(painted, privacy: .public)")
                #if DEBUG
                // Trace-only word counts, kept out of release builds.
                let prevWords = wordCount(self.eouPartialAccumulated)
                let newWords = wordCount(processed)
                let delta = newWords - prevWords
                dictationTraceLog.notice("eou partial words=\(newWords, privacy: .public) delta=\(delta, privacy: .public) painted=\(painted, privacy: .public) tail=\(transcriptMetrics(processed), privacy: .public)")
                DictationTracingService.shared.log(.engineState, .debug, "EOU Emission: words=\(newWords) (delta=\(delta)), painted=\(painted), text: \"\(transcriptMetrics(processed))\"")
                #endif

                // Stamp the wall-clock time so the overlay can derive
                // "is EOU stale right now?" via TimelineView. Polished
                // thinking-indicator gates on this.
                self.lastEouEmitAt = Date()
                // Always accumulate so a Smart PTT release stop has the
                // latest text, even when EOU isn't currently the overlay
                // driver (e.g., toggle confirmed but user is still talking).
                self.eouPartialAccumulated = processed
                if self.multiStageActive {
                    // Multi-stage path: feed the staged transcript model.
                    // The overlay's multi-stage view binds to it directly.
                    self.stagedTranscript.ingestEouPartial(processed)
                }
                // These fields update whenever EOU drives the overlay, multi-stage or not.
                // Cinematic mode and the single-stage preview read them; the multi-stage view
                // ignores them.
                if painted {
                    self.volatileText = processed
                    self.lastVolatileSnapshot = processed
                    self.maybeWriteVolatileSnapshot(processed)
                }
            }
        }

        startEouFeeder(asr: eou)
    }

    /// One feeder task forwards queued buffers to the EOU actor in order.
    private func startEouFeeder(asr: StreamingEouAsrManager) {
        guard let queue = streamingAudioQueue else { return }
        eouFeederTask = Task(priority: .userInitiated) { [weak self] in
            var consecutiveErrors = 0
            while !Task.isCancelled {
                guard let pcm = await queue.dequeue() else { return }
                do {
                    try await asr.appendAudio(pcm)
                    try await asr.processBufferedAudio()
                    consecutiveErrors = 0
                } catch {
                    consecutiveErrors += 1
                    let errMsg = error.localizedDescription
                    DictationTracingService.shared.log(.engineState, .warning, "EOU Feeder error #\(consecutiveErrors): \(errMsg)")
                    print("[TranscriptionService] EOU feeder error #\(consecutiveErrors): \(errMsg)")
                    
                    if consecutiveErrors >= 5 {
                        DictationTracingService.shared.log(.engineState, .error, "EOU Feeder reached 5 consecutive errors. Triggering actor reset.")
                        await asr.reset()

                        if let self = self {
                            await MainActor.run {
                                // The actor reset cleared FluidAudio's accumulator, so the next
                                // partial starts short. Realign the staged transcript, as audio
                                // recovery does, so that partial isn't treated as a shrink.
                                self.eouPartialAccumulated = ""
                                self.eouSpeechBackedWordCount = 0
                                self.ghostFreezeBeganAt = 0
                                self.ghostFrozenWordsAtStart = 0
                                self.stagedTranscript.resetEouAlignment()
                                if self.currentEngineForOverlay == .eou {
                                    DictationTracingService.shared.log(.engineState, .error, "ASR stream failed to stabilize. Falling back overlay driver to TDT.")
                                    self.setEngineForOverlay(.tdt)
                                }
                            }
                        }
                        consecutiveErrors = 0
                    }
                }
                guard self != nil else { return }
            }
        }
    }

    /// Cleanup for EOU partials, matching the polling path: filler removal, profanity filter, and
    /// dictionary substitutions, with the same settings.
    private func dualEngineProcessLive(_ raw: String) -> String {
        // Same input as last time (EOU repeating itself during a pause): return the cached result.
        if let lastRaw = lastEouRawInput, lastRaw == raw {
            return lastEouProcessedOutput
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastEouRawInput = raw
            lastEouProcessedOutput = ""
            return ""
        }
        var processed = Self.removeFillerWords(trimmed)
        processed = Self.filterProfanity(processed)
        processed = CustomDictionary.apply(to: processed)

        lastEouRawInput = raw
        lastEouProcessedOutput = processed
        return processed
    }
}
