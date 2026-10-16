// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Menu bar menu. Rendered as a native NSMenu, so it only uses menu-safe
/// content: buttons, toggles, text, and dividers.
struct MenuBarView: View {
    var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false

    var body: some View {
        setupStatus
        meetingStatus

        Button("Open SideWave", systemImage: "macwindow") {
            appState.showMainWindow = true
            NSApp.activate()
        }
        Button("Settings\u{2026}", systemImage: "gearshape") {
            NSApp.activate()
            openWindow(id: "settings")
        }
        Button("SideWave Help", systemImage: "questionmark.circle") {
            NSApp.activate()
            openWindow(id: "help")
        }

        Divider()

        Toggle(isOn: $showAdvancedControls) {
            Label("Advanced View", systemImage: "slider.horizontal.3")
        }

        Divider()

        Button("Quit SideWave", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// One actionable setup blocker, shown only while something needs
    /// attention. Accessibility comes first because the shortcut and paste
    /// can't work without it.
    @ViewBuilder
    private var setupStatus: some View {
        if !appState.isAccessibilityGranted {
            Text("Accessibility access is off")
            Button("Open Accessibility Settings\u{2026}", systemImage: "exclamationmark.triangle") {
                NSApp.activate()
                AppDelegate.openAccessibilitySettings()
            }
            Divider()
        } else if appState.microphonePermission != .granted {
            Text("Microphone access is off")
            Button("Allow Microphone Access\u{2026}", systemImage: "mic.slash") {
                appState.requestedPage = .home
                appState.showMainWindow = true
                NSApp.activate()
            }
            Divider()
        } else if !appState.transcriptionService.modelState.isReady {
            Text(modelStatus(appState.transcriptionService.modelState))
            Button("Show Setup", systemImage: "arrow.down.circle") {
                appState.showMainWindow = true
                NSApp.activate()
            }
            Divider()
        }
    }

    /// Recording indicator with a stop action, so a meeting can be ended
    /// while the main window is closed.
    @ViewBuilder
    private var meetingStatus: some View {
        if case .recording(let duration) = appState.meetingService.state {
            Text("Recording meeting \u{00B7} \(Self.duration(duration))")
            Button("Stop and Transcribe", systemImage: "stop.circle") {
                appState.meetingService.stopRecording()
                appState.meetingService.processRecording()
                appState.showMainWindow = true
                NSApp.activate()
            }
            Divider()
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func modelStatus(_ state: ModelState) -> String {
        switch state {
        case .notDownloaded: "Speech models need to be downloaded"
        case .downloading(let progress): "Downloading speech models \u{00B7} \(Int(progress * 100))%"
        case .downloadingAuxiliary(let model): "Downloading \(model)"
        case .verifying: "Checking speech model files"
        case .compiling: "Preparing speech models for this Mac"
        case .loading: "Loading speech models"
        case .error: "Speech model setup needs attention"
        case .ready: "Speech models are ready"
        }
    }
}
