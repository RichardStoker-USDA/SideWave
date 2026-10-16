// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// The SideWave brand mark, alive: three sine strands braided the way the
/// menu bar icon draws them, flowing while the mic listens. The strands
/// carry the session's meaning through color — SideWave blues while
/// dictating, the Apple Intelligence or Gemma palette while refining,
/// still and quiet at rest.
struct WaveStrands: View {

    enum Mood: Equatable {
        /// Barely breathing, monochrome (pre-ready, notices).
        case calm
        /// Full flow in the SideWave blues.
        case listening
        /// Backend palette sweep while the refine model writes.
        case refining(OverlayDisplayState.RefinePalette)
        /// One settled accent stroke (terminal flash).
        case settled
    }

    var mood: Mood
    /// Bumps to surge amplitude briefly (new words arrived).
    var activityPulse: Int

    @Environment(\.colorScheme) private var scheme
    /// Wall-clock stamp of the last activity pulse; the surge decays
    /// exponentially from it inside draw(). Canvas redraws every frame
    /// under TimelineView, so time-based decay is the reliable way to
    /// animate it (SwiftUI value animation is invisible to Canvas reads).
    @State private var lastPulseAt: Date?

    var body: some View {
        TimelineView(.animation(paused: mood == .calm || mood == .settled)) { timeline in
            Canvas { context, size in
                draw(context: context, size: size, date: timeline.date)
            }
        }
        .onChange(of: activityPulse) {
            lastPulseAt = Date()
        }
        .accessibilityHidden(true)
    }

    private func draw(context: GraphicsContext, size: CGSize, date: Date) {
        let time = date.timeIntervalSinceReferenceDate
        let midY = size.height / 2
        let width = size.width

        // Breathing amplitude: a slow swell so the wave reads as alive,
        // never frantic. Activity surges ride on top and decay away.
        let breathe = 0.62 + 0.20 * sin(time * 1.35)
        var surge = 0.0
        if let lastPulseAt {
            let elapsed = date.timeIntervalSince(lastPulseAt)
            if elapsed >= 0 {
                surge = 0.55 * exp(-elapsed / 0.45)
            }
        }
        let baseAmplitude = (size.height * 0.34) * min(1.35, breathe + surge)

        let strands: [(phase: Double, amplitude: Double, speed: Double, opacity: Double, lineWidth: Double)] = [
            (0.0, 1.00, 1.9, 1.00, 1.8),
            (.pi * 0.72, 0.74, 1.55, 0.55, 1.5),
            (.pi * 1.38, 0.52, 2.35, 0.32, 1.2),
        ]

        for strand in strands {
            var path = Path()
            let steps = 46
            for step in 0...steps {
                let fraction = Double(step) / Double(steps)
                let x = fraction * width
                // Taper to points at both ends, the icon's silhouette.
                let taper = sin(fraction * .pi)
                let angle = fraction * .pi * 2.45 + time * strand.speed + strand.phase
                let y = midY + CGFloat(sin(angle) * strand.amplitude * baseAmplitude * taper)
                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            var strandContext = context
            strandContext.opacity = strand.opacity
            strandContext.stroke(
                path,
                with: .linearGradient(
                    gradient(for: mood, time: time),
                    startPoint: .zero,
                    endPoint: CGPoint(x: width, y: 0)
                ),
                style: StrokeStyle(
                    lineWidth: strand.lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }

    private func gradient(for mood: Mood, time: TimeInterval) -> Gradient {
        switch mood {
        case .calm:
            let base = scheme == .dark ? 0.72 : 0.42
            return Gradient(colors: [
                Color(white: base, opacity: 0.55),
                Color(white: base, opacity: 0.9),
                Color(white: base, opacity: 0.55),
            ])
        case .listening:
            return Self.sideWaveGradient(for: scheme)
        case .refining(let palette):
            // Slow hue drift so the refine read as active work.
            let stops = palette == .appleIntelligence
                ? Self.appleIntelligenceStops(for: scheme)
                : Self.gemmaStops
            let shift = Int(time * 1.6) % stops.count
            let rotated = Array(stops[shift...] + stops[..<shift])
            return Gradient(colors: rotated.map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2) })
        case .settled:
            return Self.sideWaveGradient(for: scheme)
        }
    }

    // MARK: Palettes

    /// The brand blues, matched to the site accent family (#1f5fbf
    /// light / #6fb2ff dark) with a deep anchor so the braid has depth.
    static func sideWaveGradient(for scheme: ColorScheme) -> Gradient {
        if scheme == .dark {
            return Gradient(colors: [
                Color(.sRGB, red: 0.310, green: 0.600, blue: 1.000),
                Color(.sRGB, red: 0.560, green: 0.780, blue: 1.000),
                Color(.sRGB, red: 0.360, green: 0.680, blue: 0.960),
            ])
        }
        return Gradient(colors: [
            Color(.sRGB, red: 0.122, green: 0.373, blue: 0.749),
            Color(.sRGB, red: 0.180, green: 0.500, blue: 0.900),
            Color(.sRGB, red: 0.100, green: 0.420, blue: 0.700),
        ])
    }

    /// Carried from the original overlay's DesignSystem: the classic
    /// Apple Intelligence stops, jewel-toned for light backgrounds.
    static func appleIntelligenceStops(for scheme: ColorScheme) -> [(Double, Double, Double)] {
        if scheme == .dark {
            return [
                (0.961, 0.725, 0.918),
                (0.776, 0.525, 1.000),
                (0.737, 0.510, 0.953),
                (0.553, 0.624, 1.000),
                (0.667, 0.431, 0.933),
                (1.000, 0.404, 0.471),
                (1.000, 0.729, 0.443),
            ]
        }
        return [
            (0.769, 0.180, 0.525),
            (0.494, 0.224, 0.839),
            (0.478, 0.184, 0.796),
            (0.227, 0.267, 0.753),
            (0.431, 0.184, 0.776),
            (0.824, 0.153, 0.259),
            (0.620, 0.369, 0.059),
        ]
    }

    /// Carried Gemma blues (sampled from the Google palette in the
    /// original overlay).
    static let gemmaStops: [(Double, Double, Double)] = [
        (0.180, 0.482, 0.961),
        (0.357, 0.608, 1.000),
        (0.541, 0.745, 1.000),
        (0.392, 0.604, 0.980),
    ]
}
