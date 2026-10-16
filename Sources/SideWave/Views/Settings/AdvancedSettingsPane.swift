// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

struct AdvancedSettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("experimentalFeatures") private var experimentalFeatures = false
    @State private var showExperimentalConfirmation = false
    @State private var showDiagnosticLogConfirmation = false
    @State private var diagnosticLogEnabled = PasteTracer.isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }

    var body: some View {
        SettingsCard("Shortcut timing") {
            SettingsToggleRow("Smart Push-to-Talk",
                              caption: "Hold the shortcut to dictate and release to finish. A quick tap still starts and stops a longer dictation.",
                              isOn: Binding(get: { appState.hotkeyManager.smartPTTEnabled },
                                            set: { appState.hotkeyManager.smartPTTEnabled = $0 }))
            SettingsDivider()
            holdThreshold
        }
        .settingsSpotlight(key: "hotkey", appState: appState)

        SettingsCard("Diagnostics") {
            SettingsToggleRow("Troubleshooting log",
                              caption: "Records how each paste went, without the text itself, to help diagnose text that doesn't reach its window. Turning it off deletes the log.",
                              isOn: Binding(get: { diagnosticLogEnabled }, set: { enabled in
                                  if enabled {
                                      showDiagnosticLogConfirmation = true
                                  } else {
                                      PasteTracer.setEnabled(false)
                                      diagnosticLogEnabled = false
                                  }
                              }))
            if diagnosticLogEnabled {
                HStack(spacing: Spacing.sm) {
                    Button("Show Log in Finder") {
                        let url = PasteTracer.traceFileURL()
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            let parent = url.deletingLastPathComponent()
                            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(parent)
                        }
                    }
                    .actionButton()
                    Button("Clear Log") { PasteTracer.clear() }
                        .actionButton()
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Animate.standard, value: diagnosticLogEnabled)
        .alert("Turn On the Troubleshooting Log?", isPresented: $showDiagnosticLogConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") {
                PasteTracer.setEnabled(true)
                diagnosticLogEnabled = true
            }
        } message: {
            Text("Each dictation adds one line to a local file with the time, target app and process ID, the length of the pasted text (not the text), the paste methods tried, and the result. Only the latest 200 entries are kept, the file is readable only by you, and it's never sent anywhere.")
        }

        SettingsCard("Experimental features") {
            SettingsToggleRow("Show experimental features",
                              caption: "Adds an Experimental section to this sidebar with Relay and pipeline tuning. These features may change, crash, or be removed.",
                              isOn: Binding(get: { experimentalFeatures }, set: { enabled in
                                  if enabled { showExperimentalConfirmation = true } else { turnOffExperimentalFeatures() }
                              }))
        }
        .alert("Show Experimental Features?", isPresented: $showExperimentalConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Show") { experimentalFeatures = true }
        } message: {
            Text("These features are still in development. They can crash, lose data, or behave unexpectedly, and may change or be removed in later versions.")
        }

        AdvancedResetSection()
    }

    private var holdThreshold: some View {
        let defaultMs = Int((HotkeyManager.smartPTTThresholdDefault * 1000).rounded())
        let currentMs = Int((appState.hotkeyManager.smartPTTThreshold * 1000).rounded())
        let minMs = HotkeyManager.smartPTTThresholdMin * 1000
        let maxMs = HotkeyManager.smartPTTThresholdMax * 1000
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hold threshold").font(.callout)
                Spacer()
                if currentMs != defaultMs {
                    Button("Reset") { appState.hotkeyManager.smartPTTThreshold = HotkeyManager.smartPTTThresholdDefault }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
                Text("\(currentMs) ms").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { appState.hotkeyManager.smartPTTThreshold * 1000 },
                                  set: { appState.hotkeyManager.smartPTTThreshold = $0 / 1000 }),
                   in: minMs...maxMs, step: 50) {
                Text("Hold threshold")
            } minimumValueLabel: {
                Text("\(Int(minMs)) ms")
            } maximumValueLabel: {
                Text("\(Int(maxMs)) ms")
            }
            .labelsHidden()
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("How long you hold the shortcut, after recording is ready, before the release finishes the dictation instead of toggling. The default is \(defaultMs) ms. Raise it if quick taps register as holds.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hiding experimental features also stops what they started, and resets
    /// the settings whose only control is about to disappear.
    private func turnOffExperimentalFeatures() {
        appState.relayModeEnabled = false
        // removeObject lets the hardware-tier default registered at launch apply again.
        UserDefaults.standard.removeObject(forKey: "refineFixedIntervalEnabled")
        UserDefaults.standard.set(false, forKey: "perWordTransitionAnimation")
        UserDefaults.standard.set(false, forKey: "useEouToRefineDirect")
        withAnimation(reduceMotion ? nil : Animate.standard) { experimentalFeatures = false }
    }
}

/// Restore defaults, or erase everything. The full reset asks twice.
private struct AdvancedResetSection: View {
    @State private var showRestoreConfirm = false
    @State private var showResetConfirm = false
    @State private var showResetFinalConfirm = false
    @State private var resetError: String?

    var body: some View {
        SettingsCard("Reset") {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("Restore default settings").font(.callout)
                    Text("Returns every option to its default and restarts SideWave. History, glossaries, downloaded models, and setup are kept.")
                        .settingsCaption()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                Button("Restore Defaults\u{2026}") { showRestoreConfirm = true }
                    .actionButton()
            }
            .confirmationDialog("Restore default settings?", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button("Restore and Restart") { AppResetService.restoreDefaultSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("SideWave restarts with default settings. Your dictation history, glossaries, downloaded models, and setup are kept.")
            }

            SettingsDivider()

            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("Erase SideWave").font(.callout)
                    Text("Deletes history, meetings, glossaries, settings, and downloaded models, then quits. SideWave opens at setup next time.")
                        .settingsCaption()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                Button("Erase\u{2026}", role: .destructive) { showResetConfirm = true }
                    .actionButton()
            }
            .confirmationDialog("Erase all SideWave data?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Continue\u{2026}", role: .destructive) {
                    // Let the first dialog finish closing before showing the second.
                    DispatchQueue.main.async { showResetFinalConfirm = true }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your dictation history, meeting recordings and transcripts, glossaries, settings, and downloaded speech, speaker, voice, and language models will be deleted. Apple Intelligence and macOS permissions are kept. SideWave will quit.")
            }
            .confirmationDialog("This can't be undone.", isPresented: $showResetFinalConfirm, titleVisibility: .visible) {
                Button("Erase and Quit", role: .destructive) {
                    do { try AppResetService.performFactoryReset() } catch { resetError = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All SideWave data and models are deleted and the app quits. Models download again on the next launch.")
            }
        }
        .alert("Couldn't Erase SideWave", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
            Button("OK") { resetError = nil }
        } message: { Text(resetError ?? "") }
    }
}
