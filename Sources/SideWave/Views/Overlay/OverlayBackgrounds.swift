// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

// MARK: - Star Field Background

/// Renders a twinkling star field using Canvas + TimelineView.
/// Stars are randomly positioned with sinusoidal opacity animation at staggered phases.
private struct StarFieldView: View {
    /// Seed-based star layout so positions stay stable across redraws.
    private struct Star {
        let x: Double // 0..1 normalized
        let y: Double // 0..1 normalized
        let radius: CGFloat // 1..3
        let phase: Double // offset for twinkle animation
        let speed: Double // twinkle frequency multiplier
        let baseOpacity: Double // 0.15..0.7
    }

    let reduceMotion: Bool
    private let stars: [Star]

    init(count: Int = 45, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        // Deterministic pseudo-random layout from a fixed seed.
        // Using a simple LCG so it's reproducible without importing GameplayKit.
        var seed: UInt64 = 0xDEAD_BEEF_CAFE
        func nextRandom() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF)
        }

        var generated: [Star] = []
        for _ in 0..<count {
            generated.append(Star(
                x: nextRandom(),
                y: nextRandom(),
                radius: CGFloat(1.0 + nextRandom() * 2.0),
                phase: nextRandom() * .pi * 2,
                speed: 0.3 + nextRandom() * 0.8,
                baseOpacity: 0.15 + nextRandom() * 0.55
            ))
        }
        self.stars = generated
    }

    var body: some View {
        if reduceMotion {
            // Static star field: no twinkling, stars at their base opacity
            Canvas { context, size in
                for star in stars {
                    let center = CGPoint(x: star.x * size.width, y: star.y * size.height)
                    let rect = CGRect(
                        x: center.x - star.radius,
                        y: center.y - star.radius,
                        width: star.radius * 2,
                        height: star.radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Color.white.opacity(star.baseOpacity))
                    )
                }
            }
        } else {
            TimelineView(.animation(minimumInterval: Animate.waveFrameRate30)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate

                Canvas { context, size in
                    for star in stars {
                        let twinkle = sin(time * star.speed + star.phase)
                        // Map sin [-1,1] to [0.3, 1.0] range then scale by baseOpacity
                        let opacity = star.baseOpacity * (0.3 + 0.7 * (twinkle * 0.5 + 0.5))

                        let center = CGPoint(x: star.x * size.width, y: star.y * size.height)
                        let rect = CGRect(
                            x: center.x - star.radius,
                            y: center.y - star.radius,
                            width: star.radius * 2,
                            height: star.radius * 2
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(Color.white.opacity(opacity))
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Cinematic Background Modifier

/// Breathing glow behind the push-to-talk "Release to send" hint: two soft shadows pulse together
/// on a transparent text layer, so the readable text above stays sharp.
struct PTTHaloPulse: ViewModifier {
    @State private var pulse: Bool = false

    func body(content: Content) -> some View {
        content
            .shadow(color: Color.accentColor.opacity(pulse ? 0.55 : 0.30), radius: pulse ? 5 : 3)
            .shadow(color: Color.accentColor.opacity(pulse ? 0.35 : 0.18), radius: pulse ? 14 : 9)
            .animation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .onDisappear { pulse = false }
    }
}

/// Replaces the standard overlay background with a dark space background + stars
/// when cinematic mode is active. Overrides liquid glass to preserve the dark
/// environment the crawl effect needs.
private struct CinematicBackgroundModifier: ViewModifier {
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    private let cornerRadius: CGFloat = CornerRadius.xl

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Deep space black
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(red: 0.02, green: 0.02, blue: 0.04))

                    // Star field behind everything
                    StarFieldView(reduceMotion: reduceMotion)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(0.5),
                radius: 20,
                y: 10
            )
    }
}

// MARK: - Overlay Background Modifier

/// Applies liquid glass when enabled, with a clean dark/light panel fallback
/// when the user has glass toggled off.
private struct OverlayBackgroundModifier: ViewModifier {
    let colorScheme: ColorScheme
    let liquidGlassEnabled: Bool

    /// Corner radius matching the cinematic modifier (14pt) for visual consistency.
    private let cornerRadius: CGFloat = CornerRadius.xl

    func body(content: Content) -> some View {
        if liquidGlassEnabled {
            // Explicitly specify RoundedRectangle as both containerShape and
            // glassEffect shape to prevent Tahoe from defaulting to Capsule,
            // which clips text at rounded top edges.
            content
                .containerShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(
                    shape.fill(Color.overlayBackground(for: colorScheme))
                )
                .clipShape(shape)
                .overlay(
                    shape
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color.black.opacity(0.06),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.15),
                    radius: colorScheme == .dark ? 16 : 8,
                    y: colorScheme == .dark ? 8 : 4
                )
        }
    }
}

// MARK: - Overlay Background Application

/// Applies the correct background modifier without type erasure.
/// Uses @ViewBuilder to statically resolve either cinematic or standard
/// background at compile time, avoiding AnyView dynamic dispatch every frame.
extension View {
    @ViewBuilder
    func overlayBackground(isCinematic: Bool, colorScheme: ColorScheme, liquidGlassEnabled: Bool, reduceMotion: Bool) -> some View {
        if isCinematic {
            self.modifier(CinematicBackgroundModifier(colorScheme: colorScheme, reduceMotion: reduceMotion))
        } else {
            self.modifier(OverlayBackgroundModifier(colorScheme: colorScheme, liquidGlassEnabled: liquidGlassEnabled))
        }
    }
}
