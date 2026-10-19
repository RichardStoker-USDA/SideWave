// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
@preconcurrency import AVFAudio
import FluidAudio
import Foundation

@MainActor
extension MeetingTranscriptionService {
    // MARK: - Recording

    func startRecording(deviceUID: String? = nil) async throws {
        guard case .idle = state, !isStartingRecording else { throw MeetingError.busy }
        guard !MicTestController.isCapturing, AVAudioApplication.shared.recordPermission == .granted else {
            throw MeetingError.microphoneUnavailable
        }
        isStartingRecording = true
        defer { isStartingRecording = false }
        let newSession = try MeetingSessionStore.createSession(
            deviceUID: deviceUID, expectedSpeakers: expectedSpeakers)
        try await beginRecording(into: newSession, deviceUID: deviceUID, resumedDuration: 0, isResume: false)
    }

    /// Resume an orphaned meeting: reopen its directory, start a new audio part,
    /// and continue recording. Prior parts + live journal are preserved.
    func resumeRecording(orphan: OrphanedMeeting) async throws {
        guard case .idle = state, !isStartingRecording else { throw MeetingError.busy }
        guard !MicTestController.isCapturing, AVAudioApplication.shared.recordPermission == .granted else {
            throw MeetingError.microphoneUnavailable
        }
        isStartingRecording = true
        defer { isStartingRecording = false }
        let reopened = try MeetingSessionStore.openSession(orphan)
        reopened.setStatus(.recording)
        try await beginRecording(
            into: reopened, deviceUID: reopened.deviceUID,
            resumedDuration: orphan.recordedDuration, isResume: true)
    }

    private func beginRecording(
        into newSession: MeetingSession, deviceUID: String?,
        resumedDuration: TimeInterval, isResume: Bool
    ) async throws {
        postRecordingWarning = nil
        transcript = nil
        liveSegments = []
        // Names re-derive at commit; a resumed OR fresh meeting must not inherit
        // the previous meeting's speaker renames.
        speakerNames = [:]
        session = newSession
        // The timer continues the meeting's running total from prior parts.
        priorPartsDuration = resumedDuration
        recordingDuration = resumedDuration

        // Declared before the setup do/catch so the level-poll task (started on
        // the success path below) can read it.
        let levelStore = MeetingLevelStore()

        do {
        let fileURL = try newSession.beginPart()
        self.audioFileURL = fileURL

        let liveWanted = HardwareDetector.physicalMemoryGB() >= 16 && MeetingEngine.liveASRModelPresent()
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let liveCont = liveWanted ? continuation : nil
        let prepared = try await AudioSetupOperation<MeetingCapture>.run(timeout: 8) { operation in
            try MeetingCapture.prepare(fileURL: fileURL, deviceUID: deviceUID, levelStore: levelStore,
                                     liveContinuation: liveCont, operation: operation)
        } dispose: { $0.close(waitForHAL: true) }
        capture = prepared
        try Task.checkCancellation()
        audioWriter = prepared.writer
        audioDiagnostics = prepared.diagnostics
        recordingSampleRate = prepared.sampleRate
        liveTranscriptAvailable = liveWanted
        liveWasActive = liveWanted
        if liveWanted {
            liveContinuation = continuation
            startLivePipeline(stream: stream, session: newSession)
        } else {
            continuation.finish()
        }
        } catch {
            // A timed-out HAL worker owns its own cleanup. Never touch its
            // inputNode from the main actor while that worker is still blocked.
            if let failedCapture = capture {
                DispatchQueue.global(qos: .userInitiated).async { failedCapture.close() }
            }
            capture = nil
            audioWriter = nil
            audioDiagnostics = nil
            liveContinuation?.finish()
            liveContinuation = nil
            liveConsumerTask?.cancel(); liveConsumerTask = nil
            liveDrainTask?.cancel(); liveDrainTask = nil
            await engine.abandonLive()
            if isResume {
                // Prior parts are the user's kept audio; keep them recoverable.
                newSession.setStatus(.stopped)
            } else {
                // Fresh session captured nothing; drop the empty directory.
                newSession.finalizeAndDelete()
            }
            session = nil
            audioFileURL = nil
            throw error
        }

        recordingStartTime = Date()
        state = .recording(duration: recordingDuration)

        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, let start = self.recordingStartTime else { break }
                if (self.audioWriter?.failedWriteCount ?? 0) > 0 {
                    self.stopRecording()
                    self.state = .error("Recording stopped because audio could not be saved. Your recorded audio is kept for recovery. Free disk space, then resume or process this meeting.")
                    break
                }
                // Continue the running total from earlier parts of a resumed
                // meeting; a fresh meeting has priorPartsDuration == 0.
                let partElapsed = Date().timeIntervalSince(start)
                self.recordingDuration = self.priorPartsDuration + partElapsed
                self.state = .recording(duration: self.recordingDuration)
            }
        }

        levelPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { break }
                let newLevel = levelStore.level
                if abs(self.audioLevel - newLevel) >= 0.001 {
                    self.audioLevel = newLevel
                }
            }
        }

        // Heartbeat: rewrite the manifest every 10s so a crash leaves a fresh
        // "recording" timestamp for the recovery scan.
        heartbeatTask = Task.detached(priority: .utility) { [weak newSession, weak writer = audioWriter] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { break }
                writer?.checkpoint()
                newSession?.heartbeat()
            }
        }
    }

    private func startLivePipeline(stream: AsyncStream<MeetingAudioChunk>, session: MeetingSession) {
        let engine = self.engine
        liveConsumerTask = Task { [weak self] in
            do {
                try await engine.beginLive(session: session)
            } catch {
                // Live off; recording continues on the CAF, batch at stop.
                // Finish the continuation so the tap's per-buffer copy+yield
                // becomes a no-op for the rest of the meeting.
                await MainActor.run { [weak self] in
                    self?.liveWasActive = false
                    self?.liveTranscriptAvailable = false
                    self?.liveContinuation?.finish()
                    self?.liveContinuation = nil
                }
                return
            }
            for await chunk in stream {
                await engine.ingestLive(chunk.samples, sampleRate: chunk.sampleRate)
            }
        }
        liveDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                let segments = await engine.drainLive()
                if !segments.isEmpty {
                    await MainActor.run { [weak self] in self?.liveSegments = segments }
                }
            }
        }
    }

    func stopRecording() {
        durationTimer?.cancel(); durationTimer = nil
        levelPollTask?.cancel(); levelPollTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil

        capture?.close()
        capture = nil

        // Stop feeding the live pipeline; finalizing happens in processRecording.
        liveContinuation?.finish(); liveContinuation = nil
        liveDrainTask?.cancel(); liveDrainTask = nil
        liveConsumerTask?.cancel(); liveConsumerTask = nil

        audioWriter?.close()
        let writeFailures = audioWriter?.failedWriteCount ?? 0
        let capturedDuration = audioWriter?.recordedDuration ?? 0
        audioWriter = nil

        // Record the finalized part's OWN elapsed time (not the meeting's running
        // total, which includes prior parts of a resumed session) so recovery
        // sums part durations correctly.
        session?.finishCurrentPart(
            duration: capturedDuration, sampleRate: recordingSampleRate)
        session?.setStatus(.stopped)

        if let diag = audioDiagnostics {
            let report = diag.evaluate()
            if writeFailures > 0 {
                postRecordingWarning = "Some audio couldn't be saved to disk (\(writeFailures) buffer\(writeFailures == 1 ? "" : "s") lost). The transcript may be incomplete. Check that you have free disk space."
            } else if report.clippingFraction > 0.02 {
                postRecordingWarning = "Audio was clipping. Reduce input gain."
            } else if report.quietFraction > 0.80 {
                postRecordingWarning = "Recording sounds quiet. Check microphone input before running again."
            } else if report.speechActiveFraction < 0.10 {
                postRecordingWarning = "SideWave didn't hear much speech in the recording."
            }
        } else if writeFailures > 0 {
            postRecordingWarning = "Some audio couldn't be saved to disk (\(writeFailures) buffer\(writeFailures == 1 ? "" : "s") lost). The transcript may be incomplete. Check that you have free disk space."
        }
        audioDiagnostics = nil

        SWLog.note("[MeetingTranscription] Recording stopped. Duration: \(String(format: "%.1f", recordingDuration))s")

        if case .recording = state {
            state = .idle
        }
    }
}
