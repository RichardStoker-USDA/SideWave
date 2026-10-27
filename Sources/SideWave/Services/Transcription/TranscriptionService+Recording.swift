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
    // MARK: - Recording

    func startRecording(deviceUID: String? = nil, allowStaleEngineRetry: Bool = true) async {
        guard !isRecording, !Task.isCancelled else { return }
        guard modelState.isReady else {
            SWLog.note("[TranscriptionService] Model not ready, cannot start recording")
            return
        }

        if !speechModelsPrepared {
            await warmUpModelsIfNeeded()
            guard modelState.isReady, !Task.isCancelled else { return }
        }

        // Stamp this session so the previous session's tail-end cleanup
        // (which may still be running because of refine / final transcription
        // awaits) doesn't wipe the new session's setup state.
        sessionGeneration += 1

        // Phase timestamps at notice level, so a slow start shows which phase took the time.
        let startEntryAt = CFAbsoluteTimeGetCurrent()
        dictationTraceLog.notice("startRecording entry")

        // Request mic permission if needed
        let granted = await requestMicPermission()
        dictationTraceLog.notice("startRecording permission checked elapsedMs=\((CFAbsoluteTimeGetCurrent() - startEntryAt) * 1000, format: .fixed(precision: 0), privacy: .public)")
        guard !Task.isCancelled else { return }
        guard granted else {
            SWLog.note("[TranscriptionService] Microphone permission denied")
            // Surface a modal alert with a deep-link to System Settings
            // instead of silently aborting. Otherwise the hotkey fires,
            // nothing happens, and the user has no idea why.
            AppDelegate.showMicrophoneAlert()
            return
        }

        configureSessionPipeline()
        let useDualEngine = dualEngineActive
        eouGhostSuppressionActive = UserDefaults.standard.bool(forKey: "eouGhostSuppression")
        lastCommittedEouWordCount = 0
        lastSessionOriginalText = ""
        lastSessionEouRawText = ""
        lastSessionFinalPassRuns = []
        translateRefineKeptSourceLanguage = false
        translateHeldSegmentCount = 0
        // Start the interval clock now, so the first interval finalize happens N seconds in rather
        // than on the first poll.
        lastFinalizeWallTime = CFAbsoluteTimeGetCurrent()
        eouPartialAccumulated = ""
        // Drop the live-cleanup memo so the new session never returns a
        // result computed under the prior session's filter settings.
        lastEouRawInput = nil
        lastEouProcessedOutput = ""
        // Reset stale-EOU stamp at session start so the thinking indicator
        // doesn't carry a false-positive "stale" signal from the prior
        // session's last EOU emit.
        lastEouEmitAt = nil
        // Single-line session-start log so the user can verify in Console.app
        // which experimental flags actually activated. Filter:
        // subsystem == "com.sidewave.dev" AND category == "dictation-trace"
        dictationTraceLog.notice("session start dualEngine=\(useDualEngine, privacy: .public) multiStage=\(self.multiStageActive, privacy: .public) refine=\(self.refineRealTimeActive, privacy: .public) directEouRefine=\(self.directEouRefineActive, privacy: .public)")
        currentEngineForOverlay = .undecided
        stagedTranscript.reset()
        refineQueue.removeAll()
        specialtyLiveStatus = nil

        // Set inside the do block once the engine is resolved; read by the
        // catch to decide whether a fresh-engine retry is worth one attempt.
        var engineWasReused = false

        do {
            // Reset state BEFORE the audio engine starts capturing. Otherwise
            // clearSamplesKeepCapacity() would wipe samples the tap just wrote.
            confirmedText = ""
            volatileText = ""
            lastVolatileSnapshot = ""
            cachedFrozenText = ""
            audioBuffers.lastBufferTime = Date().timeIntervalSince1970
            // Arm the speech detector before the tap goes live. Starting `lastSpeechAt` at now
            // gives the first words a trust window, and resetting here rather than in the EOU start
            // path means the model load can't erase speech the tap already classified.
            audioBuffers.resetSpeechDetector()
            vadSawSpeechThisSession = false
            lastVadSpeechSampleIndex = -1
            vadConsumedFrontierSampleIndex = 0
            hasAttemptedRecovery = false
            consecutivePollingErrors = 0
            audioBuffers.clearSamplesKeepCapacity()
            audioBuffers.reserveSamples(4_800_000) // Pre-allocate for ~5 minutes
            frozenSegments = []
            totalFrozenSegmentsCount = 0
            frozenSampleCount = 0
            totalDroppedSamples = 0
            segmentFinalizationFailures = 0
            setupSessionPersistence()
            // Raw audio capture for replay (see SessionAudioCapture). Compiled only into debug
            // builds, so a release build can never write dictation audio to disk.
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "keepSessionAudioRecordings"),
               let dir = sessionDirectory, let id = sessionID {
                sessionAudioCapture = SessionAudioCapture(
                    url: dir.appendingPathComponent("\(id).wav")
                )
            } else {
                sessionAudioCapture = nil
            }
            #else
            sessionAudioCapture = nil
            #endif
            if useDualEngine {
                streamingAudioQueue = StreamingAudioQueue()
            }

            // The audio engine starts first so capture begins right away; the recognizer load that follows
            // (100 to 350 ms) runs while the tap fills the buffer, so the first words aren't lost.
            //
            // `engine.inputNode` can block in a synchronous CoreAudio call that task cancellation can't
            // interrupt, so setup runs on a separate thread with a deadline, keeping the UI responsive.
            //
            // If a kept engine still has background work (the previous session's teardown or the launch
            // prewarm), wait for it, with a limit, before reusing the engine; a stuck one is replaced. The
            // route lease rejects new setup until the old worker finishes.
            if let pending = engineQuiesceTask {
                let finished: Void? = await Self.raceWithHardTimeout(seconds: 1.0) {
                    await pending.value
                }
                engineQuiesceTask = nil
                if finished == nil {
                    SWLog.note("[TranscriptionService] Engine quiesce timed out; abandoning kept engine for a fresh one")
                    engineStorage = nil
                }
            }
            try Task.checkCancellation()
            engineWasReused = (engineStorage as? AVAudioEngine) != nil
            try await setupAudioEngine(deviceUID: deviceUID)

            // The engine is capturing. Load the recognizer while the tap keeps buffering, typically
            // 100 to 350 ms warm.
            let version = storedModelVersion()
            let models: AsrModels
            if let cached = cachedModels, cachedModelVersion == version.rawValue {
                models = cached
            } else {
                models = try await version.loadModels()
                cachedModels = models
                cachedModelVersion = version.rawValue
                // Cold load during a session (fresh install, or warm-up didn't finish in time): run
                // the first TDT inference on silence. The tap keeps buffering meanwhile.
                try await runTdtWarmupDecode(models, context: "session-cold-load")
            }

            try Task.checkCancellation()

            // Create AsrManager for polling-based transcription (live preview + final result)
            let pollManager = AsrManager(config: ASRConfig.default)
            try await pollManager.loadModels(models)
            try Task.checkCancellation()
            pollingAsrManager = pollManager

            // The polling loop uses pollingAsrManager, now set, and waits for isRecording, set
            // below.
            startPollingLoop(pollManager: pollManager)
            // High-frequency audio level polling (~20Hz) for equalizer animation.
            // Also gated by isRecording; sleeps until the flip.
            startAudioLevelPolling()
            startLiveTailPolling()

            // Mark recording active. The polling loop wakes up, the audio level
            // task starts publishing levels, the wave visualizer animates.
            isRecording = true

            // Dual-engine path: load EOU streaming actor in parallel and start
            // its feeder Task. Polling pipeline keeps running normally; the
            // overlay-driver flag decides which engine paints UI.
            if useDualEngine {
                await startDualEngineEou()
            }
            try Task.checkCancellation()

            // Start audio health check
            startAudioHealthCheck()

            // Initialize CTC vocabulary boosting and VAD in background tasks.
            // These gate on isRecording at task entry, so must run AFTER the
            // flip above or they'd no-op silently.
            startBoostSetup(models: models)
            startVadSetup()

        } catch {
            // A reused engine can be stale in ways the bind check can't see, such as after wake or
            // a device re-enumerated under the same ID. Retry once with a new engine so the press
            // still works.
            if engineWasReused && allowStaleEngineRetry && !isRecording && !Task.isCancelled {
                SWLog.note("[TranscriptionService] Setup failed on reused engine; retrying once with a fresh engine")
                teardownEngine(destroyEngine: true)
                await startRecording(deviceUID: deviceUID, allowStaleEngineRetry: false)
                return
            }
            SWLog.note("[TranscriptionService] Failed to start recording: \(error)")
            isRecording = false
            pollingTask?.cancel()
            pollingTask = nil
            audioLevelTask?.cancel()
            audioLevelTask = nil
            liveTailPollingTask?.cancel()
            liveTailPollingTask = nil
            audioLevel = 0
            pollingAsrManager = nil
            ctcBooster = nil
            channelSelector = nil
            resampler = nil
            eouFeederTask?.cancel()
            eouFeederTask = nil
            if let queue = streamingAudioQueue {
                queue.finish()
                streamingAudioQueue = nil
            }
            if let eou = eouAsr {
                eouAsr = nil
                // Reset (not cleanup) so the cached actor stays loaded.
                let box = TaskBox<Void, Never>()
                let task = Task { [weak self] in
                    await eou.reset()
                    if let self = self, self.eouResetTask == box.task {
                        self.eouResetTask = nil
                    }
                }
                box.task = task
                eouResetTask = task
            }
            tearDownRefineWorker()
            multiStageActive = false
            refineRealTimeActive = false
            directEouRefineActive = false
            lastCommittedEouWordCount = 0
            stagedTranscript.reset()
            dualEngineActive = false
            currentEngineForOverlay = .undecided
            eouPartialAccumulated = ""
            audioBuffers.clearSamples()
            // Setup failed; never keep this engine for reuse.
            teardownEngine(destroyEngine: true)
        }
    }

    private func configureSessionPipeline() {
        let useDualEngine = UserDefaults.standard.bool(forKey: "useDualEngineSmartPTT")
        dualEngineActive = useDualEngine
        multiStageActive = useDualEngine && UserDefaults.standard.bool(forKey: "useMultiStageRendering")
        refineRealTimeActive = multiStageActive && UserDefaults.standard.bool(forKey: "useRealTimeRefine")
            && !UserDefaults.standard.bool(forKey: "skipRefine")
        directEouRefineActive = multiStageActive && UserDefaults.standard.bool(forKey: "useEouToRefineDirect")
    }

    /// Stops recording and returns the final transcript. `preferFastResult` comes from the Smart
    /// Push-to-Talk release: in a dual-engine session it returns EOU's text right away; in a
    /// polling-only session it has no effect.
    func stopRecording(preferFastResult: Bool = false) async -> String {
        guard isRecording, let pollManager = pollingAsrManager else { return "" }

        // Dual-engine routing. Both engines were running in parallel; the
        // press-mode flag chooses which transcript becomes the final result.
        if dualEngineActive, eouAsr != nil {
            // ASR-only output finishes the last TDT segment on both tap and
            // push-to-talk release. Streaming EOU can omit a short ending.
            let needsConfirmedEnding = UserDefaults.standard.bool(forKey: "skipRefine")
            return await stopRecordingDualEngine(
                pollManager: pollManager,
                preferFastResult: preferFastResult && !needsConfirmedEnding
            )
        }

        // If a new session starts while this stop waits for the final transcription, the cleanup at
        // the end is skipped so the new session's recognizer, VAD, and CTC state stay intact.
        let stoppingSession = sessionGeneration

        isRecording = false
        isPollingInProgress = false

        // Cancel all background tasks (don't await pollingTask, just cancel and move on)
        healthCheckTask?.cancel()
        pollingTask?.cancel()
        audioLevelTask?.cancel()
        liveTailPollingTask?.cancel()
        boostSetupTask?.cancel()
        vadSetupTask?.cancel()
        audioLevel = 0

        // Stop audio engine (no more samples after this)
        teardownEngine()

        // Capture state before cleanup. Use lastVolatileSnapshot rather than volatileText, which
        // finalization clears and could leave empty here.
        let currentCachedFrozenText = cachedFrozenText
        let lastKnownVolatile = lastVolatileSnapshot.isEmpty ? volatileText : lastVolatileSnapshot

        // Nil out task references
        pollingTask = nil
        audioLevelTask = nil
        healthCheckTask = nil
        boostSetupTask = nil
        vadSetupTask = nil

        // Calculate total samples and remaining active segment
        let bufferCount = audioBuffers.sampleCount()
        let totalSamples = bufferCount + totalDroppedSamples

        // If no meaningful audio at all
        guard totalSamples >= 3_200 else {
            if sessionGeneration == stoppingSession {
                cleanupRecordingState()
            }
            return ""
        }

        // Get remaining active segment audio
        let activeStart = frozenSampleCount - totalDroppedSamples
        let activeCount = bufferCount - activeStart
        let activeSamples = audioBuffers.sampleRange(from: activeStart, count: activeCount)

        let finalManager = pollManager

        // Save VAD state before cleanup. When VAD reports speech ended, token timings can strip
        // words predicted during the trailing silence.
        let vadWasSpeaking = vadStreamState?.triggered ?? true
        let speechEndSample = lastSpeechEndSampleIndex
        let capturedFrozenSampleCount = frozenSampleCount

        // Attempt final transcription of remaining segment (with timeout)
        var remainingText: String? = nil
        if activeSamples.count >= 3_200 {
            if activeSamples.count <= 240_000 {
                // Short enough for clean final transcription
                do {
                    // 15 s matches the longest segment (14.8 s) plus CTC rescoring. A hard race, not a
                    // task group, which would wait out a transcribe that ignores cancellation.
                    let raced = await Self.raceWithHardTimeout(seconds: 15) { () async -> ASRResult? in
                        // A new decoder state per call, so each transcribe starts clean.
                        guard var decoderState = try? TdtDecoderState() else { return nil }
                        return try? await finalManager.transcribe(activeSamples, decoderState: &decoderState)
                    }
                    guard let finalResult = raced ?? nil else { throw CancellationError() }

                    // Apply CTC vocabulary rescoring before phantom word filter and text processing
                    let rescoredText = await applyCtcRescoring(result: finalResult, audioSamples: activeSamples)

                    let finalText = Self.applyPhantomWordFilter(
                        text: rescoredText,
                        tokenTimings: finalResult.tokenTimings,
                        vadWasSpeaking: vadWasSpeaking,
                        speechEndSample: speechEndSample,
                        frozenSampleCount: capturedFrozenSampleCount
                    )

                    var processed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    processed = Self.removeFillerWords(processed)
                    processed = ProseOrdinalReverter.revert(TextNormalizer.shared.normalizeSentence(processed))
                    processed = Self.filterProfanity(processed)
                    processed = CustomDictionary.apply(to: processed)

                    remainingText = processed
                } catch {
                    // Timeout fallback: use last known volatile text
                    SWLog.note("[TranscriptionService] Final segment transcription failed/timed out: \(error)")
                    remainingText = lastKnownVolatile
                }
            } else {
                // Too long for single transcription, use last polling result
                remainingText = lastKnownVolatile
            }
        }

        // Assemble final text from cached frozen text + remaining active segment
        var finalText = currentCachedFrozenText
        if let remaining = remainingText,
           !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if finalText.isEmpty {
                finalText = remaining
            } else {
                finalText += " " + remaining
            }
        }
        finalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)


        // Clean up only if no new dictation started while waiting. Cleaning up now would clear the
        // new session's recognizer state and leave it recording without transcribing.
        if sessionGeneration == stoppingSession {
            cleanupRecordingState()
        }
        return finalText
    }

    /// Runs EOU's `finish()` with a hard 2 s limit, so a residual chunk is processed without ever
    /// stalling the stop. A finish that times out may still be running inside the actor and would
    /// clear or fill the next session's state when it resumes, so that actor is retired instead of
    /// reset for reuse: it leaves the cache, its callback goes nowhere, and a fresh one loads.
    private func finishEouForStop(_ eou: StreamingEouAsrManager) async {
        let finished: Void? = await Self.raceWithHardTimeout(seconds: 2) { _ = try? await eou.finish() }
        // Yield once so callbacks scheduled before `finish()` returned can update `liveEouTail`
        // before paste assembly reads it.
        await Task.yield()
        // Clearing `eouAsr` keeps cleanupRecordingState() from resetting it again.
        eouAsr = nil
        if finished != nil {
            // Reset, don't clean up, so the cached actor stays loaded; the next session waits on
            // `eouResetTask`.
            eouResetTask = Task { await eou.reset() }
        } else {
            SWLog.note("[TranscriptionService] EOU finish timed out; retiring that streaming engine")
            if cachedEouAsr === eou { cachedEouAsr = nil }
            Task { await eou.setPartialTranscriptCallback { _ in } }
            Task { [weak self] in await self?.warmUpModelsIfNeeded() }
        }
    }

    /// Transcribes a whole session's audio when the live stages produced nothing. Nil on failure
    /// or after 30 s.
    nonisolated private static func recoverTranscript(_ samples: [Float], with manager: AsrManager) async -> String? {
        let result = await raceWithHardTimeout(seconds: 30) { () async -> String? in
            guard var decoderState = try? TdtDecoderState(),
                  let recovered = try? await manager.transcribe(samples, decoderState: &decoderState) else { return nil }
            return recovered.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result ?? nil
    }

    /// Dual-engine stop. With `preferFastResult` (push-to-talk release) it returns EOU's text after
    /// a bounded `finish()`. Otherwise (toggle) it tears EOU down and continues with the standard
    /// polling stop, so vocabulary boosting and the final transcribe still run.
    private func stopRecordingDualEngine(
        pollManager: AsrManager,
        preferFastResult: Bool
    ) async -> String {
        guard isRecording else { return "" }

        let stoppingSession = sessionGeneration
        let eouActor = eouAsr
        let eouText = eouPartialAccumulated

        if preferFastResult {
            // Let refines that are about to finish land before the worker stops; the worker exits
            // as soon as recording stops. The wait is short, 0.3 to 2.5 s depending on queue depth,
            // because anything missed becomes the unrefined tail that AppState's stop pass refines.
            if multiStageActive && refineRealTimeActive {
                let queueDepth = refineQueue.count + (dictationFormatter?.state == .generating ? 1 : 0)
                // A short floor: a refine that won't finish soon falls to the tail, which the stop
                // pass refines anyway, so a longer wait only adds stop latency.
                let adaptiveBudget = min(2.5, max(0.3, 0.6 * Double(queueDepth)))
                _ = await awaitPendingRefines(timeout: adaptiveBudget)
            }

            // Smart PTT release: paste EOU's raw fast-lane text.
            isRecording = false
            isPollingInProgress = false
            healthCheckTask?.cancel()
            pollingTask?.cancel()
            audioLevelTask?.cancel()
            liveTailPollingTask?.cancel()
            boostSetupTask?.cancel()
            vadSetupTask?.cancel()
            eouFeederTask?.cancel()
            tearDownRefineWorker()
            audioLevel = 0
            teardownEngine()
            streamingAudioQueue?.finish()

            if let eou = eouActor {
                // Open the stop-drain gate so EOU's last callbacks (fired
                // during finish()) land in stagedTranscript instead of
                // being rejected by the `isRecording` guard.
                isStoppingDrain = true
                await finishEouForStop(eou)
                isStoppingDrain = false
            }

            // Multi-stage: paste `stagedTranscript.finalText()`, which joins confirmed and refined
            // spans with the EOU tail, or the EOU text if no TDT segment finished. Errors across
            // segment boundaries are already fixed by the boundary-merge refines, which rewrite the
            // last 8 words of the previous span together with the new one while 2 anchor words stay
            // fixed.

            // Always include the EOU tail for Smart PTT (fast-lane release) so that the user's
            // final spoken words are never dropped.
            let includeRawEouTail = true
            let skipRefine = UserDefaults.standard.bool(forKey: "skipRefine")

            var processed: String
            if multiStageActive {
                lastSessionOriginalText = stagedTranscript.originalText(includeRawEouTail: includeRawEouTail)
                lastSessionEouRawText = stagedTranscript.eouRawText()
                lastSessionFinalPassRuns = stagedTranscript.finalPassRuns(includeRawEouTail: includeRawEouTail)
                let staged = skipRefine
                    ? stagedTranscript.originalText(includeRawEouTail: includeRawEouTail)
                    : stagedTranscript.finalText(includeRawEouTail: includeRawEouTail)
                processed = staged.isEmpty
                    ? eouText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : staged
                
                // Bulletproof Fallback: if EOU text is empty (due to cold-load lag, whisper, or ANE failure),
                // fall back to offline transcription of the full session audio using the high-reliability ASR.
                if processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let totalSamples = audioBuffers.sampleCount()
                    if totalSamples > 16000 { // at least 1s of audio recorded
                        DictationTracingService.shared.log(.engineState, .warning, "Smart PTT release: Staged transcript is empty. Running full offline ASR recovery...")
                        let samples = audioBuffers.allSamples()
                        if let recovered = await Self.recoverTranscript(samples, with: pollManager) {
                            processed = recovered
                            DictationTracingService.shared.log(.engineState, .info, "ASR Recovery Succeeded: \"\(transcriptMetrics(processed))\"")
                        } else {
                            DictationTracingService.shared.log(.engineState, .error, "ASR Recovery failed or timed out")
                        }
                    }
                }
            } else {
                processed = eouText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !processed.isEmpty {
                    processed = Self.removeFillerWords(processed)
                    processed = Self.filterProfanity(processed)
                    processed = CustomDictionary.apply(to: processed)

                }
            }


            if sessionGeneration == stoppingSession {
                cleanupRecordingState()
            }
            return processed
        }

        // Toggle release in multi-stage: catch the trailing audio that
        // hasn't yet been TDT-finalized so the paste includes the last
        // few words the speaker said.
        if multiStageActive {
            // Cancel polling before the forced finalize and refine drain, or the polling task could
            // wake during an await, still see recording active, and finalize the same trailing
            // audio. isRecording stays true through the forced finalize because
            // finalizeCurrentSegment requires it; isPollingInProgress blocks polling until the
            // cancel takes effect.
            isPollingInProgress = true
            pollingTask?.cancel()
            pollingTask = nil

            // Finalize the trailing audio so the last words become a TDT span instead of living only in the
            // EOU tail. Pass vadTriggered: true so finalizeCurrentSegment uses activeSampleCount; with false
            // it would use the fixed segment length and corrupt frozenSampleCount.
            //
            // Skip it when a VAD finalize just ran and VAD isn't in speech: the remaining audio is the
            // silence between the pause and the stop key, and TDT tends to repeat the last word from it.
            // A stop mid-sentence still finalizes, because VAD is in speech then.
            //
            // Drain VAD first so its frontier covers the trailing audio. Otherwise the pause guard fails open
            // and a breath before the stop can come back as "Yeah."
            await drainVadWithinLimit()
            let bufferCount = audioBuffers.sampleCount()
            let activeStart = frozenSampleCount - totalDroppedSamples
            let activeCount = bufferCount - activeStart
            let nowSec = CFAbsoluteTimeGetCurrent()
            let aFinalizeHasFired = frozenSampleCount > 0
            let recentlyFinalized = aFinalizeHasFired && (nowSec - lastFinalizeWallTime) < 1.5
            let speechEndConsumed = (lastSpeechEndSampleIndex == nil)
            let vadCurrentlySpeaking = vadStreamState?.triggered ?? false
            let trailingIsPhantomSilence = vadStreamState != nil && recentlyFinalized
                                        && speechEndConsumed
                                        && !vadCurrentlySpeaking
            if activeCount >= 3200 && !trailingIsPhantomSilence {
                // A hard limit like the other stop steps. finalizeCurrentSegment drops a late
                // result itself once recording has stopped, and the EOU tail still has these words.
                let speechEnd = lastSpeechEndSampleIndex
                let finalized: Void? = await Self.raceWithHardTimeout(seconds: 15) { [weak self] in
                    await self?.finalizeCurrentSegment(vadTriggered: true, activeSampleCount: activeCount,
                                                       speechEndSample: speechEnd, isFinalStop: true)
                }
                if finalized == nil {
                    SWLog.note("[TranscriptionService] Final segment timed out; using the streaming tail")
                }
            } else if trailingIsPhantomSilence {
                dictationTraceLog.notice("stop: skip force-finalize (trailing silence after recent VAD finalize, activeCount=\(activeCount, privacy: .public))")
            }
            // Clear so a subsequent paste path doesn't re-fire phantom
            // filter on the same speech-end sample.
            lastSpeechEndSampleIndex = nil

            // No wait for refines here: AppState's stop pass refines whatever live refine hasn't
            // finished, under its own limit, so waiting would only delay the paste.

            // Teardown matches the fast (PTT) path. Tasks already nil-ed
            // for pollingTask above; nil the rest for hygiene.
            isRecording = false
            isPollingInProgress = false
            healthCheckTask?.cancel(); healthCheckTask = nil
            audioLevelTask?.cancel(); audioLevelTask = nil
            liveTailPollingTask?.cancel(); liveTailPollingTask = nil
            boostSetupTask?.cancel(); boostSetupTask = nil
            vadSetupTask?.cancel(); vadSetupTask = nil
            eouFeederTask?.cancel(); eouFeederTask = nil
            tearDownRefineWorker()
            audioLevel = 0
            teardownEngine()
            streamingAudioQueue?.finish()

            if let eou = eouActor {
                isStoppingDrain = true
                await finishEouForStop(eou)
                isStoppingDrain = false
            }

            // Always include the EOU tail for toggle stop so that any trailing spoken words
            // not captured by TDT's finalization are still pasted.
            let includeRawEouTail = true
            let skipRefine = UserDefaults.standard.bool(forKey: "skipRefine")

            lastSessionOriginalText = stagedTranscript.originalText(includeRawEouTail: includeRawEouTail)
            lastSessionEouRawText = stagedTranscript.eouRawText()
            lastSessionFinalPassRuns = stagedTranscript.finalPassRuns(includeRawEouTail: includeRawEouTail)
            let staged = skipRefine
                ? stagedTranscript.originalText(includeRawEouTail: includeRawEouTail)
                : stagedTranscript.finalText(includeRawEouTail: includeRawEouTail)
            var processed = staged.isEmpty
                ? eouText.trimmingCharacters(in: .whitespacesAndNewlines)
                : staged

            if processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let totalSamples = audioBuffers.sampleCount()
                if totalSamples > 16000 { // at least 1s of audio recorded
                    dictationTraceLog.warning("stop toggle: Staged transcript is empty. Running full offline ASR recovery...")
                    let samples = audioBuffers.allSamples()
                    if let recovered = await Self.recoverTranscript(samples, with: pollManager) {
                        processed = recovered
                    } else {
                        dictationTraceLog.error("ASR recovery failed or timed out in toggle stop")
                    }
                }
            }


            if sessionGeneration == stoppingSession {
                cleanupRecordingState()
            }
            return processed
        }

        // Legacy toggle release (no multi-stage). Drop dual-engine state
        // and recurse into the standard polling stop so vocab boost +
        // multilingual + final transcribe all run.
        if let eou = eouActor {
            eouResetTask = Task { await eou.reset() }
        }
        eouAsr = nil
        eouFeederTask?.cancel()
        eouFeederTask = nil
        tearDownRefineWorker()
        streamingAudioQueue?.finish()
        streamingAudioQueue = nil
        dualEngineActive = false
        currentEngineForOverlay = .undecided
        eouPartialAccumulated = ""
        _ = pollManager
        return await stopRecording(preferFastResult: false)
    }

    #if DEBUG
    struct RecognitionFixtureResult {
        let confirmedBeforeStop: String
        let previewBeforeStop: String
        let usesStagedPreview: Bool
        let finalText: String
    }

    func recognizeFixture(_ segments: [[Float]], preferFastResult: Bool = false) async throws -> RecognitionFixtureResult {
        precondition(AppPaths.isTestHost && ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1")
        precondition(!isRecording && UserDefaults.standard.bool(forKey: "skipRefine"))
        await warmUpModelsIfNeeded()
        guard let models = cachedModels else { throw CancellationError() }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        pollingAsrManager = manager
        sessionGeneration += 1
        configureSessionPipeline()
        currentEngineForOverlay = .tdt
        isRecording = true
        audioBuffers.resetSpeechDetector()
        if dualEngineActive { await startDualEngineEou() }
        for (index, segment) in segments.enumerated() {
            audioBuffers.appendSamples(segment)
            if let eou = eouAsr {
                for start in stride(from: 0, to: segment.count, by: 2_560) {
                    let chunk = Array(segment[start..<min(segment.count, start + 2_560)])
                    if let buffer = Self.makePCMBuffer16k(samples: chunk) {
                        _ = try await eou.process(audioBuffer: buffer)
                    }
                }
                await Task.yield()
            }
            if index < segments.count - 1 {
                await finalizeCurrentSegment(vadTriggered: true, activeSampleCount: segment.count)
            } else {
                var decoder = try TdtDecoderState()
                let partial = try await manager.transcribe(segment, decoderState: &decoder)
                volatileText = partial.text
                lastVolatileSnapshot = partial.text
            }
        }
        let committed = cachedFrozenText
        let preview = usesStagedPreview ? stagedTranscript.finalText(includeRawEouTail: true)
            : [confirmedText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
        let staged = usesStagedPreview
        let text = await stopRecording(preferFastResult: preferFastResult)
        return RecognitionFixtureResult(confirmedBeforeStop: committed, previewBeforeStop: preview,
                                        usesStagedPreview: staged, finalText: text)
    }
    #endif

    func cancelRecording(preserveRecovery: Bool = false) async {
        guard isRecording else { return }

        isRecording = false
        isPollingInProgress = false
        healthCheckTask?.cancel()
        healthCheckTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        liveTailPollingTask?.cancel()
        liveTailPollingTask = nil
        boostSetupTask?.cancel()
        boostSetupTask = nil
        vadSetupTask?.cancel()
        vadSetupTask = nil
        audioLevel = 0

        teardownEngine()
        confirmedText = ""
        volatileText = ""
        lastVolatileSnapshot = ""
        cachedFrozenText = ""
        frozenSegments = []
        totalFrozenSegmentsCount = 0
        frozenSampleCount = 0
        totalDroppedSamples = 0
        segmentFinalizationFailures = 0
        consecutivePollingErrors = 0
        // Reset dashboard stats
        currentConfidence = 0
        currentSegmentCount = 0
        currentRtfx = 0
        isVadReady = false
        isCtcBoosterReady = false
        ctcBoostStatus = .inactive
        fillerWordsRemovedCount = 0
        dictionaryReplacementsCount = 0
        vadTriggeredSegments = 0
        ctcBoostsApplied = 0
        refinesCompletedCount = 0
        vocabTermsInOutputCount = 0
        if !preserveRecovery { cleanupSessionFile() }
        sessionID = nil
        sessionDirectory = nil
        pollingAsrManager = nil
        ctcBooster = nil
        channelSelector = nil
        resampler = nil
        eouFeederTask?.cancel()
        eouFeederTask = nil
        tearDownRefineWorker()
        multiStageActive = false
        refineRealTimeActive = false
        stagedTranscript.reset()
        if let queue = streamingAudioQueue {
            queue.finish()
            streamingAudioQueue = nil
        }
        if let eou = eouAsr {
            eouAsr = nil
            // Reset (not cleanup) so the cached actor stays loaded for the
            // next session. cleanup() drops the underlying CoreML models.
            eouResetTask = Task { await eou.reset() }
        }
        dualEngineActive = false
        currentEngineForOverlay = .undecided
        eouPartialAccumulated = ""
        vadDrainEpoch += 1
        vadDrainTask = nil
        vadManager = nil
        vadStreamState = nil
        vadAccumulationBuffer = []
        vadTotalSamplesProcessed = 0
        lastSpeechEndSampleIndex = nil
        consecutiveVadErrors = 0
        audioBuffers.clearSamples()
    }
}
