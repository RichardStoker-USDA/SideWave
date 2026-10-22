// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

struct SoundSettingsPane: View {
    @AppStorage("soundEffectsEnabled") private var soundEffectsEnabled = true
    @AppStorage("soundEffectsVolume") private var volume = 0.3
    @AppStorage("soundEffect_recordingStart") private var startSound = "Blow"
    @AppStorage("soundEffect_recordingStop") private var stopSound = "__none__"
    @AppStorage("soundEffect_promptConfirmed") private var confirmedSound = "Bottle"
    @AppStorage("soundEffect_error") private var errorSound = "Basso"

    private let service = SoundEffectService.shared

    var body: some View {
        SettingsCard {
            SettingsToggleRow("Sound effects",
                              caption: "Short sounds when dictation starts, stops, delivers text, or runs into a problem.",
                              isOn: $soundEffectsEnabled)
            if soundEffectsEnabled {
                SettingsDivider()
                SettingsRow(label: "Volume") {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "speaker.fill").font(.caption).adaptiveSecondary()
                        Slider(value: $volume, in: 0...1, step: 0.05)
                            .frame(width: 200)
                            .accessibilityLabel("Sound effects volume")
                            .accessibilityValue("\(Int(volume * 100)) percent")
                        Image(systemName: "speaker.wave.3.fill").font(.caption).adaptiveSecondary()
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }

        if soundEffectsEnabled {
            SettingsCard("Sounds") {
                SoundEventRow(event: .recordingStart, selection: $startSound, service: service)
                SettingsDivider()
                SoundEventRow(event: .recordingStop, selection: $stopSound, service: service)
                SettingsDivider()
                SoundEventRow(event: .promptConfirmed, selection: $confirmedSound, service: service)
                SettingsDivider()
                SoundEventRow(event: .error, selection: $errorSound, service: service)
                SettingsDivider()
                HStack {
                    Spacer()
                    Button("Restore Default Sounds") {
                        startSound = SoundEvent.recordingStart.factoryDefault.persistenceKey
                        stopSound = SoundEvent.recordingStop.factoryDefault.persistenceKey
                        confirmedSound = SoundEvent.promptConfirmed.factoryDefault.persistenceKey
                        errorSound = SoundEvent.error.factoryDefault.persistenceKey
                        volume = 0.3
                        service.resetToDefaults()
                    }
                    .actionButton()
                }
            }
        }
    }
}

/// One event: its name and description, a sound menu, and a preview button.
private struct SoundEventRow: View {
    let event: SoundEvent
    @Binding var selection: String
    let service: SoundEffectService

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: event.iconName)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(event.displayName).font(.callout)
                Text(event.description).settingsCaption()
            }
            Spacer(minLength: Spacing.sm)
            ChoiceMenu(title: "\(event.displayName) sound",
                       value: SoundOption.from(persistenceKey: selection).displayName,
                       selection: $selection) {
                ForEach(SoundOption.allOptions, id: \.persistenceKey) { Text($0.displayName).tag($0.persistenceKey) }
            }
            .fixedSize()
            .onChange(of: selection) { _, newValue in
                service.setSound(SoundOption.from(persistenceKey: newValue), for: event)
            }
            Button {
                service.preview(SoundOption.from(persistenceKey: selection))
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(selection == "__none__")
            .help("Play this sound")
            .accessibilityLabel("Play \(event.displayName.lowercased()) sound")
        }
    }
}
