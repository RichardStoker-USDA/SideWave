// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

struct MeetingSetupSheet: View {
    @Bindable var appState: AppState
    let onStart: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State var helpExpanded = false
    @State private var showMicrophoneTest = false

    private var microphoneName: String {
        appState.audioDeviceManager.selectedDevice?.name
            ?? appState.audioDeviceManager.resolvedDefaultDevice.map { "System: \($0.name)" }
            ?? "System default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("New Meeting").font(.title2.weight(.semibold))
            Text("Record the conversation, review the speakers, then create your notes.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            PreferenceRow(label: "Microphone") {
                ChoiceMenu(title: "Meeting microphone", value: microphoneName, selection: Binding(
                    get: { appState.audioDeviceManager.selectedDeviceUID ?? "" },
                    set: { appState.audioDeviceManager.userDidSelectDevice($0.isEmpty ? nil : $0) }
                )) {
                    Text("System default").tag("")
                    ForEach(appState.audioDeviceManager.availableDevices) {
                        Text($0.pickerLabel()).tag($0.uid)
                    }
                }
                .frame(maxWidth: 310, alignment: .trailing)
            }
            Button("Test Microphone", systemImage: "waveform") { showMicrophoneTest = true }
                .actionButton()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Up to 8 speakers, identified automatically", systemImage: "person.3")
                Label("Audio saved on this Mac during recording", systemImage: "internaldrive")
            }
            .font(.callout).foregroundStyle(.secondary)

            DisclosureGroup("Recording tips", isExpanded: $helpExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Use one microphone that can hear everyone, or a mixed input from your audio interface. SideWave does not record computer audio separately.")
                        Text("For an interface, choose the physical input in Microphone Settings. Auto can select loopback audio if that channel is louder.")
                        Text("A quiet room and speakers taking turns give clearer labels. Overlap, similar voices, and distant speakers can reduce accuracy. Review names before sharing.")
                        Text("If SideWave is interrupted, the saved recording is offered for recovery next time you open the app.")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 180)
                .padding(.top, Spacing.sm)
            }
            .font(.callout)
            .disclosureGroupStyle(.row)

            Divider()
            HStack(spacing: Spacing.sm) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .actionButton().keyboardShortcut(.cancelAction)
                Button("Start Recording") {
                    onStart(nil)
                    dismiss()
                }
                .prominentActionButton().keyboardShortcut(.defaultAction)
                .disabled(appState.audioDeviceManager.availableDevices.isEmpty || appState.isDictationBusy)
            }
        }
        .padding(Spacing.xxl)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showMicrophoneTest) { MicrophoneTestSheet(appState: appState) }
    }
}
