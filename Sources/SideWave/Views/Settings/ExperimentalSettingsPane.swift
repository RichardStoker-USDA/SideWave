// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

struct ExperimentalSettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("refineFixedIntervalEnabled") private var fixedIntervalEnabled = false
    @AppStorage("refineFixedIntervalSeconds") private var fixedIntervalSeconds = 8
    @AppStorage("perWordTransitionAnimation") private var perWordTransitionAnimation = false
    @AppStorage("tdtHiddenRefineSweep") private var tdtHiddenRefineSweep = false
    @AppStorage("useMultiStageRendering") private var useMultiStageRendering = false
    @AppStorage("useEouToRefineDirect") private var useEouToRefineDirect = false
    @AppStorage("skipRefine") private var skipRefine = false
    @State private var infoTopic: InfoTopic?

    var body: some View {
        SettingsCard("Fixed-interval refine") {
            SettingsToggleRow("Refine on a timer",
                              caption: "Refines while you keep talking instead of waiting for pauses. No segment grows past 14.8 seconds either way.",
                              isOn: $fixedIntervalEnabled,
                              info: { infoTopic = .fixedIntervalRefine })
            GlassSegmentedPicker(selection: $fixedIntervalSeconds,
                                 segments: [.init("Every 4 s", tag: 4), .init("Every 8 s", tag: 8), .init("Every 12 s", tag: 12)],
                                 expands: true,
                                 accessibilityLabel: "Refine interval")
                .disabled(!fixedIntervalEnabled)
                .opacity(fixedIntervalEnabled ? 1 : 0.5)
        }
        .sheet(item: $infoTopic) { InfoSheet(topic: $0) }

        SettingsCard("Older display modes") {
            SettingsToggleRow("Per-word draft animation",
                              caption: "The earlier fade where each draft word turns white separately. Turning it on replaces the two-stage display; choose your engine preset again to return.",
                              isOn: Binding(get: { perWordTransitionAnimation }, set: { enabled in
                                  perWordTransitionAnimation = enabled
                                  // The per-word path only renders with the two-stage sweep off,
                                  // and only engine presets write the sweep setting.
                                  if enabled { tdtHiddenRefineSweep = false }
                              }))
                .disabled(!useMultiStageRendering || skipRefine)
            SettingsDivider()
            SettingsToggleRow("Refine the live draft directly",
                              caption: "Sends the streaming draft straight to Refine, skipping Parakeet's confirmation. Loses vocabulary boosting and multilingual fallback. Not recommended.",
                              isOn: $useEouToRefineDirect)
                .disabled(!useMultiStageRendering || skipRefine)
        }

        SettingsCard("Relay") {
            SettingsToggleRow("Press Return after dictation",
                              caption: "Sends dictated text and submits it. Terminal and iTerm2 receive it directly; other apps get a paste followed by Return.",
                              isOn: $appState.relayModeEnabled)
        }

        #if DEBUG
        DeveloperDiagnosticsCard()
        #endif
    }
}

#if DEBUG
/// Debug builds only: recent pipeline trace events and a JSON export.
private struct DeveloperDiagnosticsCard: View {
    @State private var events: [DictationTracingService.TraceEvent] = []
    @State private var exportedName: String?

    var body: some View {
        SettingsCard("Pipeline trace") {
            HStack {
                Text("Model loading, audio, engine state, paste, and rendering events.").settingsCaption()
                Spacer()
                Button("Export JSON") {
                    if let url = DictationTracingService.shared.exportTraceDump() {
                        exportedName = url.lastPathComponent
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .actionButton().controlSize(.small)
                Button("Clear") {
                    DictationTracingService.shared.clear()
                    events = DictationTracingService.shared.getEvents()
                }
                .actionButton().controlSize(.small)
            }
            if let exportedName {
                Text("Saved \(exportedName)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if events.isEmpty {
                Text("No events yet. Start a dictation to record some.").settingsCaption()
            } else {
                ForEach(events.suffix(8).reversed()) { event in
                    HStack(alignment: .top, spacing: Spacing.xxs) {
                        Text("[\(event.formattedTime)]").foregroundStyle(.secondary)
                        Text(event.category.rawValue).bold()
                        Text(event.message)
                        Spacer()
                        if let duration = event.durationMs {
                            Text(String(format: "%.1f ms", duration)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .onAppear { events = DictationTracingService.shared.getEvents() }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveDictationTrace)) { _ in
            events = DictationTracingService.shared.getEvents()
        }
    }
}
#endif
