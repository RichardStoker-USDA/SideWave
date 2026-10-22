// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import TipKit

/// Searchable transcript history with inline expansion and earlier-stage comparison.
struct HistoryView: View {
    @Environment(AppState.self) var appState
    private let historyTip = HistoryTip()
    var historyStore: HistoryStore
    let shortcutDisplay: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("historyRetentionDays") private var historyRetentionDays: Int = 7

    @State private var selectedEntryID: UUID?
    @State private var historySearchText: String = ""
    @State private var debouncedSearchText: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showHistoryInfo: Bool = false
    @State private var showClearConfirmation: Bool = false
    @State private var showRetentionPopover: Bool = false
    @State private var showStagesForSelected: Bool = false
    @State private var showBackTranslation: Bool = false
    /// Persisted toggle for AI-titling. When off, sidebar rows fall back
    /// to the prefix-based title and the summarizer task is skipped.
    /// Users with slower Macs may prefer off for the lighter pipeline.
    @AppStorage("historyAITitlesEnabled") private var historyAITitlesEnabled: Bool = true

    init(historyStore: HistoryStore, shortcutDisplay: String) {
        self.historyStore = historyStore
        self.shortcutDisplay = shortcutDisplay
        _selectedEntryID = State(initialValue: historyStore.entries.first?.id)
    }

    private var sortedEntries: [TranscriptionEntry] {
        // HistoryStore.entries is already newest-first (insert at 0).
        historyStore.entries
    }

    var body: some View {
        VStack(spacing: 0) {
            detailTopBar
            Divider()
            if visibleEntries.isEmpty {
                detailEmptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleEntries) { entry in
                            historyEntry(entry)
                            Divider().padding(.horizontal, Spacing.lg)
                        }
                    }
                    .padding(.vertical, Spacing.sm)
                }
                .scrollIndicators(.visible)
                .softScrollEdge()
            }
            historyFooter
        }
        .buttonBorderShape(.capsule)
        .safeAreaInset(edge: .top) {
            if let error = historyStore.persistenceError {
                HStack(spacing: 12) {
                    Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Show Storage") { NSWorkspace.shared.open(historyStore.storageDirectory) }
                    Button("Retry Save") { historyStore.flush() }
                }
                .padding(12)
                .background(.regularMaterial)
            }
        }
        .alert("Clear All History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                if reduceMotion {
                    historyStore.clearAll()
                    selectedEntryID = nil
                } else {
                    withAnimation(Animate.standard) {
                        historyStore.clearAll()
                        selectedEntryID = nil
                    }
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
        .sheet(isPresented: $showHistoryInfo) {
            InfoSheet(topic: .history)
        }
        .sheet(isPresented: $showBackTranslation) {
            if let entry = selectedEntry {
                BackTranslationSheet(
                    entry: entry,
                    formatter: appState.dictationFormatter,
                    historyStore: historyStore
                )
            }
        }
        .task {
            await HistoryTip.visited.donate()
            if selectedEntryID == nil {
                selectedEntryID = sortedEntries.first?.id
            }
        }
        .onChange(of: historySearchText) { _, newValue in
            searchDebounceTask?.cancel()
            if newValue.isEmpty {
                debouncedSearchText = ""
            } else {
                searchDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    debouncedSearchText = newValue
                    autoSelectMatchingEntry(for: newValue)
                }
            }
        }
        .onChange(of: selectedEntryID) { _, _ in
            // Collapse the stages disclosure when the user picks a
            // different entry so the new one opens with the refined
            // text only (matches the Mail/Reminders detail pattern).
            showStagesForSelected = false
        }
    }

    private var selectedEntry: TranscriptionEntry? {
        guard let id = selectedEntryID else { return nil }
        return historyStore.entries.first { $0.id == id }
    }

    private var visibleEntries: [TranscriptionEntry] {
        sortedEntries.filter { matchesSearch($0, query: activeSearchQuery) }
    }

    private func historyEntry(_ entry: TranscriptionEntry) -> some View {
        let expanded = selectedEntryID == entry.id
        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Button {
                    withAnimation(reduceMotion || appState.reduceAppMotion ? nil : Animate.standard) {
                        selectedEntryID = expanded ? nil : entry.id
                    }
                } label: {
                    HStack(alignment: .top, spacing: Spacing.md) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 14, height: 20)
                            .adaptiveSecondary()
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(sidebarTitle(for: entry))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: Spacing.xs) {
                                Text(appLabel(for: entry)).lineLimit(1)
                                Text("·")
                                Text(entry.relativeTimeString)
                                if let backend = entry.displayRefineBackend {
                                    Text("·")
                                    refineBackendLogoTiny(for: backend)
                                }
                            }
                            .font(.caption)
                            .adaptiveSecondary()
                            if !expanded {
                                Text(entry.text)
                                    .font(.callout)
                                    .adaptiveSecondary()
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(sidebarTitle(for: entry))")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                Button { copyToClipboard(entry.text) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy text")
                .accessibilityLabel("Copy text")
                Menu { sidebarContextMenu(for: entry) } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Entry actions")
            }
            if expanded {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    detailSubtitle(entry)
                    detailBody(entry)
                    if entry.hasAnyStageHistory { stagesDisclosure(entry) }
                    if entry.wasTranslated { backTranslationButton(entry) }
                }
                .padding(.leading, 14 + Spacing.md)
                .transition(.opacity)
            }
        }
        .padding(Spacing.lg)
        .contextMenu { sidebarContextMenu(for: entry) }
    }

    /// Show a useful preview while an optional generated title is pending.
    private func sidebarTitle(for entry: TranscriptionEntry) -> String {
        if let summary = entry.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        let words = entry.text
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(4)
            .map(String.init)
        let stub = words.joined(separator: " ")
        return stub.isEmpty ? "Untitled" : stub
    }

    /// Subtitle leading text: the target app (or entry-type label for
    /// non-pasted entries). Recovered + cancelled entries get a more
    /// descriptive label so the user understands the row at a glance.
    private func appLabel(for entry: TranscriptionEntry) -> String {
        switch entry.entryType {
        case .cancelled: return "Not sent"
        case .recovered: return entry.recoveryIncomplete == true ? "Partly recovered" : "Recovered"
        case .meeting:   return "Meeting"
        case .document: return "Document · \(entry.appName)"
        default:
            if entry.appName.isEmpty || entry.appName == "Unknown" {
                return "Dictation"
            }
            return entry.appName
        }
    }

    @ViewBuilder
    private func refineBackendLogoTiny(for backendRaw: String?) -> some View {
        if let raw = backendRaw,
           let backend = DictationFormatterService.Backend(rawValue: raw)
        {
            Group {
                switch backend {
                case .appleIntelligence, .appleIntelligenceLegacy:
                    // Single-path glyph: .multicolor falls back to flat mono, so
                    // the shared scheme-aware gradient is the brand treatment
                    // (decorative in-app use; matches the dashboard Refine row).
                    Image(systemName: "apple.intelligence")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.appleIntelligenceGlyphGradient(for: colorScheme))
                case .gemma4E2B, .gemma4E4B, .gemma4_12B:
                    Image("GemmaLogo")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 11, height: 11)
            .help("Refined with \(backend.displayName)")
            .accessibilityElement()
            .accessibilityLabel("Refined with \(backend.displayName)")
        }
    }

    @ViewBuilder
    private func sidebarContextMenu(for entry: TranscriptionEntry) -> some View {
        Button {
            copyToClipboard(entry.text)
        } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }
        if entry.hasDistinctRawText, let raw = entry.rawText {
            Button {
                copyToClipboard(raw)
            } label: {
                Label("Copy Recognized Text", systemImage: "doc.on.doc.fill")
            }
        }
        if entry.hasDistinctEouText, let eou = entry.eouText {
            Button {
                copyToClipboard(eou)
            } label: {
                Label("Copy Live Draft", systemImage: "waveform")
            }
        }
        Divider()
        Button(role: .destructive) {
            let nextID = sortedEntries.first(where: { $0.id != entry.id })?.id
            historyStore.deleteEntry(id: entry.id)
            if selectedEntryID == entry.id {
                selectedEntryID = nextID
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Sidebar footer (more-actions menu + retention quick-set)
    //
    // Matches the Vocabulary footer: an actions menu on the left (Clear All History, AI-Generated
    // Titles) and the retention control on the right, with a chevron so it reads as clickable.

    private var historyFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.sm) {
                Menu {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear All History", systemImage: "trash")
                    }
                    .disabled(historyStore.entries.isEmpty)
                    Divider()
                    Toggle(isOn: $historyAITitlesEnabled) {
                        Label("AI-Generated Titles", systemImage: "text.alignleft")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.callout.weight(.medium))
                        .adaptiveSecondary()
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options")
                .accessibilityLabel("More options")
                .popoverTip(historyTip, arrowEdge: .leading)

                Spacer()

                Button {
                    showRetentionPopover = true
                } label: {
                    HStack(spacing: 3) {
                        Text("Keeps history \(retentionShortLabel)")
                            .font(.caption2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.medium))
                    }
                    .adaptiveSecondary()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Change how long history is kept")
                .popover(isPresented: $showRetentionPopover, arrowEdge: .bottom) {
                    retentionPopover
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
    }

    /// Compact retention label for the sidebar footer button. "7 days"
    /// instead of "7 Days" or "Keeps history for 7 days". The verbose
    /// text would not fit at 190pt width.
    private var retentionShortLabel: String {
        let retention = HistoryRetention(rawValue: historyRetentionDays) ?? .sevenDays
        switch retention {
        case .oneDay:       return "1 day"
        case .threeDays:    return "3 days"
        case .sevenDays:    return "7 days"
        case .fourteenDays: return "14 days"
        case .thirtyDays:   return "30 days"
        case .ninetyDays:   return "90 days"
        case .never:        return "forever"
        }
    }

    private var retentionPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("History retention")
                .font(.callout.weight(.semibold))
            ForEach(HistoryRetention.allCases) { option in
                Button {
                    historyRetentionDays = option.rawValue
                    showRetentionPopover = false
                    historyStore.pruneExpiredEntries()
                } label: {
                    HStack {
                        Text(option.displayName)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Spacer()
                        if historyRetentionDays == option.rawValue {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            Divider()
            Text("Full control in Settings > Privacy")
                .font(.caption2)
                .adaptiveTertiary()
        }
        .padding(Spacing.md)
        .frame(width: 220)
    }

    private var detailTopBar: some View {
        HStack(spacing: Spacing.sm) {
            SearchField("Search all stages", text: $historySearchText)
            HelpLink { showHistoryInfo = true }
                .help("How History works")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
    }

    /// The collapsed header already shows the app and relative time, so the
    /// expanded entry adds only the full date, length, and refining model.
    private func detailSubtitle(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            HStack(spacing: Spacing.xs) {
                Text(entry.fullDateString)
                subtitleDivider
                Text("\(wordCount(for: entry.text)) words").monospacedDigit()
                if let label = refineBackendName(for: entry.displayRefineBackend) {
                    subtitleDivider
                    Text("Refined with \(label)")
                }
            }
            .lineLimit(1)
            if entry.entryType == .recovered, entry.recoveryIncomplete == true {
                Text("Partly recovered. The original recording files are kept in storage.")
            }
        }
        .font(.caption)
        .adaptiveSecondary()
    }

    /// The thin dot divider between subtitle segments.
    private var subtitleDivider: some View {
        Text("·")
            .font(.caption)
            .adaptiveTertiary()
    }

    @ViewBuilder
    private func detailBody(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .settingsCardStyle()
    }

    /// Back-translation, only for translated entries. Opens a sheet that runs the model on request
    /// and saves the result on the entry.
    @ViewBuilder
    private func backTranslationButton(_ entry: TranscriptionEntry) -> some View {
        Button {
            showBackTranslation = true
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "character.book.closed")
                    .font(.callout)
                    .adaptiveSecondary()
                Text("Literal back-translation")
                    .font(.callout)
                    .adaptiveSecondary()
                Spacer(minLength: 0)
                Text(entry.outputLanguageValue.shortLabel)
                    .font(.caption)
                    .adaptiveTertiary()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See this \(entry.outputLanguageValue.displayName) text translated word-for-word back into what you dictated, plus which phrases were localized.")
        .accessibilityLabel("Show literal back-translation")
    }

    /// "Show earlier stages" for multi-stage entries: the recognized text and live draft from
    /// before refining, each with a copy button.
    @ViewBuilder
    private func stagesDisclosure(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                let toggle = { showStagesForSelected.toggle() }
                if reduceMotion {
                    toggle()
                } else {
                    withAnimation(Animate.quick) { toggle() }
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .adaptiveSecondary()
                        .rotationEffect(.degrees(showStagesForSelected ? 90 : 0))
                    Text(showStagesForSelected ? "Hide earlier stages" : "Show earlier stages")
                        .font(.callout)
                        .adaptiveSecondary()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showStagesForSelected ? "Hide the text from before refining" : "Show the recognized text and live draft from before refining")
            .accessibilityLabel(showStagesForSelected ? "Hide earlier transcription stages" : "Show earlier transcription stages")
            .accessibilityAddTraits(showStagesForSelected ? .isSelected : [])

            if showStagesForSelected {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if entry.hasDistinctRawText, let raw = entry.rawText {
                        stageRow(label: "Recognized", sublabel: "Before refining", text: raw)
                    }
                    if entry.hasDistinctEouText, let eou = entry.eouText {
                        stageRow(label: "Live draft", sublabel: "Streaming preview, before punctuation", text: eou)
                    }
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        )
                )
            }
        }
    }

    @ViewBuilder
    private func stageRow(label: String, sublabel: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Text(label)
                    .technicalLabel()
                Text(sublabel)
                    .font(.caption2)
                    .adaptiveTertiary()
                Spacer()
                Button {
                    copyToClipboard(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .adaptiveTertiary()
                }
                .buttonStyle(.plain)
                .help("Copy this text")
                .accessibilityLabel("Copy \(label.lowercased()) text")
            }
            Text(text)
                .font(.body)
                .adaptiveSecondary()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(text.count) characters")
                .font(.caption2)
                .adaptiveTertiary()
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 1)
        )
    }

    private var detailEmptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: activeSearchQuery.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .adaptiveSecondary()
            Text(emptyStateTitle).font(.title3.weight(.semibold))
            Text(emptyStateBody)
                .font(.callout)
                .adaptiveSecondary()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if !debouncedSearchText.isEmpty { return "No matches" }
        if historyStore.entries.isEmpty { return "No history yet" }
        return "Pick an entry"
    }

    private var emptyStateBody: String {
        if !debouncedSearchText.isEmpty {
            return "Nothing matches \"\(debouncedSearchText)\". Try a shorter query or clear the search."
        }
        if historyStore.entries.isEmpty {
            return "Press \(shortcutDisplay) to dictate. Your sessions appear here, ready to search and copy."
        }
        return "Expand an entry to read its text and compare earlier stages."
    }

    // MARK: - Search helpers

    private var activeSearchQuery: String {
        debouncedSearchText.trimmingCharacters(in: .whitespaces)
    }

    private func isDimmedInSearch(_ entry: TranscriptionEntry, query q: String) -> Bool {
        guard !q.isEmpty else { return false }
        return !entryMatches(entry, query: q)
    }

    private func matchesSearch(_ entry: TranscriptionEntry, query q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return entryMatches(entry, query: q)
    }

    private func entryMatches(_ entry: TranscriptionEntry, query q: String) -> Bool {
        // Case-insensitive `range(of:)` avoids making a lowercased copy of every field on every
        // keystroke.
        if entry.text.range(of: q, options: .caseInsensitive) != nil { return true }
        if entry.appName.range(of: q, options: .caseInsensitive) != nil { return true }
        if let summary = entry.aiSummary, summary.range(of: q, options: .caseInsensitive) != nil { return true }
        if let raw = entry.rawText, raw.range(of: q, options: .caseInsensitive) != nil { return true }
        if let eou = entry.eouText, eou.range(of: q, options: .caseInsensitive) != nil { return true }
        if let backend = entry.displayRefineBackend, let name = refineBackendName(for: backend),
           name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        return false
    }

    private func autoSelectMatchingEntry(for searchText: String) {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if let current = selectedEntry, entryMatches(current, query: q) {
            return
        }
        if let firstMatch = sortedEntries.first(where: { entryMatches($0, query: q) }) {
            selectedEntryID = firstMatch.id
        }
    }

    // MARK: - Misc helpers

    private func copyToClipboard(_ text: String) {
        TypingService.writeSensitiveString(text, to: .general)
    }

    private func wordCount(for text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func refineBackendName(for backendRaw: String?) -> String? {
        guard let raw = backendRaw,
              let backend = DictationFormatterService.Backend(rawValue: raw)
        else { return nil }
        switch backend {
        case .appleIntelligence, .appleIntelligenceLegacy: return backend.displayName
        case .gemma4E2B:         return "Gemma 4 E2B"
        case .gemma4E4B:         return "Gemma 4 E4B"
        case .gemma4_12B:        return "Gemma 4 12B"
        }
    }

}

// MARK: - Literal back-translation sheet

/// Sheet for a translated dictation: runs a literal back-translation when asked (never in the
/// background), saves it on the entry, and shows it with secondary labels for supporting text.
private struct BackTranslationSheet: View {
    let entry: TranscriptionEntry
    let formatter: DictationFormatterService
    let historyStore: HistoryStore

    @Environment(\.dismiss) private var dismiss

    private enum LoadState {
        case loading
        case ready(BackTranslation)
        case notReady
        case failed
    }

    @State private var state: LoadState = .loading
    /// Bumped by Retry so the `.task(id:)` re-runs the lookup.
    @State private var attempt: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 480, height: 440)
        .task(id: attempt) {
            await runLookup()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Literal back-translation")
                    .font(.headline)
                Text("How your \(entry.outputLanguageValue.displayName) reads translated straight back to what you dictated.")
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading it back word-for-word…")
                    .font(.callout)
                    .adaptiveSecondary()
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.xl)

        case .notReady:
            statusMessage(
                icon: "exclamationmark.circle",
                text: "The Refine model isn't loaded yet. Turn it on in Settings › Refine and wait for Ready, then try again."
            )

        case .failed:
            VStack(alignment: .leading, spacing: Spacing.md) {
                statusMessage(
                    icon: "exclamationmark.triangle",
                    text: "Couldn't produce a back-translation this time. The model may have been busy."
                )
                Button("Try Again") { attempt += 1 }
                    .buttonStyle(.borderless)
            }

        case .ready(let result):
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Word for word")
                        .technicalLabel()
                    Text(result.literalText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Spacing.md)
                .settingsCardStyle()

                if !result.reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("What was localized")
                            .font(.caption.weight(.medium))
                            .adaptiveSecondary()
                        Text(result.reasoning)
                            .font(.callout)
                            .adaptiveSecondary()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func statusMessage(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.callout)
                .adaptiveSecondary()
            Text(text)
                .font(.callout)
                .adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runLookup() async {
        // Cached from a previous open; show it, never re-run the model.
        if let cached = entry.backTranslation {
            state = .ready(cached)
            return
        }
        state = .loading
        let outcome = await formatter.backTranslate(
            translatedText: entry.text,
            originalText: entry.rawText,
            targetLanguage: entry.outputLanguageValue
        )
        switch outcome {
        case .success(let result):
            historyStore.setBackTranslation(id: entry.id, result)
            state = .ready(result)
        case .notReady:
            state = .notReady
        case .failed:
            state = .failed
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("History - Light") {
    HistoryView(historyStore: HistoryStore.shared, shortcutDisplay: "Right Option")
        .frame(width: 720, height: 540)
        .preferredColorScheme(.light)
}

#Preview("History - Dark") {
    HistoryView(historyStore: HistoryStore.shared, shortcutDisplay: "Right Option")
        .frame(width: 720, height: 540)
        .preferredColorScheme(.dark)
}
#endif
