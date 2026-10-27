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
    // MARK: - Dictation Flow

    func handleStartRecording() {
        let requestedTarget = nextDictationTarget
        nextDictationTarget = .auto
        // Hotkeys and menu actions must honor the same edit lock as the document controls.
        guard !isProcessingAgenticEdit else {
            showToast("Finish or stop the document edit before dictating", icon: "doc.text")
            return
        }
        // Prevent re-entry: if already processing a start, actively recording, or overlay showing, bail
        guard !isProcessingStart, !isProcessingStop, !transcriptionService.isRecording, !isOverlayVisible else {
            // A press during the final refine in toggle mode: show a toast instead of ignoring it.
            // Refine finishes within 8 s with status on the overlay.
            if isCleaningUp {
                // Don't queue a start here. In toggle mode the user's stop press arrives here too,
                // and a queued start would begin a session right after the stop that the next press
                // would end.
                showToast("Finishing Refine…", icon: "sparkles")
            } else if isProcessingStart {
                // A start is already running (the first run compiles the speech models). Say so, so
                // the hotkey doesn't seem broken.
                showToast("Warming up the speech engine. Starting in a moment", icon: "hourglass")
            } else if isProcessingStop {
                // The last dictation is finishing recognition or being pasted. Every step there
                // has a deadline, so say what's happening rather than ignore the press.
                showToast("Finishing the last dictation…", icon: "hourglass")
            }
            return
        }

        // Guard against concurrent meeting recording. Two AVAudioEngine
        // instances opening the same input device drops one of the streams
        // silently on USB, or forces HFP double-negotiation on Bluetooth.
        if meetingService.isCaptureActive || MicTestController.isCapturing {
            showToast("Finish the meeting or microphone test first", icon: "mic")
            return
        }

        // Check accessibility before starting -- if not granted, show alert and bail
        guard AXIsProcessTrusted() else {
            SWLog.note("[SideWave] Accessibility not granted, showing alert")
            isAccessibilityGranted = false
            AppDelegate.showAccessibilityAlert()
            return
        }

        refreshMicrophonePermission()
        guard microphonePermission == .granted else {
            requestedPage = .home
            showMainWindow = true
            showToast("Enable microphone access in SideWave to start dictating", icon: "mic.slash")
            return
        }

        guard transcriptionService.modelState.isReady else {
            // Build a highly accurate, polished, dynamic status message based on the actual model state:
            let msg: String
            switch transcriptionService.modelState {
            case .notDownloaded:
                msg = "Model not downloaded -- open SideWave to download"
                showMainWindow = true
            case .downloading(let progress):
                msg = "Model downloading: \(Int(progress * 100))%"
            case .downloadingAuxiliary(let model):
                msg = "Downloading auxiliary \(model)\u{2026}"
            case .verifying:
                msg = "Checking speech model files. Try again when setup finishes."
            case .compiling:
                msg = "Compiling model optimized for Apple Silicon\u{2026}"
            case .loading:
                msg = "Loading model into Unified Memory\u{2026}"
            case .error(let err):
                msg = "Model error: \(err)"
            case .ready:
                msg = "Ready" // fallback, should not hit this since guard checked .isReady
            }

            overlayMessage = msg
            isOverlayVisible = true

            // Auto-hide after 2 seconds. Only dismiss if the message is still the
            // same message -- prevents dismissing a legitimate recording overlay
            // if the user manages to start recording before the timer fires.
            let dismissMessage = overlayMessage
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if overlayMessage == dismissMessage {
                    isOverlayVisible = false
                    overlayMessage = ""
                }
            }
            return
        }

        guard prepareDocumentCapture(target: requestedTarget, resuming: pendingSessionText != nil) else { return }

        guard let startAttempt = captureStart.begin() else { return }
        dictationFormatter.beginDictation()
        if pendingSessionText?.isEmpty != false {
            refinementCountAtSessionStart = dictationFormatter.completedRefinementCount
        }
        accumulatedSessionText = pendingSessionText
        accumulatedSessionPass = pendingSessionPass
        if pendingSessionText == nil { accumulatedSessionNeedsRefinement = false }
        lastDictationFailure = nil
        documentEditNotice = nil
        didFinishDictation = false
        startInFlightSince = Date()
        // Belt-and-suspenders with handleStopRecording: a new session must never
        // inherit a prior stop's cancel flags (see the reset there for why they
        // can leak past the silent/command/specialty early returns).
        cancelRequestedDuringStop = false
        preserveRawOnCleanupCancel = false
        pendingSoftStopAfterStart = false
        resetRecordingStats()
        // Unlock Electron app AX trees (Teams, Slack, etc.) before capture.
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            WindowTargetingService.unlockElectronAXTree(pid: frontPID)
        }

        // Capture the system-wide focused element BEFORE the overlay steals
        // focus. This direct AXUIElement reference is the most reliable way to
        // re-find the exact field later. Fingerprint is the fallback.
        targetFocusedElement = WindowTargetingService.captureSystemFocusedElement()
        targetWindowID = nil
        targetSelection = nil

        // Determine paste target based on mode
        if dictationTargetMode == DictationTargetMode.assignedWindow.rawValue {
            let unavailable = checkAssignedTarget()
            if let unavailable {
                showToast(unavailable + " This dictation goes to the app you're in.",
                          icon: "arrow.uturn.backward", duration: 3.5)
            }
            targetAssignmentRevision = assignmentRevision
            if unavailable == nil, let pid = assignedAppPID {
                targetPID = pid
                targetAppName = assignedAppName ?? "Unknown"
                targetFieldFingerprint = assignedFieldFingerprint
                targetWindowID = assignedWindowID
                // In assigned mode, the element focused at start usually belongs to another app or
                // window. Keep it only if it's in the assigned window; otherwise it would take focus
                // away or send the text somewhere other than the assigned window.
                if let el = targetFocusedElement, Self.elementPID(el) != pid
                    || (assignedWindowID != nil && WindowTargetingService.containingWindowID(of: el) != assignedWindowID) {
                    targetFocusedElement = nil
                }
                targetSelection = targetFocusedElement.flatMap(WindowTargetingService.selectedRange(of:))
            } else {
                // Nothing chosen, or the choice can't take text now: behave like "where dictation
                // started".
                let captured = DeliveryTarget.captureFocused()
                targetPID = captured?.pid
                targetAppName = TypingService.appName(for: targetPID)
                targetFieldFingerprint = captured?.fingerprint
                targetFocusedElement = captured?.element
                targetWindowID = captured?.windowID
                targetSelection = captured?.selection
            }
        } else if pasteTargetTiming == "finish" {
            targetPID = nil
            targetAppName = "Front app when done"
            targetFieldFingerprint = nil
            // Finish mode resolves the real target at stop time, not now, so
            // the start-time focused element is stale. Drop it; the field
            // captured at stop drives delivery instead.
            targetFocusedElement = nil
        } else {
            // Where dictation started: the app, its window, the field, and the caret, so the text
            // goes back there however the user moves around before stopping.
            let captured = DeliveryTarget.captureFocused()
            targetPID = captured?.pid
            targetAppName = TypingService.appName(for: targetPID)
            targetFieldFingerprint = captured?.fingerprint
            targetFocusedElement = captured?.element
            targetWindowID = captured?.windowID
            targetSelection = captured?.selection
        }

        // Show overlay
        overlayMessage = ""

        // Set hotkey state synchronously BEFORE the async Task so the CGEvent callback
        // sees isRecording=true immediately, preventing double-tap re-entry in toggle mode.
        hotkeyManager.isRecording = true
        // Show preparation immediately in the selected output surface.
        // The paste target has already been captured before opening a document.
        let pressTemplateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
        let pressTemplate = DictationFormatterService.Template(rawValue: pressTemplateRaw) ?? .standard
        if pressTemplate.isSpecialty || isSpecialtyActive || isCommandDictation {
            openSpecialtyEditor()
            didAutoOpenSpecialtyEditor = true
        } else {
            isOverlayVisible = true
        }
        appStateTraceLog.notice("AppState.handleStartRecording: overlay shown, hotkeyManager.isRecording=true")

        // Decides whether a dual-engine press is push-to-talk or toggle (a no-op for other
        // sessions). First wait for the engine to be live, since the overlay driver can't be set
        // earlier. Then watch isSmartPTTHolding for the threshold plus 200 ms: if the user is
        // holding, use EOU; otherwise use TDT. isSmartPTTActive won't work here because it changes
        // only on release, after the deadline.
        let smartPTTThreshold = hotkeyManager.smartPTTThreshold
        Task { [weak self] in
            let engineWaitDeadline = Date().addingTimeInterval(12.0)
            var engineUp = false
            let startWaitTime = Date()
            while Date() < engineWaitDeadline {
                guard let strongSelf = self, strongSelf.captureStart.accepts(startAttempt) else { return }
                let recording = strongSelf.transcriptionService.isRecording
                let dualReady = strongSelf.transcriptionService.isDualEngineReady
                if recording && dualReady {
                    engineUp = true
                    break
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            
            let waitDuration = Date().timeIntervalSince(startWaitTime) * 1000.0
            guard engineUp,
                  let strongSelf = self,
                  strongSelf.captureStart.accepts(startAttempt),
                  strongSelf.transcriptionService.isRecording
            else {
                DictationTracingService.shared.log(.engineState, .error, "Dictation engine failed to spin up in 12s.")
                return
            }
            
            DictationTracingService.shared.log(.engineState, .info, "Dictation engine and dual-engine are ready. Startup lag: \(String(format: "%.2f", waitDuration))ms")

            let decisionDeadline = Date().addingTimeInterval(smartPTTThreshold + 0.2)
            var resolvedAsSmartPTT = false
            while Date() < decisionDeadline {
                guard let s = self, s.captureStart.accepts(startAttempt), s.transcriptionService.isRecording else { return }
                if s.hotkeyManager.isSmartPTTHolding {
                    DictationTracingService.shared.log(.engineState, .info, "Decision Task: User is holding hotkey. Directing overlay owner to EOU.")
                    s.transcriptionService.setEngineForOverlay(.eou)
                    resolvedAsSmartPTT = true
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            
            guard let s = self, s.captureStart.accepts(startAttempt), s.transcriptionService.isRecording else { return }
            if !resolvedAsSmartPTT {
                DictationTracingService.shared.log(.engineState, .info, "Decision Task: Hotkey hold not detected past threshold. Directing overlay owner to TDT (toggle).")
                s.transcriptionService.setEngineForOverlay(.tdt)
            }
        }

        // Run the Bluetooth output checks off the main thread. They can stall for hundreds of ms
        // during renegotiation, which delayed the overlay and pushed ordinary taps past the
        // push-to-talk threshold. Sound playback returns to the main actor.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let suppress = AudioDeviceManager.isDefaultOutputBluetooth()
                && AudioDeviceManager.isDefaultOutputRunning()
            guard !suppress else { return }
            Task { @MainActor [weak self] in
                guard let self, self.captureStart.accepts(startAttempt) else { return }
                SoundEffectService.playSkippingOutputCheck(.recordingStart)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.captureStart.accepts(startAttempt) else { return }
            self.applyDictationVolumeControl()
        }

        // Start recording. If it fails (mic denied, model error), revert state.
        // After start completes, check if a stop was queued during the async gap.
        let effectiveDeviceUID = resolveDictationInputUID()
        appStateTraceLog.notice("AppState.handleStartRecording: dispatched audio side-effects, kicking off engine startRecording")
        let startKickoff = CACurrentMediaTime()
        recordingStartTask = Task { @MainActor [self] in
            defer {
                captureStart.finish(startAttempt)
                recordingStartTask = nil
            }
            await transcriptionService.startRecording(deviceUID: effectiveDeviceUID)
            recordingStartTask = nil
            let startElapsed = (CACurrentMediaTime() - startKickoff) * 1000
            appStateTraceLog.notice("AppState.startRecording awaited done elapsed=\(startElapsed, format: .fixed(precision: 0), privacy: .public)ms transcriptionService.isRecording=\(self.transcriptionService.isRecording, privacy: .public) hotkeyManager.isRecording=\(self.hotkeyManager.isRecording, privacy: .public) pendingStop=\(self.pendingStopAfterStart, privacy: .public)")
            // A cancelled preparation retains ownership until its engine is down.
            if !captureStart.accepts(startAttempt) || Task.isCancelled {
                await transcriptionService.cancelRecording()
                hotkeyManager.clearEngineLive()
                restoreDictationVolumeControl()
                isOverlayVisible = false
                pendingStopAfterStart = false
                return
            }

            captureStart.finish(startAttempt)
            if !transcriptionService.isRecording {
                captureStart.cancel()
                pendingSoftStopAfterStart = false
                appStateTraceLog.notice("AppState.startRecording FAILED — engine never went live, tearing down overlay")
                // A silent vanish reads as "the app ignored me". Say what
                // happened; the retry is a fresh press.
                SoundEffectService.play(.error)
                let message = "Dictation couldn't start. Check the microphone and try again."
                recordDictationFailure(.capture(message))
                showToast(message, icon: "exclamationmark.triangle")
                hotkeyManager.isRecording = false
                hotkeyManager.clearEngineLive()
                isOverlayVisible = false
                pendingStopAfterStart = false
                restoreDictationVolumeControl()
            } else if pendingSoftStopAfterStart {
                pendingSoftStopAfterStart = false
                pendingStopAfterStart = false
                await handleSoftStop()
            } else if pendingStopAfterStart {
                // Recording started successfully but user pressed stop while start was
                // in flight. Engine is live; confirm so smart-PTT semantics work
                // for any subsequent press, then honor the deferred stop.
                hotkeyManager.confirmEngineLive()
                self.recordingStartTime = Date()
                pendingStopAfterStart = false
                await handleStopRecording()
            } else {
                // Recording started successfully: confirm engine-live with the
                // hotkey manager so the smart-PTT release threshold is anchored
                // to the moment the engine actually came up, not to key-down.
                hotkeyManager.confirmEngineLive()
                self.recordingStartTime = Date()

                // Pro USB and Thunderbolt interfaces need about 600 ms to wake their IO stream on
                // every start, which only mic standby avoids. After two slow starts in a row with
                // standby off, suggest it once.
                if startElapsed > 450, !keepMicOnStandby {
                    consecutiveSlowEngineStarts += 1
                    if consecutiveSlowEngineStarts >= 2,
                       !UserDefaults.standard.bool(forKey: "standbySuggestionShown") {
                        UserDefaults.standard.set(true, forKey: "standbySuggestionShown")
                        showToast("Your mic takes a moment to wake. Mic standby (Input & Output) makes starts instant", icon: "bolt")
                    }
                } else {
                    consecutiveSlowEngineStarts = 0
                }

                let templateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
                let template = DictationFormatterService.Template(rawValue: templateRaw) ?? .standard
                
                if self.hotkeyManager.isRecording {
                    if !template.isSpecialty && !self.isSpecialtyActive && !self.isCommandDictation {
                        self.isOverlayVisible = true
                    }
                }

                if (template.isSpecialty || self.isSpecialtyActive) && !self.isCommandDictation && !self.didAutoOpenSpecialtyEditor {
                    self.openSpecialtyEditor()
                    self.didAutoOpenSpecialtyEditor = true
                }

                // Relay mode only pastes and presses Return after dictation; the user runs their
                // own terminal session. SideWave doesn't start agent processes, which would inherit
                // its privacy permissions and cause permission prompts.
            }
        }
    }
}
