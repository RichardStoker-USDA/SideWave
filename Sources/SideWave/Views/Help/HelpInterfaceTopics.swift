// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Overlay

struct HelpOverlayContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Static HUD Overlay Preview
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The preview while you dictate")
                    .font(.headline)
                Text("Confirmed words are solid; the live draft after them is gray and can still change:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    let confirmed = Text("We should run the assembly on SCINet, ")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    let provisional = Text("because the lab server keeps running out\u{2026}")
                        .font(.system(.body, design: .rounded, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text("\(confirmed)\(provisional)")
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .continuousCorner(CornerRadius.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                }
            }
        }

        HelpCard {
            HelpOverlayStatesCard()
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Why words don't jump around")
                    .font(.headline)
                Text("As the recognizer hears more, it revises earlier words: punctuation, contractions, a misheard sound. SideWave lines up the new words with the text on screen so your place stays put. Reduce Motion uses a quieter transition.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Position and appearance")
                    .font(.headline)
                Text("The preview floats above other windows at the bottom center of your main display, above the Dock, and grows upward as text arrives.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    bulletRow("Move", "Drag the preview anywhere, on any display. SideWave remembers the spot.")
                    bulletRow("Lock Position", "Right-click the preview and choose Lock Position to stop it from moving.")
                    bulletRow("Reset Position", "Right-click the preview, or open Settings > Overlay, and choose Reset Position to put it back.")
                    bulletRow("Size and style", "Settings > Overlay sets the size, the text style (Standard or Cinematic), the wave color and sensitivity, and the Liquid Glass background. Right-click the preview and choose Expand Overlay for more room.")
                }
            }
        }
    }

    private func bulletRow(_ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(desc)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Audio Devices

struct HelpAudioDevicesContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Choosing a microphone")
                    .font(.headline)
                Text("SideWave lists the built-in, USB, and wireless inputs on your Mac and updates the list as devices come and go. Choose one on Home or in Settings > Microphone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HelpDeepLinkButton(label: "Manage Audio Devices", systemImage: "mic", targetPage: nil, targetSettingsTab: .settingsAudio, spotlightKey: "audio")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "bolt.horizontal.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Microphone standby")
                        .font(.headline)
                }
                Text("Keep microphone on standby, in Settings > Microphone, is off by default. Turned on, it keeps the input open between dictations so recording starts faster. It uses some power, and macOS shows its microphone indicator while the input is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.warningAmber)
                        .accessibilityHidden(true)
                    Text("Bluetooth headsets")
                        .font(.headline)
                }
                Text("Using a Bluetooth headset as the microphone can switch it to a call profile, which lowers both microphone and playback quality.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Text("For the best results, record with the Mac's built-in microphone or a USB mic and keep listening on your Bluetooth headphones. Setup, Home, and Settings > Microphone show a note when a Bluetooth microphone is selected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The wave")
                    .font(.headline)
                Text("The preview's wave follows your microphone level. If it looks too flat or too jumpy, change Wave sensitivity in Settings > Overlay. It doesn't affect recognition.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            HelpAudioRoutingExamples()
        }
    }
}

/// Static side-by-side of the two Bluetooth mic routing setups.
struct HelpAudioRoutingExamples: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Two ways to set up audio")
                .font(.headline)
            
            routingProfile(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "Built-in or USB mic (recommended)",
                rows: [
                    ("AirPods", "Stay on A2DP high-quality playback"),
                    ("Quality", "Full-band stereo"),
                    ("Music", "Keeps its playback quality; volume follows your audio-during-dictation setting")
                ]
            )

            routingProfile(
                icon: "exclamationmark.triangle.fill",
                tint: Color.warningAmber,
                title: "Bluetooth headset as the mic",
                rows: [
                    ("AirPods", "May switch to a call profile"),
                    ("Quality", "Depends on the headset and macOS"),
                    ("Music", "Playback quality may be reduced")
                ]
            )
        }
    }

    private func routingProfile(icon: String, tint: Color, title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(row.1)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .continuousCorner(CornerRadius.lg)
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - History

struct HelpHistoryContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What an entry keeps")
                    .font(.headline)
                Text("Each entry keeps the final text, the app it went to, and the earlier text stages. History stores text only, never audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(.secondary)
                        Text("Mail")
                            .font(.caption.weight(.semibold))
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text("2 minutes ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("19 words")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    historyTextBlock(
                        label: "Refined",
                        text: "I was thinking we should run the assembly on SCINet, because the lab server keeps running out of memory.",
                        italic: false,
                        color: .primary
                    )
                    historyTextBlock(
                        label: "Recognized text (under Show earlier stages)",
                        text: "\"so um i was thinking we should probably you know run the assembly on sign it because the lab server keeps uh running out of memory\"",
                        italic: true,
                        color: .secondary
                    )

                    HStack {
                        Spacer()
                        HelpDeepLinkButton(label: "Open History", systemImage: "arrow.up.forward", targetPage: .history, targetSettingsTab: nil, spotlightKey: nil)
                    }
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Earlier stages")
                    .font(.headline)
                Text("Expand an entry and choose Show earlier stages to see the recognized text and the live draft. The Refine model's name and badge appear only when Refine ran.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Search and copy")
                    .font(.headline)
                Text("Search matches titles, apps, model names, final text, and earlier stages. Copy is on each row; its menu also copies the recognized text or live draft, or deletes the entry.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Storage and retention")
                    .font(.headline)
                Text("History is stored in SideWave's Application Support folder on this Mac. Set how long entries stay with Keep history in Settings > Privacy or at the bottom of History; older entries are deleted automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func historyTextBlock(label: String, text: String, italic: Bool, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .italic(italic)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .continuousCorner(CornerRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
