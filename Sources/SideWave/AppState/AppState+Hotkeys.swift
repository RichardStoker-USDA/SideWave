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

    /// Assign a specific app as the permanent paste target. A menu built before the app quit can
    /// still offer it; picking it then does nothing.
    func assignTarget(pid: pid_t, name: String) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        assignmentRevision += 1
        assignedAppPID = pid
        assignedAppName = name
        assignedBundleID = app.bundleIdentifier
        assignedWindowID = nil
        assignedWindowTitle = nil
        assignedWindowChosen = false
        assignedFieldFingerprint = nil
        borderOverlay.detach()
    }

    /// Sets the paste target to an app's window, and fingerprints the focused field so it can be
    /// found at paste. `chosen` is true when the user picked this window from the app's window
    /// list; otherwise they picked the app, and the target follows the app if the window closes.
    func assignWindow(_ window: WindowInfo, chosen: Bool) {
        guard WindowTargetingService.windowExists(window.windowID, pid: window.pid) else { return }
        assignmentRevision += 1
        assignedAppPID = window.pid
        assignedAppName = window.appName
        assignedBundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier
        assignedWindowID = window.windowID
        assignedWindowTitle = window.title
        assignedWindowChosen = chosen
        assignedFieldFingerprint = WindowTargetingService.captureFocusedFieldFingerprint(
            pid: window.pid,
            windowID: window.windowID
        )
        borderOverlay.attach(to: window.windowID, pid: window.pid)
    }

    /// Clear the assigned target (reverts to focused-window behavior even in assigned mode).
    func clearAssignedTarget() {
        assignmentRevision += 1
        assignedAppPID = nil
        assignedAppName = nil
        assignedBundleID = nil
        assignedWindowID = nil
        assignedWindowTitle = nil
        assignedWindowChosen = false
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

    /// Checks the chosen app or window before text is sent there. Returns why it can't go there,
    /// as a sentence for a toast, or nil when it can (or when nothing is chosen).
    ///
    /// A minimized window or one on another Space still counts; delivery brings it back. An app
    /// that quit and reopened is found again by its bundle ID. When the user picked the app and its
    /// window was replaced, the choice follows the app.
    func checkAssignedTarget() -> String? {
        guard let name = assignedAppName else { return nil }
        let alive = { (pid: pid_t) in NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false }
        if assignedAppPID.map(alive) != true, let bundleID = assignedBundleID,
           let reopened = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .first(where: { !$0.isTerminated }) {
            assignedAppPID = reopened.processIdentifier
        }
        let pid = assignedAppPID
        let check = AssignedTargetCheck.evaluate(
            appRunning: pid.map(alive) ?? false,
            windowID: assignedWindowID,
            windowExists: pid.flatMap { p in assignedWindowID.map { WindowTargetingService.windowExists($0, pid: p) } } ?? false,
            windowChosen: assignedWindowChosen,
            windowCount: pid.flatMap(WindowTargetingService.windowCount(pid:)))
        switch check {
        case .ready:
            return nil
        case .followApp:
            assignedWindowID = nil
            assignedWindowTitle = nil
            borderOverlay.detach()
            return nil
        case .chosenWindowClosed:
            clearAssignedTarget()
            return "The \(name) window you chose closed."
        case .appNotOpen:
            return "\(name) isn't open."
        case .noOpenWindow:
            return "\(name) has no open window."
        }
    }
}
