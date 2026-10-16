// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import QuartzCore

// MARK: - Border Overlay Window

/// Transparent, click-through window that draws a colored border around a target window.
/// Tracks the target window's position and size in real time using AXObserver + polling.
///
/// `@MainActor`-isolated: it drives an `NSWindow` and AppKit ordering, all of
/// which must run on the main thread. Every caller (AppState) is already on the
/// main actor, the AXObserver callback and poll timer both hop to main, so the
/// isolation is now compiler-enforced instead of convention. No `deinit`
/// cleanup: this is a single app-lifetime instance owned by AppState, which
/// calls `detach()` explicitly; a nonisolated deinit cannot touch the
/// main-actor window/timer/observer state anyway.
@MainActor
final class BorderOverlayController {
    private var overlayWindow: NSWindow?
    private var borderView: GradientBorderView?
    private var pollTimer: Timer?
    private var targetWindowID: CGWindowID = 0
    private var targetPID: pid_t = 0
    private var observer: AXObserver?

    var isActive: Bool { overlayWindow != nil }

    /// Start tracking a window and show the border overlay.
    func attach(to windowID: CGWindowID, pid: pid_t) {
        detach()
        targetWindowID = windowID
        targetPID = pid

        guard let frame = WindowTargetingService.windowFrame(for: windowID) else { return }

        let borderWidth: CGFloat = 1.5
        let screenFrame = convertToScreenCoordinates(frame)
        let overlayFrame = screenFrame.insetBy(dx: -borderWidth, dy: -borderWidth)

        let window = NSWindow(
            contentRect: overlayFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Same level as the target so order(.above, relativeTo:) can
        // interleave the overlay with other normal-level windows.
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        guard let contentView = window.contentView else { return }
        let bView = GradientBorderView(frame: contentView.bounds)
        bView.autoresizingMask = [.width, .height]
        contentView.addSubview(bView)
        // Order directly above the target window instead of on top of everything
        window.order(.above, relativeTo: Int(windowID))


        self.overlayWindow = window
        self.borderView = bView

        setupObserver()
        startPolling()
    }

    /// Stop tracking and hide the overlay.
    func detach() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let obs = observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
        }
        observer = nil

        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        borderView = nil
        targetWindowID = 0
        targetPID = 0
    }

    // MARK: - Position Tracking

    private func setupObserver() {
        guard targetPID > 0 else { return }

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let controller = Unmanaged<BorderOverlayController>.fromOpaque(refcon).takeUnretainedValue()
            // The AX run-loop source is added to the main run loop, so this
            // fires on the main thread; hop to the main actor explicitly.
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.updatePosition() } }
        }

        guard AXObserverCreate(targetPID, callback, &obs) == .success, let obs else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(targetPID)
        var windowsRef: CFTypeRef?

        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWindows = windowsRef as? [AXUIElement] {
            for axWindow in axWindows {
                var wid: CGWindowID = 0
                if WindowTargetingService._AXUIElementGetWindow(axWindow, &wid) == .success,
                   wid == targetWindowID {
                    AXObserverAddNotification(obs, axWindow, kAXWindowMovedNotification as CFString, refcon)
                    AXObserverAddNotification(obs, axWindow, kAXWindowResizedNotification as CFString, refcon)
                    break
                }
            }
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        self.observer = obs
    }

    private func startPolling() {
        // Supplement AXObserver with polling for smooth tracking during drags
        // Scheduled on the main run loop (attach/startPolling run on the main
        // actor), so the block fires on the main thread; assert that isolation.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePosition() }
        }
    }

    private func updatePosition() {
        guard targetWindowID != 0 else {
            detach()
            return
        }

        // Single CGWindowListCopyWindowInfo call for both visibility check and z-order sync.
        // This replaces two separate calls per frame, halving WindowServer IPC overhead.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            overlayWindow?.orderOut(nil)
            return
        }

        // Check if target is on screen and find z-order positions in one pass
        guard let overlay = overlayWindow else { return }
        let overlayNumber = CGWindowID(overlay.windowNumber)
        var targetFound = false
        var targetIndex: Int?
        var overlayIndex: Int?

        for (i, info) in windowList.enumerated() {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            if wid == targetWindowID { targetFound = true; targetIndex = i }
            if wid == overlayNumber { overlayIndex = i }
            if targetIndex != nil && overlayIndex != nil { break }
        }

        guard targetFound,
              let frame = WindowTargetingService.windowFrame(for: targetWindowID) else {
            overlayWindow?.orderOut(nil)
            return
        }

        let borderWidth: CGFloat = 1.5
        let screenFrame = convertToScreenCoordinates(frame)
        let overlayFrame = screenFrame.insetBy(dx: -borderWidth, dy: -borderWidth)

        if overlay.isVisible == false {
            overlay.order(.above, relativeTo: Int(targetWindowID))
        }
        overlay.setFrame(overlayFrame, display: true)

        // Sync z-order: re-order only if overlay isn't directly above target
        if let oi = overlayIndex, let ti = targetIndex, oi == ti - 1 {
            return  // Already correct
        }
        overlay.order(.above, relativeTo: Int(targetWindowID))
    }

    /// Convert from CG coordinates (top-left origin) to NSScreen coordinates (bottom-left origin).
    /// Finds the correct screen for the target window instead of assuming primary display.
    private func convertToScreenCoordinates(_ cgRect: CGRect) -> NSRect {
        // CG uses a global coordinate space with origin at top-left of the primary display.
        // NSScreen uses bottom-left origin. The primary screen's frame.origin is always (0,0)
        // in NS coordinates, but secondary screens can have negative or offset origins.
        // We need the primary screen's height for the Y-flip since CG coordinates
        // are relative to the primary display's top-left corner.
        guard let primaryScreen = NSScreen.screens.first else { return cgRect }
        let primaryHeight = primaryScreen.frame.height
        return NSRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.origin.y - cgRect.size.height,
            width: cgRect.size.width,
            height: cgRect.size.height
        )
    }
}

// MARK: - Gradient Border View

/// Draws an animated rainbow gradient border using a conic CAGradientLayer.
/// The colors flow around the border by shifting the gradient's color stops
/// over time -- no layer rotation involved.
final class GradientBorderView: NSView {
    private var gradientLayer: CAGradientLayer!
    private var shapeLayer: CAShapeLayer!
    private let borderWidth: CGFloat = 1.5
    private let cornerRadius: CGFloat = 8.0
    private nonisolated(unsafe) var animationTimer: Timer?
    private var colorOffset: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupLayers()
        startAnimation()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        animationTimer?.invalidate()
    }

    private func setupLayers() {
        // Shape layer: the rounded rect border stroke used as a mask
        shapeLayer = CAShapeLayer()
        updateShapePath()
        shapeLayer.fillColor = nil
        shapeLayer.strokeColor = NSColor.white.cgColor
        shapeLayer.lineWidth = borderWidth

        // Conic gradient centered in the view, masked to the border stroke
        gradientLayer = CAGradientLayer()
        gradientLayer.frame = bounds
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        updateGradientColors()
        gradientLayer.mask = shapeLayer

        layer?.addSublayer(gradientLayer)
    }

    /// Generate shifted rainbow colors based on current offset.
    /// By shifting hue values each frame, colors appear to flow around the border.
    private func updateGradientColors() {
        let count = 8
        var colors: [CGColor] = []
        for i in 0..<count {
            let hue = (CGFloat(i) / CGFloat(count - 1) + CGFloat(colorOffset)).truncatingRemainder(dividingBy: 1.0)
            colors.append(NSColor(hue: hue, saturation: 0.85, brightness: 0.95, alpha: 1.0).cgColor)
        }
        // Disable implicit animation for smooth manual updates
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = colors
        CATransaction.commit()
    }

    private func updateShapePath() {
        let insetRect = bounds.insetBy(dx: borderWidth, dy: borderWidth)
        shapeLayer?.path = CGPath(
            roundedRect: insetRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    override func layout() {
        super.layout()
        gradientLayer?.frame = bounds
        updateShapePath()
    }

    // MARK: - Animation Timer

    private func startAnimation() {
        guard animationTimer == nil else { return }
        // 30fps is smooth enough for a color shift and saves CPU vs 60fps
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                // Shift colors -- ~0.03 revolutions per second for a gentle flow
                self.colorOffset += 0.001
                if self.colorOffset >= 1.0 { self.colorOffset -= 1.0 }
                self.updateGradientColors()
            }
        }
    }
}
