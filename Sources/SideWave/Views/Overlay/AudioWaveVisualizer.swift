// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

// MARK: - Audio Wave Visualizer

/// Which refine backend is running. Apple Intelligence uses the purple and pink palette, Gemma a
/// blue one.
enum RefiningBackendForPalette: Hashable {
    case appleIntelligence
    case gemma
}


/// Gemma palette for the refined-text bloom. The wave uses its own brighter set
/// (`gemmaCleanupPalette`); the text needs a light-mode variant because the near-white stops would
/// vanish on the light overlay. The Apple Intelligence colors come from
/// `Color.appleIntelligenceStops(for:)` in DesignSystem.
enum GemmaPalette {
    static let dark: [(Double, Double, Double)] = [
        (0.180, 0.482, 0.961),
        (0.357, 0.608, 1.000),
        (0.847, 0.918, 1.000),
        (0.965, 0.980, 1.000),
        (0.541, 0.745, 1.000),
        (0.392, 0.604, 0.980),
    ]
    /// Deeper Google-blue set, legible on white.
    static let light: [(Double, Double, Double)] = [
        (0.098, 0.318, 0.749),
        (0.145, 0.400, 0.808),
        (0.192, 0.451, 0.831),
        (0.110, 0.353, 0.706),
        (0.216, 0.435, 0.792),
        (0.157, 0.353, 0.741),
    ]
    static func stops(for scheme: ColorScheme) -> [(Double, Double, Double)] {
        scheme == .light ? light : dark
    }

    /// Saturated subset for small glyph tints (the Refine header sparkles).
    /// Skips the near-white dark-scheme stops — at caption size they wash
    /// the glyph out; the deep-to-bright blues keep it legible both schemes.
    static func glyphColors(for scheme: ColorScheme) -> [Color] {
        let source = scheme == .light
            ? light
            : [dark[0], dark[1], dark[4], dark[5]]
        return source.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    }
}

/// Overlapping sine waves along the bottom of the overlay, in spectrum or accent colors. They
/// ripple gently in silence and grow with speech.
struct AudioWaveVisualizer: View {
    let audioLevel: Double
    let colorMode: String // "rainbow" or "accent"
    let sensitivity: Double // 0.0 to 1.0, amplifies raw RMS
    let liquidGlass: Bool // apply glass treatment on macOS 26+
    var isCleanupMode: Bool = false // steady traveling wave for AI cleanup phase
    /// True while a segment refine runs during dictation. The wave keeps reacting to audio but
    /// switches to the refine backend's palette.
    var isRefining: Bool = false
    /// Warmup / initializing state. Gently ripples in accent color.
    var isWarmingUp: Bool = false
    /// Which backend is refining, for the palette. Defaults to Apple Intelligence.
    var refiningBackend: RefiningBackendForPalette = .appleIntelligence
    var frameRateInterval: TimeInterval = Animate.waveFrameRate30
    var isIdleBreathing: Bool = false
    let accessibilityLabelOverride: String?
    let accessibilityValueOverride: String?
    @State private var smoothedLevel: Double = 0
    /// A fixed clock for offscreen previews; live sessions use TimelineView.
    var sampleTime: TimeInterval?

    init(
        audioLevel: Double,
        colorMode: String,
        sensitivity: Double,
        liquidGlass: Bool,
        isCleanupMode: Bool = false,
        isRefining: Bool = false,
        isWarmingUp: Bool = false,
        refiningBackend: RefiningBackendForPalette = .appleIntelligence,
        frameRateInterval: TimeInterval = Animate.waveFrameRate30,
        isIdleBreathing: Bool = false,
        reduceMotion: Bool = false,
        accessibilityLabelOverride: String? = nil,
        accessibilityValueOverride: String? = nil,
        sampleTime: TimeInterval? = nil
    ) {
        self.audioLevel = audioLevel
        self.colorMode = colorMode
        self.sensitivity = sensitivity
        self.liquidGlass = liquidGlass
        self.isCleanupMode = isCleanupMode
        self.isRefining = isRefining
        self.isWarmingUp = isWarmingUp
        self.refiningBackend = refiningBackend
        self.frameRateInterval = frameRateInterval
        self.isIdleBreathing = isIdleBreathing
        self.reduceMotion = reduceMotion
        self.accessibilityLabelOverride = accessibilityLabelOverride
        self.accessibilityValueOverride = accessibilityValueOverride
        self.sampleTime = sampleTime

        let multiplier = 1.0 + sensitivity * 7.0
        let amplified = min(audioLevel * multiplier, 1.0)
        let curved = pow(amplified, 0.55)
        self._smoothedLevel = State(initialValue: curved)
    }
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var effectLevel: Double {
        // In cleanup mode, use a steady breathing amplitude instead of audio input
        if isCleanupMode {
            return 0.25
        }
        if isWarmingUp {
            return 0.08
        }
        return smoothedLevel < 0.01 ? 0 : smoothedLevel
    }

    // Small idle amplitude so waves gently ripple even when silent
    private var amplitude: Double {
        if isWarmingUp {
            return 0.04
        }
        return 0.22 + effectLevel * 0.78
    }



    /// Gemma refine palette, from Gemma 4 brand imagery: blue to near-white and back, so the wave
    /// pulses light and dark the way the purple and pink reads as Apple Intelligence. Wave only;
    /// the text bloom uses `GemmaPalette`, which has a light-mode variant.
    private static let gemmaCleanupPalette: [Color] = [
        Color(red: 0.180, green: 0.482, blue: 0.961),  // deep Google blue
        Color(red: 0.357, green: 0.608, blue: 1.000),  // bright sky blue
        Color(red: 0.847, green: 0.918, blue: 1.000),  // very light blue
        Color(red: 0.965, green: 0.980, blue: 1.000),  // near-white (cool)
        Color(red: 0.541, green: 0.745, blue: 1.000),  // soft sky
        Color(red: 0.392, green: 0.604, blue: 0.980),  // periwinkle blue
    ]

    /// Gradients for the fixed palettes, built once instead of per wave layer per frame.
    private static let rainbowGradient = Gradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple])
    private static let gemmaCleanupGradient = Gradient(colors: gemmaCleanupPalette)

    /// Gradient for rainbow strokes, switching to the backend palette while a segment refine runs.
    /// Cached, so no allocation per frame.
    private var activeRainbowGradient: Gradient {
        guard isRefining else { return Self.rainbowGradient }
        switch refiningBackend {
        case .appleIntelligence: return Color.appleIntelligenceGradient(for: colorScheme)
        case .gemma:             return Self.gemmaCleanupGradient
        }
    }

    /// Fixed time value for the static resting wave when Reduce Motion is on.
    /// Produces a pleasant mid-amplitude sine shape without any movement.
    private static let staticTime: TimeInterval = 2.5

    /// One precomputed sample per stride point along the wave's width.
    typealias WaveSample = (x: CGFloat, relX: Double, env: Double, twoPiRelX: Double)

    /// Edge envelope per canvas width. `pow(sin(.pi * relX), 1.5)` depends only on width, but was
    /// computed for every point of every wave each frame, the most expensive step in the loop.
    /// Computed once per width; the overlay width rarely changes.
    private static var envelopeCache: (width: Int, samples: [WaveSample])?

    @MainActor
    static func waveEnvelopeSamples(forWidth width: CGFloat) -> [WaveSample] {
        guard width > 0 else { return [] }
        let key = Int(width.rounded())
        if let cache = envelopeCache, cache.width == key {
            return cache.samples
        }

        var samples: [WaveSample] = []
        samples.reserveCapacity(Int(width / 2) + 2)
        for x in stride(from: 0 as CGFloat, through: width, by: 2) {
            let relX = Double(x / width)
            samples.append((x, relX, pow(sin(.pi * relX), 1.5), 2.0 * .pi * relX))
        }

        envelopeCache = (key, samples)
        return samples
    }

    var body: some View {
        Group {
            if let sampleTime {
                renderedFrame(at: sampleTime)
            } else if reduceMotion {
                renderedFrame(at: Self.staticTime)
            } else {
                TimelineView(.animation(minimumInterval: frameRateInterval)) { timeline in
                    renderedFrame(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(height: 30)
        .onChange(of: audioLevel) { _, newValue in
            // Amplify based on sensitivity setting
            // sensitivity 0.0 = 1x multiplier, 1.0 = 8x multiplier
            let multiplier = 1.0 + sensitivity * 7.0
            let amplified = min(newValue * multiplier, 1.0)
            // Power curve to make quiet sounds more visible
            let curved = pow(amplified, 0.55)
            smoothedLevel = smoothedLevel * 0.6 + curved * 0.4
        }
        .animation(reduceMotion ? nil : Animate.waveResponse, value: smoothedLevel)
        .accessibilityLabel(
            accessibilityLabelOverride ?? (
                isCleanupMode ? "Refining visualizer" :
                isWarmingUp ? "Warmup visualizer" :
                isRefining ? "Refinement visualizer" : "Audio level visualizer"
            )
        )
        .accessibilityValue(
            accessibilityValueOverride ?? (
                isCleanupMode ? "Refining your dictation" :
                isWarmingUp ? "Downloading models or initializing" :
                isRefining ? "Refining your dictation" :
                (smoothedLevel > 0.1 ? "Active, level \(Int(smoothedLevel * 100)) percent" : "Silent")
            )
        )
    }

    /// Both layers share one clock; the still path freezes phase, not microphone feedback.
    @ViewBuilder
    func renderedFrame(at time: TimeInterval) -> some View {
        let phase = reduceMotion ? Self.staticTime : time
        if isCleanupMode {
            ZStack {
                cleanupCanvasView(time: phase).blur(radius: 5).opacity(0.4)
                cleanupCanvasView(time: phase)
            }
        } else {
            ZStack {
                waveCanvasView(time: phase).blur(radius: liquidGlass ? 6 : 4)
                    .opacity(0.30 + effectLevel * 0.20)
                waveCanvasView(time: phase)
            }
        }
    }

    /// Raw Canvas drawing for a single wave layer. Accepts a pre-computed
    /// time value so the caller can share one TimelineView across layers.
    private func waveCanvasView(time: TimeInterval) -> some View {
        Canvas { context, size in
            let waveCount = 4
            let midY = size.height / 2
            let yScale = size.height * 0.45
            // Envelope + relX precomputed once per width (see waveEnvelopeSamples).
            let samples = Self.waveEnvelopeSamples(forWidth: size.width)

            let currentAmplitude: Double
            if isIdleBreathing {
                // Modulate amplitude between 0.55 and 0.80 on a slow 3.0s cycle
                currentAmplitude = 0.68 + 0.12 * sin(time * 2.0 * .pi / 3.0)
            } else {
                currentAmplitude = amplitude
            }

            for i in 0..<waveCount {
                let waveAmplitude = currentAmplitude * (1.0 - Double(i) * 0.18)
                let frequency = 1.5 + Double(i) * 0.35
                let phase = time * (1.2 + Double(i) * 0.25) + Double(i) * 0.7
                let lineWidth = max(1.0, 2.5 - Double(i) * 0.4)
                let opacity = 0.85 - Double(i) * 0.15

                var path = Path()

                for (idx, sample) in samples.enumerated() {
                    let sine = sin(frequency * sample.twoPiRelX + phase)
                    // Envelope tapers the edges for an organic look (cached).
                    let y = midY + sine * waveAmplitude * yScale * sample.env

                    if idx == 0 {
                        path.move(to: CGPoint(x: sample.x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: sample.x, y: y))
                    }
                }

                if isWarmingUp {
                    // Muted, calm, breathing periwinkle/accent wave during warmup
                    context.stroke(
                        path,
                        with: .color(Color.accentColor.opacity(opacity * 0.35)),
                        style: StrokeStyle(lineWidth: lineWidth * 0.9, lineCap: .round)
                    )
                } else if colorMode == "cinematic" {
                    // Muted gray waves so text is the focus
                    context.stroke(
                        path,
                        with: .color(Color.white.opacity(opacity * 0.25)),
                        style: StrokeStyle(lineWidth: lineWidth * 0.8, lineCap: .round)
                    )
                } else if colorMode == "rainbow" {
                    context.stroke(
                        path,
                        with: .linearGradient(
                            activeRainbowGradient,
                            startPoint: CGPoint(x: 0, y: midY),
                            endPoint: CGPoint(x: size.width, y: midY)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                } else if isRefining {
                    // Accent mode still shows the backend palette while a refine runs; the accent
                    // color is for the resting state.
                    let gradient: Gradient
                    switch refiningBackend {
                    case .appleIntelligence: gradient = Color.appleIntelligenceGradient(for: colorScheme)
                    case .gemma:             gradient = Self.gemmaCleanupGradient
                    }
                    context.stroke(
                        path,
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: 0, y: midY),
                            endPoint: CGPoint(x: size.width, y: midY)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                } else {
                    context.stroke(
                        path,
                        with: .color(Color.accentColor.opacity(opacity)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                }
            }
        }
    }

    /// Cleanup-mode ribbons. Three overlapping sines with breathing amplitude
    /// and a sliding linear gradient that makes the palette appear to flow
    /// through the wave.
    private func cleanupCanvasView(time: TimeInterval) -> some View {
        Canvas { context, size in
            let midY = size.height / 2
            let ribbonCount = 3
            let yScale = size.height * 0.45
            // Envelope + relX precomputed once per width (see waveEnvelopeSamples).
            let samples = Self.waveEnvelopeSamples(forWidth: size.width)
            // Breathing amplitude: 0.18 -> 0.55 on a 1.6s cosine ease
            let breath = 0.18 + 0.37 * (0.5 - 0.5 * cos(time * 2 * .pi / 1.6))
            // Gradient slide: the palette shifts one width every 2.4s
            let slidePhase = (time.truncatingRemainder(dividingBy: 2.4)) / 2.4
            let slideX = slidePhase * size.width

            for i in 0..<ribbonCount {
                let waveAmplitude = breath * (1.0 - Double(i) * 0.15)
                let frequency = 1.4 + Double(i) * 0.3
                let phase = time * (0.9 + Double(i) * 0.18) + Double(i) * 0.6
                let lineWidth = max(1.2, 2.2 - Double(i) * 0.35)

                var path = Path()
                for (idx, sample) in samples.enumerated() {
                    let sine = sin(frequency * sample.twoPiRelX + phase)
                    let y = midY + sine * waveAmplitude * yScale * sample.env
                    if idx == 0 {
                        path.move(to: CGPoint(x: sample.x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: sample.x, y: y))
                    }
                }

                // Sliding linear gradient: startPoint moves left-to-right over
                // time so the palette visibly travels through each ribbon.
                let startX = slideX - size.width
                let endX = slideX + size.width
                // The end-of-session pass uses the active backend's palette too, with the
                // light-overlay variant in light mode.
                let gradient: Gradient
                switch refiningBackend {
                case .appleIntelligence: gradient = Color.appleIntelligenceGradient(for: colorScheme)
                case .gemma:             gradient = Self.gemmaCleanupGradient
                }
                context.stroke(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: startX, y: midY),
                        endPoint: CGPoint(x: endX, y: midY)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }
        }
    }
}

extension AudioWaveVisualizer: Equatable {
    nonisolated static func == (lhs: AudioWaveVisualizer, rhs: AudioWaveVisualizer) -> Bool {
        MainActor.assumeIsolated {
            abs(lhs.audioLevel - rhs.audioLevel) < 0.01 &&
            lhs.colorMode == rhs.colorMode &&
            lhs.sensitivity == rhs.sensitivity &&
            lhs.liquidGlass == rhs.liquidGlass &&
            lhs.isCleanupMode == rhs.isCleanupMode &&
            lhs.isRefining == rhs.isRefining &&
            lhs.isWarmingUp == rhs.isWarmingUp &&
            lhs.refiningBackend == rhs.refiningBackend &&
            lhs.frameRateInterval == rhs.frameRateInterval &&
            lhs.isIdleBreathing == rhs.isIdleBreathing &&
            lhs.reduceMotion == rhs.reduceMotion &&
            lhs.sampleTime == rhs.sampleTime &&
            lhs.accessibilityLabelOverride == rhs.accessibilityLabelOverride &&
            lhs.accessibilityValueOverride == rhs.accessibilityValueOverride
        }
    }
}
