// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
import SideWaveKit

/// Dashboard-lite: session status, one record control (AX-addressable
/// for the capture rig), the live transcript, and recent history.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcriptPane
            Divider()
            historyPane
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear {
            if !AppSettings.onboardingComplete {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            // The brand mark, alive: calm at rest, flowing while a
            // session runs; the same wave the overlay carries.
            WaveStrands(
                mood: model.phase == .live ? .listening : .calm,
                activityPulse: model.transcriptPulse
            )
            .frame(width: 52, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text("SideWave")
                    .font(.title2.weight(.semibold))
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if let progress = model.setupProgress {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 180)
                    Text(progress.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            recordButton
        }
        .padding(20)
    }

    private var statusLine: String {
        switch model.phase {
        case .idle:
            if !model.modelsReady {
                return model.setupError ?? "Preparing speech models"
            }
            if let notice = model.notice { return notice }
            if model.siblingAppRunning {
                return "The original SideWave is running, so the hotkey is paused here to prevent double dictation. Record still works."
            }
            return "Ready. Press \(AppSettings.hotkey.displayString) anywhere to dictate."
        case .starting:
            return "Starting…"
        case .live:
            if let device = model.resolvedDeviceName {
                return "Listening on \(device)"
            }
            return "Listening"
        case .stopping:
            return "Finishing…"
        }
    }

    private var recordButton: some View {
        Button {
            model.toggleFromUI()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.phase == .idle ? "mic.fill" : "stop.fill")
                Text(recordLabel)
            }
            .frame(minWidth: 96)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(!model.modelsReady && model.phase == .idle)
        .accessibilityIdentifier("record-button")
        .keyboardShortcut("r", modifiers: [.command])
    }

    private var recordLabel: String {
        switch model.phase {
        case .idle: return "Record"
        case .starting: return "Starting"
        case .live: return "Stop"
        case .stopping: return "Finishing"
        }
    }

    // MARK: Transcript

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.phase == .idle ? "Last dictation" : "Live transcript")
                .font(.headline)

            ScrollView {
                if model.settledText.isEmpty && model.settlingText.isEmpty {
                    Text("Your words appear here as you speak.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    (Text(model.settledText).foregroundStyle(.primary)
                        + Text(model.settlingText).foregroundStyle(.secondary))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 84, maxHeight: 150)

            permissionRows
        }
        .padding(20)
    }

    @ViewBuilder
    private var permissionRows: some View {
        if !model.accessibilityGranted {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(Color.accentColor)
                Text("Accessibility permission is needed for the global hotkey and typing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings") {
                    openAccessibilitySettings()
                }
                .controlSize(.small)
                Button("Recheck") {
                    model.refreshPermissions()
                }
                .controlSize(.small)
            }
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: History

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                if !model.history.entries.isEmpty {
                    Button("Clear") { model.history.clear() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            if model.history.entries.isEmpty {
                Text("Finished dictations are kept here, on this Mac only.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(model.history.entries) { entry in
                        HistoryRow(entry: entry)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.finalText)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.date, style: .relative)
                    Text("·")
                    Text(entry.appName)
                    if entry.refined {
                        Text("·")
                        Text("Refined")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.finalText, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")

            Button(role: .destructive) {
                model.history.delete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 3)
    }
}
