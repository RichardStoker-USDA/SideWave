// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import TipKit
import UniformTypeIdentifiers

// MARK: - AI-assist shared building blocks

/// One editable candidate in the review-and-approve step, shared by the
/// Describe-your-field and Learn-from-history sheets. `include` drives the
/// checkbox; the three text fields are user-editable before save.
struct AIVocabCandidate: Identifiable {
    let id = UUID()
    var include: Bool = true
    var canonical: String
    var aliases: String
    var context: String
}

/// State machine shared by both AI-assist sheets: type a source, watch the
/// local model work, review candidates, or recover from an error.
enum AISheetState: Equatable {
    case idle
    case thinking
    case reviewing
    case error(String)
}

/// Small shared helpers for the AI-assist sheets so the Describe and Learn
/// flows stay in lockstep on backend copy and readiness.
enum AIAssist {
    /// Per-backend "what's running" line under the thinking wave. Keeps the
    /// on-device promise visible while the model works.
    static func thinkingSubtitle(for backend: DictationFormatterService.Backend) -> String {
        switch backend {
        case .gemma4E2B:               return "Gemma 4 E2B with thinking mode · entirely on this Mac"
        case .gemma4E4B:               return "Gemma 4 E4B with thinking mode · entirely on this Mac"
        case .gemma4_12B:              return "Gemma 4 12B with thinking mode · entirely on this Mac"
        case .appleIntelligence:       return "Apple Foundation Model · entirely on this Mac"
        case .appleIntelligenceLegacy: return "Apple Foundation Model (Legacy) · entirely on this Mac"
        }
    }

    /// Best-effort read of whether the extractor can run right now. Gemma has
    /// to be loaded into RAM (`.ready`); AFM is OS-owned and attemptable
    /// unless the formatter reports it disabled/unavailable. The extractor
    /// still guards the true state at call time; this only powers the
    /// up-front heads-up so a user isn't surprised by an error after typing.
    @MainActor
    static func backendReady(_ formatter: DictationFormatterService) -> Bool {
        switch formatter.activeBackend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            return formatter.state == .ready
        case .appleIntelligence, .appleIntelligenceLegacy:
            switch formatter.state {
            case .unavailable, .disabled: return false
            default: return true
            }
        }
    }
}

/// The "model is working" phase for the AI-assist sheets: the reactive audio
/// wave plus a title and per-backend on-device subtitle. Respects Reduce
/// Motion; the wave holds a steady level instead of animating.
struct AIThinkingView: View {
    let title: String
    let subtitle: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.lg)
            TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 30.0, paused: reduceMotion)) { context in
                AudioWaveVisualizer(
                    audioLevel: amplitude(at: context.date),
                    colorMode: "rainbow",
                    sensitivity: 0.7,
                    liquidGlass: false,
                    isCleanupMode: false,
                    isRefining: false
                )
                .accessibilityHidden(true)
                .frame(height: 64)
            }
            VStack(spacing: Spacing.xxs) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.lg)
        }
        .frame(maxWidth: .infinity)
    }

    private func amplitude(at date: Date) -> Double {
        if reduceMotion { return 0.5 }
        // 0.6 Hz breathing wave, amplitude 0.25–0.75. Lively enough to read
        // as "the model is working" without looking like a recording.
        let t = date.timeIntervalSinceReferenceDate
        return 0.25 + 0.25 * abs(sin(t * 1.4))
    }
}

/// Shared error phase for the AI-assist sheets: muted amber glyph, a plain-
/// language message (the extractor's own copy, never a raw error), and a
/// retry that returns to the input step.
struct AIErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer(minLength: Spacing.lg)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.warningAmber)
                .accessibilityHidden(true)
            Text("Couldn't extract words")
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: onRetry)
                .actionButton()
            Spacer(minLength: Spacing.lg)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Inline "the local model isn't loaded yet" heads-up for the AI-assist
/// input phase. Secondary text + SF Symbol, no colored callout box.
struct AIBackendNotReadyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The Refine model isn't loaded yet. Turn it on in Settings › Refine and wait for Ready, then extract.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Describe Vocabulary (AI-assist)

struct DescribeVocabularySheet: View {
    let appState: AppState
    let onSave: (String, [VocabTerm]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var collectionName: String = ""
    @State private var description: String = ""
    @State private var selectedCategories: Set<VocabularyAIExtractor.Category> = Set(VocabularyAIExtractor.Category.allCases)
    @State private var wordCount: Double = 12
    @State private var candidates: [AIVocabCandidate] = []
    @State private var state: AISheetState = .idle
    /// The running extraction, held so dismissing the sheet mid-generation can
    /// cancel it; otherwise an orphaned Gemma run keeps the GPU busy and
    /// stalls later refines.
    @State private var extractTask: Task<Void, Never>?
    @FocusState private var descriptionFocused: Bool

    private static let descriptionPlaceholder: String =
        "e.g. I'm a plant geneticist studying drought tolerance in maize. We do phenotyping, metabolomics, transcriptomics, and rhizosphere sampling. Frequent acronyms: GxE, QTL, GWAS, SNP, NIRS, BLUP."

    private static let minWords: Double = 5
    private static let maxWords: Double = 25

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
        .frame(width: 600, height: 540)
        .onAppear {
            if state == .idle { descriptionFocused = true }
        }
        .onDisappear { extractTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: "text.book.closed")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Describe Your Vocabulary")
                    .font(.headline)
                Text(state == .reviewing
                     ? "Review the words SideWave found. Edit or uncheck any before saving."
                     : "Tell SideWave the kind of words you want it to learn. A local model builds the glossary.")
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

    // MARK: Body switch

    @ViewBuilder
    private var bodyContent: some View {
        switch state {
        case .idle:
            inputContent
        case .thinking:
            AIThinkingView(title: "Thinking through your description…", subtitle: thinkingSubtitle)
        case .reviewing:
            reviewingContent
        case .error(let msg):
            AIErrorView(message: msg) { state = .idle }
        }
    }

    // MARK: Input phase

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Glossary name")
                    .font(.callout.weight(.medium))
                TextField("e.g. My Research Lab", text: $collectionName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("What kind of words?")
                    .font(.callout.weight(.medium))
                ZStack(alignment: .topLeading) {
                    // Placeholder shown under the TextEditor while empty.
                    // SwiftUI's TextEditor doesn't support a native prompt
                    // so we composite one in. Fully transparent to clicks
                    // because the editor is layered over it.
                    if description.isEmpty {
                        Text(Self.descriptionPlaceholder)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $description)
                        .font(.callout)
                        .frame(minHeight: 140, maxHeight: 200)
                        .scrollContentBackground(.hidden)
                        .focused($descriptionFocused)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                        .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
                )
                Text("Be specific. The more concrete you are about projects, tools, and jargon, the better the model picks the right words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            categoryPicker

            wordCountSlider

            if !backendReady {
                AIBackendNotReadyNote()
            }
        }
    }

    private var backendReady: Bool {
        AIAssist.backendReady(appState.dictationFormatter)
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text("Focus on")
                    .font(.callout.weight(.medium))
                Spacer()
                HStack(spacing: Spacing.xs) {
                    Button("Select All") {
                        selectedCategories = Set(VocabularyAIExtractor.Category.allCases)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .disabled(selectedCategories.count == VocabularyAIExtractor.Category.allCases.count)
                    Text("·").foregroundStyle(.tertiary)
                    Button("Clear") {
                        selectedCategories.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .disabled(selectedCategories.isEmpty)
                }
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ],
                alignment: .leading,
                spacing: Spacing.xxs
            ) {
                ForEach(VocabularyAIExtractor.Category.allCases) { category in
                    Toggle(isOn: Binding(
                        get: { selectedCategories.contains(category) },
                        set: { isOn in
                            if isOn { selectedCategories.insert(category) }
                            else    { selectedCategories.remove(category) }
                        }
                    )) {
                        Text(category.displayName)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Text(selectedCategories.isEmpty
                 ? "Nothing checked. SideWave will catch any uncommon word the dictation model might miss."
                 : "SideWave prioritizes these kinds, plus any other uncommon words.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var wordCountSlider: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("How many words?")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(Int(wordCount.rounded())) \(Int(wordCount.rounded()) == 1 ? "word" : "words")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: Spacing.xs) {
                Text("\(Int(Self.minWords))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Slider(value: $wordCount, in: Self.minWords...Self.maxWords, step: 1)
                Text("\(Int(Self.maxWords))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text("Each word adds a short hint to the Refine prompt. Keep lean, more isn't always better.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Thinking phase

    /// Per-backend "what's running" line under the thinking wave. Keeps the
    /// promise that everything happens locally up front.
    private var thinkingSubtitle: String {
        AIAssist.thinkingSubtitle(for: appState.dictationFormatter.activeBackend)
    }

    // MARK: Reviewing phase

    private var reviewingContent: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Found \(candidates.count) \(candidates.count == 1 ? "candidate" : "candidates"). \(candidates.filter(\.include).count) selected.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: Spacing.xs) {
                    ForEach($candidates) { $candidate in
                        CandidateRow(candidate: $candidate)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            .frame(maxHeight: 380)
        }
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

            switch state {
            case .idle:
                Button("Extract") {
                    extractTask = Task { await extract() }
                }
                .prominentActionButton()
                .keyboardShortcut(.defaultAction)
                .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .thinking:
                Button("Extract") {}
                    .prominentActionButton()
                    .disabled(true)
            case .reviewing:
                Button("Save to Glossary") { save() }
                    .prominentActionButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            case .error:
                Button("Try Again") {
                    state = .idle
                }
                .prominentActionButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    private var canSave: Bool {
        !collectionName.trimmingCharacters(in: .whitespaces).isEmpty
        && candidates.contains { $0.include && !$0.canonical.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @MainActor
    private func extract() async {
        state = .thinking
        do {
            let extracted = try await VocabularyAIExtractor.extract(
                description: description,
                categories: selectedCategories,
                maxTerms: Int(wordCount.rounded()),
                via: appState.dictationFormatter
            )
            // Sheet dismissed mid-generation; drop the result instead of
            // mutating state on a view that's gone.
            try Task.checkCancellation()
            candidates = extracted.map {
                AIVocabCandidate(canonical: $0.canonical,
                                 aliases: $0.aliases.joined(separator: ", "),
                                 context: $0.definition ?? "")
            }
            if candidates.isEmpty {
                state = .error("The model didn't return any words. Try describing more specifically. Mention the projects, tools, jargon, or people you actually use.")
            } else {
                state = .reviewing
            }
        } catch is CancellationError {
            // Expected on dismiss; nothing to surface.
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func save() {
        let terms = candidates
            .filter { $0.include }
            .compactMap { c -> VocabTerm? in
                let trimmed = c.canonical.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                let aliases = c.aliases
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let ctx = c.context.trimmingCharacters(in: .whitespacesAndNewlines)
                return VocabTerm(
                    canonical: trimmed,
                    aliases: aliases,
                    definition: ctx.isEmpty ? nil : ctx,
                    priority: 2,
                    scope: .both
                )
            }
        let name = collectionName.trimmingCharacters(in: .whitespaces)
        onSave(name, terms)
        dismiss()
    }
}
