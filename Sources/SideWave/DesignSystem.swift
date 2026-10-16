// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Motion

enum Animate {
    static let quick = Animation.spring(response: 0.2, dampingFraction: 0.7)
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.75)
    static let fadeQuick = Animation.easeInOut(duration: 0.15)
    static let waveResponse = Animation.spring(response: 0.12, dampingFraction: 0.7)
    static let appleSmooth = Animation.smooth(duration: 0.45)
    static let appleSnappy = Animation.snappy(duration: 0.25)

    static let waveFrameRate30: TimeInterval = 1.0 / 30.0
    static let waveFrameRate60: TimeInterval = 1.0 / 60.0

    /// Draft text turns white behind a pointer that chases the newest word at
    /// a steady pace, independent of segment timing. This is how many word
    /// positions on each side of the pointer are mid-fade.
    static let tdtTrailFadeWindow: Double = 1.6

    /// Refined words dip and restore their opacity in a staggered ripple.
    static let refinedPulseDuration: TimeInterval = 0.500

    /// The refined sweep fades words from gray to the text color left to
    /// right in about the same total time whatever the segment length.
    static let refinedSweepTotalMs: TimeInterval = 0.800
    static let refinedSweepWordDuration: TimeInterval = 0.220
}

// MARK: - Metrics

enum Spacing {
    static let hairline: CGFloat = 1
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum Size {
    static let documentText: CGFloat = 15
    static let iconSmall: CGFloat = 14
    static let iconXL: CGFloat = 32
    static let iconXXL: CGFloat = 48
}

enum CornerRadius {
    static let badge: CGFloat = 5
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 14
}

enum CoachMarkSize {
    // Points, so the reading size is the same on every display.
    static let width: CGFloat = 500
    static let height: CGFloat = 360
}

/// Window translucency. Opacity is a user setting in Settings > General;
/// the blur and materials are fixed.
enum WindowAppearance {
    static let opacityKey = "windowOpacity"
    static let defaultOpacity: Double = 0.90
    static let blurRadius = 18
}

// MARK: - Colors

extension Color {
    static func primaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(white: 0.9) : Color(white: 0.1)
    }

    static func secondaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(white: 0.68) : Color(white: 0.38)
    }

    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        // controlBackgroundColor follows Increase Contrast as well as appearance.
        Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.95 : 1.0)
    }

    static func cardBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    /// Dictation preview background when Liquid Glass is turned off.
    static func overlayBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.94)
            : Color.white.opacity(0.96)
    }

    static let recordingRed = Color.red

    /// Muted amber for warnings, used instead of the bright system orange.
    static let warningAmber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.88, green: 0.72, blue: 0.30, alpha: 1.0)
            : NSColor(red: 0.78, green: 0.58, blue: 0.15, alpha: 1.0)
    })
}

// MARK: - Preference rows

/// Label on the leading edge and a control on the trailing edge. Stacks
/// when the row is too narrow for both.
struct PreferenceRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.lg) {
                Text(label).font(.callout).fixedSize()
                Spacer(minLength: Spacing.md)
                content
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(label).font(.callout)
                content
            }
        }
    }
}

/// A switch with its label, sharing one size and trailing edge across the app.
struct PreferenceToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: Spacing.md)
            Toggle(title, isOn: $isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .frame(minHeight: 28)
    }
}

/// A native menu in the app's quiet capsule shape.
struct ChoiceMenu<Selection: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }
                .pickerStyle(.inline)
        } label: {
            Text(value).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        // Inline pickers use checkmarks, not the surrounding switch style.
        .toggleStyle(.automatic)
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

// MARK: - Modifiers

extension View {
    /// Clips to a rounded rectangle with continuous corners.
    func continuousCorner(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Quiet grouped surface used for settings and help sections.
    func settingsCardStyle() -> some View {
        modifier(SettingsCardModifier())
    }

    /// Small uppercase label for technical sections.
    func technicalLabel() -> some View {
        font(.system(.caption2, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Color.secondary)
    }

    /// Content fades softly under the toolbar.
    func softScrollEdge() -> some View {
        scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// Standard secondary action: a bordered capsule.
    func actionButton() -> some View {
        font(.callout).controlSize(.large).buttonBorderShape(.capsule).buttonStyle(.bordered)
    }

    /// The one primary action in a view.
    func prominentActionButton() -> some View {
        font(.callout).controlSize(.large).buttonBorderShape(.capsule).buttonStyle(.borderedProminent)
    }

    /// Secondary text with enough contrast on light glass surfaces.
    func adaptiveSecondary() -> some View {
        modifier(AdaptiveSubtleTextModifier(lightOpacity: 0.74, darkOpacity: 0.62))
    }

    /// One step quieter than adaptiveSecondary.
    func adaptiveTertiary() -> some View {
        modifier(AdaptiveSubtleTextModifier(lightOpacity: 0.58, darkOpacity: 0.45))
    }
}

private struct SettingsCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.025), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
    }
}

/// Light-mode secondary and tertiary styles fade on near-white glass, so
/// light mode uses a stronger opacity. Dark mode keeps the system tones.
private struct AdaptiveSubtleTextModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let lightOpacity: Double
    let darkOpacity: Double

    func body(content: Content) -> some View {
        content.foregroundStyle(Color.primaryText(for: colorScheme)
            .opacity(colorScheme == .light ? lightOpacity : darkOpacity))
    }
}

// MARK: - Keycaps

/// One key label drawn like a physical keycap.
struct KeyCapView: View {
    let key: String
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(key: String, compact: Bool = false) {
        self.key = key
        self.compact = compact
    }

    private var dark: Bool { colorScheme == .dark }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: CornerRadius.badge, style: .continuous) }
    private var textColor: Color { dark ? Color.white.opacity(0.85) : Color.primary.opacity(0.75) }
    private var fillColor: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05) }
    private var borderColor: Color { dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12) }
    private var shadowColor: Color { dark ? Color.black.opacity(0.4) : Color.black.opacity(0.12) }

    var body: some View {
        Text(key)
            .font(.system(size: compact ? 9.5 : 11, weight: .semibold, design: .rounded))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 5 : Spacing.xs)
            .padding(.vertical, compact ? Spacing.xxxs : 3)
            .frame(minWidth: compact ? 18 : 22)
            .background(shape.fill(fillColor))
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .shadow(color: shadowColor, radius: 0.5, y: 1)
    }
}

/// A shortcut such as "Option + Space" drawn as a row of keycaps.
struct KeyCapRow: View {
    let displayString: String
    let compact: Bool

    init(displayString: String, compact: Bool = false) {
        self.displayString = displayString
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(Array(displayString.components(separatedBy: " + ").enumerated()), id: \.offset) { _, part in
                let segment = part.trimmingCharacters(in: .whitespaces)
                if !segment.isEmpty { KeyCapView(key: segment, compact: compact) }
            }
        }
    }
}

// MARK: - Window background

/// Frosted window background: a vibrancy material plus an extra blur of the
/// desktop behind the window. Opacity comes from the user setting.
struct WindowBackgroundView: NSViewRepresentable {
    let opacity: Double
    var blurRadius: Int = WindowAppearance.blurRadius
    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    final class Coordinator {
        var effectView: NSVisualEffectView?
        var lastBlurRadius = -1
        var windowObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true

        let effectView = NSVisualEffectView(frame: .zero)
        effectView.blendingMode = .behindWindow
        effectView.isEmphasized = true
        // Stays active when the window loses focus, so the frost doesn't shift.
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.effectView = effectView

        // The blur needs the window, which isn't attached yet.
        let coordinator = context.coordinator
        coordinator.windowObservation = container.observe(\.window, options: [.new]) { [weak coordinator] view, _ in
            MainActor.assumeIsolated {
                guard let coordinator, let window = view.window else { return }
                self.applyBlur(to: window, coordinator: coordinator)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let effectView = context.coordinator.effectView else { return }
        let dark = colorScheme == .dark
        // Materials hosted in SwiftUI need an explicit appearance. The solid
        // backing keeps text legible over bright desktops.
        nsView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        nsView.layer?.backgroundColor = NSColor(white: dark ? 0.10 : 0.96, alpha: CGFloat(opacity)).cgColor
        effectView.material = dark ? .underWindowBackground : .windowBackground
        effectView.alphaValue = CGFloat(opacity)
        if let window = nsView.window {
            applyBlur(to: window, coordinator: context.coordinator)
            window.invalidateShadow()
        }
    }

    private func applyBlur(to window: NSWindow, coordinator: Coordinator) {
        guard blurRadius != coordinator.lastBlurRadius else { return }
        let previous = coordinator.lastBlurRadius
        coordinator.lastBlurRadius = blurRadius
        if blurRadius > 0 || previous > 0 {
            WindowBlurHelper.setBlurRadius(blurRadius, for: window)
        }
    }
}

/// Sets the window server's background blur for a window. This is a private
/// CoreGraphics call; if it's unavailable the window keeps its material only.
enum WindowBlurHelper {
    @discardableResult
    @MainActor
    static func setBlurRadius(_ radius: Int, for window: NSWindow) -> Bool {
        // dlopen(nil) is the main program handle and must not be closed.
        guard let handle = dlopen(nil, RTLD_LAZY),
              let connectionSymbol = dlsym(handle, "CGSDefaultConnectionForThread"),
              let blurSymbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadius")
        else { return false }

        typealias ConnectionFunc = @convention(c) () -> UnsafeMutableRawPointer
        typealias BlurFunc = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
        let connection = unsafeBitCast(connectionSymbol, to: ConnectionFunc.self)
        let setBlur = unsafeBitCast(blurSymbol, to: BlurFunc.self)
        return setBlur(connection(), Int32(window.windowNumber), Int32(max(0, min(30, radius)))) == 0
    }
}

// MARK: - Segmented control

/// Segmented control on a glass track for pickers inside content. The
/// selected segment slides between positions; Reduce Motion skips the slide.
struct GlassSegmentedPicker<Tag: Hashable>: View {
    struct Segment: Identifiable {
        let tag: Tag
        let label: String
        var isEnabled: Bool
        var id: Tag { tag }

        init(_ label: String, tag: Tag, isEnabled: Bool = true) {
            self.label = label
            self.tag = tag
            self.isEnabled = isEnabled
        }
    }

    @Binding var selection: Tag
    let segments: [Segment]
    /// Fill the container with equal segments instead of hugging labels.
    var expands = false
    /// Reserve the longest label's width for every segment so a tight
    /// container can't shrink one label smaller than the others.
    var equalWidths = false
    var accessibilityLabel: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    @State private var hoveredTag: Tag?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segmentButton($0) }
        }
        .padding(Spacing.xxs)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .modifier(OptionalAccessibilityLabel(label: accessibilityLabel))
    }

    @ViewBuilder
    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.tag == selection
        Button {
            guard segment.tag != selection else { return }
            withAnimation(reduceMotion ? nil : Animate.standard) { selection = segment.tag }
        } label: {
            ZStack {
                if equalWidths {
                    // Hidden copies reserve the widest label's width.
                    ForEach(segments) { Text($0.label).font(.callout.weight(.semibold)).lineLimit(1).hidden() }
                }
                Text(segment.label)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.white : Color.primaryText(for: colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: expands ? .infinity : nil)
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                } else if hoveredTag == segment.tag {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
            // Plain buttons don't dim when disabled, so dim them here.
            .opacity(segment.isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!segment.isEnabled)
        .onHover { hovering in
            if hovering { hoveredTag = segment.tag } else if hoveredTag == segment.tag { hoveredTag = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredTag)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Labels the whole control only when a label is given, so each segment
/// stays reachable by VoiceOver.
private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(label) } else { content }
    }
}

// MARK: - Apple Intelligence colors

// One definition for every "Apple Intelligence is working" treatment: the
// wave tint, refined-text glow, and glyph tints. In-app decoration only.
//
// macOS 26 uses the familiar bright stops. macOS 27 uses a softer,
// desaturated treatment for which Apple hasn't published values, so those
// stops are an approximation (saturation x0.75, brightness x0.92). Light
// mode uses deeper versions of the same hues that each stay near 4.5:1 or
// better on white.
extension Color {
    private static let aiStopsDarkClassic: [(Double, Double, Double)] = [
        (0.961, 0.725, 0.918), (0.776, 0.525, 1.000), (0.737, 0.510, 0.953), (0.553, 0.624, 1.000),
        (0.667, 0.431, 0.933), (1.000, 0.404, 0.471), (1.000, 0.729, 0.443),
    ]
    private static let aiStopsDarkTahoe27: [(Double, Double, Double)] = [
        (0.884, 0.721, 0.854), (0.765, 0.592, 0.920), (0.728, 0.571, 0.877), (0.612, 0.661, 0.920),
        (0.675, 0.512, 0.858), (0.920, 0.509, 0.555), (0.920, 0.733, 0.536),
    ]
    private static let aiStopsLightClassic: [(Double, Double, Double)] = [
        (0.769, 0.180, 0.525), (0.494, 0.224, 0.839), (0.478, 0.184, 0.796), (0.227, 0.267, 0.753),
        (0.431, 0.184, 0.776), (0.824, 0.153, 0.259), (0.620, 0.369, 0.059),
    ]
    private static let aiStopsLightTahoe27: [(Double, Double, Double)] = [
        (0.707, 0.301, 0.539), (0.534, 0.348, 0.772), (0.513, 0.310, 0.732), (0.330, 0.357, 0.693),
        (0.476, 0.305, 0.714), (0.758, 0.295, 0.368), (0.570, 0.397, 0.183),
    ]

    private static let aiStopsDark: [(Double, Double, Double)] = {
        if #available(macOS 27, *) { return aiStopsDarkTahoe27 } else { return aiStopsDarkClassic }
    }()
    private static let aiStopsLight: [(Double, Double, Double)] = {
        if #available(macOS 27, *) { return aiStopsLightTahoe27 } else { return aiStopsLightClassic }
    }()

    /// Raw sRGB stops for per-frame interpolation without NSColor round trips.
    static func appleIntelligenceStops(for scheme: ColorScheme) -> [(Double, Double, Double)] {
        scheme == .light ? aiStopsLight : aiStopsDark
    }

    private static let aiGradientDark = Gradient(colors: aiStopsDark.map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2) })
    private static let aiGradientLight = Gradient(colors: aiStopsLight.map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2) })

    /// Cached so the wave renderers don't rebuild a gradient every frame.
    static func appleIntelligenceGradient(for scheme: ColorScheme) -> Gradient {
        scheme == .light ? aiGradientLight : aiGradientDark
    }

    /// Diagonal gradient for tinting the apple.intelligence symbol, which
    /// has no built-in multicolor palette.
    static func appleIntelligenceGlyphGradient(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(gradient: appleIntelligenceGradient(for: scheme), startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
