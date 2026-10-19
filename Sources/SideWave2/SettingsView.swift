// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
import SideWaveKit

/// Settings-lite: hotkey, microphone, language, refine, appearance.
/// Nothing else in v1; the simple view IS the app.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(AppSettings.pttThresholdMsKey) private var pttThresholdMs = 500
    @AppStorage(AppSettings.preferredDeviceUIDKey) private var preferredDeviceUID = ""
    @AppStorage(AppSettings.languageCodeKey) private var languageCode = "auto"
    @AppStorage(AppSettings.refineEnabledKey) private var refineEnabled = true
    @AppStorage(AppSettings.refineBackendKey) private var refineBackend =
        RefineBackendChoice.appleIntelligence.rawValue
    @AppStorage(AppSettings.refineTemplateKey) private var refineTemplate =
        RefineTemplate.standard.rawValue
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppearanceChoice.system.rawValue

    @State private var capturingHotkey = false
    @State private var hotkeyDisplay = AppSettings.hotkey.displayString
    @State private var devices: [AudioInputDeviceInfo] = []

    var body: some View {
        Form {
            hotkeySection
            microphoneSection
            dictationSection
            refineSection
            appearanceSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { refreshDevices() }
        .onChange(of: languageCode) { model.settingsChanged() }
        .onChange(of: refineBackend) { model.settingsChanged() }
        .onChange(of: refineTemplate) { model.settingsChanged() }
        .onChange(of: refineEnabled) { model.settingsChanged() }
        .onChange(of: appearance) { model.settingsChanged() }
    }

    // MARK: Hotkey

    private var hotkeySection: some View {
        Section("Hotkey") {
            HStack {
                Text("Dictation key")
                Spacer()
                Button {
                    beginCapture()
                } label: {
                    Text(capturingHotkey ? "Press a key…" : hotkeyDisplay)
                        .frame(minWidth: 130)
                }
                .disabled(capturingHotkey || !model.hotkey.isInstalled)
            }
            if !model.accessibilityGranted {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.secondary)
                    Text("The global hotkey needs Accessibility permission. Grant it from the SideWave window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Tap to start, tap again to stop. Hold and speak, then release to send.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Text("Hold threshold")
                Slider(
                    value: Binding(
                        get: { Double(pttThresholdMs) },
                        set: { pttThresholdMs = Int($0) }
                    ),
                    in: 300...1000, step: 50
                )
                Text("\(pttThresholdMs) ms")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text("How long a hold must last, measured from the moment the engine is live, before releasing sends the text.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func beginCapture() {
        capturingHotkey = true
        model.hotkey.captureNext = { shortcut in
            model.hotkey.setShortcut(shortcut)
            hotkeyDisplay = shortcut.displayString
            capturingHotkey = false
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        Section("Microphone") {
            Picker("Input device", selection: $preferredDeviceUID) {
                Text("System default").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Text("Chosen fresh at every session. If the device is missing, the system default steps in and the session says so.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshDevices() {
        devices = AudioDevices.listInputDevices()
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Section("Dictation") {
            Picker("Language", selection: $languageCode) {
                ForEach(LanguageChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }
            Text("Automatic hears any supported language. Picking one loads a leaner model tuned for it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Refine

    private var refineSection: some View {
        Section("Refine") {
            Toggle("Clean up text before pasting", isOn: $refineEnabled)

            if refineEnabled {
                Picker("Model", selection: $refineBackend) {
                    ForEach(RefineBackendChoice.allCases) { backend in
                        Text(backend.displayName).tag(backend.rawValue)
                    }
                }
                if let message = RefinerAFM.availabilityMessage(),
                    refineBackend == RefineBackendChoice.appleIntelligence.rawValue
                {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Style", selection: $refineTemplate) {
                    ForEach(RefineTemplate.allCases) { template in
                        Text(template.displayName).tag(template.rawValue)
                    }
                }
                Text(RefineTemplate(rawValue: refineTemplate)?.subtitle ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }
            .pickerStyle(.segmented)

            downloadsDisclosure
        }
    }

    /// The transparency ledger: every model fetch the app ever made.
    /// SideWave has no other network activity, so this list is the whole
    /// story.
    private var downloadsDisclosure: some View {
        DisclosureGroup("Downloads") {
            if model.downloads.records.isEmpty {
                Text("No downloads yet. Models fetch once on first setup and load from disk after that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.downloads.records) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(record.component)
                                .font(.callout)
                            Spacer()
                            Text(record.networkFetch ? "Downloaded" : "Loaded from disk")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(record.source)  ·  \(record.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                Text("Dictation itself never touches the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
