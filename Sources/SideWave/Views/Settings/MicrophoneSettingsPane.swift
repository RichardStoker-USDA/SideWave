// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import CoreAudio
import SwiftUI

struct MicrophoneSettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("dictationAudioControl") private var dictationAudioControl = "lower"
    @AppStorage("dictationVolumeReduction") private var dictationVolumeReduction: Double = 60
    @State private var showMicrophoneTest = false
    @State private var showBluetoothWarning = false
    @State private var pendingBluetoothUID: String?
    @State private var syncAppInputWithSystem = AudioDeviceManager.isSyncAppInputWithSystemEnabled
    @State private var infoTopic: InfoTopic?

    private var devices: AudioDeviceManager { appState.audioDeviceManager }
    private var captureBusy: Bool {
        appState.isDictationBusy || appState.meetingService.isCaptureActive || MicTestController.isCapturing
    }

    /// Shows which physical device System Default points at.
    private var systemDefaultLabel: String {
        devices.resolvedDefaultDevice.map { "System Default \u{00B7} \($0.name)" } ?? "System Default"
    }

    /// The device the channel picker applies to: the chosen input, or the
    /// system default when none is chosen.
    private var channelDevice: AudioInputDevice? {
        if let uid = devices.selectedDeviceUID { return devices.availableDevices.first { $0.uid == uid } }
        return devices.availableDevices.first { $0.isDefault }
    }

    var body: some View {
        SettingsCard("Input") {
            SettingsRow(label: "Microphone") {
                ChoiceMenu(title: "Microphone",
                           value: devices.selectedDeviceUID == nil ? systemDefaultLabel : (devices.selectedDevice?.name ?? "Unavailable microphone"),
                           selection: Binding(get: { devices.selectedDeviceUID ?? "__system_default__" },
                                              set: selectDevice)) {
                    Text(systemDefaultLabel).tag("__system_default__")
                    ForEach(devices.availableDevices) { Text($0.pickerLabel()).tag($0.uid) }
                }
                .fixedSize()
                .accessibilityLabel("Microphone input")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Check the level and channel before you dictate.")
                    .settingsCaption()
                Spacer(minLength: Spacing.sm)
                Button("Test Microphone\u{2026}") { showMicrophoneTest = true }
                    .actionButton()
            }

            if let device = channelDevice, device.channelCount > 1 {
                SettingsDivider()
                InputChannelSelector(device: device, storageUID: devices.selectedDeviceUID ?? device.uid)
                    .disabled(captureBusy)
            }

            if devices.selectedDeviceIsBluetooth {
                SettingsDivider()
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "airpods").adaptiveSecondary().accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Bluetooth microphone").font(.callout.weight(.medium))
                        Text("Using a Bluetooth headset as a microphone lowers audio quality for both the microphone and anything playing through it. A wired or built-in microphone avoids this.")
                            .settingsCaption()
                            .fixedSize(horizontal: false, vertical: true)
                        if let recommended = devices.recommendedNonBluetoothDevice {
                            Button("Switch to \(recommended.name)") { devices.userDidSelectDevice(recommended.uid) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }

            SettingsDivider()
            DisclosureGroup("Audio conversion") {
                SettingsToggleRow("High-quality resampling",
                                  caption: "Uses an anti-aliased converter to bring audio down to 16 kHz. Recommended for audio interfaces and sources above 48 kHz. Takes effect on the next dictation.",
                                  isOn: Binding(
                                    get: { UserDefaults.standard.object(forKey: "useHighQualityResampling") as? Bool ?? true },
                                    set: { UserDefaults.standard.set($0, forKey: "useHighQualityResampling") }))
                    .padding(.top, Spacing.sm)
            }
            .font(.callout)
            .disclosureGroupStyle(.row)
            .disabled(captureBusy)
        }
        .settingsSpotlight(key: "audio", appState: appState)

        SettingsCard("Automatic switching") {
            InputPriorityEditor(appState: appState)
            SettingsDivider()
            SettingsToggleRow("Keep SideWave and macOS on the same input",
                              caption: "Choosing a microphone in SideWave also changes the macOS default, and macOS changes update SideWave while it's idle. Turn this off to keep a separate SideWave choice.",
                              isOn: $syncAppInputWithSystem)
                .onChange(of: syncAppInputWithSystem) { _, enabled in
                    AudioDeviceManager.setSyncAppInputWithSystem(enabled)
                    // Align macOS with the current choice right away.
                    if enabled { devices.syncMacOSDefaultToSelection() }
                }
        }

        SettingsCard("While dictating") {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    HStack(spacing: Spacing.xxs) {
                        Text("Keep microphone on standby").font(.callout)
                        Button { infoTopic = .microphoneStandby } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless).adaptiveSecondary()
                            .accessibilityLabel("About microphone standby")
                    }
                    Text("Starts recording faster by keeping the microphone ready between dictations. macOS shows the microphone indicator while it's on.")
                        .settingsCaption()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                if appState.isMicOnStandby {
                    Text("Active").font(.caption.weight(.medium)).adaptiveSecondary()
                        .padding(.top, 2)
                        .transition(.opacity)
                }
                Toggle("Keep microphone on standby", isOn: $appState.keepMicOnStandby)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            .animation(.easeOut(duration: 0.2), value: appState.isMicOnStandby)

            SettingsDivider()
            SettingsRow(label: "Other audio") {
                ChoiceMenu(title: "Other audio while dictating",
                           value: ["none": "Keep Volume", "mute": "Mute", "lower": "Lower Volume"][dictationAudioControl] ?? "Keep Volume",
                           selection: $dictationAudioControl) {
                    Text("Keep Volume").tag("none")
                    Text("Lower Volume").tag("lower")
                    Text("Mute").tag("mute")
                }
                .fixedSize()
            }
            if dictationAudioControl == "lower" {
                SettingsRow(label: "Lower by") {
                    HStack(spacing: Spacing.sm) {
                        Slider(value: $dictationVolumeReduction, in: 10...100, step: 10)
                            .frame(width: 180)
                            .accessibilityLabel("Volume reduction")
                            .accessibilityValue("\(Int(dictationVolumeReduction)) percent")
                        Text("\(Int(dictationVolumeReduction))%")
                            .font(.callout.monospacedDigit()).adaptiveSecondary()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Text(dictationAudioControl == "mute" ? "Other audio is silenced while you dictate and restored afterward."
                 : dictationAudioControl == "lower" ? "Other audio is turned down while you dictate and restored afterward."
                 : "Other audio keeps playing at its normal volume.")
                .settingsCaption()
        }
        .sheet(isPresented: $showMicrophoneTest) { MicrophoneTestSheet(appState: appState) }
        .sheet(item: $infoTopic) { InfoSheet(topic: $0) }
        .alert("Use a Bluetooth Microphone?", isPresented: $showBluetoothWarning) {
            Button("Cancel", role: .cancel) { pendingBluetoothUID = nil }
            Button("Use Anyway") {
                if let uid = pendingBluetoothUID {
                    AudioDeviceManager.acknowledgeBluetoothMic(uid: uid)
                    devices.userDidSelectDevice(uid)
                }
                pendingBluetoothUID = nil
            }
        } message: {
            Text("Bluetooth headsets switch to a lower-quality hands-free mode when their microphone is in use, which also lowers the quality of music or calls. Wired or built-in microphones avoid this.")
        }
    }

    /// Bluetooth inputs ask once per device; familiar devices switch directly.
    private func selectDevice(_ value: String) {
        let uid = value == "__system_default__" ? nil : value
        if let uid,
           let device = devices.availableDevices.first(where: { $0.uid == uid }),
           device.isBluetooth, !AudioDeviceManager.hasAcknowledgedBluetoothMic(uid: uid) {
            pendingBluetoothUID = uid
            showBluetoothWarning = true
        } else {
            devices.userDidSelectDevice(uid)
        }
    }
}

/// Picks which physical input of a multichannel device feeds dictation.
private struct InputChannelSelector: View {
    let device: AudioInputDevice
    /// Channel choices are stored per physical device, so System Default and
    /// an explicit choice of the same device share one setting.
    let storageUID: String?
    /// Re-reads the stored values after writes that bypass a binding.
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        let currentMode = AudioDeviceManager.channelMode(forUID: storageUID)
        let cachedAuto = AudioDeviceManager.autoDetectedChannel(forUID: storageUID)

        SettingsRow(label: "Input channel") {
            ChoiceMenu(title: "Input channel", value: currentMode.displayLabel, selection: Binding(
                get: { AudioDeviceManager.channelMode(forUID: storageUID).rawValue },
                set: { raw in
                    guard let mode = ChannelMode(rawValue: raw) else { return }
                    AudioDeviceManager.setChannelMode(mode, forUID: storageUID)
                    // Leaving Auto clears its calibration so returning re-detects.
                    if mode != .auto { AudioDeviceManager.resetAutoDetectedChannel(forUID: storageUID) }
                    refresh &+= 1
                })) {
                Text(ChannelMode.auto.displayLabel).tag("auto")
                ForEach(1...device.channelCount, id: \.self) { Text(ChannelMode.channel($0).displayLabel).tag("channel:\($0)") }
                Text(ChannelMode.mix.displayLabel).tag("mix")
            }
            .fixedSize()
            .accessibilityLabel("Microphone input channel")
        }
        Text("\(device.name) has \(device.channelCount) input channels. If your microphone is on one input, such as input 1 of an audio interface, choose it. Auto picks the loudest channel, which can be a loopback of computer audio. Mix averages all channels and can make a single microphone quieter.")
            .settingsCaption()
            .fixedSize(horizontal: false, vertical: true)
        if case .auto = currentMode {
            HStack {
                Text(cachedAuto.map { "Using channel \($0)." } ?? "Auto picks a channel on the next recording.")
                    .settingsCaption()
                Spacer()
                if cachedAuto != nil {
                    Button("Detect Again") {
                        AudioDeviceManager.resetAutoDetectedChannel(forUID: storageUID)
                        refresh &+= 1
                    }
                    .buttonStyle(.link)
                    .font(.subheadline)
                }
            }
        }
    }
}

/// Switches the macOS input to a preferred microphone when Bluetooth
/// headphones (or, optionally, anything else) take it over.
private struct InputPriorityEditor: View {
    @Bindable var appState: AppState
    @State private var priorityUIDs = AudioDeviceManager.audioInputPriorityUIDs()
    @State private var overrideBluetooth = AudioDeviceManager.isAutoOverrideBluetoothInputEnabled
    @State private var overrideAlways = AudioDeviceManager.isAlwaysOverrideInputEnabled
    @State private var showPermissionAlert = false

    private var devices: AudioDeviceManager { appState.audioDeviceManager }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsToggleRow("Switch back when Bluetooth takes over",
                              caption: "When Bluetooth headphones connect, use the first available microphone in your list. Playback stays on the headphones.",
                              isOn: $overrideBluetooth)
                .onChange(of: overrideBluetooth) { _, enabled in
                    AudioDeviceManager.setAutoOverrideBluetoothInput(enabled)
                    if enabled { prepareList { overrideBluetooth = false; AudioDeviceManager.setAutoOverrideBluetoothInput(false) } }
                }
            SettingsToggleRow("Always use my preferred microphone",
                              caption: "Whenever the macOS input changes, switch to the first available microphone in your list. This changes the input for other apps too.",
                              isOn: $overrideAlways)
                .onChange(of: overrideAlways) { _, enabled in
                    AudioDeviceManager.setAlwaysOverrideInput(enabled)
                    if enabled { prepareList { overrideAlways = false; AudioDeviceManager.setAlwaysOverrideInput(false) } }
                }
            if overrideBluetooth || overrideAlways {
                priorityList
            }
        }
        .alert("Microphone Access Needed", isPresented: $showPermissionAlert) {
            Button("Open System Settings") { AppDelegate.openMicrophoneSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SideWave needs microphone access to switch inputs for you. Allow it in System Settings, then turn this on again.")
        }
    }

    @ViewBuilder
    private var priorityList: some View {
        let addable = devices.availableDevices.filter { !$0.isBluetooth && !priorityUIDs.contains($0.uid) }
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Preferred microphones").font(.callout.weight(.medium))
                Spacer()
                if !addable.isEmpty {
                    Menu {
                        ForEach(addable) { device in
                            Button(device.pickerLabel(includeDefault: false)) {
                                priorityUIDs.append(device.uid)
                                AudioDeviceManager.setAudioInputPriorityUIDs(priorityUIDs)
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .fixedSize()
                    .accessibilityLabel("Add a microphone to the list")
                }
            }
            if priorityUIDs.isEmpty {
                Text("Add at least one microphone to use automatic switching.")
                    .settingsCaption()
            } else {
                ForEach(Array(priorityUIDs.enumerated()), id: \.element) { index, uid in
                    priorityRow(index: index, uid: uid)
                }
            }
        }
        .padding(.top, Spacing.xs)
    }

    private func priorityRow(index: Int, uid: String) -> some View {
        let device = devices.availableDevices.first { $0.uid == uid }
        return HStack(spacing: Spacing.sm) {
            Text("\(index + 1).").font(.callout.monospacedDigit()).adaptiveTertiary().frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(device?.pickerLabel(includeDefault: false) ?? devices.knownInputName(forUID: uid) ?? "Disconnected microphone")
                    .font(.callout)
                    .foregroundStyle(device == nil ? .secondary : .primary)
                    .lineLimit(2)
                if device == nil {
                    Text("Not connected").font(.caption).adaptiveTertiary()
                }
            }
            Spacer()
            ControlGroup {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("Move up")
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == priorityUIDs.count - 1)
                    .accessibilityLabel("Move down")
            }
            .controlSize(.small)
            .fixedSize()
            Button(role: .destructive) {
                priorityUIDs.removeAll { $0 == uid }
                AudioDeviceManager.setAudioInputPriorityUIDs(priorityUIDs)
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove from list")
        }
    }

    private func move(_ index: Int, by offset: Int) {
        priorityUIDs.swapAt(index, index + offset)
        AudioDeviceManager.setAudioInputPriorityUIDs(priorityUIDs)
    }

    /// First enable seeds the list with the built-in microphone and asks for
    /// microphone access now, rather than on the first dictation.
    private func prepareList(onDenied: @escaping @MainActor () -> Void) {
        if priorityUIDs.isEmpty,
           let builtIn = devices.availableDevices.first(where: {
               AudioDeviceManager.transportTypeForUID($0.uid) == kAudioDeviceTransportTypeBuiltIn }) {
            priorityUIDs = [builtIn.uid]
            AudioDeviceManager.setAudioInputPriorityUIDs(priorityUIDs)
        }
        Task {
            let granted: Bool
            switch AVAudioApplication.shared.recordPermission {
            case .granted: granted = true
            case .undetermined: granted = await AVAudioApplication.requestRecordPermission()
            default: granted = false
            }
            if !granted {
                await MainActor.run {
                    showPermissionAlert = true
                    onDenied()
                }
            }
        }
    }
}
