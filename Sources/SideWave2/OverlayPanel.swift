// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

/// The floating dictation overlay: a non-activating glass capsule at the
/// bottom of the screen. It never takes focus (the user's target app
/// keeps the caret) and never captures the mouse.
@MainActor
final class OverlayPanelController {

    private var panel: NSPanel?
    private let model: AppModel
    private var hideTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        registerObservation()
        applyVisibility()
    }

    /// One-shot observation registration; each change hops to the main
    /// actor (breaking any synchronous cycle), applies visibility, and
    /// re-arms.
    private func registerObservation() {
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyVisibility()
                self.registerObservation()
            }
        }
    }

    private func applyVisibility() {
        switch model.phase {
        case .starting, .live, .stopping:
            hideTask?.cancel()
            hideTask = nil
            show()
        case .idle:
            // Linger to flash the outcome, then slip away.
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func show() {
        if panel == nil {
            // Fixed stage; the capsule inside hugs its content and stays
            // centered, so the panel never needs live resizing.
            let content = NSHostingView(
                rootView: OverlayRootView(model: model)
                    .frame(width: Self.stageSize.width, height: Self.stageSize.height))
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.stageSize),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: true
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = content
            self.panel = panel
        }
        layout()
        panel?.orderFrontRegardless()
    }

    private static let stageSize = NSSize(width: 680, height: 96)

    private func hide() {
        panel?.orderOut(nil)
    }

    /// Bottom-center of the screen the user is working on.
    private func layout() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - Self.stageSize.width / 2,
            y: frame.minY + 22
        )
        panel.setFrame(NSRect(origin: origin, size: Self.stageSize), display: true)
    }
}

/// Bridges the observable model to the pure overlay view. Lives in the
/// panel; the render harness bypasses it and feeds states directly.
struct OverlayRootView: View {
    let model: AppModel

    var body: some View {
        OverlayView(state: model.overlayState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
