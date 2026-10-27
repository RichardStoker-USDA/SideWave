// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

struct PrivacySettingsPane: View {
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 7
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    @AppStorage(TypingService.restoreClipboardKey) private var restoreClipboard = false
    @State private var confirmingRestore = false
    @State private var clipboardAccess = NSPasteboard.general.accessBehavior
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsCard("On this Mac") {
            Text("Speech recognition and Refine run on this Mac. Dictation audio is processed in memory and isn't saved; meeting audio is saved locally so a recording can be recovered. Microphone standby, when on, keeps the input open between dictations. SideWave downloads models and, when you choose, glossary bundles and app updates. It sends no usage analytics or crash reports.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsCard("Clipboard") {
            Text("Most apps, including Terminal, take dictation without the clipboard. Electron apps such as Slack, and long dictations in a browser, get a clipboard paste, and the dictation replaces what you had copied. SideWave doesn't read your clipboard unless you turn on restore.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
            if showAdvancedControls {
                SettingsDivider()
                SettingsToggleRow("Restore clipboard after pasting",
                                  caption: "Reads what you copied right before a clipboard paste and puts it back afterward. The copy stays on this Mac, encrypted in memory, for at most 10 seconds.",
                                  isOn: Binding(get: { restoreClipboard },
                                                set: { on in if on { confirmingRestore = true } else { restoreClipboard = false } }))
                if restoreClipboard {
                    clipboardAccessStatus
                }
            } else if restoreClipboard {
                Text("Restore clipboard after pasting is on. Turn on Advanced view to change it.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Let SideWave read your clipboard?", isPresented: $confirmingRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") {
                restoreClipboard = true
                requestClipboardAccess()
            }
        } message: {
            Text("Before a clipboard paste, SideWave reads what you copied so it can put it back afterward. The copy stays on this Mac, in memory only, and is never saved to disk or logged. Each part is encrypted as soon as it's read, with a key made for that copy alone. The key is erased when your clipboard is put back, and no more than 10 seconds after it was read. After that, no one can decrypt the copy, including you. What's put back stays local to this Mac.\n\nmacOS may ask whether SideWave can paste from other apps. SideWave restores your clipboard only after you allow it.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clipboardAccess = NSPasteboard.general.accessBehavior
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

    /// What macOS currently allows. SideWave reads the clipboard only when macOS already allows it,
    /// so a macOS alert can't appear in the middle of a paste.
    @ViewBuilder private var clipboardAccessStatus: some View {
        switch clipboardAccess {
        case .alwaysAllow:
            statusCaption("macOS allows SideWave to read the clipboard.")
        case .default:
            HStack(alignment: .firstTextBaseline) {
                statusCaption("macOS hasn't allowed SideWave to read the clipboard yet, so it isn't restored. Ask macOS, then allow SideWave in Privacy & Security under Paste from Other Apps.")
                Spacer(minLength: Spacing.md)
                Button("Ask macOS") { requestClipboardAccess() }
                    .actionButton()
            }
        case .ask, .alwaysDeny:
            HStack(alignment: .firstTextBaseline) {
                statusCaption(clipboardAccess == .ask
                    ? "macOS asks before each clipboard read, and SideWave won't let that interrupt a paste, so your clipboard isn't restored yet. Allow SideWave in Privacy & Security under Paste from Other Apps."
                    : "macOS blocks SideWave from reading the clipboard, so it isn't restored. Allow SideWave in Privacy & Security under Paste from Other Apps.")
                Spacer(minLength: Spacing.md)
                Button("Open Privacy & Security") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .actionButton()
            }
        @unknown default:
            EmptyView()
        }
    }

    private func statusCaption(_ text: String) -> some View {
        Text(text)
            .settingsCaption()
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Reads the clipboard once now, so a macOS permission alert, if any, appears here rather
    /// than during a paste. The read can wait on that alert, so it runs off the main thread.
    private func requestClipboardAccess() {
        Task {
            await Task.detached(priority: .userInitiated) { TypingService.requestClipboardAccess() }.value
            clipboardAccess = NSPasteboard.general.accessBehavior
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
            Image(systemName: icon).adaptiveSecondary().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.callout.weight(.semibold).monospacedDigit())
                Text(label).font(.caption).adaptiveSecondary()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
