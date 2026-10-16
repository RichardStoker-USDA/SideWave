// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

@preconcurrency import AppKit
import SwiftUI

// MARK: - Toast Content View

/// Compact notification pill shown at the top of the screen for transient feedback.
private struct ToastContentView: View {
    let message: String
    let icon: String?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(toastBackground)
    }

    private var toastBackground: some View {
        RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
            .fill(.clear)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
    }
}

// MARK: - Toast Controller

/// Manages a floating NSPanel for brief, non-interactive toast notifications.
/// Follows the same panel lifecycle pattern as DictationOverlayController:
/// generation counter for race prevention, full panel teardown after dismiss
/// to avoid SwiftUI attribute graph accumulation.
@MainActor
final class ToastController {
    static let shared = ToastController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var appearanceObserver: NSObjectProtocol?
    private var showGeneration = 0

    private init() {
        // Watch for appearance preference changes so the toast panel matches
        // the user's light/dark/system setting even between show() calls.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let mode = UserDefaults.standard.string(forKey: "appearance") ?? "system"
                self?.updateAppearance(mode)
            }
        }
    }

    deinit {
        if let obs = appearanceObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Public API

    /// Display a toast notification at the top-center of the screen.
    ///
    /// If a toast is already visible, the content updates in-place and the
    /// auto-dismiss timer restarts (no flicker from tear-down / recreate).
    ///
    /// - Parameters:
    ///   - message: Short text to display.
    ///   - icon: Optional SF Symbol name shown to the left of the text.
    ///   - duration: Seconds before auto-dismiss. Defaults to 1.5.
    func show(message: String, icon: String? = nil, duration: TimeInterval = 1.5) {
        showGeneration += 1
        let currentGeneration = showGeneration

        // If the panel exists but is mid-fade-out, tear it down and start fresh
        // to avoid the hide() completion handler racing with this show() call.
        if let existingPanel = panel, existingPanel.alphaValue < 1 {
            existingPanel.orderOut(nil)
            existingPanel.contentView = nil
            hostingView = nil
            panel = nil
        }

        let content = ToastContentView(message: message, icon: icon)

        if let hostingView, let panel {
            // Panel already on screen: swap content, recalculate size, reset timer
            hostingView.rootView = AnyView(content)
            hostingView.layoutSubtreeIfNeeded()
            let newSize = NSSize(
                width: max(hostingView.fittingSize.width, 80),
                height: max(hostingView.fittingSize.height, 30)
            )
            panel.setContentSize(newSize)
            positionPanel() // re-center with new width
        } else {
            // First show (or previous panel was torn down): create from scratch
            createPanel(content: content)
            positionPanel()

            let mode = UserDefaults.standard.string(forKey: "appearance") ?? "system"
            updateAppearance(mode)

            panel?.alphaValue = 0
            panel?.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel?.animator().alphaValue = 1
            }
        }

        // VoiceOver announcement
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )

        // Schedule auto-dismiss (generation check prevents stale closures)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard let self, self.showGeneration == currentGeneration else { return }
            self.hide()
        }
    }

    /// Immediately fade out and destroy the toast panel.
    func hide() {
        guard let panel else { return }
        let hideGeneration = showGeneration

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showGeneration == hideGeneration else { return }
                self.panel?.orderOut(nil)
                self.panel?.contentView = nil
                self.hostingView = nil
                self.panel = nil
            }
        }
    }

    // MARK: - Appearance

    private func updateAppearance(_ mode: String) {
        guard let panel else { return }
        switch mode {
        case "light":
            panel.appearance = NSAppearance(named: .aqua)
        case "dark":
            panel.appearance = NSAppearance(named: .darkAqua)
        default:
            panel.appearance = nil // inherit system
        }
        if let hostingView {
            hostingView.needsLayout = true
            hostingView.needsDisplay = true
        }
        panel.invalidateShadow()
        panel.display()
    }

    // MARK: - Panel Lifecycle

    private func createPanel(content: ToastContentView) {
        // Use a generous initial size; SwiftUI intrinsic sizing handles the rest.
        let initialWidth: CGFloat = 400
        let initialHeight: CGFloat = 60

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        // Let the hosting view size itself to content, then size the panel to match
        let fittingSize = hosting.fittingSize
        let panelSize = NSSize(
            width: max(fittingSize.width, 80),
            height: max(fittingSize.height, 30)
        )
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        panel.setContentSize(panelSize)
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    private func positionPanel() {
        guard let panel else { return }

        let screen = panel.screen ?? NSScreen.main
        guard let screen else { return }

        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let windowSize = panel.frame.size

        // Centered horizontally
        let x = fullFrame.midX - windowSize.width / 2

        // ~80pt below the top of the visible frame (just under the menu bar).
        // macOS coordinate system has origin at bottom-left, so "below menu bar"
        // means visibleFrame.maxY minus offset minus window height.
        let topOffset: CGFloat = 80
        let y = visibleFrame.maxY - topOffset - windowSize.height

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
