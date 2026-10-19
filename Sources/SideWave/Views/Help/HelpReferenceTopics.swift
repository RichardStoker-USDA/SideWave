// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Settings Overview

struct HelpSettingsOverviewContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Simple and Advanced view")
                        .font(.headline)
                }
                Text("Both views share the same Home: Template, Refine model, Output language, Microphone, Send to, and Shortcut. Advanced view adds recording and recognition controls below your recent dictation, plus expert settings. Switching views never changes your models or how dictation runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    HelpDeepLinkButton(label: "Open General Settings", systemImage: "arrow.up.forward", targetPage: nil, targetSettingsTab: .settingsGeneral, spotlightKey: nil)
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Settings panes")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    tabRow("General", "Appearance, window opacity, reduced motion, Advanced view, and the dictation shortcut.", .settingsGeneral)
                    SettingsDivider()
                    tabRow("Speech Recognition", "The speech model, where models are stored, and glossary bundles.", .settingsDictation)
                    SettingsDivider()
                    tabRow("Meetings", "Show or hide Meetings in the main window, and choose the model for meeting notes.", .settingsMeetings)
                    SettingsDivider()
                    tabRow("Refine", "Turn Refine on or off, choose Apple Intelligence or Gemma, and prepare the model. Templates and Formatting Rules are on Home.", .settingsRefine)
                    SettingsDivider()
                    tabRow("Microphone", "Choose and test the microphone and its input channel, set automatic switching and standby, and choose what happens to other audio while you dictate.", .settingsAudio)
                    SettingsDivider()
                    tabRow("Sound Effects", "Sounds for when dictation starts, stops, delivers text, or runs into a problem, and their volume.", .settingsSound)
                    SettingsDivider()
                    tabRow("Overlay", "Size and position the dictation preview, and choose its text style, wave color, and animation.", .settingsOverlay)
                    SettingsDivider()
                    tabRow("Privacy", "How long History keeps dictations, what it stores, and every download and update check.", .settingsPrivacy)
                    SettingsDivider()
                    tabRow("Advanced", "Shortcut timing, the troubleshooting log, experimental features, and resetting SideWave.", .settingsAdvanced, advanced: true)
                    SettingsDivider()
                    tabRow("About", "Version, links, update checks, and Acknowledgments with every third-party license.", .settingsAbout)
                }

                Text("The Advanced pane appears when Advanced view is on. Turning on experimental features there adds an Experimental pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.xs)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "text.badge.checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Links to Settings")
                        .font(.headline)
                }
                Text("Buttons in Help that point to a setting open Settings and briefly highlight that control.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func tabRow(_ name: String, _ desc: String, _ tab: SidebarItem, advanced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(name)
                    .font(.body.weight(.semibold))
                Spacer()
                if advanced && !showAdvancedControls {
                    // The Advanced pane is hidden in Simple view, so point at the switch.
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .semibold))
                        Text("In Advanced view")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    HelpDeepLinkButton(label: "Open \(name)", systemImage: "arrow.up.forward.square", targetPage: nil, targetSettingsTab: tab, spotlightKey: nil)
                }
            }
            Text(desc)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Keyboard Shortcuts

struct HelpKeyboardShortcutsContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("While dictating")
                    .font(.headline)

                HelpShortcutRow(action: "Start / Stop Dictation", keys: appState.hotkeyManager.shortcut.displayString, isAlternate: false)
                HelpShortcutRow(action: "Hold to talk", keys: "Hold \(appState.hotkeyManager.shortcut.displayString)", isAlternate: true)
                HelpShortcutRow(action: "Rewrite and finish (turn on in Settings)", keys: "Hold at stop", isAlternate: false)
                HelpShortcutRow(action: "Paste the last result again", keys: "Double-tap your shortcut", isAlternate: true)
                HelpShortcutRow(action: "Stop and keep on Home, no paste", keys: "Escape", isAlternate: false)
                HelpShortcutRow(action: "Cancel and save to History, no paste", keys: "Control + Escape", isAlternate: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Menu commands")
                    .font(.headline)

                HelpShortcutRow(action: "SideWave Mini", keys: "Command + Shift + M", isAlternate: false)
                HelpShortcutRow(action: "Send to Chosen App", keys: "Command + Shift + T", isAlternate: true)
                HelpShortcutRow(action: "Add Trailing Space", keys: "Command + Shift + Space", isAlternate: false)
                HelpShortcutRow(action: "Light / Dark / System Appearance", keys: "Command + Option + 1 / 2 / 0", isAlternate: true)
                HelpShortcutRow(action: "SideWave Help", keys: "Command + ?", isAlternate: false)
                HelpShortcutRow(action: "Settings", keys: "Command + ,", isAlternate: true)
            }
        }
    }
}

// MARK: - Troubleshooting

struct HelpTroubleshootingContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(Color.warningAmber)
                        .accessibilityHidden(true)
                    Text("Permissions")
                        .font(.headline)
                }
                Text("The readiness message on Home names what's missing. SideWave needs Microphone access to record and Accessibility access for the shortcut and pasting. Use its button to open the right page in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(Color.warningAmber)
                        .accessibilityHidden(true)
                    Text("Model downloads")
                        .font(.headline)
                }
                Text("If a download stays at 0%, check that a firewall, proxy, or VPN isn't blocking huggingface.co, then retry. SideWave keeps the files it already has and repairs incomplete ones, and it checks every Gemma file before using the model.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "mic.slash")
                        .foregroundStyle(Color.warningAmber)
                        .accessibilityHidden(true)
                    Text("No audio, or the preview stays empty")
                        .font(.headline)
                }
                Text("Run Test Microphone in Settings > Microphone. If the level doesn't move, check the device, the permission, and the input channel. With an audio interface, pick the microphone's channel: Auto takes the loudest one, which can be a loopback of computer sound. Reconnect the device or choose another, and wait for Listening before you speak.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(Color.warningAmber)
                        .accessibilityHidden(true)
                    Text("Text doesn't paste")
                        .font(.headline)
                }
                Text("Some secure fields and remote-desktop apps block pasting. Copy the entry from History and paste it yourself, or turn on Also copy text to clipboard on the Dictation tab. Check that SideWave has Accessibility access in System Settings > Privacy & Security.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Privacy

struct HelpPrivacyContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("On your Mac")
                        .font(.headline)
                }
                Text("Speech recognition, Refine, meeting notes, and glossary suggestions run on your Mac. History and recovery files stay on it. Text you paste into another app goes to that app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("No analytics")
                        .font(.headline)
                }
                Text("SideWave sends no analytics or crash reports. It goes online to download models, fetch glossary bundles you ask for, and check for updates if you allow it; those servers see an ordinary connection. Data Transparency lists every download and update check, including failed ones, until you clear it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


// MARK: - Technology & Credits

struct HelpTechnologyAndCreditsContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What SideWave is built on")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: Spacing.md) {
                    moduleRow("FluidAudio", "Runs the speech, voice activity, and speaker models on Apple silicon.")
                    moduleRow("NVIDIA Parakeet TDT 0.6B", "The main speech recognition model, compiled for the Apple Neural Engine.")
                    moduleRow("NVIDIA Parakeet Realtime EOU 120M", "The streaming model behind the gray draft.")
                    moduleRow("NVIDIA Parakeet TDT-CTC 110M", "Checks glossary words against the audio.")
                    moduleRow("Silero VAD v6", "Finds pauses in speech.")
                    moduleRow("NVIDIA Nemotron 3 Diarization", "Labels speakers in meetings.")
                    moduleRow("Gemma 4 and MLX Swift LM", "Google's Gemma 4 models for Refine, run on the GPU with MLX.")
                    moduleRow("NVIDIA NeMo Text Processing", "Writes spoken numbers, dates, and amounts as digits. Included with FluidAudio.")
                    moduleRow("Sparkle", "Checks for updates and verifies their signatures. It sends no system profile.")
                    moduleRow("Swift Markdown", "Formats documents and meeting notes.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Licenses")
                    .font(.headline)
                Text("SideWave is built on open-source models and code. Settings > About > Acknowledgments lists each one with what SideWave uses it for, its license, and the full license and notice text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func moduleRow(_ name: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(name)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Text(desc)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
