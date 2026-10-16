// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

/// Shows the completed meeting transcript with speaker labels and timestamps.
struct MeetingResultsView: View {
    let transcript: MeetingTranscript
    /// True when this sheet is showing the live service transcript (just
    /// recorded this session), false when it's a row reopened from history.
    /// Drives the destructive button's label + action so it does what it says.
    let isLiveMeeting: Bool
    let onDismiss: () -> Void
    let onPurgeAudio: () -> Void
    /// Called when the user picks a new speaker count from the "Identify Speakers"
    /// picker. Nil = auto-detect. The caller should invoke
    /// `MeetingTranscriptionService.rediarize(expected:)` with this value.
    var onRediarize: ((Int?) -> Void)? = nil
    /// Called while rediarize is running so the owner can show a progress
    /// indicator. The view itself stays usable.
    var isRediarizing: Bool = false
    /// Called when the user renames a speaker in a live meeting, so the in-memory transcript used
    /// for formatting gets the new name too. Nil for History rows, which save the rename directly
    /// to MeetingHistoryStore.
    var onRenameSpeaker: ((String, String) -> Void)? = nil

    @State private var editableNames: [String: String]
    @State private var showCopiedToast = false
    @State private var editingSpeakerID: String? = nil
    @State private var showEditSpeakerSheet = false
    @State private var exportError: String?
    @State private var showDeleteConfirmation = false

    init(
        transcript: MeetingTranscript,
        isLiveMeeting: Bool,
        onDismiss: @escaping () -> Void,
        onPurgeAudio: @escaping () -> Void,
        onRediarize: ((Int?) -> Void)? = nil,
        isRediarizing: Bool = false,
        onRenameSpeaker: ((String, String) -> Void)? = nil
    ) {
        self.transcript = transcript
        self.isLiveMeeting = isLiveMeeting
        self.onDismiss = onDismiss
        self.onPurgeAudio = onPurgeAudio
        self.onRediarize = onRediarize
        self.isRediarizing = isRediarizing
        self.onRenameSpeaker = onRenameSpeaker
        _editableNames = State(initialValue: transcript.speakerNames)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(!transcript.hasSpeech ? "Meeting Details" : (transcript.isPartial ? "Partial Meeting Transcript" : "Meeting Transcript"))
                        .font(.title2.weight(.semibold))
                    Text(transcript.hasSpeech ? transcript.segmentSpeakerSummary : "Recorded \(MeetingSegment.formatTimestamp(transcript.duration))")
                        .settingsCaption()
                    if transcript.isPartial {
                        Text("Recovered from the live journal. Some speech may be missing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if transcript.hasSpeech {
                    HStack(spacing: Spacing.sm) {
                        Button(showCopiedToast ? "Copied" : "Copy") {
                            copyTranscript()
                        }
                        .actionButton()

                        Button("Save .md") {
                            saveTranscriptFile()
                        }
                        .actionButton()
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)

            speakerStrip
                .padding(.bottom, Spacing.sm)

            SettingsDivider()

            // Transcript content
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.md) {
                    if !transcript.hasSpeech {
                        ContentUnavailableView("No speech detected", systemImage: "waveform",
                            description: Text("No words were recognized in this recording. Check the microphone before recording again."))
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(transcript.segments) { segment in
                        MeetingSegmentRow(
                            segment: segment,
                            speakerName: editableNames[segment.speakerId] ?? defaultDisplayName(for: segment.speakerId)
                        )
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
            }
            .softScrollEdge()
            .overlay(alignment: .top) {
                if isRediarizing {
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text(transcript.isPartial ? "Processing saved audio…" : "Re-detecting speakers…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xxs)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, Spacing.sm)
                }
            }

            SettingsDivider()

            // Footer actions
            HStack {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    // Live meeting still has audio on disk to delete; a history
                    // row's audio was purged in a prior session, so the button
                    // deletes the saved meeting instead of pretending otherwise.
                    Label(isLiveMeeting ? "Delete Audio & Close" : "Delete Meeting", systemImage: "trash")
                }
                .actionButton()

                Spacer()

                Button("Close") {
                    onDismiss()
                }
                .prominentActionButton()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
        }
        .alert("Couldn't save transcript", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Try another location or copy the transcript.")
        }
        .confirmationDialog(isLiveMeeting ? "Delete the saved audio?" : "Delete this meeting?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(isLiveMeeting ? "Delete Audio & Close" : "Delete Meeting", role: .destructive) { onPurgeAudio() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(isLiveMeeting ? "You won't be able to process this recording again. Export the transcript first if it hasn't been saved to history." : "The transcript and its saved formats will be removed from history.")
        }
        .sheet(isPresented: $showEditSpeakerSheet) {
            EditSpeakersSheet(
                currentCount: uniqueSpeakerIDs.count,
                onCommit: { newCount in
                    onRediarize?(newCount)
                }
            )
        }
        .onChange(of: transcript.speakerNames) { _, newNames in
            // Running detection again keeps the meeting ID, so SwiftUI keeps this view's state.
            // Sync the names when the transcript's speakers change, so rows show the new "Speaker
            // N" labels.
            editableNames = newNames
            editingSpeakerID = nil
        }
    }

    private var uniqueSpeakerIDs: [String] {
        Array(Set(transcript.segments.map(\.speakerId))).sorted()
    }

    /// Default name for a speaker ("Speaker N" in sorted order), matching the service. Used when a
    /// name is cleared, so two cleared speakers don't share a raw detector ID.
    private func defaultDisplayName(for id: String) -> String {
        if let idx = uniqueSpeakerIDs.firstIndex(of: id) {
            return "Speaker \(idx + 1)"
        }
        return id
    }

    /// Persist a committed rename. Live meetings route through the service so
    /// its in-RAM transcript (what the completion screen formats) updates too;
    /// history rows write straight to the store.
    private func commitRename(id: String) {
        let resolved = editableNames[id] ?? defaultDisplayName(for: id)
        if let onRenameSpeaker {
            onRenameSpeaker(id, resolved)
        } else {
            MeetingHistoryStore.shared.updateSpeakerNames(
                meetingID: transcript.id,
                names: editableNames
            )
        }
    }

    // MARK: - Speaker pill strip

    @ViewBuilder
    private var speakerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(uniqueSpeakerIDs, id: \.self) { id in
                    SpeakerPill(
                        speakerID: id,
                        defaultName: defaultDisplayName(for: id),
                        name: Binding(
                            get: { editableNames[id] ?? defaultDisplayName(for: id) },
                            set: { editableNames[id] = $0 }
                        ),
                        isEditing: editingSpeakerID == id,
                        onBeginEdit: { editingSpeakerID = id },
                        onCommit: {
                            editingSpeakerID = nil
                            commitRename(id: id)
                        }
                    )
                }

                if onRediarize != nil {
                    Button {
                        if transcript.isPartial || !transcript.hasSpeech { onRediarize?(nil) }
                        else { showEditSpeakerSheet = true }
                    } label: {
                        Label(transcript.isPartial || !transcript.hasSpeech ? "Process Saved Audio" : "Identify Speakers", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .actionButton()
                    .disabled(isRediarizing)
                    .padding(.leading, Spacing.xs)
                }
            }
            // Inset inside the scroll view so the first capsule's outline isn't clipped.
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xxxs)
        }
    }

    /// Plain-text transcript with the user's current speaker names applied.
    /// Shared by Copy and Save so both reflect renames made in this sheet.
    private func transcriptExportText() -> String {
        var export = transcript
        export.speakerNames = editableNames
        return export.plainText
    }

    private func copyTranscript() {
        TypingService.writeSensitiveString(transcriptExportText(), to: .general)

        showCopiedToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showCopiedToast = false
        }
    }

    private func saveTranscriptFile() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let stamp = fmt.string(from: transcript.timestamp)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "meeting-transcript-\(stamp).md"
        panel.canCreateDirectories = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try transcriptExportText().write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    exportError = "The transcript wasn't saved. Try another location or use Copy. \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Speaker Pill

private struct SpeakerPill: View {
    let speakerID: String
    /// Stable "Speaker N" default this pill falls back to when its name is
    /// cleared, so clearing never exposes the raw diarizer id.
    let defaultName: String
    @Binding var name: String
    let isEditing: Bool
    let onBeginEdit: () -> Void
    let onCommit: () -> Void

    @FocusState private var focused: Bool
    @State private var draft: String = ""

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Circle()
                .fill(speakerColor.opacity(0.35))
                .frame(width: 8, height: 8)
            if isEditing {
                TextField("", text: $draft, onCommit: {
                    name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.isEmpty { name = defaultName }
                    onCommit()
                })
                .textFieldStyle(.plain)
                .font(.caption.weight(.medium))
                .frame(minWidth: 70, maxWidth: 160)
                .focused($focused)
                .onAppear {
                    draft = name
                    focused = true
                }
            } else {
                Text(name)
                    .font(.caption.weight(.medium))
                    .onTapGesture(count: 2) { onBeginEdit() }
            }
            if !isEditing {
                Button {
                    onBeginEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Rename speaker")
                .accessibilityLabel("Rename speaker \(name)")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(speakerColor.opacity(0.4), lineWidth: 1)
        )
    }

    private var speakerColor: Color {
        meetingSpeakerColor(for: speakerID)
    }
}

// MARK: - Edit Speakers Sheet

private struct EditSpeakersSheet: View {
    let currentCount: Int
    let onCommit: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Re-run Speaker Detection")
                .font(.title3.weight(.semibold))

            SettingsDivider()

            Text("We detected \(currentCount) voice\(currentCount == 1 ? "" : "s") on the first pass. Re-running analyzes the audio again and re-splits the transcript without re-transcribing. Detection finds up to 8 speakers automatically; a specific count can't be forced.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)

            Text("Names carry over when the re-run lands on the same speaker slots, so check attributions afterward. Formats generated before the re-run get marked so you can regenerate them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .actionButton()
                    .keyboardShortcut(.cancelAction)

                Button("Re-run") {
                    onCommit(nil)
                    dismiss()
                }
                .prominentActionButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 440)
        .frame(minHeight: 260)
    }
}

// MARK: - Segment Row

private struct MeetingSegmentRow: View {
    let segment: MeetingSegment
    let speakerName: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Circle().fill(speakerColor).frame(width: 6, height: 6)
                Text(speakerName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primaryText(for: colorScheme))

                // Timestamp
                Text(segment.formattedTimeRange)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.secondaryText(for: colorScheme))

                Spacer()
            }

            Text(segment.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(Spacing.md)
        .settingsCardStyle()
    }

    /// Assign a consistent color to each speaker based on their ID.
    private var speakerColor: Color {
        meetingSpeakerColor(for: segment.speakerId)
    }
}

// MARK: - Speaker color

/// Color markers supplement the readable speaker labels.
private let meetingSpeakerPalette: [Color] = [.blue, .green, .purple, .brown, .pink, .teal, .indigo, .red]

/// A stable color per speaker. `String.hashValue` is seeded per launch, so a reopened meeting would
/// change colors; FNV-1a over the ID is stable.
private func meetingSpeakerColor(for id: String) -> Color {
    var hash: UInt64 = 1469598103934665603 // FNV-1a offset basis
    for scalar in id.unicodeScalars {
        hash ^= UInt64(scalar.value)
        hash = hash &* 1099511628211 // FNV-1a prime
    }
    return meetingSpeakerPalette[Int(hash % UInt64(meetingSpeakerPalette.count))]
}
