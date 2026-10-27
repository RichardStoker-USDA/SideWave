// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import FluidAudio
import AVFAudio
import Foundation
import os
import Sparkle
import SwiftUI

@MainActor
extension AppState {
    /// Clean up all resources on app termination. Called via willTerminateNotification.
    /// All work here must be SYNCHRONOUS because the process exits immediately after
    /// the notification handler returns. Async Tasks won't get a chance to run.
    func shutdown() {
        guard !hasShutdown else { return }
        hasShutdown = true
        documentDrafts.flush()

        overlayController.hide(synchronous: true)

        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil

        // Stop any recording. teardownEngine() is synchronous; cancelRecording() is async and
        // wouldn't finish before exit.
        if transcriptionService.isRecording {
            transcriptionService.teardownEngineForShutdown()
            restoreDictationVolumeControl()
        }

        // Stop a meeting recording synchronously and save it as resumable. An unfinished meeting
        // stays on disk and the next launch offers to continue it; only finished sessions are
        // removed here.
        switch meetingService.state {
        case .recording:
            meetingService.stopRecording()
        case .processing:
            meetingService.cancelProcessing()
        case .complete:
            // Delete only audio with a durable full transcript. Partial or
            // unsaved results keep their session for recovery.
            meetingService.purgeAudioFile()
        default:
            // Idle with a live session means stopped but not processed, which is what "Stop & Keep"
            // produces just before quit. Keep it for recovery at next launch.
            break
        }

        // Write pending history now. Saves are batched over 0.5 s, and quit could otherwise drop
        // the last entry.
        HistoryStore.shared.flush()
    }

    func startServices() {
        guard !servicesStarted, !AppPaths.isTestHost else { return }
        servicesStarted = true
        // The quit guard (applicationShouldTerminate) needs the live meeting
        // state; AppDelegate has no other path to this instance.
        AppDelegate.appState = self
        hotkeyManager.start()
        startAccessibilityPolling()
        // Resolve the layout-derived Cmd+V keycode on the main thread now.
        // macOS 27 hard-asserts the TIS input-source APIs are main-queue;
        // first-touch from the paste queue was a SIGTRAP.
        TypingService.warmUpKeyboardLayoutCache()
        // Every Accessibility call to another app waits at most 3 s (the macOS default is 6), so an
        // app that stops answering can't hold targeting or delivery for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 3)
        // Legacy tmp-dir cleanup only; the durable session store below is
        // never touched by it.
        MeetingTranscriptionService.cleanupStaleAudioFiles()
        // Crash/quit recovery: surface interrupted meetings instead of
        // deleting them. The sheet offers continue / transcribe / discard.
        pendingMeetingRecovery = MeetingSessionStore.scanForOrphans()
        if !pendingMeetingRecovery.isEmpty {
            SWLog.note("[AppState] Found \(pendingMeetingRecovery.count) interrupted meeting(s) to recover")
        }
        // Remove settings and files left by the voice agent server in earlier versions.
        LegacyStateCleanup.run()

        // Crash recovery: restore volume if the app was killed during dictation
        if let crashVolume = UserDefaults.standard.object(forKey: "sidewave_savedVolume") as? Float {
            AudioDeviceManager.setSystemOutputVolume(crashVolume)
            if !UserDefaults.standard.bool(forKey: "sidewave_savedWasMuted") {
                AudioDeviceManager.setSystemOutputMuted(false)
            }
            UserDefaults.standard.removeObject(forKey: "sidewave_savedVolume")
            UserDefaults.standard.removeObject(forKey: "sidewave_savedWasMuted")
        }

        // Register for app termination to clean up resources
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main thread (the MainActor's executor); shutdown()
            // is MainActor-isolated and must run synchronously before terminate.
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }

        // Check Apple Intelligence again when the app becomes active, in case the user just turned
        // it on in System Settings.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dictationFormatter.refreshAFMAvailability()
            }
        }

        // Sleep/wake handling: prevent stale CoreAudio state after wake.
        // macOS reconnects audio devices asynchronously during wake, so device
        // properties cached before sleep can be invalid (CoreAudio -10877 errors).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, so assume main-actor isolation. Async tasks can't be
            // used: macOS doesn't wait for them before sleeping, so the engine, volume, and overlay
            // teardown must finish before this returns.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.transcriptionService.isRecording {
                    SWLog.note("[AppState] System sleeping during recording, tearing down synchronously")
                    self.transcriptionService.teardownEngineForShutdown()
                    self.restoreDictationVolumeControl()
                    self.hotkeyManager.isRecording = false
                }
                if case .recording = self.meetingService.state {
                    SWLog.note("[AppState] System sleeping during meeting recording, stopping and queuing for transcription")
                    self.meetingService.stopRecording()
                    // Process the recording instead of leaving it: the task pauses during sleep and
                    // finishes after wake, saving the transcript to meeting history.
                    self.meetingService.processRecording()
                    self.meetingStoppedBySleep = true
                }

                // Synchronously tear down the overlay panel to prevent AppKit window state anomalies on wake
                self.overlayController.hide(synchronous: true)
                self.isOverlayVisible = false
            }
        }

        // On wake, tell the user a meeting recording was interrupted by sleep and is being
        // transcribed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.meetingStoppedBySleep else { return }
                self.meetingStoppedBySleep = false
                self.showToast("Meeting recording stopped by sleep. Transcribing now", icon: "moon.zzz")
            }
        }

        // Load CoreML models now so the first dictation is fast. Skipped in tests: the Neural
        // Engine compile races the test host's exit and can crash.
        if NSClassFromString("XCTestCase") == nil {
            Task { await transcriptionService.warmUpModelsIfNeeded() }
        }

        // CoreAudio keep-alive. Reading device properties every 1.5 s keeps input devices from
        // idling, like the Sound settings level meter does, which avoids 200 to 500 ms of setup on
        // the next start. No audio is captured and no indicator appears.
        startHalKeepAliveTimer()

        // Give the transcription service the formatter for real-time segment refines. It holds a
        // weak reference; AppState owns the formatter.
        transcriptionService.dictationFormatter = dictationFormatter

        // Surface a toast when the formatter auto-unloads due to memory
        // pressure. Without this, the toggle still reads "on" but dictations
        // silently fall back to raw text until the user finds the Settings UI.
        dictationFormatter.onAutoUnloaded = { [weak self] in
            guard let self else { return }
            // Turn Refine off so later dictations don't show a second "model not ready" toast; the
            // memory-pressure toast tells the user to turn it back on.
            self.dictationCleanupEnabled = false
            self.showToast(
                "Refine paused: low memory. Re-enable in Settings.",
                icon: "memorychip"
            )
        }


        // Startup hardware memory calibration
        if ProcessInfo.processInfo.physicalMemory < 8 * 1024 * 1024 * 1024 {
            lowMemoryMode = true
            dictationCleanupEnabled = false
            UserDefaults.standard.set(false, forKey: "dictationCleanupEnabled")
            // Also force set skipRefine = true in UserDefaults
            UserDefaults.standard.set(true, forKey: "skipRefine")
            
            // Dispatch a diagnostic toast warning the user
            showToast("Refinement disabled: System has less than 8GB RAM.", icon: "exclamationmark.triangle")
        } else {
            // Load the Refine model at startup so hold to refine is always available. Settings >
            // Advanced has a switch to stop this on low-end hardware.
            let refineKilled = UserDefaults.standard.bool(forKey: "refineDisabledByUser")
            if !refineKilled && !ExperiencePreset.isRecognitionOnly() {
                dictationCleanupEnabled = true
            } else if _storedDictationCleanupEnabledAtLaunch && !ExperiencePreset.isRecognitionOnly() {
                dictationCleanupEnabled = true
            }
        }

        // Start Sparkle updater (deferred from init to avoid triggering network
        // TCC prompts before the user has finished onboarding)
        if supportsAppUpdates { try? updaterController.updater.start() }
    }

    /// Checks AXIsProcessTrusted() every 1.5 s. When granted, starts the hotkey and updates the UI.
    /// Keeps checking afterward so a revoked permission shows up too.
    private func startAccessibilityPolling() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { [weak self] in
            var consecutiveGranted = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                guard !Task.isCancelled, let self else { break }
                self.refreshMicrophonePermission()
                let granted = AXIsProcessTrusted()
                if self.isAccessibilityGranted != granted {
                    self.isAccessibilityGranted = granted
                }
                // Auto-start hotkey once permission arrives
                if granted && !self.hotkeyManager.isInitialized {
                    self.hotkeyManager.start()
                }
                // After hotkey is stable for 30 consecutive checks (~45s), slow down
                if granted && self.hotkeyManager.isInitialized {
                    consecutiveGranted += 1
                    if consecutiveGranted > 30 {
                        break
                    }
                } else {
                    consecutiveGranted = 0
                }
            }
        }
    }
}
