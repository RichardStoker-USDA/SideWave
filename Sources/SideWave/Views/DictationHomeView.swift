// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

enum DictationSessionPhase: String, CaseIterable {
    case idle, preparing, listening, finishing, delivered, failed

    var title: String {
        switch self {
        case .idle: "Ready to dictate"
        case .preparing: "Preparing microphone"
        case .listening: "Listening"
        case .finishing: "Finishing dictation"
        case .delivered: "Dictation finished"
        case .failed: "Dictation needs attention"
        }
    }

    var isBusy: Bool { self == .preparing || self == .listening || self == .finishing }
}

struct DictationHomeView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("skipRefine") private var skipRefine = false
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    @State private var recordingShortcut = false
    @State private var cachedBackends: Set<String> = []
    @State private var showsInstructions = false
    @State private var offeredLanguages = DictationFormatterService.OutputLanguage.allCases

    private var phase: DictationSessionPhase { appState.dictationSessionPhase }
    private var pending: String? { phase.isBusy ? nil : appState.pendingSessionText }
    private var recentText: String { pending ?? appState.historyStore.entries.first?.text ?? "" }
    private var template: DictationFormatterService.Template { appState.selectedDictationTemplate }
    private var refineEnabled: Bool { appState.dictationCleanupEnabled && !skipRefine }
    private var controlsBusy: Bool { appState.isDictationBusy || appState.isProcessingAgenticEdit }
    private var backendLocked: Bool {
        if controlsBusy { return true }
        switch appState.dictationFormatter.state {
        case .loading, .downloading, .generating: return true
        default: return false
        }
    }

    var body: some View {
        DictationHomeSurface(
            phase: phase,
            speechModelState: appState.transcriptionService.modelState,
            statusDetail: appState.lastDictationError ?? appState.historyStore.persistenceError,
            hotkey: appState.hotkeyManager.shortcut.displayString,
            transcript: recentText,
            transcriptLabel: pending == nil ? "Recent dictation" : "Paused dictation",
            metadata: pending == nil ? appState.historyStore.entries.first?.relativeTimeString ?? "" : "Ready to resume",
            hasPendingSession: pending != nil,
            audioLevel: appState.transcriptionService.audioLevel,
            isEditingDocument: appState.isProcessingAgenticEdit,
            documentTemplate: template.isSpecialty ? template.workspaceTitle : nil,
            isRefining: appState.dictationFormatter.state == .generating,
            refiningBackend: appState.dictationFormatter.activeBackend.huggingFaceRepoID == nil ? .appleIntelligence : .gemma,
            reduceMotion: reduceMotion || appState.reduceAppMotion,
            advanced: $showAdvancedControls,
            advancedControls: showAdvancedControls ? AnyView(DictationAdvancedControls(appState: appState)) : nil,
            onPrimaryAction: primaryAction,
            onCopy: { TypingService.writeSensitiveString(recentText, to: .general) },
            onDiscard: { appState.discardPendingSession() },
            onPause: { Task { await appState.handleSoftStop() } },
            onOpenDocument: { appState.openSpecialtyEditor() },
            onHistory: { appState.requestedPage = .history },
            onSettings: { openWindow(id: "settings") }
        ) {
            everydayControls
        }
        .sheet(isPresented: $showsInstructions) { DocumentInstructionsView(appState: appState) }
        .onChange(of: recordingShortcut) { _, value in appState.hotkeyManager.isCapturingShortcut = value }
        .onDisappear { appState.hotkeyManager.isCapturingShortcut = false }
        .task {
            let cached = await Task.detached(priority: .utility) {
                Set(DictationFormatterService.Backend.allCases.filter {
                    $0.huggingFaceRepoID != nil && DictationFormatterService.isGemmaBackendCached($0)
                }.map(\.rawValue))
            }.value
            guard !Task.isCancelled else { return }
            cachedBackends = cached
        }
        .onChange(of: appState.dictationFormatter.state) { _, state in
            if state == .ready, appState.dictationFormatter.activeBackend.huggingFaceRepoID != nil {
                cachedBackends.insert(appState.dictationFormatter.activeBackend.rawValue)
            }
        }
        .task(id: appState.dictationCleanupBackend) {
            let backend = DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend) ?? .gemma4E2B
            offeredLanguages = DictationFormatterService.offeredOutputLanguages(for: backend)
        }
    }

    private var everydayControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                WorkspaceField("Template", icon: "text.alignleft") {
                    DictationTemplateMenu(appState: appState, opensDocument: false)
                }
                WorkspaceField("Output language", icon: "globe") { languageMenu }
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(refineEnabled || template.isSpecialty ? template.workspaceDescription : "Keep the recognized text without a model refinement pass.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Formatting Rules") { showsInstructions = true }
                    .buttonStyle(.borderless).font(.caption).fixedSize()
                    .disabled(controlsBusy || !refineEnabled)
            }
            HStack(alignment: .top, spacing: 20) {
                WorkspaceField("Refine model", icon: "cpu") { modelMenu }
                WorkspaceField("Microphone", icon: "mic") { microphoneMenu }
            }
            HStack(alignment: .top, spacing: 20) {
                WorkspaceField("Send to", icon: template.isSpecialty ? "doc.text" : "arrow.up.forward.app") { destinationMenu }

                WorkspaceField("Shortcut", icon: "keyboard") {
                    HStack(spacing: 8) {
                        HotkeyRecorderButton(shortcut: appState.hotkeyManager.shortcut, isRecording: $recordingShortcut,
                                             onRecord: { appState.saveShortcut($0) })
                            .help("Click to change your dictation shortcut")
                            .accessibilityLabel("Change dictation shortcut")
                        Spacer(minLength: 0)
                        Menu {
                            Button("Tap to Start and Stop") { appState.hotkeyManager.smartPTTEnabled = false }
                            Button("Tap to Toggle, Hold to Talk") { appState.hotkeyManager.smartPTTEnabled = true }
                        } label: {
                            Text(appState.hotkeyManager.smartPTTEnabled ? "Tap or hold" : "Tap to toggle")
                                .font(.caption).lineLimit(1)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Shortcut behavior")
                    }
                    .disabled(controlsBusy)
                }

            }
            if appState.audioDeviceManager.selectedDeviceIsBluetooth {
                Text("Bluetooth microphone use can reduce headphone playback quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if refineEnabled || template.isSpecialty { refineReadiness }
        }
    }

    private var microphoneMenu: some View {
        WorkspaceMenu(value: appState.audioDeviceManager.selectedDevice?.name
                      ?? appState.audioDeviceManager.resolvedDefaultDevice.map { "System: \($0.name)" } ?? "System default") {
            Picker("Microphone", selection: Binding(
                get: { appState.audioDeviceManager.selectedDeviceUID ?? "" },
                set: { appState.audioDeviceManager.userDidSelectDevice($0.isEmpty ? nil : $0) }
            )) {
                Text("System default").tag("")
                ForEach(appState.audioDeviceManager.availableDevices) { Text($0.pickerLabel()).tag($0.uid) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Audio Settings…") { openSettingsCategory(.settingsAudio) }
        }
        .disabled(controlsBusy).accessibilityLabel("Microphone")
    }

    private var languageMenu: some View {
        let current = DictationFormatterService.OutputLanguage.from(code: appState.dictationOutputLanguage)
        let languages = offeredLanguages.contains(current) ? offeredLanguages : offeredLanguages + [current]
        return WorkspaceMenu(value: current == .matchInput ? "As spoken" : current.displayName) {
            Picker("Output language", selection: $appState.dictationOutputLanguage) {
                ForEach(languages) { language in
                    Text(language == .matchInput ? "As spoken" : language.displayName).tag(language.rawValue)
                }
            }
            .pickerStyle(.inline)
        }
        .disabled(controlsBusy || !refineEnabled)
        .help(refineEnabled ? "Keep the language you speak, or translate with the selected model" : "Choose a refining template to translate your words")
        .accessibilityLabel("Output language")
    }

    private var modelMenu: some View {
        WorkspaceMenu(value: DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend)?.displayName ?? "Choose model") {
            Picker("Refine model", selection: $appState.dictationCleanupBackend) {
                ForEach(DictationFormatterService.Backend.availableBackends, id: \.rawValue) { backend in
                    Text(backend.displayName + (backend.huggingFaceRepoID != nil && !cachedBackends.contains(backend.rawValue) ? " · Download required" : ""))
                        .tag(backend.rawValue)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Model Settings…") { openSettingsCategory(.settingsRefine) }
        }
        .disabled(backendLocked || (!refineEnabled && !template.isSpecialty))
        .accessibilityLabel("Refine model")
    }

    private var destinationTitle: String {
        if template.isSpecialty { return "Document preview" }
        if appState.dictationTargetMode == DictationTargetMode.assignedWindow.rawValue { return appState.assignedAppName ?? "Choose an app" }
        return appState.pasteTargetTiming == "finish" ? "App at Finish" : "App at Start"
    }

    private var destinationMenu: some View {
        WorkspaceMenu(value: destinationTitle) {
            if template.isSpecialty {
                Button("Open Document Preview") { appState.openSpecialtyEditor() }
                Text("Review and copy the finished document.")
            } else {
                Button("App at Start") { selectDestination(timing: "start") }
                Button("App at Finish") { selectDestination(timing: "finish") }
                Menu("A Specific App or Window") {
                    ForEach(AppState.runningApps()) { app in
                        let windows = WindowTargetingService.windows(for: app.pid)
                        if windows.count > 1 {
                            Menu(app.name) {
                                Button("Any Window") {
                                    appState.dictationTargetMode = DictationTargetMode.assignedWindow.rawValue
                                    appState.assignTarget(pid: app.pid, name: app.name)
                                }
                                ForEach(windows) { window in
                                    Button(window.title) {
                                        appState.dictationTargetMode = DictationTargetMode.assignedWindow.rawValue
                                        appState.assignWindow(window)
                                    }
                                }
                            }
                        } else {
                            Button(app.name) {
                                appState.dictationTargetMode = DictationTargetMode.assignedWindow.rawValue
                                if let window = windows.first { appState.assignWindow(window) }
                                else { appState.assignTarget(pid: app.pid, name: app.name) }
                            }
                        }
                    }
                }
            }
        }
        .disabled(controlsBusy)
        .accessibilityLabel("Send dictated text to")
        .help(template.isSpecialty ? "Document templates stay in SideWave for review and copying" : "The app in front when you start or finish speaking, or one app you choose")
    }

    private func selectDestination(timing: String) {
        appState.dictationTargetMode = DictationTargetMode.focusedWindow.rawValue
        appState.pasteTargetTiming = timing
        appState.clearAssignedTarget()
    }

    @ViewBuilder private var refineReadiness: some View {
        switch appState.dictationFormatter.state {
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 72)
                Text("Downloading \(appState.dictationFormatter.activeBackend.displayName)")
                Spacer(minLength: 0)
                Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Preparing the model on this Mac")
            }.font(.caption).foregroundStyle(.secondary)
        case .error, .unloaded, .disabled, .unavailable:
            HStack(alignment: .firstTextBaseline) {
                Text("Refine needs preparation. Your captured words are kept.")
                Spacer(minLength: 4)
                Button("Model Settings") { openSettingsCategory(.settingsRefine) }.buttonStyle(.borderless)
            }.font(.caption).foregroundStyle(.secondary)
        case .ready, .generating: EmptyView()
        }
    }

    private func openSettingsCategory(_ category: SidebarItem) {
        appState.requestedSettingsTab = category
        openWindow(id: "settings")
    }

    private func primaryAction() {
        if !phase.isBusy, !appState.transcriptionService.modelState.isReady {
            openSettingsCategory(.settingsDictation)
            return
        }
        guard !appState.isProcessingAgenticEdit else { appState.openSpecialtyEditor(); return }
        switch phase {
        case .preparing: Task { await appState.handleCancelRecording() }
        case .listening: Task { await appState.handleStopRecording() }
        case .finishing: break
        default:
            if pending != nil { appState.resumePendingSession() }
            else { appState.handleStartRecording() }
        }
    }
}

/// The same everyday controls and session feedback remain in place in both view modes.
struct DictationHomeSurface<Controls: View>: View {
    let phase: DictationSessionPhase
    var speechModelState: ModelState = .ready
    var statusDetail: String?
    let hotkey: String
    let transcript: String
    let transcriptLabel: String
    var metadata = ""
    var hasPendingSession = false
    var audioLevel = 0.0
    var isEditingDocument = false
    var documentTemplate: String?
    var isRefining = false
    var refiningBackend: RefiningBackendForPalette = .appleIntelligence
    var reduceMotion = false
    var advanced: Binding<Bool> = .constant(false)
    var advancedControls: AnyView? = nil
    let onPrimaryAction: () -> Void
    let onCopy: () -> Void
    let onDiscard: () -> Void
    var onPause: () -> Void = {}
    var onOpenDocument: () -> Void = {}
    var onHistory: () -> Void = {}
    var onSettings: () -> Void = {}
    @ViewBuilder let controls: Controls
    @State private var expandsRecentOutput = false

    var speechNeedsPreparation: Bool { !phase.isBusy && !isEditingDocument && !speechModelState.isReady }

    private var actionLabel: String {
        if speechNeedsPreparation { return speechModelState.isSettingUp ? "Preparing…" : "Model settings" }
        if isEditingDocument { return "Updating document" }
        switch phase {
        case .preparing: return "Cancel"
        case .listening: return documentTemplate == nil ? "Finish & paste" : "Finish dictation"
        case .finishing: return "Finishing…"
        default: return hasPendingSession ? "Resume" : documentTemplate == nil ? "Dictate" : "New dictation"
        }
    }

    private var detail: String {
        if speechNeedsPreparation {
            switch speechModelState {
            case .loading: return "Loading speech engines. The microphone stays off."
            case .compiling: return "Preparing speech engines for this Mac. This can take a moment."
            case .verifying: return "Checking speech model files."
            case .downloading(let progress): return "Downloading speech models: \(Int(progress * 100))%."
            case .downloadingAuxiliary(let model): return "Preparing \(model.lowercased())."
            case .error(let message): return message
            case .notDownloaded: return "Prepare the speech models before dictating."
            case .ready: break
            }
        }
        if let statusDetail { return statusDetail }
        if isEditingDocument { return "Applying your instruction. The previous document is kept." }
        switch phase {
        case .preparing: return "Speak when the microphone is ready."
        case .listening: return "Press \(hotkey) again to finish."
        case .finishing: return "Recording stopped. Your words are still being processed."
        default: return documentTemplate == nil ? "Place your cursor, then press \(hotkey)." : "Your document opens as you dictate. Review it before copying."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text("Dictation").font(.system(size: 22, weight: .semibold))
                    Spacer(minLength: 8)
                    GlassSegmentedPicker(selection: advanced, segments: [
                        .init("Simple", tag: false), .init("Advanced", tag: true)
                    ], accessibilityLabel: "View mode")
                    .help("Advanced adds tuning controls without changing your dictation settings")
                    Button(action: onSettings) { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Open Settings").accessibilityLabel("Open Settings")
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(speechNeedsPreparation
                                ? (speechModelState.isSettingUp ? "Preparing speech recognition" : "Speech recognition needs attention")
                                : isEditingDocument ? "Updating document" : phase.title)
                                .font(.headline)
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if phase == .listening {
                            Button("Pause", systemImage: "pause.fill", action: onPause)
                                .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                                .help("Keep this dictation and resume later")
                        }
                        Button(action: onPrimaryAction) {
                            HStack(spacing: 7) {
                                if phase == .finishing || isEditingDocument || (speechNeedsPreparation && speechModelState.isSettingUp) { ProgressView().controlSize(.small) }
                                else { Image(systemName: phase == .listening || phase == .preparing ? "stop.fill" : "mic.fill") }
                                Text(actionLabel)
                            }.padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                        .disabled(phase == .finishing || isEditingDocument || (speechNeedsPreparation && speechModelState.isSettingUp))
                        .keyboardShortcut(.return, modifiers: [.command])
                    }

                    AudioWaveVisualizer(
                        audioLevel: phase == .listening && audioLevel.isFinite ? max(0, audioLevel) : 0,
                        colorMode: "rainbow", sensitivity: 0.5, liquidGlass: false,
                        isCleanupMode: (phase == .finishing || isEditingDocument) && isRefining,
                        isRefining: isRefining, isWarmingUp: phase == .preparing || (speechNeedsPreparation && speechModelState.isSettingUp),
                        refiningBackend: refiningBackend,
                        isIdleBreathing: !phase.isBusy && !isEditingDocument, reduceMotion: reduceMotion
                    )
                    .frame(height: 22).accessibilityHidden(true)
                    controls
                    if documentTemplate != nil {
                        HStack {
                            Label("Review before copying", systemImage: "doc.text")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Open Document", systemImage: "arrow.up.forward.square", action: onOpenDocument)
                                .buttonStyle(.borderless).font(.callout)
                        }
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
                recentOutput
                if let advancedControls {
                    Divider()
                    advancedControls
                }
            }
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
            .padding(24)
        }
        .scrollIndicators(.automatic)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: advanced.wrappedValue)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: expandsRecentOutput)
    }

    private var recentOutput: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(transcriptLabel).font(.callout.weight(.semibold))
                Text(metadata).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !transcript.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                        .buttonStyle(.borderless).font(.caption)
                }
                Button("History", action: onHistory).buttonStyle(.borderless).font(.caption)
            }
            if transcript.isEmpty {
                Text("Finished dictation is saved here and in History.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(transcript).font(.system(size: 14)).lineSpacing(4)
                    .lineLimit(expandsRecentOutput ? nil : 2)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if transcript.count > 180 || transcript.contains("\n") || hasPendingSession {
                    HStack {
                        if transcript.count > 180 || transcript.contains("\n") {
                            Button(expandsRecentOutput ? "Show less" : "Read more") { expandsRecentOutput.toggle() }
                                .buttonStyle(.borderless).font(.caption)
                        }
                        Spacer()
                        if hasPendingSession {
                            Button("Discard Paused Dictation", role: .destructive, action: onDiscard)
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
        }.padding(.horizontal, 2)
    }
}

struct WorkspaceField<Control: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let control: Control

    init(_ title: String, icon: String, @ViewBuilder control: () -> Control) {
        self.title = title; self.icon = icon; self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            control.frame(height: 30)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-\(title)")
    }
}

struct WorkspaceMenu<Options: View>: View {
    let value: String
    @ViewBuilder let options: Options

    var body: some View {
        Menu { options } label: {
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).frame(height: 30)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .accessibilityValue(value)
    }
}

struct DictationTemplateMenu: View {
    @Bindable var appState: AppState
    var opensDocument = false
    var documentsOnly = false
    @AppStorage("skipRefine") private var skipRefine = false

    var showsSelectedTemplate: Bool {
        appState.selectedDictationTemplate.isSpecialty || (appState.dictationCleanupEnabled && !skipRefine)
    }

    var selectionTitle: String {
        showsSelectedTemplate ? appState.selectedDictationTemplate.workspaceTitle : "As spoken"
    }

    var body: some View {
        WorkspaceMenu(value: selectionTitle) {
            if !documentsOnly {
                Section("Paste into an app") {
                    Button { appState.selectDictationOutput(nil, openDocument: opensDocument) } label: {
                        Label("As Spoken · No Refinement", systemImage: showsSelectedTemplate ? "text.alignleft" : "checkmark")
                    }
                    ForEach(DictationFormatterService.Template.allCases.filter { !$0.isSpecialty }) { option in
                        choice(option)
                    }
                }
            }
            Section("Review as a document") {
                ForEach(DictationFormatterService.Template.allCases.filter(\.isSpecialty)) { option in choice(option) }
            }
        }
        .disabled(appState.isDictationBusy || appState.isProcessingAgenticEdit || appState.pendingSessionText != nil)
        .help(appState.pendingSessionText == nil ? "Choose how your dictation is delivered" : "Resume or discard the paused dictation before changing templates")
        .accessibilityLabel("Template")
    }

    private func choice(_ template: DictationFormatterService.Template) -> some View {
        Button { appState.selectDictationOutput(template, openDocument: opensDocument) } label: {
            Label(template.workspaceTitle, systemImage: template == appState.selectedDictationTemplate && showsSelectedTemplate ? "checkmark" : template.isSpecialty ? "doc.text" : "text.alignleft")
        }
    }
}

extension DictationFormatterService.Template {
    var workspaceTitle: String {
        switch self {
        case .instructions: "Instructions"
        case .emailReady: "Email"
        default: displayName
        }
    }

    var workspaceDescription: String {
        switch self {
        case .standard: "Clean up grammar and filler words while keeping your voice."
        case .professional: "Clear, polished wording for work and formal writing."
        case .concise: "Tighten the wording while keeping the important details."
        case .emailReady: "Turn your dictation into an email to review and copy."
        case .instructions: "Build clear steps and instructions in a document preview."
        case .aiPrompt: "Organize your request into a structured prompt to review."
        case .custom: "Shape a document with your own formatting rules."
        }
    }
}

private struct DictationAdvancedControls: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sideWaveExperience") private var experience = "full"
    @AppStorage("dictationAudioControl") private var audioControl = "lower"
    @AppStorage("dictationVolumeReduction") private var volumeReduction = 60.0
    @AppStorage("skipRefine") private var skipRefine = false
    @AppStorage("useDualEngineSmartPTT") private var dualEngine = true
    @AppStorage("useRealTimeRefine") private var liveRefine = true
    @AppStorage("performFinalRefinePass") private var finalRefine = true
    @AppStorage("homeRecordingOptionsOpen") private var showsRecordingOptions = true
    @AppStorage("homePipelineOptionsOpen") private var showsPipeline = false
    private var busy: Bool { appState.isDictationBusy || appState.isProcessingAgenticEdit }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Advanced controls").font(.headline)
                Spacer()
                Button("All Dictation Settings") {
                    appState.requestedSettingsTab = .settingsAdvanced
                    openWindow(id: "settings")
                }.buttonStyle(.borderless).font(.caption)
            }
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup("Recording & delivery", isExpanded: $showsRecordingOptions) {
                    recordingOptions.padding(.top, Spacing.md).padding(.bottom, Spacing.xs)
                }
                .disclosureGroupStyle(.row)
                if appState.dictationSessionPhase.isBusy {
                    Divider().padding(.vertical, Spacing.md)
                    liveDiagnostics
                }
                Divider().padding(.vertical, Spacing.md)
                DisclosureGroup("Recognition & refinement", isExpanded: $showsPipeline) {
                    pipelineOptions.padding(.top, Spacing.md).padding(.bottom, Spacing.xs)
                }
                .disclosureGroupStyle(.row)
            }
            .padding(Spacing.lg)
            .settingsCardStyle()
        }
        .font(.callout).toggleStyle(.switch).controlSize(.small)
        .disabled(busy)
    }

    private var recordingOptions: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                PreferenceToggle("Keep microphone on standby", isOn: $appState.keepMicOnStandby)
                    .help("Keeps the input device awake between sessions. The macOS microphone indicator remains visible.")
                Text(appState.isMicOnStandby ? "The microphone is on standby." : "The microphone is released between dictations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if appState.hotkeyManager.smartPTTEnabled {
                PreferenceToggle("Refine held dictation", isOn: $appState.smartPTTAlwaysRefine)
                PreferenceToggle("Submit after pasting", isOn: $appState.smartPTTAutoSubmit)
                if appState.smartPTTAutoSubmit {
                    PreferenceRow(label: "Submit key") {
                        ChoiceMenu(title: "Submit key", value: appState.smartPTTAutoSubmitKey == "shift-return" ? "Shift + Return" : "Return", selection: $appState.smartPTTAutoSubmitKey) {
                            Text("Return").tag("return")
                            Text("Shift + Return").tag("shift-return")
                        }.fixedSize()
                    }
                }
            }
            PreferenceRow(label: "Other audio while dictating") {
                ChoiceMenu(title: "Other audio", value: ["none": "Keep volume", "lower": "Lower volume", "mute": "Mute"][audioControl] ?? "Keep volume", selection: $audioControl) {
                    Text("Keep volume").tag("none")
                    Text("Lower volume").tag("lower")
                    Text("Mute").tag("mute")
                }.fixedSize()
            }
            if audioControl == "lower" {
                PreferenceRow(label: "Volume reduction") {
                    HStack(spacing: Spacing.sm) {
                        Slider(value: $volumeReduction, in: 10...100, step: 10)
                            .frame(width: 180)
                            .accessibilityLabel("Volume reduction")
                            .accessibilityValue("\(Int(volumeReduction)) percent")
                        Text("\(Int(volumeReduction))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var pipelineOptions: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            PreferenceRow(label: "Dictation Mode") {
                ChoiceMenu(title: "Dictation Mode", value: ["full": "Complete", "standard": "Basic", "speedy": "Minimalistic"][experience] ?? "Complete", selection: Binding(
                    get: { experience }, set: { ExperiencePreset.apply($0, appState: appState) }
                )) {
                    Text("Complete").tag("full")
                    Text("Basic").tag("standard")
                    Text("Minimalistic").tag("speedy")
                }
                .fixedSize()
                .disabled(appState.pendingSessionText != nil)
            }
            Text(ExperiencePreset.description(for: experience, refinementEnabled: appState.dictationCleanupEnabled && !skipRefine))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PreferenceToggle("Refine while speaking", isOn: $liveRefine)
                .disabled(skipRefine || !appState.dictationCleanupEnabled || !dualEngine)
            PreferenceToggle("Final refinement pass", isOn: $finalRefine)
                .disabled(skipRefine || !appState.dictationCleanupEnabled)
            Button("Speech Models and Pipeline Settings") {
                appState.requestedSettingsTab = .settingsDictation
                openWindow(id: "settings")
            }.buttonStyle(.link)
        }
    }

    private var liveDiagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live activity").font(.callout.weight(.medium))
            HStack(spacing: 20) {
                diagnostic("Words", value: "\(appState.wordsTranscribedCount)")
                diagnostic("Segments", value: "\(appState.transcriptionService.currentSegmentCount)")
                diagnostic("Refinements", value: "\(appState.transcriptionService.refinesCompletedCount)")
                diagnostic("Vocabulary", value: "\(appState.transcriptionService.vocabTermsInOutputCount)")
            }
            HStack(spacing: 20) {
                diagnostic("Input", value: "\(appState.transcriptionService.audioInputDisplayPercent)%")
                diagnostic("Confidence", value: "\(Int(max(0, min(1, appState.transcriptionService.currentConfidence)) * 100))%")
                diagnostic("Processing / audio", value: appState.transcriptionService.currentRtfx > 0 ? String(format: "%.1fx", appState.transcriptionService.currentRtfx) : "Waiting")
                diagnostic("Fillers removed", value: "\(appState.transcriptionService.fillerWordsRemovedCount)")
            }
        }
    }

    private func diagnostic(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}
