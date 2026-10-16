// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

struct PrivacySettingsPane: View {
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 7
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsCard("On this Mac") {
            Text("Speech recognition and Refine run on this Mac. Dictation audio is processed in memory and isn't saved; meeting audio is saved locally so a recording can be recovered. Microphone standby, when on, keeps the input open between dictations. SideWave downloads models and, when you choose, glossary bundles and app updates. It sends no usage analytics or crash reports.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsCard("History") {
            SettingsRow(label: "Keep history") {
                ChoiceMenu(title: "History retention",
                           value: HistoryRetention(rawValue: historyRetentionDays)?.displayName ?? "Choose",
                           selection: $historyRetentionDays) {
                    ForEach(HistoryRetention.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .fixedSize()
                .accessibilityLabel("History retention period")
            }
            Text("Finished dictations older than this are removed. Interrupted meeting recordings are kept until you process or discard them.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
            SettingsDivider()
            HStack(alignment: .firstTextBaseline) {
                Text("History stores the original and refined text, earlier stages, the time, the target app, and the model used. It doesn't store dictation audio.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.md)
                Button("Show in Finder") {
                    let directory = AppPaths.applicationSupportDirectory()
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                }
                .actionButton()
            }
        }
        .onChange(of: historyRetentionDays) { _, _ in HistoryStore.shared.pruneExpiredEntries() }

        SettingsCard("Network activity") {
            Text("Every download and update check is recorded here, including failed or cancelled transfers. The record stays on this Mac until you clear it and never includes your text.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
            NetworkActivitySummaryRow(log: NetworkActivityLog.shared)
            HStack {
                Button("Open Data Transparency") { openWindow(id: "data-transparency") }
                    .actionButton()
                Spacer()
            }
        }
    }
}

/// Event count, total downloaded, and total uploaded, updated live.
struct NetworkActivitySummaryRow: View {
    let log: NetworkActivityLog

    var body: some View {
        HStack(spacing: Spacing.lg) {
            stat("Events", value: "\(log.events.count)", icon: "list.number")
            Divider().frame(height: 28)
            stat("Downloaded", value: log.totalIncomingBytes.byteCountText, icon: "arrow.down.circle")
            Divider().frame(height: 28)
            stat("Uploaded", value: log.totalOutgoingBytes == 0 ? "None" : log.totalOutgoingBytes.byteCountText,
                 icon: "arrow.up.circle")
            Spacer(minLength: 0)
        }
    }

    private func stat(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.callout.weight(.semibold).monospacedDigit())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
