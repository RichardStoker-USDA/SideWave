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

        MCPServerCard(appState: appState)
        AgentVoiceCard(appState: appState)

        #if DEBUG
        DeveloperDiagnosticsCard()
        #endif
    }

    /// Single quotes protect spaces and shell metacharacters in the app path.
    static func shellQuotedPath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct MCPServerCard: View {
    @Bindable var appState: AppState

    /// The helper ships inside the app, so the command follows the app if it moves.
    private var helperPath: String {
        Bundle.main.path(forAuxiliaryExecutable: "sidewave-mcp")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sidewave-mcp").path
    }

    private var commands: [(client: String, command: String, note: String)] {
        let path = ExperimentalSettingsPane.shellQuotedPath(helperPath)
        return [
            ("Claude Code", "claude mcp add --scope user sidewave -- \(path)", "Anthropic"),
            ("Codex CLI", "codex mcp add sidewave -- \(path)", "OpenAI"),
            ("Gemini CLI", "gemini mcp add sidewave -- \(path)", "Google"),
        ]
    }

    var body: some View {
        SettingsCard("MCP server") {
            SettingsToggleRow("Run the local MCP server",
                              caption: "Lets a coding agent read your live transcript and speak replies through SideWave. It listens on a local socket, not the network. Connected clients may send text to their own cloud services.",
                              isOn: Binding(get: { appState.mcpServer.isRunning }, set: { enabled in
                                  UserDefaults.standard.set(enabled, forKey: "mcpServerEnabled")
                                  if enabled { Task { await appState.mcpServer.start() } } else { appState.mcpServer.stop() }
                              }))
            if appState.mcpServer.isRunning {
                Label("Running", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if let error = appState.mcpServer.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            SettingsDivider()
            Text("Add SideWave to a client by running its command in Terminal:")
                .settingsCaption()
            ForEach(commands, id: \.client) { item in
                HStack(alignment: .top, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.client).font(.caption.weight(.medium))
                        Text(item.note).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(width: 84, alignment: .leading)
                    Text(item.command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.command, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy the \(item.client) command")
                    .accessibilityLabel("Copy \(item.client) command")
                }
            }
            Text("If you move SideWave, run the command again so it points to the new location.")
                .settingsCaption()
        }
    }
}

private struct AgentVoiceCard: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsCard("Agent voice") {
            SettingsRow(label: "Voice") {
                HStack(spacing: Spacing.sm) {
                    ChoiceMenu(title: "Agent voice", value: appState.ttsService.selectedVoice.capitalized,
                               selection: Binding(get: { appState.ttsService.selectedVoice },
                                                  set: { voice in Task { await appState.ttsService.updateVoice(voice) } })) {
                        ForEach(TTSService.availableVoices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .fixedSize()
                    Button(appState.ttsService.hasPendingSpeech ? "Stop" : "Preview",
                           systemImage: appState.ttsService.hasPendingSpeech ? "stop.fill" : "play.fill") {
                        if appState.ttsService.hasPendingSpeech {
                            appState.ttsService.stopSpeaking()
                        } else {
                            appState.ttsService.speak("This is a preview of the selected voice.")
                        }
                    }
                    .actionButton()
                }
            }
            Text("Agents speak through PocketTTS on this Mac. The first use downloads the voice model, about 750 MB.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
            switch appState.ttsService.modelPhase {
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading voice model \(Int(fraction * 100))%").settingsCaption() }
            case .initializing:
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the voice model\u{2026}").settingsCaption()
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            case .ready:
                if appState.ttsService.isPreparingSpeech {
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Preparing speech\u{2026}").settingsCaption()
                    }
                }
                if let message = appState.ttsService.lastPlaybackError {
                    Text(message).settingsCaption().fixedSize(horizontal: false, vertical: true)
                }
            case .uninitialized:
                EmptyView()
            }
        }
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
