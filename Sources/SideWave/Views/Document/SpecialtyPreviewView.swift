// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// A document workspace with dictation, direct editing, and local model instructions.
struct SpecialtyPreviewView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var isEditorFocused: Bool
    @FocusState var isInstructionFocused: Bool

    @State var copySuccess = false
    @State var showEditingHelp = false
    @State var showActivity = false
    @State var activityContentHeight: CGFloat = 80
    @State private var showsTextEditor = false
    @State private var showsLiveTranscript = true
    @State private var confirmClear = false
    @State private var confirmDiscardPaused = false
    @State private var showsFormattingInstructions = false
    @State private var showsRecentDocuments = false
    @State private var activityStartedAt = Date()
    /// Document snapshots captured just before each applied assistant edit, so
    /// the user can step back through them. Capped to keep memory bounded.
    @State var undoStack: [String] = []
    /// The pre-edit document, captured when an edit starts; committed to the
    /// undo stack only if the edit actually changed the text.
    @State var pendingUndoSnapshot: String?
    /// The instruction that drove the in-flight edit, captured when it starts so
    /// it can be logged to the activity rail once the edit actually lands.
    @State var pendingAskInstruction: String?
    /// One-line record of each ask the assistant applied, newest first. Powers
    /// the activity rail so the user can see what just changed and ask again.
    @State var appliedAsks: [AppliedAsk] = []
    /// Bumped each time an assistant edit lands, to fire the refine-sweep.
    @State var editLandedToken = 0

    static let historyCap = 20

    var reduceMotion: Bool { systemReduceMotion || appState.reduceAppMotion }
    var isEngineRunning: Bool { appState.transcriptionService.isRecording }
    var isEditing: Bool { appState.isProcessingAgenticEdit }
    var activity: SpecialtyActivity {
        SpecialtyActivity(session: appState.dictationSessionPhase,
                          command: appState.isCommandDictation,
                          editing: isEditing,
                          generating: appState.dictationFormatter.state == .generating)
    }
    var docEmpty: Bool { appState.specialtyEditedText.isEmpty }
    var isEditModelReady: Bool { appState.dictationFormatter.state == .ready }
    private var hasDocumentCapture: Bool { appState.dictationSessionPhase.isBusy && !isEditing && !appState.isCommandDictation }
    private var displaysLiveTranscript: Bool { hasDocumentCapture && showsLiveTranscript }
    /// A voice-ask is in progress: recording, and AppState has latched this
    /// session as a command dictation (words land in the Ask bar, not the page).
    var isVoiceAsking: Bool { isEngineRunning && appState.isCommandDictation }
    /// Recording that fills the page (empty-page dictation).
    var isVoiceDictating: Bool { isEngineRunning && !appState.isCommandDictation }
    var instructionEmpty: Bool {
        appState.agenticEditInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The user's real dictation hotkey, e.g. "⌥ + Space", for onboarding copy.
    var hotkeyDisplay: String { appState.hotkeyManager.shortcut.displayString }

    /// Document type per template: AI Prompt emits XML structure, which reads
    /// wrong proportionally, so it keeps monospacing; prose templates get the
    /// larger document type.
    private var documentFont: Font {
        let template = DictationFormatterService.Template(rawValue: appState.dictationCleanupTemplate) ?? .standard
        return template == .aiPrompt
            ? .system(size: Size.documentText, design: .monospaced)
            : .system(size: Size.documentText)
    }

    var body: some View {
        slab
            .frame(minWidth: 640, minHeight: 520)
            .buttonBorderShape(.capsule)
            .sheet(isPresented: $showsFormattingInstructions) {
                DocumentInstructionsView(appState: appState)
            }
            .sheet(isPresented: $showsRecentDocuments) { RecentDocumentsView(appState: appState) }
            .confirmationDialog("Clear this document?", isPresented: $confirmClear) {
                Button("Clear Document", role: .destructive) {
                    appState.clearSpecialtyDocument()
                    appliedAsks.removeAll()
                    undoStack.removeAll()
                }
            } message: { Text("You can copy it first. Saved dictation history is kept.") }
            .confirmationDialog("Discard the paused dictation?", isPresented: $confirmDiscardPaused) {
                Button("Discard Paused Dictation", role: .destructive) { appState.discardPendingSession() }
            } message: { Text("The words from this paused capture will be removed. Your saved document stays unchanged.") }
            .onAppear {
                guard currentTemplate.isSpecialty else { dismissWindow(id: "specialty-preview"); return }
                appState.isSpecialtyActive = true
            }
            .onDisappear {
                appState.isSpecialtyActive = false
                appState.nextDictationTarget = .auto
            }
            .onChange(of: appState.dictationCleanupTemplate) {
                undoStack.removeAll()
                appliedAsks.removeAll()
                if !currentTemplate.isSpecialty { dismissWindow(id: "specialty-preview") }
            }
            .onChange(of: appState.documentRevision) {
                undoStack.removeAll()
                appliedAsks.removeAll()
                pendingUndoSnapshot = nil
                pendingAskInstruction = nil
                showsTextEditor = false
                showActivity = false
            }
            .onChange(of: activity) { _, new in
                activityStartedAt = .now
                if new == .preparing { showsLiveTranscript = true; showsTextEditor = false }
            }
            .onChange(of: appState.transcriptionService.confirmedText) { mirrorCommandDictation() }
            .onChange(of: appState.transcriptionService.volatileText) { mirrorCommandDictation() }
            .onChange(of: appState.isProcessingAgenticEdit) { old, new in
                handleEditProcessingChange(old: old, new: new)
            }
    }

    private var currentTemplate: DictationFormatterService.Template {
        DictationFormatterService.Template(rawValue: appState.dictationCleanupTemplate) ?? .standard
    }

    private var slab: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 10) {
                Label(displaysLiveTranscript ? "Live dictation" : "Document preview",
                      systemImage: displaysLiveTranscript ? "waveform" : "doc.text")
                    .font(.caption).adaptiveSecondary()
                Spacer(minLength: 8)
                if hasDocumentCapture, !docEmpty {
                    Button(displaysLiveTranscript ? "Show document" : "Show live dictation") { showsLiveTranscript.toggle() }
                        .buttonStyle(.borderless).font(.caption)
                } else if !hasDocumentCapture {
                    GlassSegmentedPicker(selection: $showsTextEditor, segments: [
                        .init("Read", tag: false, isEnabled: !activity.isWorking && !isEngineRunning),
                        .init("Edit text", tag: true, isEnabled: !activity.isWorking && !isEngineRunning)
                    ], accessibilityLabel: "Document view")
                    .disabled(activity.isWorking || isEngineRunning)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            if let notice = appState.documentEditNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").adaptiveSecondary()
                    Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { appState.documentEditNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss edit message")
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
            }
            modelReadiness
            if let error = appState.documentDrafts.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).adaptiveSecondary()
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            documentSurface.padding(.horizontal, 20)
            if !docEmpty && !hasDocumentCapture {
                askBar.padding(.horizontal, 20).padding(.top, 14)
                    .disabled(appState.pendingSessionText != nil)
            }
            sessionControls.padding(.horizontal, 20).padding(.top, 12)
            footer.padding(.horizontal, 20).padding(.bottom, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: displaysLiveTranscript)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            WorkspaceField("Template", icon: "doc.text") {
                DictationTemplateMenu(appState: appState, opensDocument: false, documentsOnly: true)
            }.frame(maxWidth: 250)
            Spacer(minLength: 0)
            Button("New", systemImage: "square.and.pencil") { appState.newSpecialtyDocument() }
                .buttonStyle(.bordered)
                .disabled(activity.isWorking || isEngineRunning || appState.pendingSessionText != nil)
                .help("Start a new document and keep this one in Recents")
                .keyboardShortcut("n", modifiers: [.command])
            Button("Recents", systemImage: "clock") { showsRecentDocuments = true }
                .buttonStyle(.borderless)
                .disabled(activity.isWorking || isEngineRunning || appState.pendingSessionText != nil)
            Button(action: copyToClipboard) {
                Label(copySuccess ? "Copied" : "Copy", systemImage: copySuccess ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent).disabled(docEmpty || activity.isWorking || isEngineRunning)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Menu {
                Button("Formatting Rules") { showsFormattingInstructions = true }
                    .disabled(activity.isWorking || isEngineRunning)
                Toggle("Append dictation automatically", isOn: Bindable(appState).autoAppendSpecialtyAdditions)
                    .disabled(activity.isWorking || isEngineRunning)
                Toggle("Show document activity", isOn: $showActivity)
                if appState.pendingSessionText != nil {
                    Button("Discard Paused Dictation", role: .destructive) { confirmDiscardPaused = true }
                }
                Divider()
                Button("Return to Ordinary Dictation") { appState.selectDictationOutput(.standard, openDocument: false) }
                    .disabled(activity.isWorking || isEngineRunning || appState.pendingSessionText != nil)
                Button("Clear Document", role: .destructive) { confirmClear = true }
                    .disabled(docEmpty || activity.isWorking || isEngineRunning || appState.pendingSessionText != nil)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Document options").accessibilityLabel("Document options")
        }
        .padding(20)
    }

    private var sessionControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                if activity.isWorking {
                    SpecialtyProcessingFeedback(activity: activity, template: currentTemplate.workspaceTitle,
                                                backend: appState.dictationFormatter.activeBackend.displayName,
                                                startedAt: activityStartedAt)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sessionTitle).font(.callout.weight(.medium))
                        Text(sessionDetail).font(.caption).adaptiveSecondary()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                if isEditing {
                    Button("Stop Edit") { appState.cancelAgenticEdit() }.buttonStyle(.bordered)
                        .help("Restore the document before this edit")
                } else if activity == .preparing {
                    Button("Cancel") { Task { await appState.handleCancelRecording() } }.buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                } else if appState.isCleaningUp {
                    Button("Keep Text") { appState.requestCleanupCancel() }.buttonStyle(.bordered)
                        .help("Stop formatting and keep the captured text")
                } else if activity.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    if appState.pendingSessionText != nil {
                        Button("Review Words") { showActivity = true }.buttonStyle(.borderless)
                    }
                    if isEngineRunning && !isVoiceAsking {
                        Button("Pause", systemImage: "pause.fill") { Task { await appState.handleSoftStop() } }
                            .buttonStyle(.borderless).help("Keep this dictation and resume later")
                            .keyboardShortcut(.cancelAction)
                    }
                    Button {
                        if isEngineRunning { Task { await appState.handleStopRecording() } }
                        else { startVoiceDictation() }
                    } label: {
                        Label(isEngineRunning ? (isVoiceAsking ? "Apply spoken change" : "Finish dictation") : (appState.pendingSessionText != nil ? "Resume dictation" : docEmpty ? "Dictate" : "Add dictation"),
                              systemImage: isEngineRunning ? "stop.fill" : "mic.fill")
                    }
                    .buttonStyle(.bordered).keyboardShortcut(.return, modifiers: [.command])
                }
            }
            AudioWaveVisualizer(audioLevel: isEngineRunning ? appState.transcriptionService.audioLevel : 0,
                colorMode: "rainbow", sensitivity: 0.5, liquidGlass: false,
                isCleanupMode: !isEngineRunning && appState.dictationFormatter.state == .generating,
                isRefining: appState.dictationFormatter.state == .generating,
                isWarmingUp: activity == .preparing,
                refiningBackend: appState.dictationFormatter.activeBackend.huggingFaceRepoID == nil ? .appleIntelligence : .gemma,
                isIdleBreathing: activity == .ready, reduceMotion: reduceMotion)
                .frame(height: 24).accessibilityHidden(true)
        }
        .accessibilityIdentifier("document-session-controls")
    }

    private var sessionTitle: String {
        if activity == .ready {
            if appState.pendingSessionText != nil { return "Dictation paused" }
            if docEmpty { return "Ready to dictate" }
            return isEditModelReady ? "Ready to add or edit" : "Ready to add words"
        }
        return activity.title
    }

    private var sessionDetail: String {
        switch activity {
        case .ready:
            if appState.pendingSessionText != nil { return "Review your captured words or resume this dictation." }
            if docEmpty { return "Choose Dictate or press \(hotkeyDisplay) to begin." }
            return "\(hotkeyDisplay) starts a new document. Choose Add dictation to continue this one."
        case .preparing: return "Speak when the microphone is ready."
        case .listening: return docEmpty ? "Speak naturally. Finish to format your words." : "New words will be added to your saved document."
        case .listeningForInstruction: return "Say what to change, then finish to apply it."
        case .finishing: return "Microphone stopped. Finishing the last words."
        case .formatting: return "Formatting with \(appState.dictationFormatter.activeBackend.displayName). Your words are kept."
        case .editing: return "Applying your instruction. Stop edit restores the previous text."
        }
    }

    @ViewBuilder
    private var modelReadiness: some View {
        switch appState.dictationFormatter.state {
        case .downloading(let progress):
            HStack(spacing: Spacing.sm) {
                ProgressView(value: progress).frame(width: 72)
                Text("Downloading \(appState.dictationFormatter.activeBackend.displayName)")
                Spacer(minLength: 0)
                Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
            .font(.caption).adaptiveSecondary()
            .padding(.horizontal, Spacing.lg).padding(.bottom, Spacing.md)
        case .loading:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.mini)
                Text("Preparing the model. Document editing will be available when it is ready.")
                Spacer(minLength: 0)
            }
            .font(.caption).adaptiveSecondary()
            .padding(.horizontal, Spacing.lg).padding(.bottom, Spacing.md)
        case .disabled, .unloaded, .error, .unavailable:
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("Refine is not ready. You can type; model edits need a ready model.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Refine Settings") {
                    appState.requestedSettingsTab = .settingsRefine
                    openWindow(id: "settings")
                }
                .buttonStyle(.borderless).fixedSize()
            }
            .font(.caption).adaptiveSecondary()
            .padding(.horizontal, Spacing.lg).padding(.bottom, Spacing.md)
        case .ready, .generating: EmptyView()
        }
    }

    private var documentSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
            if displaysLiveTranscript {
                if activity == .preparing {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Preparing to listen").font(.title3.weight(.medium))
                        Text("Your words will appear here, with the same live refinement as the dictation preview.")
                            .font(.callout).adaptiveSecondary()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
                } else {
                    DictationOverlayContent(appState: appState, embeddedTranscript: true).padding(20)
                }
            } else if docEmpty && !showsTextEditor {
                if activity.isWorking {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "text.alignleft").font(.largeTitle).adaptiveTertiary()
                        Text("Your document will appear here").font(.callout).adaptiveSecondary()
                    }
                } else { emptyStateOnboarding }
            } else if showsTextEditor {
                TextEditor(text: Bindable(appState).specialtyEditedText)
                    .font(documentFont).lineSpacing(6).padding(20)
                    .scrollContentBackground(.hidden).focused($isEditorFocused)
                    .disabled(activity.isWorking || isEngineRunning)
                    .accessibilityLabel("Document text")
            } else if currentTemplate == .aiPrompt {
                ScrollView {
                    Text(appState.specialtyEditedText)
                        .font(documentFont).lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .accessibilityLabel("Document text")
                        .accessibilityValue(appState.specialtyEditedText)
                }
            } else {
                MarkdownWebView(markdown: appState.specialtyEditedText, followsStreamingOutput: isEditing,
                                preservesLineBreaks: true)
            }
            RefineSweepOverlay(token: editLandedToken, reduceMotion: reduceMotion)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateOnboarding: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New document").font(.system(size: 22, weight: .medium))
            Text(currentTemplate.workspaceDescription)
                .font(.body).adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)
            Text("Dictate below or use your shortcut. When you finish, review the result here, edit the text, or ask for a change.")
                .font(.callout).adaptiveSecondary().lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Type a Document", systemImage: "keyboard") {
                showsTextEditor = true
                isEditorFocused = true
            }.buttonStyle(.bordered)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

}
