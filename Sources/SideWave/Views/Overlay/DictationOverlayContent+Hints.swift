// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

extension DictationOverlayContent {
    @ViewBuilder
    var targetPickerRow: some View {
        HStack(spacing: Spacing.xs) {
            if let icon = cachedRunningApps.first(where: { $0.pid == appState.assignedAppPID })?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: Size.iconSmall, height: Size.iconSmall)
            } else {
                Image(systemName: "macwindow")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let name = appState.assignedAppName {
                Text(name)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No target set")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Menu {
                ForEach(cachedRunningApps) { app in
                    let windows = WindowTargetingService.windows(for: app.pid)
                    if windows.count > 1 {
                        Menu {
                            Button {
                                appState.assignTarget(pid: app.pid, name: app.name)
                            } label: {
                                Label("Any Window", systemImage: "macwindow")
                            }
                            Divider()
                            ForEach(windows) { window in
                                Button {
                                    appState.assignWindow(window)
                                } label: {
                                    Label(window.title, systemImage: "macwindow.on.rectangle")
                                }
                            }
                        } label: {
                            if let icon = app.icon {
                                Label { Text(app.name) } icon: { Image(nsImage: icon) }
                            } else {
                                Label(app.name, systemImage: "macwindow")
                            }
                        }
                    } else {
                        Button {
                            if let window = windows.first {
                                appState.assignWindow(window)
                            } else {
                                appState.assignTarget(pid: app.pid, name: app.name)
                            }
                        } label: {
                            if let icon = app.icon {
                                Label { Text(app.name) } icon: { Image(nsImage: icon) }
                            } else {
                                Label(app.name, systemImage: "macwindow")
                            }
                        }
                    }
                }

                if appState.assignedAppPID != nil {
                    Divider()
                    Button("Clear Target") {
                        appState.clearAssignedTarget()
                    }
                }
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(.caption))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Choose dictation target")
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation target: \(appState.assignedAppName ?? "No target set")")
    }

    @ViewBuilder
    var hintTextView: some View {
        HStack(spacing: Spacing.md) {
            // Crossfade between the toggle hint and the push-to-talk hint on every text change.
            // During a push-to-talk hold the hint is larger and emphasized so "release to send" is
            // easy to see.
            Group {
                if isInSmartPTTHold {
                    pttHintPill
                } else {
                    Text(hintText)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(hintForegroundStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .id(hintText)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 2)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: hintText)
            Spacer(minLength: 0)
            if shouldShowTokenCounter {
                tokenCounterBadge
            }
        }
    }

    /// The push-to-talk hint: larger accent-colored text with a soft breathing glow and a thin
    /// drifting underline that echoes the wave. Static with Reduce Motion.
    @ViewBuilder
    private var pttHintPill: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack {
                if !reduceMotion {
                    // Soft breathing halo behind the hint. Single layer
                    // with the same shape as the visible foreground so
                    // the glow tracks the text + keycap exactly.
                    pttHintForeground
                        .opacity(0.001)
                        .modifier(PTTHaloPulse())
                }
                pttHintForeground
            }
            .lineLimit(1)
            .truncationMode(.tail)

            pttWaveUnderline
                .frame(height: 2)
        }
        .accessibilityLabel(hintText)
    }

    /// The visible content of the hint pill. During Smart-PTT hold the
    /// hotkey appears as a keycap badge so the "what to release" cue is
    /// instantly readable. Other states render the full text run.
    @ViewBuilder
    private var pttHintForeground: some View {
        let compactDisplay = appState.hotkeyManager.shortcut.compactDisplayString
        let isToggleMode = appState.hotkeyManager.activationMode == .toggle
        let pttRefining = appState.smartPTTAlwaysRefine && appState.dictationCleanupEnabled
        if isToggleMode && isInSmartPTTHold {
            HStack(spacing: 5) {
                Text("Release")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                KeyCapRow(displayString: compactDisplay, compact: true)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(pttRefining ? "to refine and send" : "to send")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            Text(hintText)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    /// Thin underline drifting under the push-to-talk hint: two gradients with sine offsets, same 4
    /// s period, opposite phase, so the loop has no visible seam.
    @ViewBuilder
    private var pttWaveUnderline: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let period: Double = 4.0
            let t = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            let angle = t * 2 * Double.pi
            let primaryOffset = CGFloat(sin(angle))
            let secondaryOffset = CGFloat(sin(angle + Double.pi / 2))
            let primaryBreathe = 0.45 + 0.35 * (1 + sin(angle)) / 2
            let secondaryBreathe = 0.18 + 0.18 * (1 + sin(angle + Double.pi)) / 2

            let primaryStops: [Gradient.Stop] = [
                .init(color: Color.accentColor.opacity(0.0), location: 0),
                .init(color: Color.accentColor.opacity(0.95), location: 0.5),
                .init(color: Color.accentColor.opacity(0.0), location: 1),
            ]
            let secondaryStops: [Gradient.Stop] = [
                .init(color: Color.accentColor.opacity(0.0), location: 0),
                .init(color: Color.accentColor.opacity(0.55), location: 0.5),
                .init(color: Color.accentColor.opacity(0.0), location: 1),
            ]

            GeometryReader { geo in
                ZStack {
                    Capsule(style: .continuous)
                        .fill(LinearGradient(stops: secondaryStops, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width)
                        .offset(x: reduceMotion ? 0 : secondaryOffset * geo.size.width * 0.18)
                        .opacity(reduceMotion ? 0.3 : secondaryBreathe)
                        .blur(radius: 2)

                    Capsule(style: .continuous)
                        .fill(LinearGradient(stops: primaryStops, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width)
                        .offset(x: reduceMotion ? 0 : primaryOffset * geo.size.width * 0.28)
                        .opacity(reduceMotion ? 0.55 : primaryBreathe)
                }
            }
        }
    }

    /// True when the user's start-press hold has crossed the smart-PTT
    /// threshold and a release will commit the dictation as raw paste.
    private var isInSmartPTTHold: Bool {
        appState.hotkeyManager.isSmartPTTHolding
    }

    private var hintText: String {
        let shortcutDisplay = appState.hotkeyManager.shortcut.displayString
        if appState.dictationSessionPhase == .finishing { return appState.cleanupStatus }
        if isWarmingUp {
            // The warm-up body already says it's starting, so the hint only shows how to cancel.
            return "Esc to cancel"
        }
        switch appState.hotkeyManager.activationMode {
        case .toggle:
            if isInSmartPTTHold {
                // Smart PTT in flight. Wording reflects whether the user
                // opted into "Always refine" so the hint matches what will
                // actually happen on release.
                if appState.smartPTTAlwaysRefine && appState.dictationCleanupEnabled {
                    return "Release \(shortcutDisplay) to refine and send"
                }
                return "Release \(shortcutDisplay) to send"
            }
            if appState.hotkeyManager.holdToRewriteEnabled && appState.dictationCleanupEnabled {
                return "Tap \(shortcutDisplay) to finish · Hold to rewrite and finish · Esc to pause"
            }
            return "Tap \(shortcutDisplay) to finish and send · Esc to pause"
        case .pushToTalk:
            return "Release to send  \u{00B7}  Esc to save"
        }
    }

    /// Style for the refine glyphs (the Refine header and the document "Formatting…" label), in the
    /// active backend's colors to match the wave: the Apple Intelligence gradient or Gemma blue.
    var refineGlyphStyle: AnyShapeStyle {
        switch appState.dictationFormatter.activeBackend {
        case .appleIntelligence, .appleIntelligenceLegacy:
            return AnyShapeStyle(Color.appleIntelligenceGlyphGradient(for: colorScheme))
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            return AnyShapeStyle(LinearGradient(
                colors: GemmaPalette.glyphColors(for: colorScheme),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }

    /// The hint uses the accent color during a push-to-talk hold and secondary text otherwise.
    private var hintForegroundStyle: AnyShapeStyle {
        if isCinematic {
            return AnyShapeStyle(Color.white.opacity(0.25))
        }
        if isInSmartPTTHold {
            return AnyShapeStyle(Color.accentColor.opacity(0.85))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.6))
    }
}
