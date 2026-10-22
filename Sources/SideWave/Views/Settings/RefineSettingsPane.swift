// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

struct RefineSettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("skipRefine") private var skipRefine = false
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    @AppStorage("refineCadence") private var refineCadence = "standard"
    #if DEBUG
    /// Runs AFM 3 with the macOS 26 prompt profile. Read by
    /// DictationFormatterService.effectiveAFMGeneration.
    @AppStorage("devForceAFMGen1Profile") private var devForceAFMGen1Profile = false
    #endif
    @State private var showPromptPreview = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }

    private var refineEnabled: Binding<Bool> {
        Binding(
            // On only when the model is enabled and skipRefine is clear, so this
            // pane agrees with the Dictation tab's Enable Refine switch.
            get: { appState.dictationCleanupEnabled && !skipRefine },
            set: { newValue in
                // Remembered at launch; without it the model loads again on relaunch.
                UserDefaults.standard.set(!newValue, forKey: "refineDisabledByUser")
                if newValue {
                    // A preset can set skipRefine without the auto-forced marker,
                    // and dictationCleanupEnabled's didSet only clears the marked case.
                    skipRefine = false
                    UserDefaults.standard.removeObject(forKey: "skipRefineAutoForced")
                }
                appState.dictationCleanupEnabled = newValue
            }
        )
    }

    var body: some View {
        SettingsCard {
            SettingsToggleRow("Refine",
                              caption: "A local language model fixes recognition errors, punctuation, and filler words. Your original text stays in History, and nothing is sent off this Mac.",
                              isOn: refineEnabled)
                .disabled(appState.lowMemoryMode || appState.isDictationBusy || appState.isProcessingAgenticEdit)
                .help(appState.lowMemoryMode ? "Refine needs at least 8 GB of memory." : "Refine dictated text before it's sent")

            if appState.lowMemoryMode {
                Text("Refine is unavailable on Macs with less than 8 GB of memory.")
                    .settingsCaption()
            }

            if appState.dictationCleanupEnabled {
                SettingsDivider()
                SettingsRow(label: "Model") {
                    ChoiceMenu(title: "Refine model", value: DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend)?.displayName ?? "Choose model", selection: $appState.dictationCleanupBackend) {
                        ForEach(DictationFormatterService.Backend.availableBackends) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .fixedSize()
                    .disabled(isBackendSwitchLocked)
                    .help(backendSwitchLockedHelp)
                }
                Text("Apple Intelligence uses the model built into macOS. Gemma downloads once: E2B is the smallest and fastest (about 3 GB), E4B uses about 5.2 GB, and 12B uses about 6.8 GB and suits Macs with 24 GB of memory or more.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()
                SettingsRow(label: "Status") { RefineStatusLabel(state: appState.dictationFormatter.state) }
                stateDetail
            }
        }
        .animation(reduceMotion ? nil : Animate.standard, value: appState.dictationCleanupEnabled)
        .settingsSpotlight(key: "refine", appState: appState)
        .sheet(isPresented: $showPromptPreview) {
            PromptPreviewSheet(previewBuilder: {
                DictationFormatterService.makePromptPreview(
                    customInstructions: appState.dictationCleanupInstructions,
                    backend: DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend) ?? .gemma4E2B)
            }, onClose: { showPromptPreview = false })
        }

        if showAdvancedControls {
            SettingsCard("Expert") {
                SettingsRow(label: "Refine cadence") {
                    ChoiceMenu(title: "Refine cadence", value: refineCadence.capitalized, selection: $refineCadence) {
                        Text("Standard").tag("standard")
                        Text("Faster").tag("faster")
                        Text("Aggressive").tag("aggressive")
                    }
                    .fixedSize()
                    .disabled(appState.transcriptionService.isRecording || appState.isCleaningUp)
                    .help(appState.transcriptionService.isRecording || appState.isCleaningUp ? "Locked while dictating" : "")
                }
                Text("How soon a pause in speech starts a Refine pass. Fixed-interval refine in Experimental can also split continuous speech; whichever comes first is used.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
                #if DEBUG
                if devAFMGen1OverrideVisible {
                    SettingsDivider()
                    SettingsToggleRow("Use gen-1 prompt profile",
                                      caption: "Debug builds only. Runs AFM 3 with the compact prompt, output schema, and refusal retry used on macOS 26. The model doesn't change.",
                                      isOn: $devForceAFMGen1Profile)
                }
                #endif
            }
        }

        ModelStorageSection(appState: appState)
    }

    @ViewBuilder
    private var stateDetail: some View {
        let backend = appState.dictationFormatter.activeBackend
        let isAFM = backend == .appleIntelligence || backend == .appleIntelligenceLegacy
        switch appState.dictationFormatter.state {
        case .disabled, .unloaded:
            let isUnloaded = appState.dictationFormatter.state == .unloaded
            HStack(spacing: Spacing.sm) {
                Text(isAFM ? (isUnloaded ? "Ready to reconnect." : "Uses Apple Intelligence. No download.")
                     : isUnloaded ? "Downloaded. Loads in a few seconds." : "\(backend.diskSize) download, stored for reuse.")
                    .settingsCaption()
                Spacer()
                Button(isAFM ? (isUnloaded ? "Reconnect" : "Connect")
                       : isUnloaded ? "Load Model" : "Download \(backend.displayName)") {
                    if isUnloaded { appState.dictationFormatter.reload() } else { appState.dictationFormatter.enable() }
                }
                .prominentActionButton()
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ProgressView(value: progress)
                    .animation(reduceMotion ? nil : .linear(duration: 0.15), value: progress)
                    .accessibilityLabel("Downloading \(backend.displayName), \(Int(progress * 100)) percent")
                HStack {
                    Text(progress < 0.95 ? "Downloading \(backend.displayName)\u{2026}" : "Verifying download\u{2026}")
                        .settingsCaption()
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit()).adaptiveSecondary()
                        .contentTransition(.numericText(value: Double(Int(progress * 100))))
                    if progress < 0.95 {
                        Button("Cancel") {
                            appState.dictationFormatter.cancelDownload()
                            appState.dictationCleanupEnabled = false
                        }
                        .actionButton()
                        .accessibilityLabel("Cancel model download")
                    }
                }
                Text("\(backend.diskSize) download. It can take a few minutes on a slow connection.")
                    .settingsCaption()
            }

        case .loading:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(appState.dictationFormatter.preparationDetail + "\u{2026}").settingsCaption()
                Spacer()
            }

        case .error(let message):
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).accessibilityHidden(true)
                Text(message).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.sm)
                Button("Retry") { appState.dictationFormatter.reload() }
                    .prominentActionButton()
                    .accessibilityLabel("Retry model preparation")
            }

        case .ready, .generating:
            SettingsDivider()
            SettingsRow(label: "Prompt preview") {
                Button("Preview") { showPromptPreview = true }
                    .actionButton()
                    .help("Show the instructions Refine receives with your current template and settings")
            }
            Text("Shows what Refine receives with your current template, vocabulary, and instructions.")
                .settingsCaption()
            SettingsDivider()
            SettingsRow(label: isAFM ? "Apple Intelligence session" : "Model in memory") {
                Button(isAFM ? "Disconnect" : "Unload") { appState.dictationFormatter.unloadModel() }
                    .actionButton()
                    .accessibilityLabel(isAFM ? "Disconnect Apple Intelligence session" : "Unload model from memory")
            }
            Text(isAFM ? "Ends the current session. Apple Intelligence stays available and reconnects when needed."
                       : "Frees the memory the model uses. The downloaded files stay on this Mac.")
                .settingsCaption()

        case .unavailable(let message):
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "info.circle").adaptiveSecondary().accessibilityHidden(true)
                Text(message).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.sm)
                Button("Open System Settings") { Self.openAppleIntelligenceSettings() }
                    .prominentActionButton()
                    .accessibilityLabel("Open System Settings to turn on Apple Intelligence")
            }
        }
    }

    /// Locked while a model loads or generates, or during a session: switching
    /// mid-download cancels and reloads, and switching mid-generation tears the
    /// model down under an active segment.
    private var isBackendSwitchLocked: Bool {
        if appState.isDictationBusy || appState.isProcessingAgenticEdit { return true }
        switch appState.dictationFormatter.state {
        case .downloading, .loading, .generating: return true
        default: return false
        }
    }

    private var backendSwitchLockedHelp: String {
        if appState.isDictationBusy || appState.isProcessingAgenticEdit { return "Locked while dictating" }
        switch appState.dictationFormatter.state {
        case .downloading, .loading, .generating: return "Wait for the current model to finish loading or refining."
        default: return "Choose the model Refine uses"
        }
    }

    #if DEBUG
    /// Only meaningful for Apple Intelligence on macOS 27, where the gen-2 model runs.
    private var devAFMGen1OverrideVisible: Bool {
        let backend = appState.dictationCleanupBackend
        let isAFM = backend == DictationFormatterService.Backend.appleIntelligence.rawValue
            || backend == DictationFormatterService.Backend.appleIntelligenceLegacy.rawValue
        return isAFM && AFMRuntime.generation == .gen2
    }
    #endif

    /// Pane identifiers change between macOS releases, so try the specific
    /// pane first and fall back to System Settings.
    static func openAppleIntelligenceSettings() {
        for candidate in ["x-apple.systempreferences:com.apple.preference.applemodelintelligence",
                          "x-apple.systempreferences:com.apple.preferences.AppleIntelligenceSiri",
                          "x-apple.systempreferences:com.apple.Siri-Settings.extension",
                          "x-apple.systempreferences:"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

struct RefineStatusLabel: View {
    let state: DictationFormatterService.State

    var body: some View {
        switch state {
        case .disabled:
            Label("Not loaded", systemImage: "arrow.down.to.line").adaptiveSecondary()
        case .downloading(let progress):
            Label("Downloading \(Int(progress * 100))%", systemImage: "arrow.down.circle").adaptiveSecondary()
        case .loading:
            Label("Loading\u{2026}", systemImage: "hourglass").adaptiveSecondary()
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unloaded:
            Label("Downloaded, not in memory", systemImage: "internaldrive").adaptiveSecondary()
        case .generating:
            Label("Refining\u{2026}", systemImage: "wand.and.rays").adaptiveSecondary()
        case .error(let message):
            Label("Error: \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).lineLimit(2).truncationMode(.tail)
        case .unavailable:
            Label("Unavailable", systemImage: "xmark.circle").adaptiveSecondary()
        }
    }
}
