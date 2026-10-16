// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

// MARK: - Overlay Size

enum OverlaySize: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case standard = "Standard"
    case large = "Large"

    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .compact: return 420
        case .standard: return 500
        case .large: return 600
        }
    }

    var maxTextHeight: CGFloat {
        // Sized for the multi-stage preview, which needs more room than single-line text.
        switch self {
        case .compact: return 80
        case .standard: return 155
        case .large: return 220
        }
    }

    var maxLines: Int {
        switch self {
        case .compact: return 4
        case .standard: return 9
        case .large: return 13
        }
    }

    // Cinematic mode overrides: larger dimensions for the perspective crawl
    var cinematicWidth: CGFloat {
        max(width, 560)
    }

    var cinematicMaxTextHeight: CGFloat {
        max(maxTextHeight, 220)
    }

    var cinematicMaxLines: Int {
        50 // cinematic crawl accumulates text -- don't cap aggressively
    }

    static func from(rawValue: String) -> OverlaySize {
        OverlaySize(rawValue: rawValue) ?? .standard
    }
}

// MARK: - Overlay Window Controller

enum OverlayPlacement {
    static let bottomInset: CGFloat = 24
    static let edgeInset: CGFloat = 8
    static let savedAnchorKey = "overlayBottomCenter"

    static func savedAnchor(in defaults: UserDefaults) -> NSPoint? {
        guard let values = defaults.array(forKey: savedAnchorKey) as? [Double],
              values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
        return NSPoint(x: values[0], y: values[1])
    }

    static func save(_ frame: NSRect, in defaults: UserDefaults) {
        guard frame.midX.isFinite, frame.minY.isFinite else { return }
        defaults.set([Double(frame.midX), Double(frame.minY)], forKey: savedAnchorKey)
    }

    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: savedAnchorKey)
        defaults.removeObject(forKey: "overlayPositionX")
        defaults.removeObject(forKey: "overlayPositionY")
    }

    static func defaultFrame(size: NSSize, screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        frame(size: size, bottomCenter: NSPoint(x: screenFrame.midX, y: visibleFrame.minY + bottomInset),
              visibleFrame: visibleFrame)
    }

    static func resolvedFrame(size: NSSize, savedAnchor: NSPoint?,
                              screens: [(frame: NSRect, visibleFrame: NSRect)]) -> NSRect? {
        if let anchor = savedAnchor, anchor.x.isFinite, anchor.y.isFinite,
           let screen = screens.first(where: { $0.frame.contains(anchor) }) {
            return frame(size: size, bottomCenter: anchor, visibleFrame: screen.visibleFrame)
        }
        guard let primary = screens.first else { return nil }
        return defaultFrame(size: size, screenFrame: primary.frame, visibleFrame: primary.visibleFrame)
    }

    static func frame(size: NSSize, bottomCenter: NSPoint, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let fittedSize = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        return NSRect(
            x: min(max(bottomCenter.x - fittedSize.width / 2, bounds.minX), bounds.maxX - fittedSize.width),
            y: min(max(bottomCenter.y, bounds.minY), bounds.maxY - fittedSize.height),
            width: fittedSize.width, height: fittedSize.height
        )
    }
}

@MainActor
struct OverlayWindowDrag {
    private var anchor: (origin: NSPoint, pointer: NSPoint)?

    mutating func update(window: NSWindow, host: NSView, start: CGPoint, location: CGPoint) {
        guard window.isMovable else { anchor = nil; return }
        func screenPoint(_ point: CGPoint) -> NSPoint {
            let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
            return window.convertPoint(toScreen: host.convert(local, to: nil))
        }
        if anchor == nil { anchor = (window.frame.origin, screenPoint(start)) }
        guard let anchor else { return }
        let pointer = screenPoint(location)
        window.setFrameOrigin(NSPoint(x: anchor.origin.x + pointer.x - anchor.pointer.x,
                                      y: anchor.origin.y + pointer.y - anchor.pointer.y))
    }

    mutating func finish(in window: NSWindow) -> NSRect? {
        defer { anchor = nil }
        guard anchor != nil, window.isMovable else { return nil }
        return window.frame
    }
}

@MainActor
final class DictationOverlayController {
    static let shared = DictationOverlayController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var escapeMonitor: Any?
    private var windowDrag = OverlayWindowDrag()
    private nonisolated(unsafe) var appearanceObserver: NSObjectProtocol?
    private var showGeneration = 0
    var onDismiss: (() -> Void)?
    /// Called on plain Escape: soft stop (save text, don't paste).
    var onSoftStop: (() -> Void)?

    private init() {
        // Watch for appearance preference changes so the overlay panel updates
        // even when the SwiftUI DictationOverlayContent view isn't alive
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

    func show(appState: AppState) {
        showGeneration += 1
        windowDrag = OverlayWindowDrag()

        // If panel exists but is mid-fade-out, destroy it immediately and recreate
        // to avoid the hide() completion handler racing with this show() call.
        if let existingPanel = panel, existingPanel.alphaValue < 1 {
            existingPanel.orderOut(nil)
            existingPanel.contentView = nil
            hostingView = nil
            panel = nil
        }

        // Always reset overlay size to collapsed on session launch
        UserDefaults.standard.set(false, forKey: "overlayExpanded")
        setExpanded(false, animated: false)

        if panel == nil {
            createPanel(appState: appState)
        }

        // Sync panel appearance with user preference before showing
        let mode = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        updateAppearance(mode)

        positionPanel()
        setupEscapeKeyMonitor()

        panel?.alphaValue = 0
        panel?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
    }

    func setMovable(_ movable: Bool) {
        panel?.isMovable = movable
        if !movable { windowDrag = OverlayWindowDrag() }
    }

    func drag(start: CGPoint, location: CGPoint) {
        guard let panel, let hostingView else { return }
        windowDrag.update(window: panel, host: hostingView, start: start, location: location)
    }

    func rememberUserPosition() {
        guard let panel, let frame = windowDrag.finish(in: panel) else { return }
        OverlayPlacement.save(frame, in: .standard)
    }

    func resetPosition() {
        windowDrag = OverlayWindowDrag()
        OverlayPlacement.reset(in: .standard)
        positionPanel()
    }

    /// The visible card is bottom-aligned inside this transparent panel.
    static let collapsedSize = NSSize(width: 740, height: 350)
    /// Expanded dimensions are constrained to the current display.
    static let expandedSize = NSSize(width: 780, height: 1100)

    /// Resizes the panel between `collapsedSize` and `expandedSize`, keeping its bottom center
    /// fixed so the wave stays in place. Animated unless Reduce Motion is on, and kept on screen.
    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard let panel = panel else { return }
        let baseSize = expanded ? Self.expandedSize : Self.collapsedSize

        var newSize = baseSize
        let screen = panel.screen ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let maxWidth = visible.width * 0.92
            let maxHeight = visible.height * 0.85
            if newSize.width > maxWidth { newSize.width = maxWidth }
            if newSize.height > maxHeight { newSize.height = maxHeight }
        }

        guard let screen else { return }
        let newFrame = OverlayPlacement.frame(size: newSize,
            bottomCenter: NSPoint(x: panel.frame.midX, y: panel.frame.minY), visibleFrame: screen.visibleFrame)

        if animated {
            // About 0.25 s with ease-out, to match the SwiftUI `.snappy` animation of the inner
            // frame.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(newFrame, display: true, animate: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    func hide(synchronous: Bool = false) {
        windowDrag = OverlayWindowDrag()
        removeEscapeKeyMonitor()
        guard let panel else { return }
        let hideGeneration = showGeneration

        if synchronous {
            // Immediate, synchronous teardown to avoid AppKit window state anomalies upon sleep/suspension
            panel.orderOut(nil)
            panel.contentView = nil
            self.hostingView = nil
            self.panel = nil
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // If show() was called during the fade-out, the generation will have
                // advanced and this completion handler should skip the destructive teardown.
                guard let self, self.showGeneration == hideGeneration else { return }
                // Destroy panel entirely to prevent SwiftUI attribute graph
                // accumulation across sessions (the root cause of frame rate
                // degradation that persists between recording sessions).
                self.panel?.orderOut(nil)
                self.panel?.contentView = nil
                self.hostingView = nil
                self.panel = nil
            }
        }
    }

    /// Matches the panel's appearance to the user's setting, so AppKit materials follow it as well
    /// as the SwiftUI content.
    func updateAppearance(_ mode: String) {
        guard let panel else { return }
        switch mode {
        case "light":
            panel.appearance = NSAppearance(named: .aqua)
        case "dark":
            panel.appearance = NSAppearance(named: .darkAqua)
        default:
            panel.appearance = nil // inherit system
        }
        // Force the hosting view to re-resolve its layout and display,
        // ensuring SwiftUI content picks up the new appearance immediately
        if let hostingView {
            hostingView.needsLayout = true
            hostingView.needsDisplay = true
        }
        // Force AppKit to re-render after appearance change. Without this,
        // switching from e.g. "light" back to "system" can leave stale
        // materials/colors until the user manually triggers another toggle.
        panel.invalidateShadow()
        panel.display()
    }

    private func setupEscapeKeyMonitor() {
        removeEscapeKeyMonitor()
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                DispatchQueue.main.async {
                    if event.modifierFlags.contains(.control) {
                        // Ctrl+Escape: hard cancel (discard text)
                        self?.onDismiss?()
                    } else {
                        // Plain Escape: soft stop (save text, don't paste)
                        self?.onSoftStop?()
                    }
                }
            }
        }
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    private func createPanel(appState: AppState) {
        // show() resets to collapsed; setExpanded updates the panel during use.
        let expanded = UserDefaults.standard.bool(forKey: "overlayExpanded")
        let initialSize = expanded ? Self.expandedSize : Self.collapsedSize
        let maxWidth = initialSize.width
        let maxHeight = initialSize.height

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: maxWidth, height: maxHeight),
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
        panel.title = "Dictation Preview"
        // Only the visible card handles dragging, not its transparent margins.
        panel.isMovableByWindowBackground = false
        panel.isMovable = !appState.overlayPositionLocked
        panel.hidesOnDeactivate = false

        let content = DictationOverlayContent(appState: appState)
        let hosting = NSHostingView(rootView: AnyView(content.environment(appState)))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        hosting.frame = NSRect(origin: .zero, size: NSSize(width: maxWidth, height: maxHeight))
        panel.setContentSize(NSSize(width: maxWidth, height: maxHeight))
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    private func positionPanel() {
        guard let panel else { return }
        // NSScreen.main follows keyboard focus; the first screen is the primary display.
        guard let frame = OverlayPlacement.resolvedFrame(size: panel.frame.size,
            savedAnchor: OverlayPlacement.savedAnchor(in: .standard),
            screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) }) else { return }
        panel.setFrame(frame, display: true)
    }
}
