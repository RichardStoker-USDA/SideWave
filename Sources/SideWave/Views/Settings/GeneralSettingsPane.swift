// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(WindowAppearance.opacityKey) private var windowOpacity = WindowAppearance.defaultOpacity
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    @State private var isRecordingShortcut = false
    @State private var infoTopic: InfoTopic?

    var body: some View {
        SettingsCard {
            SettingsRow(label: "Appearance") {
                GlassSegmentedPicker(
                    selection: $appearance,
                    segments: [.init("System", tag: "system"), .init("Light", tag: "light"), .init("Dark", tag: "dark")],
                    equalWidths: true,
                    accessibilityLabel: "Appearance"
                )
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("Window opacity").font(.callout)
                    Spacer()
                    Text("\(Int(windowOpacity * 100))%")
                        .font(.callout.monospacedDigit()).adaptiveSecondary()
                }
                Slider(value: $windowOpacity, in: 0.5...1.0, step: 0.02)
                    .accessibilityLabel("Window opacity")
                    .accessibilityValue("\(Int(windowOpacity * 100)) percent")
                Text("How much of the desktop shows through SideWave's windows.")
                    .settingsCaption()
            }
            SettingsDivider()
            SettingsToggleRow("Reduce motion",
                              caption: "Uses still text and a calmer wave in the preview and main window.",
                              isOn: $appState.reduceAppMotion)
            SettingsDivider()
            SettingsToggleRow("Advanced view",
                              caption: "Shows expert controls throughout the app. Also in the SideWave menu and the menu bar.",
                              isOn: $showAdvancedControls)
        }

        SettingsCard("Dictation shortcut") {
            SettingsRow(label: "Shortcut") {
                HotkeyRecorderButton(shortcut: appState.hotkeyManager.shortcut,
                                     isRecording: $isRecordingShortcut,
                                     onRecord: { appState.saveShortcut($0) })
                    .help("Click, then press the key or combination you want")
                    .accessibilityLabel("Change dictation shortcut")
            }
            Text("Tap the shortcut to start, wait for Listening, then tap again to finish. Ordinary templates paste into your app; document templates open in the document window.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)

            if showAdvancedControls {
                SettingsDivider()
                SettingsToggleRow("Hold to rewrite and finish",
                                  caption: "Hold the shortcut when you stop, then release to rewrite the whole dictation before it's sent. This takes longer.",
                                  isOn: Binding(get: { appState.hotkeyManager.holdToRewriteEnabled },
                                                set: { appState.hotkeyManager.holdToRewriteEnabled = $0 }),
                                  info: { infoTopic = .holdToRewrite })
                    .disabled(appState.transcriptionService.isRecording)
            }

            SettingsDivider()
            gestureRow("Smart Push-to-Talk", icon: "hand.tap",
                       summary: "Hold for a short reply, then release to finish.", topic: .smartPushToTalk)
            SettingsDivider()
            gestureRow("Double-tap to paste again", icon: "arrow.uturn.right",
                       summary: "Paste your last result without dictating.", topic: .doubleTapRepaste)
        }
        .settingsSpotlight(key: "hotkey", appState: appState)
        .sheet(item: $infoTopic) { InfoSheet(topic: $0) }
        .onChange(of: isRecordingShortcut) { _, recording in appState.hotkeyManager.isCapturingShortcut = recording }
        .onDisappear { appState.hotkeyManager.isCapturingShortcut = false }
    }

    private func gestureRow(_ title: String, icon: String, summary: String? = nil, topic: InfoTopic) -> some View {
        Button { infoTopic = topic } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(title).font(.callout)
                    if let summary {
                        Text(summary).settingsCaption()
                    }
                }
                Spacer(minLength: Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .adaptiveTertiary()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Shows an explanation")
    }
}
