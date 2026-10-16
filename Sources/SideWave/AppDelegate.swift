// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Foundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by AppState.startServices. The quit guard below is the only
    /// consumer; everything else reaches AppState through SwiftUI.
    static weak var appState: AppState?

    /// Runs before state restoration. SideWave's windows are explicit (the main window group;
    /// others suppressed), and saved application state only caused launches where Help reopened
    /// without the main window. Turned off both in user defaults and on the running app.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppPaths.isTestHost else { return }
        // 200 ms after launch, if the main window isn't visible, find its hidden window or have
        // SwiftUI create one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.ensureDashboardVisible()
        }
    }

    private func ensureDashboardVisible() {
        let main = MainWindowTracker.mainWindow()
        if let main {
            // Recenter a window whose saved frame is off every screen, which happens after a
            // monitor layout change and looks like the window never opened.
            let anyScreenContains = NSScreen.screens.contains { screen in
                screen.visibleFrame.intersects(main.frame)
            }
            if !anyScreenContains {
                main.center()
            }
            if !main.isVisible {
                main.makeKeyAndOrderFront(nil)
            }
            main.orderFrontRegardless()
        } else {
            // No main window exists. Calling the reopen handler with hasVisibleWindows false makes
            // SwiftUI create the window group's default window.
            _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            // Retry one more time after another short delay in case
            // the first pass was too early.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let main = MainWindowTracker.mainWindow()
                if let main {
                    main.center()
                    main.makeKeyAndOrderFront(nil)
                    main.orderFrontRegardless()
                } else {
                    let names = NSApp.windows.map { win -> String in
                        let id = win.identifier?.rawValue ?? "nil"
                        return "id=\(id) title='\(win.title)'"
                    }
                    NSLog("[SideWave] ensureDashboardVisible: still no main window after retry. NSApp.windows = \(names)")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate()

        let mainWindow = MainWindowTracker.mainWindow()

        if let mainWindow {
            mainWindow.orderFrontRegardless()
            mainWindow.makeKeyAndOrderFront(nil)
        }

        // Return true so the system creates a new WindowGroup window if none exists
        return true
    }

    /// Quitting during a meeting recording asks first. "Stop & Keep" stops recording, saves it as
    /// resumable, and quits; the next launch offers to transcribe or continue it. Discard deletes
    /// it and quits; Cancel stays. Quitting while a meeting is processing isn't blocked, and the
    /// next launch offers to finish it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState = Self.appState,
              case .recording(let duration) = appState.meetingService.state else {
            return .terminateNow
        }

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let alert = NSAlert()
        alert.messageText = "A meeting is recording"
        alert.informativeText = "You've recorded \(String(format: "%d:%02d", minutes, seconds)) so far. Keep it and SideWave will offer to transcribe or continue it next time you open the app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop & Keep")
        alert.addButton(withTitle: "Discard & Quit")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            appState.meetingService.stopRecording()
            return .terminateNow
        case .alertSecondButtonReturn:
            appState.meetingService.reset(discardAudio: true)
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.flush()
        NetworkActivityLog.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window closes -- keep running for menu bar + hotkey
        return false
    }

    // MARK: - Accessibility Permission Flow

    /// Open the Accessibility pane in System Settings.
    nonisolated static func openAccessibilitySettings() {
        // Try modern macOS 13+ Privacy & Security -> Accessibility first
        if let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"),
           NSWorkspace.shared.open(modern) {
            return
        }
        // Fallback to legacy URL
        if let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
           NSWorkspace.shared.open(legacy) {
            return
        }
        // Ultimate fallback: open System Settings main window
        if let generic = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(generic)
        }
    }

    /// Open the Microphone pane in System Settings.
    nonisolated static func openMicrophoneSettings() {
        // Try modern macOS 13+ Privacy & Security -> Microphone first
        if let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"),
           NSWorkspace.shared.open(modern) {
            return
        }
        // Fallback to legacy URL
        if let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
           NSWorkspace.shared.open(legacy) {
            return
        }
        // Ultimate fallback: open System Settings main window
        if let generic = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(generic)
        }
    }

    /// Show an alert when accessibility is needed but not granted.
    /// Called from TypingService/AppState when a paste attempt fails.
    nonisolated static func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "SideWave needs Accessibility access to paste text into other apps.\n\nOpen System Settings > Privacy & Security > Accessibility, then add or re-enable SideWave."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openAccessibilitySettings()
            }
        }
    }

    /// Explains a denied microphone permission and links to the right pane in System Settings,
    /// instead of silently not recording.
    nonisolated static func showMicrophoneAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Microphone Access Required"
            alert.informativeText = "SideWave can't hear your voice without microphone access.\n\nOpen System Settings > Privacy & Security > Microphone, then enable SideWave."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openMicrophoneSettings()
            }
        }
    }
}
