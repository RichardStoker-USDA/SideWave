// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

struct SpeechSettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("selectedModelVersion") private var selectedVersion = "v3"
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    @State private var showGlossaryBundles = false

    private var currentVersion: ModelVersion { ModelVersion(rawValue: selectedVersion) ?? .v3 }

    var body: some View {
        SettingsCard {
            modelRow(icon: "waveform.badge.mic", title: currentVersion.displayName,
                     detail: "NVIDIA 600M \u{00B7} Converts speech to text")

            if showAdvancedControls {
                SettingsRow(label: "Speech model") {
                    ChoiceMenu(title: "Speech model", value: currentVersion.displayName, selection: $selectedVersion) {
                        ForEach(ModelVersion.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .fixedSize()
                    .disabled(appState.isDictationBusy || !appState.meetingService.canChangeSpeechModel
                              || appState.transcriptionService.modelState.isSettingUp)
                }
                Text("V3 is the default. Ultra uses updated multilingual weights and a larger download. Switching keeps your other downloaded models.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !appState.transcriptionService.modelState.isReady {
                ModelDownloadView(transcriptionService: appState.transcriptionService,
                                  version: currentVersion, embedded: true)
            }

            SettingsDivider()
            // The streaming and vocabulary models ship with the main model,
            // so all three share its readiness.
            modelRow(icon: "waveform.path", title: "Live preview",
                     detail: "Parakeet EOU 120M \u{00B7} Streams draft text and detects pauses")
            SettingsDivider()
            modelRow(icon: "character.book.closed", title: "Vocabulary booster",
                     detail: "CTC 110M \u{00B7} Helps recognition pick your glossary words")
            SettingsDivider()
            Text("Speech models run on this Mac and are stored in ~/Library/Application Support/FluidAudio/Models.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsCard("Glossary bundles") {
            Text("Download curated word lists, check them for updates, and review what changed. Your personal glossaries are never synced.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Browse Bundles\u{2026}") { showGlossaryBundles = true }
                    .actionButton()
                Spacer()
            }
            Text("Bundles update only when you choose, unless you turn on automatic updates for a bundle.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showGlossaryBundles) {
            GlossaryCatalogView(store: .shared, onImport: { _ in }, onOpen: { id in
                appState.requestedGlossaryID = id
                appState.requestedPage = .dictionary
                appState.showMainWindow = true
            })
        }
    }

    private func modelRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).adaptiveSecondary()
            }
            Spacer()
            SpeechModelStatusLabel(state: appState.transcriptionService.modelState)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SpeechModelStatusLabel: View {
    let state: ModelState

    var body: some View {
        switch state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading(let progress):
            Label("Downloading \(Int(progress * 100))%", systemImage: "arrow.down.circle").adaptiveSecondary()
        case .downloadingAuxiliary(let model):
            Label("Downloading \(model)\u{2026}", systemImage: "arrow.down.circle").adaptiveSecondary()
        case .verifying:
            Label("Checking files\u{2026}", systemImage: "checkmark.shield").adaptiveSecondary()
        case .compiling:
            Label("Preparing\u{2026}", systemImage: "hourglass").adaptiveSecondary()
        case .loading:
            Label("Loading\u{2026}", systemImage: "hourglass").adaptiveSecondary()
        case .notDownloaded:
            Label("Not downloaded", systemImage: "arrow.down.to.line").adaptiveSecondary()
        case .error(let message):
            Label("Error: \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).lineLimit(2).truncationMode(.tail)
        }
    }
}
