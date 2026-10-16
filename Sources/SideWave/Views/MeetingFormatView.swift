// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

/// View for formatting meeting transcripts with a local LLM.
/// Shows format picker, model tier selector, rendered markdown output, and export options.
struct MeetingFormatView: View {
    @Bindable var appState: AppState
    let transcript: MeetingTranscript

    @State private var showCopied = false
    @State private var exportError: String?
    /// True when the output on screen was loaded from saved history rather than
    /// generated this session, so the footer doesn't claim the transcript is
    /// KV-cached (it isn't until the user regenerates).
    @State private var showingSavedResult = false
    /// True when the saved output for the selected format predates the last
    /// speaker re-detection (marked in MeetingTranscript.staleFormats).
    @State private var currentFormatIsStale = false
    /// Persisted instructions for the `.custom` format. Length-capped on edit.
    @AppStorage(MeetingFormat.customInstructionsKey) private var customInstructions: String = ""
    /// Inputs for the Apple Intelligence fit check, recomputed when the transcript changes or the
    /// app becomes active instead of per render. Rebuilding the transcript text and creating a
    /// model on every streamed token grew with meeting length.
    @State private var afmInputCharCount = 0
    @State private var afmCharLimit = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var hardware: HardwareCapability { .current }

    /// True when the transcript fits Apple Intelligence's context window, from the cached inputs. A
    /// limit of 0 means not computed yet and counts as fitting.
    private var transcriptFitsAFM: Bool {
        afmCharLimit == 0 || afmInputCharCount <= afmCharLimit
    }

    /// Recomputes the fit inputs: the transcript plus the vocabulary section, as the service counts
    /// both, so a large glossary can't pass here and fail at Generate.
    private func recomputeAFMFit() {
        let text = transcript.formattingSource
        let vocab = VocabularyStore.shared.makeSnapshot().buildPromptSection(for: text)
        afmInputCharCount = text.count + vocab.count
        afmCharLimit = MeetingFormatterBackend.afmTranscriptCharLimit
    }

    /// Whether the saved output for a format predates the last rediarize.
    /// Reads the persisted meeting (same source as `savedOutput`) so the note
    /// reflects what's on disk; falls back to the passed transcript.
    private func computeStale(for format: MeetingFormat) -> Bool {
        if let stored = MeetingHistoryStore.shared.meetings.first(where: { $0.id == transcript.id }) {
            return stored.staleFormats.contains(format.rawValue)
        }
        return transcript.staleFormats.contains(format.rawValue)
    }

    /// Require recognized speech and a format that fits the chosen backend.
    private var canGenerate: Bool {
        guard transcript.hasSpeech else { return false }
        if appState.formatterService.selectedFormat == .custom,
           customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if appState.meetingFormatterBackend == MeetingFormatterBackend.appleIntelligence.rawValue {
            return transcriptFitsAFM
        }
        return true
    }

    /// Whether this Mac can run a Gemma backend. Drives the "switch to Gemma"
    /// affordance: on an 8 GB Apple Intelligence Mac there's no Gemma to switch
    /// to, so an over-long transcript just disables Generate instead.
    private var gemmaAvailable: Bool {
        hardware.availableBackends.contains(.gemma4E4B)
            || hardware.availableBackends.contains(.gemma4E2B)
    }

    /// Whether a given backend is unselectable. Mirrors canGenerate but
    /// expressed per-row for the Picker .disabled modifier.
    private func isBackendDisabled(_ backend: MeetingFormatterBackend) -> Bool {
        switch backend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B: return false
        case .appleIntelligence: return !transcriptFitsAFM
        }
    }

    /// True when a completed output is on screen, so the action button reads
    /// "Regenerate" instead of "Generate".
    private var isShowingComplete: Bool {
        if case .complete = appState.formatterService.state { return true }
        return false
    }

    private var isFormatting: Bool {
        switch appState.formatterService.state {
        case .downloading, .loading, .generating: return true
        default: return false
        }
    }

    /// Output already generated for a format, from saved meeting history, so reopening the sheet
    /// doesn't reload the model and generate again.
    private func savedOutput(for format: MeetingFormat) -> String? {
        MeetingHistoryStore.shared.meetings
            .first { $0.id == transcript.id }?
            .savedFormats[format.rawValue]
    }

    /// Seed the output area from saved history when the sheet opens or the
    /// format changes, without loading the model. Only touches idle/complete/
    /// error states so it never interrupts an in-flight generation.
    private func seedSavedOutputIfAvailable() {
        guard transcript.hasSpeech else {
            if !appState.formatterService.state.isBusy { appState.formatterService.state = .idle }
            showingSavedResult = false
            currentFormatIsStale = false
            return
        }
        let format = appState.formatterService.selectedFormat
        currentFormatIsStale = computeStale(for: format)
        switch appState.formatterService.state {
        case .idle, .complete, .error:
            if let saved = savedOutput(for: format) {
                appState.formatterService.state = .complete(output: saved)
                showingSavedResult = true
            } else if case .complete = appState.formatterService.state {
                // Switched to a format with no saved output: clear the stale
                // other-format result back to the empty state.
                appState.formatterService.state = .idle
                showingSavedResult = false
            } else {
                showingSavedResult = false
            }
        default:
            break
        }
    }

    @ViewBuilder
    private func backendRow(for backend: MeetingFormatterBackend) -> some View {
        switch backend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            Text("\(backend.displayName) (\(backend.diskSize))")
        case .appleIntelligence:
            if transcriptFitsAFM {
                Text(backend.displayName)
            } else {
                Text("\(backend.displayName) (unavailable)")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Free-text instructions for the Custom format. Persisted via @AppStorage,
    /// truncated to the shared cap on edit, with a live character count.
    @ViewBuilder
    private var customInstructionsField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            TextField(
                "Describe exactly how you want this meeting formatted",
                text: $customInstructions,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .disabled(isFormatting)
            .lineLimit(3...6)
            .onChange(of: customInstructions) { _, newValue in
                if newValue.count > MeetingFormat.customInstructionsCharLimit {
                    customInstructions = String(newValue.prefix(MeetingFormat.customInstructionsCharLimit))
                }
            }

            HStack(spacing: Spacing.xxs) {
                Text("Describe the structure and details you want in your notes.")
                    .settingsCaption()
                Spacer(minLength: Spacing.sm)
                if !customInstructions.isEmpty {
                    let count = customInstructions.count
                    Text("\(count) / \(MeetingFormat.customInstructionsCharLimit)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(count > MeetingFormat.customInstructionsCharLimit - 50
                                         ? Color.accentColor : Color.secondary)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(transcript.isPartial ? "Format Partial Transcript" : "Format Transcript")
                        .font(.title2.weight(.semibold))
                    if transcript.isPartial {
                        Text("Some speech may be missing. Check generated notes against the saved audio.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if case .complete(let output) = appState.formatterService.state {
                    exportMenu(output: output)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)

            SettingsDivider()

            // Controls
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Format picker
                PreferenceRow(label: "Format") {
                    ChoiceMenu(title: "Meeting notes format", value: appState.formatterService.selectedFormat.rawValue,
                               selection: $appState.formatterService.selectedFormat) {
                        ForEach(MeetingFormat.allCases) { format in
                            Label(format.rawValue, systemImage: format.icon)
                                .tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(isFormatting)
                }

                // Custom instructions: only for the Custom format. Persisted via
                // @AppStorage, capped like dictation's custom template.
                if appState.formatterService.selectedFormat == .custom {
                    customInstructionsField
                }

                // Model picker with only the backends this Mac can run: Apple Intelligence always,
                // Gemma with 16 GB or more. Apple Intelligence also needs a transcript that fits
                // its window.
                if hardware.isSupported {
                    PreferenceRow(label: "Local model") {
                        ChoiceMenu(title: "Meeting notes model",
                                   value: MeetingFormatterBackend(rawValue: appState.meetingFormatterBackend)?.displayName ?? "Choose model",
                                   selection: Binding(
                            get: { appState.meetingFormatterBackend },
                            set: { appState.meetingFormatterBackend = $0 }
                        )) {
                            ForEach(hardware.availableBackends) { backend in
                                // Disable an option that can't work (Apple Intelligence with a
                                // transcript too long for it), as macOS dims unavailable menu
                                // items.
                                backendRow(for: backend)
                                    .tag(backend.rawValue)
                                    .disabled(isBackendDisabled(backend))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(isFormatting)
                        .help(isFormatting ? "Finish or cancel the current formatting before changing models." : "Choose the local model for meeting notes.")
                    }
                    if appState.meetingFormatterBackend == MeetingFormatterBackend.appleIntelligence.rawValue,
                       !transcriptFitsAFM {
                        Text(gemmaAvailable
                             ? "Meeting too long for Apple Intelligence. Pick Gemma 4 E2B or E4B."
                             : "Meeting too long for Apple Intelligence on this Mac.")
                            .font(.caption)
                            .foregroundStyle(Color.warningAmber)
                    }
                }

                // Generate / Cancel button
                HStack(spacing: Spacing.sm) {
                    Spacer()
                    switch appState.formatterService.state {
                    case .idle, .complete, .error:
                        if appState.meetingFormatterBackend == MeetingFormatterBackend.appleIntelligence.rawValue,
                           !transcriptFitsAFM, gemmaAvailable {
                            // AFM can't fit this transcript but Gemma can run on
                            // this Mac. Offer a one-tap switch instead of a dead,
                            // disabled Generate button.
                            Button {
                                appState.meetingFormatterBackend = MeetingFormatterBackend.gemma4E4B.rawValue
                            } label: {
                                Label("Switch to Gemma 4 E4B", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .prominentActionButton()
                        } else {
                            Button {
                                showingSavedResult = false
                                currentFormatIsStale = false
                                appState.formatterService.format(transcript: transcript, as: appState.formatterService.selectedFormat)
                            } label: {
                                Label(isShowingComplete ? "Regenerate" : "Generate", systemImage: "doc.text")
                            }
                            .prominentActionButton()
                            .disabled(!canGenerate)
                        }

                    case .downloading, .loading, .generating:
                        Button("Cancel") {
                            appState.formatterService.cancel()
                        }
                        .actionButton()
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)

            SettingsDivider()

            // Output area
            outputArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            SettingsDivider()

            // Footer
            HStack {
                if case .complete = appState.formatterService.state {
                    if currentFormatIsStale {
                        // Output predates the last speaker re-detection. Keep it
                        // (don't auto-delete) but flag it and invite regenerate.
                        Text("Generated before speaker re-detection. Regenerate to refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if showingSavedResult {
                        Text("Saved result. Regenerate to refresh.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if appState.formatterService.reformatIsCached {
                        // Only the single-pass Gemma KV path is near-instant to
                        // reformat; AFM and map-reduce re-run the full pass, so
                        // the claim is shown only when it actually holds.
                        Text("Transcript cached for faster reformatting")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Close") {
                    appState.formatterService.cancel()
                    dismiss()
                }
                .actionButton()
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
        }
        .buttonBorderShape(.capsule)
        .safeAreaInset(edge: .top) {
            if let message = MeetingHistoryStore.shared.persistenceError {
                HStack(spacing: Spacing.sm) {
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retry Save") { MeetingHistoryStore.shared.retrySaving() }
                }
                .padding(Spacing.md)
            }
        }
        .alert("Couldn't save formatted notes", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Try another location or copy the notes.")
        }
        .task(id: transcript.id) {
            // Cache AFM-fit inputs once per transcript instead of rebuilding
            // them per render (see recomputeAFMFit / afmInputCharCount).
            recomputeAFMFit()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Check Apple Intelligence again when the app becomes active, in case it was just
            // turned on, and refresh its budget, since the window can change with it.
            if newPhase == .active {
                appState.formatterService.refreshAFMAvailability()
                recomputeAFMFit()
            }
        }
        .onAppear {
            // Show a saved result for the current format without loading the model.
            seedSavedOutputIfAvailable()
        }
        .onChange(of: appState.formatterService.selectedFormat) { _, _ in
            seedSavedOutputIfAvailable()
        }
        .onDisappear {
            // Unload the Gemma model when the sheet closes, or its 6 GB stay in memory. The next
            // format reloads it from disk.
            appState.formatterService.cancel()
            appState.formatterService.unloadModel()
        }
    }

    // MARK: - Export Menu

    private func exportMenu(output: String) -> some View {
        HStack(spacing: Spacing.sm) {
            // Copy raw markdown
            Button(showCopied ? "Copied" : "Copy") {
                TypingService.writeSensitiveString(output, to: .general)
                showCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showCopied = false
                }
            }
            .actionButton()

            // Save as markdown file
            Button("Save .md") {
                saveMarkdownFile(output)
            }
            .actionButton()
        }
    }

    // MARK: - Output Area

    @ViewBuilder
    private var outputArea: some View {
        switch appState.formatterService.state {
        case .idle:
            VStack(spacing: Spacing.md) {
                Image(systemName: "doc.text")
                    .font(.system(size: Size.iconXL))
                    .foregroundStyle(.tertiary)
                Text(transcript.hasSpeech ? "Pick a format and click Generate" : "No speech was recognized. Check the microphone or process the saved audio again before generating notes.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .downloading(_, _, let progress):
            VStack(spacing: Spacing.sm) {
                DownloadProgressCard(
                    progress: progress,
                    title: appState.formatterService.selectedBackend.displayName,
                    onCancel: { appState.formatterService.cancelDownload() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loading:
            VStack(spacing: Spacing.md) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading model\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .generating(let output, let note):
            if output.isEmpty {
                VStack(spacing: Spacing.md) {
                    ProgressView()
                        .controlSize(.regular)
                    // Map-reduce reports its stage here ("Working through the
                    // transcript in sections", "Combining sections"); the plain
                    // single-pass path shows "Generating".
                    Text(note ?? "Generating\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Show rendered markdown as it streams
                MarkdownWebView(markdown: output, followsStreamingOutput: true)
            }

        case .complete(let output):
            // Full rendered markdown
            MarkdownWebView(markdown: output)

        case .error(let message):
            VStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: Size.iconXL))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - File Actions

    private func saveMarkdownFile(_ content: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "meeting-\(formatDate(transcript.timestamp)).md"
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    exportError = "The notes weren't saved. Try another location or use Copy. \(error.localizedDescription)"
                }
            }
        }
    }


    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}
