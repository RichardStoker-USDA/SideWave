// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
import SideWaveKit

/// First-launch setup: what SideWave is, one download, two permissions.
/// Every network fetch runs through the kit's model loaders, so the only
/// bytes this app ever pulls are the speech models named here.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                WaveStrands(mood: .listening, activityPulse: 0)
                    .frame(width: 64, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to SideWave")
                        .font(.largeTitle.weight(.semibold))
                    Text("Private dictation that runs entirely on this Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                bullet(
                    symbol: "waveform",
                    title: "Speak anywhere",
                    detail: "Press \(AppSettings.hotkey.displayString) in any app. Your words are typed where your cursor is."
                )
                bullet(
                    symbol: "lock.shield",
                    title: "Nothing leaves this Mac",
                    detail: "Speech recognition and cleanup run on the Apple Neural Engine. No accounts, no cloud."
                )
                bullet(
                    symbol: "arrow.down.circle",
                    title: "One download",
                    detail: "The speech model (about 700 MB) downloads once and is cached for good."
                )
            }

            Divider()

            setupRow

            permissionsRow

            HStack {
                Spacer()
                Button("Start Dictating") {
                    AppSettings.onboardingComplete = true
                    isPresented = false
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!model.modelsReady)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    private func bullet(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var setupRow: some View {
        if model.modelsReady {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Speech models are ready.")
                    .font(.callout)
            }
        } else if let progress = model.setupProgress {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fraction)
                Text(progress.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let error = model.setupError {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Try Again") {
                    Task { await model.prepareModels() }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text("macOS will ask for microphone access on your first dictation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(
                    systemName: model.accessibilityGranted
                        ? "checkmark.circle.fill" : "hand.raised")
                    .foregroundStyle(model.accessibilityGranted ? Color.accentColor : .secondary)
                    .frame(width: 22)
                Text(
                    model.accessibilityGranted
                        ? "Accessibility permission granted."
                        : "Accessibility permission lets the hotkey work everywhere and types the result."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if !model.accessibilityGranted {
                    Button("Grant…") {
                        if let url = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    Button("Recheck") {
                        model.refreshPermissions()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
