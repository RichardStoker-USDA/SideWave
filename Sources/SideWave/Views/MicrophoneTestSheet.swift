// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Short microphone check in Settings > Microphone.
/// Lets the user verify their channel selection, source sample rate,
/// and live levels without triggering a real dictation.
struct MicrophoneTestSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var controller = MicTestController()
    @State private var hasStartedOnce = false

    private var deviceLabel: String {
        if let device = activeDevice {
            return device.pickerLabel()
        }
        return "System Default"
    }

    private var activeDevice: AudioInputDevice? {
        let mgr = appState.audioDeviceManager
        if let uid = mgr.selectedDeviceUID {
            return mgr.availableDevices.first(where: { $0.uid == uid })
        }
        return mgr.availableDevices.first(where: { $0.isDefault })
    }

    /// UID to read channel-mode storage under. Resolves System Default
    /// to the actual default device's UID so the test reads the same
    /// key the Settings UI writes (and the same key the dictation tap
    /// resolves at AppState.resolveDictationInputUID time).
    private var resolvedDeviceUID: String? {
        if let explicit = appState.audioDeviceManager.selectedDeviceUID {
            return explicit
        }
        return activeDevice?.uid
    }

    private var activeChannelMode: ChannelMode {
        AudioDeviceManager.channelMode(forUID: resolvedDeviceUID)
    }

    /// A live capture session already owns the input device. Starting the
    /// test tap alongside it would put a second AVAudioEngine on the same
    /// HAL device mid-recording (XLR interfaces renegotiate sample rate,
    /// which can glitch the recording that matters).
    private var captureBlockedReason: String? {
        if appState.meetingService.isCaptureActive {
            return "A meeting is recording. Stop it before testing the microphone."
        }
        if appState.isDictationBusy {
            return "Dictation is active. Stop it before testing the microphone."
        }
        if appState.isMicOnStandby {
            return "Keep mic on standby is holding the input device. Turn it off in Settings > Microphone before testing."
        }
        return nil
    }

    private var activeAutoChannel: Int? {
        AudioDeviceManager.autoDetectedChannel(forUID: resolvedDeviceUID)
    }

    private var resolvedChannelLabel: String {
        switch activeChannelMode {
        case .auto:
            if let channel = controller.detectedChannel {
                return "Channel \(channel) (detected during this test)"
            }
            if let cached = activeAutoChannel {
                return "Auto (previously channel \(cached))"
            }
            return "Auto. Calibrating now\u{2026}"
        case .channel(let n):
            return "Channel \(n)"
        case .mix:
            return "Mix all channels"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Header
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Microphone Test")
                    .font(.title3.weight(.semibold))
                Text("Speak for 3 seconds. This checks the input and channel used for dictation. Nothing is saved or transcribed.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            // Active device summary
            VStack(alignment: .leading, spacing: Spacing.sm) {
                summaryRow(label: "Device", value: deviceLabel)

                if let device = activeDevice, device.channelCount > 1 {
                    summaryRow(label: "Channel", value: resolvedChannelLabel)
                } else if let device = activeDevice {
                    summaryRow(label: "Channels", value: "\(device.channelCount)")
                }

                if controller.detectedSampleRate > 0 {
                    summaryRow(
                        label: "Source rate",
                        value: "\(Int(controller.detectedSampleRate)) Hz · \(controller.detectedChannelCount) ch → 16 kHz mono"
                    )
                }
            }

            SettingsDivider()

            // Level meter
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text(controller.testFinished ? "Highest input level" : "Input level")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(controller.testFinished ? controller.testMaximumDisplayPercent : controller.audioInputDisplayPercent)%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(meterColor)
                }
                meterBar
                Text(meterCaption)
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Error
            if let err = controller.lastError {
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.warningAmber)
                    Text(err)
                        .font(.callout)
                        .adaptiveSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Blocked: another capture session owns the mic right now.
            if let blocked = captureBlockedReason {
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Image(systemName: "mic.slash")
                        .adaptiveSecondary()
                    Text(blocked)
                        .font(.callout)
                        .adaptiveSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Footer buttons
            HStack(spacing: Spacing.sm) {
                Button("Restart") {
                    Task {
                        controller.stop()
                        guard captureBlockedReason == nil else { return }
                        await controller.start(deviceUID: resolvedDeviceUID)
                    }
                }
                .actionButton()
                .disabled(controller.isRunning || controller.isStarting || controller.isStopping || captureBlockedReason != nil)

                Spacer()

                Button("Done") {
                    controller.stop()
                    dismiss()
                }
                .prominentActionButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // Auto-start the test the first time the sheet appears, unless a
            // live capture session owns the mic.
            if !hasStartedOnce {
                hasStartedOnce = true
                guard captureBlockedReason == nil else { return }
                await controller.start(deviceUID: resolvedDeviceUID)
            }
        }
        .onDisappear {
            controller.stop()
        }
    }

    @ViewBuilder
    private func summaryRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(label)
                .font(.callout)
                .adaptiveSecondary()
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meterBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 4)
                    .fill(meterColor)
                    .frame(width: geo.size.width * CGFloat(controller.testFinished ? controller.testMaximumDisplayPercent : controller.audioInputDisplayPercent) / 100.0)
                    .animation(.linear(duration: 0.05), value: controller.audioInputDisplayPercent)
            }
        }
        .frame(height: 10)
    }

    private var meterColor: Color {
        switch controller.audioInputStatus {
        case .idle: return .secondary
        case .silent: return .secondary
        case .quiet: return Color.warningAmber
        case .balanced: return .green
        case .loud: return Color.accentColor
        case .clipping: return .red
        }
    }

    private var meterCaption: String {
        if captureBlockedReason != nil { return "Input is in use." }
        if controller.isStarting { return "Preparing microphone…" }
        if let result = controller.resultDescription { return result }
        switch controller.audioInputStatus {
        case .idle: return controller.isRunning ? "Listening…" : "Press Restart to test again."
        case .silent: return "Silent. Try speaking into the mic."
        case .quiet: return "Too quiet. Speak louder or move closer."
        case .balanced: return "Balanced. Good level for dictation."
        case .loud: return "Loud. Still good, but headroom is shrinking."
        case .clipping: return "Clipping. Reduce input gain on your interface."
        }
    }
}
