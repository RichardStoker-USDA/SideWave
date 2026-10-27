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
        // The last entry isn't the one being finished, and two deliveries would contend for focus.
        guard !isDictationBusy else {
            showToast("Finishing the last dictation…", icon: "hourglass")
            return
        }
        guard let lastEntry = historyStore.entries.first else {
            showToast("Nothing to re-paste", icon: "doc.questionmark")
            return
        }
        // Respect the target mode, as the main paste path does: the assigned window's field, or the
        // field focused now. Only the assigned window and field count in assigned mode; in focused
        // mode a stale assignment would send the text to the wrong window.
        let assignedMode = DictationTargetMode(rawValue: dictationTargetMode) == .assignedWindow
        let unavailable = assignedMode ? checkAssignedTarget() : nil
        if let unavailable {
            showToast(unavailable + " Re-pasting into the app you're in.", icon: "arrow.uturn.backward", duration: 3.5)
        }
        let useAssigned = assignedMode && unavailable == nil && assignedAppPID != nil
        let target: DeliveryTarget?
        if useAssigned, let pid = assignedAppPID {
            // The user is in the assigned window: use that field and its selection as they are.
            if let focused = DeliveryTarget.captureFocused(), focused.pid == pid,
               assignedWindowID == nil || focused.windowID == assignedWindowID {
                target = focused
            } else {
                target = DeliveryTarget(pid: pid, appName: assignedAppName ?? TypingService.appName(for: pid),
                                        windowID: assignedWindowID, element: nil,
                                        fingerprint: assignedFieldFingerprint, selection: nil)
            }
        } else {
            target = DeliveryTarget.captureFocused()
        }
        guard let target else {
            SoundEffectService.play(.error)
            ToastController.shared.show(message: "No text field to paste into. Text still in history",
                                        icon: "exclamationmark.triangle")
            return
        }
        var options = DeliveryRouter.Options()
        options.appendTrailingSpace = appendTrailingSpace
        Task {
            let report = await deliveryRouter.deliver(lastEntry.text, to: target, options: options) {}
            if report.outcome.landed {
                ToastController.shared.show(message: "Re-pasted last dictation", icon: "doc.on.clipboard")
            } else {
                // The entry is in history, so nothing is lost; tell the user the paste didn't land.
                SoundEffectService.play(.error)
                let msg: String
                switch (report.problem, report.outcome) {
                case (.appQuit?, _): msg = "\(target.appName) quit. Text still in history"
                case (.windowClosed?, _): msg = "That window closed. Text still in history"
                case (.notInFront?, _): msg = "Couldn't bring \(target.appName) to the front. Text still in history"
                case (_, .blockedSecureInput): msg = "Re-paste blocked: another app is holding secure keyboard input"
                default: msg = "Re-paste failed. Text still in history"
                }
                ToastController.shared.show(message: msg, icon: "exclamationmark.triangle")
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
