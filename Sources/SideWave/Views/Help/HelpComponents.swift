// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Shared Help Components

/// Related help steps share the same calm surface as settings groups.
struct HelpCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) { content() }
            .padding(Spacing.lg).settingsCardStyle()
    }
}

/// Item with title and body text
struct HelpItem: View {
    let title: String
    let content: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.body.weight(.medium))
            Text(content)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A short note under a topic, in the secondary text color.
struct HelpHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Key-value row for keyboard shortcuts with keycap-styled key labels
struct HelpShortcutRow: View {
    let action: String
    let keys: String
    let isAlternate: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var keySegments: [String] {
        keys.components(separatedBy: " + ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(action)
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer(minLength: Spacing.lg)

            HStack(spacing: Spacing.xxxs) {
                ForEach(Array(keySegments.enumerated()), id: \.offset) { _, segment in
                    KeyCapView(key: segment)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(
            isAlternate
                ? Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03)
                : Color.clear
        )
    }
}

// MARK: - Shared Help Illustrations (static, no timers)

/// Static hotkey-flow diagram: Start, Speak, Finish, Output. Built from the
/// design system's keycap + SF Symbols, no animation.
struct HelpHotkeyFlow: View {
    let keyLabel: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            node(icon: nil, key: keyLabel, title: "Press", detail: "Tap to start")
            connector
            node(icon: "waveform", key: nil, title: "Speak", detail: "Overlay shows live text")
            connector
            node(icon: nil, key: keyLabel, title: "Finish", detail: "Tap again, then wait for processing")
            connector
            node(icon: "text.cursor", key: nil, title: "Output", detail: "Paste or review a document")
        }
        .frame(maxWidth: .infinity)
    }

    private var connector: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 15)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func node(icon: String?, key: String?, title: String, detail: String) -> some View {
        VStack(spacing: Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
                    .frame(width: 54, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                if let key {
                    Text(key)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 78)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Static three-stage mock of the live preview overlay. Freshly heard words
/// show gray, sweep to white as they lock in, then refine.
struct HelpOverlayStatesCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("How words settle in the overlay")
                .font(.headline)
            Text("The streaming model shows a provisional draft while you talk. Parakeet then processes each segment with more context and confirms or corrects it. Refine can revise the confirmed text again. The stronger text tone follows your light or dark appearance; it does not guarantee that every word is correct. Review the delivered result.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            stageRow(tag: "Draft (fast)", white: "", gray: "we should use sign it for scientific research")
            stageRow(tag: "Confirmed", white: "We should use SCINet", gray: " for scientific research")
            stageRow(tag: "Refined", white: "We should use SCINet for scientific research.", gray: "")

            HStack(spacing: Spacing.lg) {
                legend(color: Color.secondary.opacity(0.55), label: "Gray, still forming")
                legend(color: .primary, label: "Confirmed text")
            }
            .padding(.top, 2)
        }
    }

    private func stageRow(tag: String, white: String, gray: String) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Text(tag)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                let confirmed = Text(white).foregroundStyle(.primary)
                let provisional = Text(gray).foregroundStyle(Color.secondary.opacity(0.55))
                Text("\(confirmed)\(provisional)")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .continuousCorner(CornerRadius.md)
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1))
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 18, height: 6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A static mock of a control row that names where the real control lives.
struct HelpSettingLocationRow: View {
    let icon: String
    let title: String
    let valueMock: String
    let location: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(valueMock)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
            .padding(Spacing.sm)
            .background(.ultraThinMaterial)
            .continuousCorner(CornerRadius.md)
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1))

            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
        }
    }
}

/// Inline note shown only in simple view: the referenced controls live in the
/// advanced view, reachable via the Advanced View switch (SideWave menu, menu
/// bar icon, Settings toolbar, or Settings > General).
/// Self-gating (renders nothing once the advanced view is on).
struct HelpAdvancedNote: View {
    var text: String = "These are advanced controls. Turn on Advanced View (in the SideWave menu, or Settings > General) to see them."
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false

    var body: some View {
        if !showAdvancedControls {
            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
