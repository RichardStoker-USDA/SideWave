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
                    Text("Simple and Advanced Views")
                        .font(.headline)
                }
                Text("Simple and Advanced views share the same Home layout. Template, Refine model, output language, microphone, Send to, and shortcut are in both. Advanced view adds recording and recognition controls below your recent dictation, plus expert settings. Switching views never changes your models or how dictation runs.")
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
                Text("Settings Panes")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    tabRow("General", "Appearance, window opacity, reduced motion, Advanced view, and the dictation shortcut.", .settingsGeneral)
                    SettingsDivider()
                    tabRow("Speech Recognition", "The speech model and its download status, plus glossary bundles.", .settingsDictation)
                    SettingsDivider()
                    tabRow("Meetings", "Show or hide Meetings in the main window, and choose the model for meeting notes.", .settingsMeetings)
                    SettingsDivider()
                    tabRow("Refine", "Turn Refine on or off, choose Apple Intelligence or Gemma, and check that the model is ready. Templates and Formatting Rules are on Home.", .settingsRefine)
                    SettingsDivider()
                    tabRow("Microphone", "Choose and test the microphone and its input channel, automatic switching, and what happens to other audio while you dictate.", .settingsAudio)
                    SettingsDivider()
                    tabRow("Sound Effects", "Sounds for when dictation starts, stops, delivers text, or runs into a problem, and their volume.", .settingsSound)
                    SettingsDivider()
                    tabRow("Overlay", "Size and position the dictation preview, and choose its text style, wave color, and animation.", .settingsOverlay)
                    SettingsDivider()
                    tabRow("Privacy", "How long History keeps dictations, what it stores, and a summary of network activity.", .settingsPrivacy)
                    SettingsDivider()
                    tabRow("Advanced", "Shortcut timing, the troubleshooting log, experimental features, and resetting SideWave.", .settingsAdvanced, advanced: true)
                    SettingsDivider()
                    tabRow("About", "Version, links, licenses, and update checks.", .settingsAbout)
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
                Text("Global Session Controls")
                    .font(.headline)

                HelpShortcutRow(action: "Start / Stop Dictation", keys: appState.hotkeyManager.shortcut.displayString, isAlternate: false)
                HelpShortcutRow(action: "Smart Push-to-Talk (hold to talk)", keys: "Hold \(appState.hotkeyManager.shortcut.displayString)", isAlternate: true)
                HelpShortcutRow(action: "Rewrite and finish (enable in Settings)", keys: "Hold at Stop", isAlternate: false)
                HelpShortcutRow(action: "Re-paste last result", keys: "Double-tap your shortcut", isAlternate: true)
                HelpShortcutRow(action: "Stop, keep as pending (no paste)", keys: "Escape", isAlternate: false)
                HelpShortcutRow(action: "Cancel and discard", keys: "Ctrl + Escape", isAlternate: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Main Window Navigation")
                    .font(.headline)

                HelpShortcutRow(action: "Open SideWave Mini", keys: "Cmd + Shift + M", isAlternate: false)
                HelpShortcutRow(action: "Toggle Paste Destination", keys: "Cmd + Shift + T", isAlternate: true)
                HelpShortcutRow(action: "Toggle Trailing Space", keys: "Cmd + Shift + Space", isAlternate: false)
                HelpShortcutRow(action: "Light / Dark / System Theme", keys: "Cmd + Option + 1 / 2 / 0", isAlternate: true)
                HelpShortcutRow(action: "Open Help & Documentation", keys: "Cmd + ?", isAlternate: false)
                HelpShortcutRow(action: "Open Preferences / Settings", keys: "Cmd + ,", isAlternate: true)
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
                    Text("1. System Permission Denials")
                        .font(.headline)
                }
                Text("Read the readiness message first. Microphone access is required to record; Accessibility is required for the global shortcut and text delivery. Use the shown System Settings action to enable the missing permission for the app you are running. SideWave Dev has separate permissions from SideWave.")
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
                    Text("2. Model Download Failures")
                        .font(.headline)
                }
                Text("If the speech or grammar models stay stuck at '0%', make sure no firewall, secure proxy, or VPN is blocking huggingface.co. Retry preparation first. SideWave keeps valid files and repairs incomplete downloads. Gemma preparation checks weight shards, tokenizer files, and the chat template before the model becomes ready. Model storage controls are available if you deliberately want to remove a cached model.")
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
                    Text("3. VAD Audio Dropouts or Stuck Spinners")
                        .font(.headline)
                }
                Text("Open Settings > Microphone and run Test Microphone with the selected input. If the level does not move, check the device, permission, and channel. For an audio interface, select the physical microphone channel in the same Microphone pane. Auto picks the strongest channel, which may be a loopback carrying computer sound. Reconnect a stalled device or choose another input, then retry. Wait for Listening before speaking.")
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
                    Text("4. Target App Paste Rejection")
                        .font(.headline)
                }
                Text("If text does not arrive in a hardened browser field or remote app, open History and copy the finished entry, then paste it manually. Also copy text to clipboard on the Dictation tab keeps future results ready for manual pasting. Also confirm Accessibility is granted for SideWave in System Settings > Privacy & Security.")
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
                    Text("Local Processing and Storage")
                        .font(.headline)
                }
                Text("Speech recognition, Refine, meeting formatting, and vocabulary assistance run on your Mac. History and recovery data are stored locally. Pasting into another app gives that app your text. Optional MCP clients can read the live transcript and may use remote services; connect only clients you intend to trust.")
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
                    Text("Zero Telemetry & Analytics")
                        .font(.headline)
                }
                Text("SideWave has no built-in analytics or automatic crash-report upload service. Model preparation and optional updates use network requests; remote hosts receive ordinary connection metadata. Data Transparency keeps app-managed download and request history until you clear it, including explicit glossary downloads and failed transfers. It is not a system-wide network monitor. A standby microphone setting can keep input open between sessions.")
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
                Text("Underlying Core Modules")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: Spacing.md) {
                    moduleRow("FluidAudio SDK", "On-device speech recognition, voice activity detection, speaker diarization, and speech synthesis. SideWave manages microphone routing, capture, and level meters.")
                    moduleRow("NVIDIA Parakeet TDT 0.6B", "NVIDIA's speech recognition model. Uses a Token-and-Duration Transducer architecture with bidirectional encoders, compiled for the Apple Neural Engine.")
                    moduleRow("NVIDIA Parakeet Realtime EOU 120M", "Streaming recognizer that paints the live gray draft and detects end of utterance, processing 160ms audio chunks on the Neural Engine.")
                    moduleRow("Silero VAD v6", "Lightweight, highly accurate voice activity detection model running on the CPU to segment speech at natural pauses.")
                    moduleRow("MLX Swift LM", "Apple Silicon machine learning framework. Powers high-speed, local Gemma 4 language model inference directly on the GPU.")
                    moduleRow("NVIDIA NeMo ITN", "Inverse text normalization library compiled as a high-performance Rust static bridge to translate spoken forms into written formatting.")
                    moduleRow("Sparkle Framework", "The optional macOS updater. It checks the release feed and verifies signed updates without sending a usage profile.")
                    moduleRow("PocketTTS", "Kyutai's local streaming speech model, converted to CoreML by FluidInference, reads responses supplied by connected MCP clients.")
                    moduleRow("Swift Markdown", "Parses document and meeting text into readable lists, tables, and code blocks without loading remote content.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Open-Source Licensing")
                    .font(.headline)
                Text("SideWave is built on open-source work. Licenses include Apache License 2.0 (FluidAudio, NeMo, CTC 110M, Gemma 4, swift-transformers), MIT License (Silero, Sparkle, MCP SDK, MLX Swift LM, PocketTTS), and Creative Commons Attribution 4.0 (Parakeet TDT and the Alba voice). VoiceZero samples use CC0. Swift Markdown uses Apache 2.0 with the Swift Runtime Library Exception; cmark retains its BSD notices. Detailed license texts can be viewed in the ACKNOWLEDGMENTS file bundled inside the application.")
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
