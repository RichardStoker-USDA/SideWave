// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

/// Finds the main SideWave window for Dock clicks, launch checks, and Show SideWave, so those
/// never bring Settings, Help, Downloads, or an update prompt forward instead.
@MainActor
enum MainWindowTracker {
    /// Set by `MainWindowReader` when the dashboard joins its window.
    static weak var window: NSWindow?

    /// Ids of the app's `Window` scenes. SwiftUI starts each window's identifier with its scene id.
    private static let auxiliarySceneIDs = [
        "settings", "data-transparency", "model-recovery", "help", "mini", "specialty-preview",
    ]

    static func mainWindow() -> NSWindow? {
        if let window { return window }
        // Before the dashboard has reported its window. AppKit windows such as Sparkle's prompts
        // and the About panel have no identifier.
        return NSApp.windows.first { win in
            guard win.level == .normal, win.styleMask.contains(.titled), !(win is NSPanel),
                  let id = win.identifier?.rawValue else { return false }
            return !auxiliarySceneIDs.contains { id.hasPrefix($0) }
        }
    }
}

/// Records the window hosting the dashboard in `MainWindowTracker`.
struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ReaderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindowTracker.window = window }
        }
    }
}
