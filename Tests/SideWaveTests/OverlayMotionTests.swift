import AppKit
import SwiftUI
import XCTest
@testable import SideWave

@MainActor
final class OverlayMotionTests: XCTestCase {
    func testPreviewDragTracksScreenCoordinatesAcrossEventsAndHonorsLock() {
        final class FlippedView: NSView { override var isFlipped: Bool { true } }
        for host in [NSView(), FlippedView()] {
            let window = NSPanel(contentRect: NSRect(x: 100, y: 200, width: 740, height: 350),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            host.frame = NSRect(origin: .zero, size: window.frame.size)
            window.contentView = host
            defer { window.contentView = nil }
            window.isMovable = true
            var drag = OverlayWindowDrag()
            drag.update(window: window, host: host, start: CGPoint(x: 300, y: 200), location: CGPoint(x: 350, y: 160))
            XCTAssertEqual(window.frame.origin, NSPoint(x: 150, y: 240))
            // The same local pointer location after the window moves represents another screen-space step.
            drag.update(window: window, host: host, start: CGPoint(x: 300, y: 200), location: CGPoint(x: 350, y: 160))
            XCTAssertEqual(window.frame.origin, NSPoint(x: 200, y: 280))
            XCTAssertEqual(drag.finish(in: window), window.frame)
            XCTAssertNil(drag.finish(in: window), "A completed drag cannot save a later programmatic move")
            window.isMovable = false
            drag.update(window: window, host: host, start: CGPoint(x: 300, y: 200), location: CGPoint(x: 400, y: 100))
            XCTAssertEqual(window.frame.origin, NSPoint(x: 200, y: 280))
            XCTAssertNil(drag.finish(in: window))
            window.isMovable = true
            drag.update(window: window, host: host, start: CGPoint(x: 300, y: 200), location: CGPoint(x: 0, y: 200))
            XCTAssertEqual(window.frame.origin, NSPoint(x: -100, y: 280), "Dragging can cross into a display with negative coordinates")
        }
    }

    func testPreviewDefaultsToBottomCenterOfPrimaryDisplay() throws {
        let primary = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let visible = NSRect(x: 80, y: 0, width: 1648, height: 1085)
        let secondary = NSRect(x: 1728, y: 300, width: 2560, height: 1440)
        let frame = try XCTUnwrap(OverlayPlacement.resolvedFrame(size: DictationOverlayController.collapsedSize,
            savedAnchor: nil, screens: [(primary, visible), (secondary, secondary)]))
        XCTAssertEqual(frame.midX, primary.midX, "A side Dock must not shift the screen's visual center")
        XCTAssertEqual(frame.minY, visible.minY + OverlayPlacement.bottomInset)
        XCTAssertTrue(visible.contains(frame))
    }

    func testPreviewRestoresUserPlacementAcrossSizesAndFallsBackWhenDisplayDisconnects() throws {
        let primary = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let secondary = NSRect(x: -2560, y: 200, width: 2560, height: 1440)
        let anchor = NSPoint(x: -1100, y: 240)
        for size in [DictationOverlayController.collapsedSize, DictationOverlayController.expandedSize] {
            let frame = try XCTUnwrap(OverlayPlacement.resolvedFrame(size: size,
                savedAnchor: anchor, screens: [(primary, primary), (secondary, secondary)]))
            XCTAssertEqual(frame.midX, anchor.x)
            XCTAssertEqual(frame.minY, anchor.y)
            XCTAssertTrue(secondary.contains(frame))
        }
        let fallback = try XCTUnwrap(OverlayPlacement.resolvedFrame(size: DictationOverlayController.collapsedSize,
            savedAnchor: anchor, screens: [(primary, primary)]))
        XCTAssertEqual(fallback.midX, primary.midX)
        XCTAssertEqual(fallback.minY, OverlayPlacement.bottomInset)
    }

    func testPreviewClampsBothAxesAfterDockOrDisplayChanges() {
        let visible = NSRect(x: 0, y: 90, width: 1024, height: 650)
        for anchor in [NSPoint(x: 5, y: 0), NSPoint(x: 1020, y: 700)] {
            let frame = OverlayPlacement.frame(size: DictationOverlayController.expandedSize,
                bottomCenter: anchor, visibleFrame: visible)
            XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(frame))
        }
    }

    func testPreviewStoresBottomCenterOnlyForExplicitPlacementAndResetsLegacyCoordinates() throws {
        let suite = "OverlayPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2984, forKey: "overlayPositionX")
        defaults.set(402, forKey: "overlayPositionY")
        XCTAssertNil(OverlayPlacement.savedAnchor(in: defaults), "Old automatic moves are not user placements")
        let frame = NSRect(x: 100, y: 120, width: 780, height: 800)
        OverlayPlacement.save(frame, in: defaults)
        XCTAssertEqual(OverlayPlacement.savedAnchor(in: defaults), NSPoint(x: 490, y: 120))
        _ = OverlayPlacement.frame(size: DictationOverlayController.collapsedSize,
            bottomCenter: NSPoint(x: 490, y: 120), visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(OverlayPlacement.savedAnchor(in: defaults), NSPoint(x: 490, y: 120))
        OverlayPlacement.reset(in: defaults)
        XCTAssertNil(OverlayPlacement.savedAnchor(in: defaults))
        XCTAssertNil(defaults.object(forKey: "overlayPositionX"))
        XCTAssertNil(defaults.object(forKey: "overlayPositionY"))
    }

    func testPreviewRejectsMalformedSavedCoordinates() throws {
        let suite = "OverlayPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value: Any in [[Double.nan, 40], [Double.infinity, 40], [40], [40, 60, 80], "invalid"] {
            defaults.set(value, forKey: OverlayPlacement.savedAnchorKey)
            XCTAssertNil(OverlayPlacement.savedAnchor(in: defaults))
        }
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = try XCTUnwrap(OverlayPlacement.resolvedFrame(size: DictationOverlayController.collapsedSize,
            savedAnchor: NSPoint(x: CGFloat.nan, y: 0), screens: [(screen, screen)]))
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.minY, OverlayPlacement.bottomInset)
    }

    func testVisiblePreviewCardStaysAtBottomOfTransparentPanel() throws {
        let defaults = UserDefaults.standard
        let keys = ["liquidGlassMode", "appearance", "reduceAppMotion", "textDisplayMode", "overlayExpanded"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "liquidGlassMode")
        defaults.set(false, forKey: "overlayExpanded")
        defaults.set(true, forKey: "reduceAppMotion")
        defaults.set("dark", forKey: "appearance")
        defaults.set("standard", forKey: "textDisplayMode")
        let state = AppState()
        state.overlayMessage = "Preparing preview"
        let host = NSHostingView(rootView: DictationOverlayContent(appState: state).environment(state))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: DictationOverlayController.collapsedSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let occupied = (0..<bitmap.pixelsHigh).filter {
            (bitmap.colorAt(x: bitmap.pixelsWide / 2, y: $0)?.alphaComponent ?? 0) > 0.5
        }
        let first = try XCTUnwrap(occupied.first)
        let last = try XCTUnwrap(occupied.last)
        XCTAssertGreaterThan(first, bitmap.pixelsHigh / 2, "The short card must not float in the middle of its panel")
        XCTAssertGreaterThanOrEqual(last, bitmap.pixelsHigh - 2, "The visible card must reach the panel's bottom")
    }

    func testSilentWaveMovesAndMicrophoneChangesItsShape() throws {
        let first = try pixels(wave(level: 0, time: 1))
        XCTAssertNotEqual(first, try pixels(wave(level: 0, time: 1.7)))
        XCTAssertNotEqual(first, try pixels(wave(level: 0.6, time: 1)))
        XCTAssertEqual(try pixels(wave(level: 0, reduced: true, time: 1)),
                       try pixels(wave(level: 0, reduced: true, time: 8)))
        let mini = MiniDashboardSurface(phase: .idle, hotkey: "Right Option", outputSummary: "As spoken",
                                        reduceMotion: true, onPrimary: {}, onExpand: {})
        XCTAssertEqual(try pixels(mini), try pixels(mini), "Mini must also stop its internal waveform clock with Reduce Motion")
    }

    func testGenerationPaletteReturnsToRainbowAfterRefinement() throws {
        let rainbow = try pixels(wave(level: 0.2, time: 1))
        let apple = try pixels(wave(level: 0.2, refining: true, time: 1))
        let gemma = try pixels(wave(level: 0.2, refining: true, backend: .gemma, time: 1))
        XCTAssertNotEqual(rainbow, apple)
        XCTAssertNotEqual(apple, gemma)
        XCTAssertEqual(rainbow, try pixels(wave(level: 0.2, backend: .gemma, time: 1)))
    }

    func testRefinedWordsHaveAnIntermediateRevealAndSettle() throws {
        let defaults = UserDefaults.standard
        let keys = ["reduceAppMotion", "refineAnimationStyle", "dictationCleanupTemplate", "visualizerColorMode"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "reduceAppMotion")
        defaults.set("Sweep", forKey: "refineAnimationStyle")
        defaults.set("standard", forKey: "dictationCleanupTemplate")
        defaults.set("rainbow", forKey: "visualizerColorMode")
        let state = AppState()
        let span = StagedTranscript.Span(id: UUID(), stage: .refined,
            text: "Review the sample results before Friday.", eouCoverageWords: 7,
            originalText: "review the sample results before friday", refinedAt: 1,
            originalEouText: "review the sample results before friday")
        func frame(_ time: TimeInterval) -> some View {
            DictationOverlayContent(textRenderSample: .init(spans: [span], tail: "", time: time), appState: state)
        }
        let start = try pixels(frame(1))
        let middle = try pixels(frame(1.25))
        let settled = try pixels(frame(3))
        XCTAssertNotEqual(start, middle)
        XCTAssertNotEqual(middle, settled)
        XCTAssertEqual(settled, try pixels(frame(8)))
    }

    func testUnchangedRefinementStaysStillAndInstantModeHasNoDelayedWords() throws {
        let defaults = UserDefaults.standard
        let keys = ["reduceAppMotion", "refineAnimationStyle", "dictationCleanupTemplate", "visualizerColorMode"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "reduceAppMotion")
        defaults.set("Sweep", forKey: "refineAnimationStyle")
        defaults.set("standard", forKey: "dictationCleanupTemplate")
        defaults.set("rainbow", forKey: "visualizerColorMode")
        var time = 1.0
        let transcript = StagedTranscript(now: { time })
        let id = transcript.ingestTdtCommitted("Review the samples before Friday.")
        transcript.markRefinedNoChange(spanID: id)
        time = 10
        transcript.refineSpan(spanID: id, refinedText: "Review the samples before Friday.")
        let state = AppState()
        func frame(_ at: TimeInterval) -> some View {
            DictationOverlayContent(textRenderSample: .init(spans: transcript.confirmedSpans, tail: "", time: at), appState: state)
        }
        XCTAssertEqual(try pixels(frame(10)), try pixels(frame(10.3)), "Unchanged words must not animate again")
        defaults.set("Instant", forKey: "refineAnimationStyle")
        transcript.refineSpan(spanID: id, refinedText: "Review the samples before Monday.")
        XCTAssertEqual(try pixels(frame(10)), try pixels(frame(11)), "Instant must show every updated word immediately")
    }

    private func wave(level: Double, reduced: Bool = false, refining: Bool = false,
                      backend: RefiningBackendForPalette = .appleIntelligence, time: TimeInterval) -> AudioWaveVisualizer {
        AudioWaveVisualizer(audioLevel: level, colorMode: "rainbow", sensitivity: 0.7,
                            liquidGlass: true, isRefining: refining, refiningBackend: backend, reduceMotion: reduced, sampleTime: time)
    }

    /// A long refine in the expanded preview made the card taller than its panel. AppKit grew the
    /// panel to fit, the card measured the larger panel, and during a resize the two never settled:
    /// AppKit raised an exception after repeated constraint passes and the app quit mid-refine.
    func testRefiningPreviewNeverResizesItsPanel() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "overlayExpanded")
        defer { if let saved { defaults.set(saved, forKey: "overlayExpanded") } else { defaults.removeObject(forKey: "overlayExpanded") } }
        let appState = AppState()
        appState.cleanupStatus = "Finishing remaining text"
        appState.cleanupStreamingText = String(repeating: "The soil moisture readings for plots four through nine look consistent with last week. ", count: 60)
        appState.isCleaningUp = true
        appState.dictationFormatter.state = .generating
        for (expanded, size) in [(true, DictationOverlayController.expandedSize), (false, DictationOverlayController.collapsedSize)] {
            defaults.set(expanded, forKey: "overlayExpanded")
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AnyView(DictationOverlayContent(appState: appState).environment(appState)))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            panel.contentView = host
            defer { panel.contentView = nil }
            for _ in 0..<3 {
                panel.display()
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(panel.frame, NSRect(origin: .zero, size: size), "expanded: \(expanded)")
        }
    }

    private func pixels<V: View>(_ view: V) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: 500, height: 40)
            .background(Color.black).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
