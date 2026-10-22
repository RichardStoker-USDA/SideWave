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
    // MARK: - Pending Session Actions

    /// Continue dictating: start a new recording with the pending text accumulated.
    func resumePendingSession() {
        guard let pendingSessionText, !isDictationBusy else { return }
        nextDictationTarget = .document
        handleStartRecording()
        if isProcessingStart {
            accumulatedSessionText = pendingSessionText
            accumulatedSessionPass = pendingSessionPass
        }
    }

    /// Discard the pending session text.
    func discardPendingSession() {
        transcriptionService.acknowledgeSavedSession()
        pendingSessionText = nil
        pendingSessionPass = nil
        pendingSessionTimestamp = nil
        accumulatedSessionText = nil
        accumulatedSessionPass = nil
    }

    // MARK: - Re-paste

    func handleRepaste() {
        guard let lastEntry = historyStore.entries.first else {
            showToast("Nothing to re-paste", icon: "doc.questionmark")
            return
        }
        // Respect the target mode: raise and paste into the assigned window, or paste into whatever
        // has focus, as the main paste path does.
        let useAssigned = DictationTargetMode(rawValue: dictationTargetMode) == .assignedWindow
            && assignedAppPID != nil
        let targetPID: pid_t?
        // Only honor the assigned window/field in assigned mode. In focused
        // mode a stale assignment would raise + scope the field search to the
        // wrong window (same defect as the main paste path's sessionWindowID).
        let repasteWindowID: CGWindowID? = useAssigned ? assignedWindowID : nil
        let repasteFieldFP: TextFieldFingerprint? = useAssigned ? assignedFieldFingerprint : nil
        if useAssigned {
            targetPID = assignedAppPID
            if let wid = repasteWindowID, let pid = targetPID {
                if !WindowTargetingService.raiseWindow(windowID: wid, pid: pid) {
                    TypingService.activateApp(pid: pid)
                }
            } else if let pid = targetPID {
                TypingService.activateApp(pid: pid)
            }
        } else {
            targetPID = TypingService.captureSystemFocusedPID()
            if let targetPID {
                TypingService.activateApp(pid: targetPID)
            }
        }
        Task {
            if let pid = targetPID {
                // Same focus verification as the primary paste path
                var focusConfirmed = false
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if let front = NSWorkspace.shared.frontmostApplication,
                       front.processIdentifier == pid {
                        focusConfirmed = true
                        break
                    }
                }
                if !focusConfirmed {
                    TypingService.activateApp(pid: pid)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            // Re-focus the locked text field if available
            if let pid = targetPID {
                if let fp = repasteFieldFP {
                    _ = WindowTargetingService.focusFieldByFingerprint(
                        fp, pid: pid, windowID: repasteWindowID
                    )
                } else {
                    _ = WindowTargetingService.ensureTextFieldFocused(
                        pid: pid, windowID: repasteWindowID
                    )
                }
            }

            typingService.typeTextInstantly(
                lastEntry.text,
                preferredTargetPID: targetPID,
                appendTrailingSpace: appendTrailingSpace
            ) { outcome in
                Task { @MainActor in
                    if outcome.landed {
                        ToastController.shared.show(
                            message: "Re-pasted last dictation",
                            icon: "doc.on.clipboard"
                        )
                    } else {
                        // The entry is in history, so nothing is lost; tell the user the paste
                        // didn't land.
                        SoundEffectService.play(.error)
                        let msg = (outcome == .blockedSecureInput)
                            ? "Re-paste blocked: another app is holding secure keyboard input"
                            : "Re-paste failed. Text still in history"
                        ToastController.shared.show(message: msg, icon: "exclamationmark.triangle")
                    }
                }
            }
        }
    }

    // MARK: - Dictation Volume Control

    /// Saves the current volume and lowers or mutes output per the setting. Saved to UserDefaults
    /// for crash recovery. Works on Bluetooth outputs too; the volume property doesn't make modern
    /// headsets renegotiate.
    func applyDictationVolumeControl() {
        let mode = UserDefaults.standard.string(forKey: "dictationAudioControl") ?? "lower"
        guard mode != "none" else { return }

        // Protect Bluetooth output routes from codec renegotiation stalls
        guard !AudioDeviceManager.isDefaultOutputBluetooth() else { return }

        // Save current state (both in memory and to disk for crash recovery)
        savedVolume = AudioDeviceManager.systemOutputVolume()
        savedMuteState = AudioDeviceManager.isSystemOutputMuted()
        UserDefaults.standard.set(savedVolume, forKey: "sidewave_savedVolume")
        UserDefaults.standard.set(savedMuteState, forKey: "sidewave_savedWasMuted")

        switch mode {
        case "mute":
            AudioDeviceManager.setSystemOutputMuted(true)
        case "lower":
            let reduction = UserDefaults.standard.double(forKey: "dictationVolumeReduction")
            let pct = reduction > 0 ? reduction : 60.0
            if let vol = savedVolume {
                AudioDeviceManager.setSystemOutputVolume(vol * Float32(1.0 - pct / 100.0))
            }
        default:
            break
        }
    }

    /// Restore volume to pre-dictation level and clear persisted state.
    /// Instant restore, no ramp. Also skipped when output was Bluetooth
    /// (savedVolume is nil in that case, so the restore is a no-op anyway).
    func restoreDictationVolumeControl() {
        let mode = UserDefaults.standard.string(forKey: "dictationAudioControl") ?? "lower"
        guard mode != "none" else { return }
        guard savedVolume != nil || savedMuteState != nil else { return }

        // Unmute if we muted it (only if system wasn't already muted before)
        if mode == "mute", let wasMuted = savedMuteState, !wasMuted {
            AudioDeviceManager.setSystemOutputMuted(false)
        }

        // Restore saved volume
        if let vol = savedVolume {
            AudioDeviceManager.setSystemOutputVolume(vol)
        }

        savedVolume = nil
        savedMuteState = nil
        UserDefaults.standard.removeObject(forKey: "sidewave_savedVolume")
        UserDefaults.standard.removeObject(forKey: "sidewave_savedWasMuted")
    }
}
