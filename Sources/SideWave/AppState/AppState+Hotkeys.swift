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
    // MARK: - Recording Stats

    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    func resetRecordingStats() {
        recordingStartTime = nil
        // All other stats (confidence, segments, fillers, etc.) live on TranscriptionService
        // and are reset by TranscriptionService.resetState() during session teardown.
    }

    // MARK: - Hotkey Callbacks

    func setupHotkeyCallbacks() {
        hotkeyManager.onStartRecording = { [weak self] in
            Task { @MainActor in
                self?.handleStartRecording()
            }
        }

        hotkeyManager.onStopRecording = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // A push-to-talk release with "Always refine" on: send the capture through Refine
                // instead of pasting it raw, then clear the flag for the next session.
                if self.hotkeyManager.isSmartPTTActive && self.smartPTTAlwaysRefine && self.dictationCleanupEnabled {
                    await self.handleStopRefinedRecording(holdGesture: false)
                } else {
                    await self.handleStopRecording()
                }
            }
        }

        hotkeyManager.onStopRefinedRecording = { [weak self] in
            Task { @MainActor in
                await self?.handleStopRefinedRecording()
            }
        }

        hotkeyManager.onCancelRecording = { [weak self] in
            Task { @MainActor in
                await self?.handleCancelRecording()
            }
        }

        hotkeyManager.onSoftStop = { [weak self] in
            Task { @MainActor in
                await self?.handleSoftStop()
            }
        }

        hotkeyManager.onRepaste = { [weak self] in
            Task { @MainActor in
                self?.handleRepaste()
            }
        }

        hotkeyManager.onCombinationCancel = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Return pressed while holding the hotkey (for example Option-Return for a new line
                // in Terminal). Cancel the recording without saving it, with a short toast.
                await self.handleCancelRecording()
                self.showToast("Dictation cancelled. Return passed through", icon: "return")
            }
        }
    }

    func loadHotkeySettings() {
        // Load saved shortcut
        if let data = UserDefaults.standard.data(forKey: "hotkeyShortcut"),
           let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
        {
            hotkeyManager.updateShortcut(shortcut)
        }

        // Load activation mode
        let mode = ActivationMode(rawValue: storedActivationMode) ?? .toggle
        hotkeyManager.updateActivationMode(mode)
    }

    func saveShortcut(_ shortcut: HotkeyShortcut) {
        hotkeyManager.updateShortcut(shortcut)
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "hotkeyShortcut")
        }
    }



    // MARK: - Window Target Assignment

    // Cached running apps list with 2-second TTL to avoid blocking Menu builders
    private static var _cachedApps: [RunningAppInfo] = []
    private static var _cachedAppsTime: Date = .distantPast

    /// Returns currently running GUI apps, excluding SideWave itself.
    /// Results are cached for 2 seconds to prevent blocking during rapid SwiftUI re-renders.
    static func runningApps() -> [RunningAppInfo] {
        let now = Date()
        if now.timeIntervalSince(_cachedAppsTime) < 2.0 && !_cachedApps.isEmpty {
            return _cachedApps
        }
        let selfBundleID = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && !app.isTerminated
                    && app.bundleIdentifier != selfBundleID
            }
        let mapped: [RunningAppInfo] = apps.compactMap { app in
            guard let name = app.localizedName else { return nil }
            return RunningAppInfo(pid: app.processIdentifier, name: name, icon: app.icon)
        }
        let result = mapped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        _cachedApps = result
        _cachedAppsTime = now
        return result
    }

    /// Assign a specific app as the permanent paste target.
    func assignTarget(pid: pid_t, name: String) {
        assignedAppPID = pid
        assignedAppName = name
        assignedWindowID = nil
        assignedWindowTitle = nil
        borderOverlay.detach()
    }

    /// Sets one window of an app as the paste target, and fingerprints the focused field so it can
    /// be found at paste.
    func assignWindow(_ window: WindowInfo) {
        assignedAppPID = window.pid
        assignedAppName = window.appName
        assignedWindowID = window.windowID
        assignedWindowTitle = window.title
        assignedFieldFingerprint = WindowTargetingService.captureFocusedFieldFingerprint(
            pid: window.pid,
            windowID: window.windowID
        )
        borderOverlay.attach(to: window.windowID, pid: window.pid)
    }

    /// Clear the assigned target (reverts to focused-window behavior even in assigned mode).
    func clearAssignedTarget() {
        assignedAppPID = nil
        assignedAppName = nil
        assignedWindowID = nil
        assignedWindowTitle = nil
        assignedFieldFingerprint = nil
        borderOverlay.detach()
    }

    /// Toggle between focused-window and assigned-window paste target modes.
    func toggleTargetMode() {
        let current = DictationTargetMode(rawValue: dictationTargetMode) ?? .focusedWindow
        switch current {
        case .focusedWindow:
            dictationTargetMode = DictationTargetMode.assignedWindow.rawValue
        case .assignedWindow:
            dictationTargetMode = DictationTargetMode.focusedWindow.rawValue
        }
    }

    /// Validate that the assigned app/window is still running. If it quit or window closed, clear.
    func validateAssignedTarget() {
        guard let pid = assignedAppPID else { return }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            clearAssignedTarget()
            return
        }
        // If a specific window was assigned, check if it's still on screen
        if let wid = assignedWindowID, !WindowTargetingService.isWindowOnScreen(wid) {
            assignedWindowID = nil
            assignedWindowTitle = nil
            borderOverlay.detach()
        }
    }
}
