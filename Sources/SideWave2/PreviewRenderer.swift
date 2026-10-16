// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

/// Headless UI verification: draws every overlay state to PNG files and
/// exits before a single window exists. Launch the binary with
/// `-renderPreviews <dir>`; nothing appears on screen. This is how the
/// overlay design gets reviewed and iterated without borrowing the
/// user's display.
@MainActor
enum PreviewRenderer {

    static func renderAllIfRequested() {
        guard let dir = UserDefaults.standard.string(forKey: "renderPreviews") else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, state) in Self.states {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                render(state: state, scheme: scheme, to: out, name: name)
            }
        }
        print("previews written to \(out.path)")
        exit(0)
    }

    private static func render(
        state: OverlayDisplayState, scheme: ColorScheme, to dir: URL, name: String
    ) {
        let stage = ZStack {
            backdrop(for: scheme)
            OverlayView(state: state)
        }
        .frame(width: 680, height: 130)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            print("render failed: \(name) \(scheme)")
            return
        }
        let suffix = scheme == .dark ? "dark" : "light"
        try? png.write(to: dir.appendingPathComponent("overlay_\(name)_\(suffix).png"))
    }

    /// A wallpaper-like backdrop so the glass material reads the way it
    /// does over a real desktop.
    private static func backdrop(for scheme: ColorScheme) -> some View {
        LinearGradient(
            colors: scheme == .dark
                ? [
                    Color(.sRGB, red: 0.10, green: 0.12, blue: 0.18),
                    Color(.sRGB, red: 0.16, green: 0.13, blue: 0.22),
                    Color(.sRGB, red: 0.08, green: 0.15, blue: 0.20),
                ]
                : [
                    Color(.sRGB, red: 0.78, green: 0.85, blue: 0.95),
                    Color(.sRGB, red: 0.90, green: 0.86, blue: 0.92),
                    Color(.sRGB, red: 0.80, green: 0.90, blue: 0.94),
                ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: The state matrix

    private static var states: [(String, OverlayDisplayState)] {
        var matrix: [(String, OverlayDisplayState)] = []

        var starting = OverlayDisplayState()
        starting.phase = .starting
        matrix.append(("01_starting", starting))

        var liveEmpty = OverlayDisplayState()
        liveEmpty.phase = .live
        matrix.append(("02_live_empty", liveEmpty))

        var fallback = OverlayDisplayState()
        fallback.phase = .live
        fallback.deviceNotice = "Using MacBook Pro Microphone"
        matrix.append(("03_live_fallback", fallback))

        var liveShort = OverlayDisplayState()
        liveShort.phase = .live
        liveShort.settledText = "The quick brown fox jumps"
        liveShort.settlingText = " over the la"
        matrix.append(("04_live_short", liveShort))

        var liveLong = OverlayDisplayState()
        liveLong.phase = .live
        liveLong.settledText =
            "We should finish the deployment first, verify every host in the fleet reports healthy, and only then move on to"
        liveLong.settlingText = " the monitoring dash"
        matrix.append(("05_live_long", liveLong))

        var ptt = OverlayDisplayState()
        ptt.phase = .live
        ptt.settledText = "Ship the release notes to the team"
        ptt.pttEngaged = true
        matrix.append(("06_live_ptt", ptt))

        var finishing = OverlayDisplayState()
        finishing.phase = .finishing(refining: false)
        finishing.settledText = "Ship the release notes to the team"
        matrix.append(("07_finishing", finishing))

        var refiningAFM = OverlayDisplayState()
        refiningAFM.phase = .finishing(refining: true)
        refiningAFM.settledText = "so um the thing is we need to improve the performance"
        refiningAFM.refinePalette = .appleIntelligence
        matrix.append(("08_refining_afm", refiningAFM))

        var refiningGemma = OverlayDisplayState()
        refiningGemma.phase = .finishing(refining: true)
        refiningGemma.settledText = "so um the thing is we need to improve the performance"
        refiningGemma.refinePalette = .gemma
        matrix.append(("09_refining_gemma", refiningGemma))

        var pasted = OverlayDisplayState()
        pasted.phase = .done(.pasted)
        matrix.append(("10_pasted", pasted))

        var saved = OverlayDisplayState()
        saved.phase = .done(.savedToHistory)
        matrix.append(("11_saved", saved))

        var suppressed = OverlayDisplayState()
        suppressed.phase = .done(.notice("No speech detected, so nothing was typed."))
        matrix.append(("12_suppressed", suppressed))

        return matrix
    }
}
