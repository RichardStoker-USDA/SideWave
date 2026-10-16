// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

struct MeetingSettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("meetingTranscriptionEnabled") private var meetingEnabled = false
    @Environment(\.openWindow) private var openWindow

    private var meetingIsBusy: Bool {
        if appState.meetingService.isStartingRecording { return true }
        switch appState.meetingService.state {
        case .recording, .processing: return true
        default: return false
        }
    }

    var body: some View {
        SettingsCard {
            SettingsToggleRow("Show Meetings in the main window",
                              caption: "Record conversations, label up to eight speakers, and write meeting notes on this Mac.",
                              isOn: $meetingEnabled)
                .disabled(meetingIsBusy)
            SettingsDivider()
            Text("Audio is saved to this Mac as you record. If SideWave is interrupted, the meeting can be resumed or processed the next time it opens. Check speaker labels before sharing notes.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsCard("Meeting notes") {
            SettingsRow(label: "Model") {
                ChoiceMenu(title: "Meeting notes model",
                           value: MeetingFormatterBackend(rawValue: appState.meetingFormatterBackend)?.displayName ?? "Choose model",
                           selection: $appState.meetingFormatterBackend) {
                    ForEach(HardwareCapability.current.availableBackends) { Text($0.displayName).tag($0.rawValue) }
                }
                .fixedSize()
                .disabled(appState.formatterService.state.isBusy)
            }
            Text("Apple Intelligence uses the model built into macOS. Gemma downloads only when you prepare it. Larger models need more memory and take longer.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Button("Meeting Help", systemImage: "questionmark.circle") {
                appState.requestedHelpSection = .meetingTranscription
                openWindow(id: "help")
            }
            .actionButton()
            Spacer()
        }
    }
}
