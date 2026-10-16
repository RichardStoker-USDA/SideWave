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
                Text("What the floating preview shows while you speak:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.green)
                        Text("Dictation Active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "text.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    
                    let confirmed = Text("We should use SCINet for scientific research ")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    let provisional = Text("at ARS because it's a powerful hpc platform\u{2026}")
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
                Text("Why Words Don't Jump Around")
                    .font(.headline)
                Text("As the recognizer gains context it revises earlier words, fixing punctuation, joining contractions, or correcting a misheard sound. SideWave aligns incoming words with the visible text to preserve reading position. Draft text stays gray while confirmed text settles into place. Reduce Motion uses a quieter transition.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Position and appearance")
                    .font(.headline)
                Text("The preview floats above other windows at the bottom center of your main display, just above the Dock. Its visible card stays anchored there as text appears. You can customize its placement:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    bulletRow("Drag to Move", "Drag the preview's background or waveform to any connected display. SideWave remembers where you put it for the next session.")
                    bulletRow("Lock Position", "Right-click the overlay and choose Lock Position to pin it in place. While locked, dragging is disabled until you unlock it.")
                    bulletRow("Reset Position", "Right-click the preview or open Settings > Overlay and choose Reset Position to return it to the bottom center of your main display.")
                    bulletRow("Size Controls", "Choose an overlay size and display mode in Settings > Overlay. Text size follows the selected overlay preset.")
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
                Text("Microphone Selection")
                    .font(.headline)
                Text("SideWave accesses all recording hardware connected to your Mac, listing built-in, USB-wired, and wireless inputs dynamically. Choose your microphone before recording in Settings > Microphone or on Home.")
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
                    Text("Microphone Standby Session")
                        .font(.headline)
                }
                Text("Keep mic on standby in Settings > Microphone is off by default. Enabling it keeps the capture path warm between sessions and can reduce startup delay. Device switching and Bluetooth negotiation may still take time. Wait for Listening before speaking. Keeping input open uses power, and macOS may show its microphone indicator. Turn standby off when you prefer to release the device between sessions.")
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
                    Text("Bluetooth Headset Constraints")
                        .font(.headline)
                }
                Text("Using a Bluetooth headset for input can switch it to a call profile with lower microphone or playback quality. The result depends on the headset and macOS version. Test the selected device before relying on it for a long session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Text("For the best results, capture the mic through your Mac's built-in microphone (or a wired USB mic) and keep output on your Bluetooth headphones. SideWave watches for this and shows a warning during setup if a low-bandwidth Bluetooth input is selected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Visualizer Levels")
                    .font(.headline)
                Text("The overlay wave is driven by your live audio level, measured in decibels relative to full scale (dBFS). If the wave looks too flat or too jumpy for your room, tune the Visualizer Sensitivity knob in Settings > Overlay.")
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
            Text("Two Ways to Route Audio")
                .font(.headline)
            Text("The difference between a clean setup and a tinny one comes down to what handles the mic:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                Text("What an Entry Keeps")
                    .font(.headline)
                Text("History keeps the output, source app, and any available earlier text stages. Recognition is an estimate of what was spoken; it is not an audio record.")
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
                        Text("Processing / audio 0.14x")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    historyTextBlock(
                        label: "Refined",
                        text: "We should use SCINet for scientific research at ARS because it is a very powerful and useful HPC platform.",
                        italic: false,
                        color: .primary
                    )
                    historyTextBlock(
                        label: "Recognition text (Show earlier stages)",
                        text: "\"so, um, i was thinking that, you know, we should probably use SCINet for scientific research at ARS because, well, it's a very powerful and useful HPC platform, you know?\"",
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
                Text("Compare available stages")
                    .font(.headline)
                Text("An entry expands in the same scroll pane. Show earlier stages reveals the available speech-recognition and provisional text. A model name appears only when refinement actually ran. Unrefined push-to-talk sessions have no refinement badge.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Search & Filter")
                    .font(.headline)
                Text("The History search bar filters titles, target apps, model names, final text, and available earlier stages. Use Copy on a row or its menu to copy a particular stage or delete that entry.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Storage & Retention")
                    .font(.headline)
                Text("History lives in SideWave's local Application Support folder. Set how long entries are kept with the Retention picker in Settings > Privacy; older entries are pruned automatically. Copy any entry's text from the History tab, and save meeting transcripts as a Markdown (.md) file from the meeting view.")
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
