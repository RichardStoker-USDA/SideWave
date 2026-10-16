// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
import SideWaveKit
import os

/// Termination witness: a menu bar app must only exit when ASKED. Every
/// quit path logs who asked, so a silent disappearance is diagnosable
/// from the unified log.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.sidewave2.app", category: "lifecycle")

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        log.notice("applicationShouldTerminate (appleEvent: \(String(describing: event), privacy: .public))")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.notice("applicationWillTerminate")
    }
}

@main
struct SideWave2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var overlay: OverlayPanelController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init() {
        // Headless UI render mode: draw the overlay states to PNGs and
        // exit before any window or scene exists.
        PreviewRenderer.renderAllIfRequested()

        let model = AppModel()
        _model = State(initialValue: model)
        _overlay = State(initialValue: OverlayPanelController(model: model))
        // App.init runs before NSApplication finishes launching; launch
        // work waits for the first run-loop turn.
        Task { @MainActor in
            model.onLaunch()
        }
    }

    var body: some Scene {
        Window("SideWave", id: "dashboard") {
            DashboardView()
                .environment(model)
        }
        .defaultSize(width: 640, height: 560)

        MenuBarExtra {
            menuContent
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Text(menuStatusLine)

        Button(model.phase == .idle ? "Start Dictation" : "Stop Dictation") {
            model.toggleFromUI()
        }
        .disabled(!model.modelsReady && model.phase == .idle)
        .keyboardShortcut("d")

        Divider()

        Button("Open SideWave") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit SideWave") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var menuStatusLine: String {
        switch model.phase {
        case .idle:
            return model.modelsReady ? "Ready" : "Preparing models…"
        case .starting: return "Starting…"
        case .live: return "Listening"
        case .stopping: return "Finishing…"
        }
    }
}
