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
    // MARK: - Session Persistence

    func setupSessionPersistence() {
        let sessionsDir = AppPaths.applicationSupportDirectory().appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsDir.path)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        sessionID = "session_\(formatter.string(from: Date()))_\(UUID().uuidString)"
        sessionDirectory = sessionsDir
    }

    /// One encoder for every segment write.
    private static let segmentEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Writes segment data on a background queue.
    func persistSegment(_ segment: FrozenSegment) {
        guard let dir = sessionDirectory, let id = sessionID else { return }
        let fileURL = dir.appendingPathComponent("\(id).jsonl")

        // Encode on current thread (fast), write on background queue (could be slow)
        guard let data = try? Self.segmentEncoder.encode(segment),
              let encoded = String(data: data, encoding: .utf8)
        else { return }
        // `let` (not `var`): the closure below only reads it. A captured
        // `var` tripped a false-positive concurrency warning even though the
        // value is fully formed before the async closure is created.
        let line = encoded + "\n"

        persistQueue.async {
            do {
                let existed = FileManager.default.fileExists(atPath: fileURL.path)
                if !existed {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } catch {
                print("[TranscriptionService] Failed to persist segment: \(error)")
            }
        }
    }

    /// Drop recovery journals only after their history entry has reached disk.
    func acknowledgeSavedSession() {
        let files = completedRecoveryFiles
        completedRecoveryFiles.removeAll()
        persistQueue.async {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    func cleanupSessionFile() {
        guard let dir = sessionDirectory, let id = sessionID else { return }
        let files = ["jsonl", "volatile", "volatile.tmp"].map { dir.appendingPathComponent("\(id).\($0)") }
        persistQueue.async {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Saves the active segment's text to a sidecar so a crash mid-segment loses nothing. Throttled
    /// by the polling loop; removed when the segment is finalized and when the session ends
    /// cleanly.
    private func persistVolatileSnapshot(_ text: String) {
        guard let dir = sessionDirectory, let id = sessionID else { return }
        let fileURL = dir.appendingPathComponent("\(id).volatile")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        persistQueue.async {
            do {
                try Self.writeRecoverySnapshot(trimmed, to: fileURL)
            } catch {
                print("[TranscriptionService] Could not save the recovery snapshot")
            }
        }
    }

    nonisolated static func writeRecoverySnapshot(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes the sidecar, keeping the .jsonl. Called after a segment is saved there.
    func cleanupVolatileSidecar() {
        guard let dir = sessionDirectory, let id = sessionID else { return }
        let fileURL = dir.appendingPathComponent("\(id).volatile")
        let tmpURL = dir.appendingPathComponent("\(id).volatile.tmp")
        persistQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    private static let volatilePersistInterval: TimeInterval = 1.5

    /// Writes the sidecar at most once per `volatilePersistInterval`.
    func maybeWriteVolatileSnapshot(_ text: String) {
        let now = Date()
        if now.timeIntervalSince(lastVolatilePersistTime) >= Self.volatilePersistInterval {
            lastVolatilePersistTime = now
            persistVolatileSnapshot(text)
        }
    }

    private static let liveCtcBoostInterval: TimeInterval = 1.5

    /// Whether enough time has passed for another live CTC boost.
    func shouldRunLiveCtcBoost() -> Bool {
        Date().timeIntervalSince(lastLiveCtcBoostTime) >= Self.liveCtcBoostInterval
    }

    // MARK: - Recording State Cleanup

    func cleanupRecordingState() {
        sessionAudioCapture?.close()
        sessionAudioCapture = nil
        confirmedText = ""
        volatileText = ""
        lastVolatileSnapshot = ""
        cachedFrozenText = ""
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
        vadManager = nil
        vadStreamState = nil
        vadAccumulationBuffer = []
        vadTotalSamplesProcessed = 0
        lastSpeechEndSampleIndex = nil
        consecutiveVadErrors = 0
        audioBuffers.clearSamples()
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
        if let directory = sessionDirectory, let id = sessionID {
            completedRecoveryFiles += ["jsonl", "volatile", "volatile.tmp"].map {
                directory.appendingPathComponent("\(id).\($0)")
            }
        }
        sessionID = nil
        sessionDirectory = nil
    }

    // MARK: - Audio Health Check

    func startAudioHealthCheck() {
        let bufs = audioBuffers
        healthCheckTask = Task { [weak self] in
            // Initial delay before first check
            try? await Task.sleep(nanoseconds: 6_000_000_000)

            while !Task.isCancelled {
                guard let self, self.isRecording else { return }

                let lastEpoch = bufs.lastBufferTime
                if lastEpoch > 0 {
                    let elapsed = Date().timeIntervalSince1970 - lastEpoch
                    if elapsed > 5 {
                        print("[TranscriptionService] WARNING: No audio buffers received in \(Int(elapsed))s")
                        if !self.hasAttemptedRecovery {
                            await self.attemptAudioRecovery()
                        } else {
                            self.teardownEngine(destroyEngine: true)
                            _ = await self.stopRecording()
                            return
                        }
                    }
                }

                // Check every 5 seconds
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Rebuild a failed input using the bounded setup path shared with session start.
    private func attemptAudioRecovery() async {
        guard isRecording, !hasAttemptedRecovery else { return }
        hasAttemptedRecovery = true
        let recoveringSession = sessionGeneration
        teardownEngine(destroyEngine: true)
        do {
            try await setupAudioEngine(deviceUID: nil)
            guard sessionGeneration == recoveringSession, isRecording, !Task.isCancelled else { return }
            audioBuffers.lastBufferTime = Date().timeIntervalSince1970
            await eouAsr?.reset()
            guard sessionGeneration == recoveringSession, isRecording, !Task.isCancelled else { return }
            eouPartialAccumulated = ""
            lastCommittedEouWordCount = 0
            stagedTranscript.resetEouAlignment()
        } catch {
            guard sessionGeneration == recoveringSession, isRecording, !Task.isCancelled else { return }
            teardownEngine(destroyEngine: true)
            _ = await stopRecording()
        }
    }

    // MARK: - Microphone Permission

    func requestMicPermission() async -> Bool {
        // Use AVAudioApplication (from AVFAudio) instead of AVCaptureDevice (from AVFoundation).
        // AVCaptureDevice.requestAccess triggers TCC media library enumeration on Sequoia,
        // causing spurious prompts for Apple Music, Google Drive, OneDrive, etc.
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            return true
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        default:
            return false
        }
    }
}
