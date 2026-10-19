// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import TipKit
import UniformTypeIdentifiers

// MARK: - Speech Profile

/// Builds and edits the user's speech profile: a compact, on-device
/// description of how they talk and write, fed to Refine so it preserves their
/// voice. One button builds it from the user's own dictation with the active
/// local model; the text is fully editable, toggleable, and clearable. This is
/// separate from Vocabulary glossaries; it teaches Refine WHO the speaker is,
/// not which words to spell. Nothing leaves the Mac.
struct SpeechProfileSheet: View {
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var store = SpeechProfileStore.shared
    /// Local editable copy of the profile text. Committed to the store on Done;
    /// Build and Clear write through to the store immediately.
    @State private var draft: String = ""
    @State private var phase: Phase = .editing
    /// The running build, held so dismissing mid-generation cancels it; an
    /// orphaned Gemma run keeps the GPU busy and stalls later refines.
    @State private var buildTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case editing
        case building
        case failed(String)
    }

    private static let charCap = SpeechProfileStore.charCap

    var body: some View {
        VStack(spacing: 0) {
            header
            SettingsDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    bodyContent
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
            }
            .softScrollEdge()
            footer
        }
        .frame(width: 600, height: 560)
        .onAppear { draft = store.profile.text }
        .onDisappear { buildTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: "person.wave.2")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Speech Profile")
                    .font(.headline)
                Text("A short description of how you talk and write. Refine reads it to keep your voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    // MARK: Body

    @ViewBuilder
    private var bodyContent: some View {
        switch phase {
        case .editing:
            editingContent
        case .building:
            AIThinkingView(
                title: "Reading how you speak…",
                subtitle: AIAssist.thinkingSubtitle(for: appState.dictationFormatter.activeBackend)
            )
        case .failed(let msg):
            AIErrorView(message: msg) { phase = .editing }
        }
    }

    private var editingContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            enabledToggle

            buildRow

            profileEditor

            privacyNote

            if !AIAssist.backendReady(appState.dictationFormatter) {
                AIBackendNotReadyNote()
            }
        }
    }

    private var enabledToggle: some View {
        Toggle(isOn: Binding(
            get: { store.isEnabled },
            set: { store.isEnabled = $0 }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Use my speech profile")
                    .font(.callout.weight(.medium))
                Text("When on, your profile is added to every Refine prompt so it understands your voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var buildRow: some View {
        HStack(spacing: Spacing.sm) {
            Button(store.hasProfile ? "Rebuild from my dictation" : "Build from my dictation history") {
                buildTask = Task { await build() }
            }
            .prominentActionButton()
            .disabled(!AIAssist.backendReady(appState.dictationFormatter))
            .help("Read your recent dictation on this Mac and write a fresh profile.")

            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Clear", role: .destructive) {
                    draft = ""
                    store.clear()
                }
                .actionButton()
            }

            Spacer(minLength: Spacing.sm)

            if let metaLine {
                Text(metaLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Your profile")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(draft.count)/\(Self.charCap)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Build from your dictation history above, or describe in your own words how you talk and how you want your dictation to read.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.callout)
                    .frame(minHeight: 150, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .onChange(of: draft) { _, newValue in
                        if newValue.count > Self.charCap {
                            draft = String(newValue.prefix(Self.charCap))
                        }
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
            )
            Text("Your description, in your words. Edit it any time; Refine uses exactly what's here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Built on this Mac from your own dictation, stored locally, and only ever added to the local Refine prompt. Nothing leaves your device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metaLine: String? {
        guard store.hasProfile, let builtAt = store.profile.builtAt else { return nil }
        let when = builtAt.formatted(date: .abbreviated, time: .omitted)
        let n = store.profile.sourceEntryCount
        if n > 0 {
            return "Built from \(n) \(n == 1 ? "dictation" : "dictations") · \(when)"
        }
        return "Updated \(when)"
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        SettingsDivider()
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .actionButton()
                .keyboardShortcut(.cancelAction)

            switch phase {
            case .building:
                Button("Done") {}
                    .prominentActionButton()
                    .disabled(true)
            case .editing, .failed:
                Button("Done") {
                    commit()
                    dismiss()
                }
                .prominentActionButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    // MARK: Actions

    /// Persist a hand-edited draft. Only writes when it differs from the stored
    /// text so an unchanged Done (e.g. right after a Build) keeps the build's
    /// timestamp and dictation count instead of overwriting them with an edit.
    private func commit() {
        guard draft != store.profile.text else { return }
        store.setEdited(text: draft)
    }

    @MainActor
    private func build() async {
        let texts = recentDictationTexts()
        let sample = VocabularyAIExtractor.sampleText(fromRecent: texts, maxChars: 6000)
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed("There's no dictation to read yet. Dictate a bit first, then build your profile, or describe your voice by hand below.")
            return
        }

        phase = .building
        do {
            let text = try await SpeechProfileBuilder.build(
                fromSampleText: sample,
                via: appState.dictationFormatter
            )
            // Sheet dismissed mid-generation; drop the result instead of
            // mutating state on a view that's gone.
            try Task.checkCancellation()
            store.setBuilt(text: text, sourceEntryCount: texts.count)
            draft = store.profile.text
            phase = .editing
        } catch is CancellationError {
            // Expected on dismiss; nothing to surface.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The user's own dictation, newest-first, final (refined) text only;
    /// meetings and other entry types are excluded.
    private func recentDictationTexts() -> [String] {
        appState.historyStore.entries
            .filter { ($0.entryType ?? .dictation) == .dictation }
            .map(\.text)
    }
}

struct CandidateRow: View {
    @Binding var candidate: AIVocabCandidate

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Toggle("", isOn: $candidate.include)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Include \(candidate.canonical)")
                .padding(.top, Spacing.xxs)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                TextField("Word", text: $candidate.canonical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                TextField("Mistranscriptions", text: $candidate.aliases)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                TextField("Description (optional)", text: $candidate.context)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}
