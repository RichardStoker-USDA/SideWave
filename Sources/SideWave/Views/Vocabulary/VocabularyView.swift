// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// The Vocabulary tab: glossaries in a sidebar, the selected glossary's
/// description and words in the detail. A glossary can be turned on or off
/// and linked to templates. Each word has a preferred spelling, optional
/// misheard forms to replace, an optional description for Refine, and two
/// switches: Replace at dictation and Send hint to Refine.
struct VocabularyView: View {
    @Environment(AppState.self) var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let dictionaryTip = DictionaryTip()

    @State private var store = VocabularyStore.shared
    @State private var selectedGlossaryID: UUID?
    @State private var wordSheet: WordSheetKind?
    @State private var glossarySheet: GlossarySheetKind?
    @State private var vocabSearchText: String = ""
    @State private var showVocabularyInfo: Bool = false
    @State private var showSpeechProfile: Bool = false
    @State private var showCatalog = false
    private enum CatalogAction { case create, importFile }
    @State private var catalogAction: CatalogAction?
    @State private var categoryFilter = ""

    init(store: VocabularyStore = .shared) {
        _store = State(initialValue: store)
        _selectedGlossaryID = State(initialValue: store.packs.first?.id)
    }

    private enum WordSheetKind: Identifiable {
        case add(packID: UUID)
        case edit(packID: UUID, term: VocabTerm)
        var id: String {
            switch self {
            case .add(let p): return "add-\(p)"
            case .edit(_, let t): return "edit-\(t.id)"
            }
        }
    }

    private enum GlossarySheetKind: Identifiable {
        case new
        case rename(packID: UUID, currentName: String)
        case describe
        case bulkImport(packID: UUID)
        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let id, _): return "rename-\(id)"
            case .describe: return "describe"
            case .bulkImport(let id): return "bulk-\(id)"
            }
        }
    }

    private var selectedPack: VocabPack? {
        guard let id = selectedGlossaryID else { return nil }
        return store.packs.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 176)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = store.persistenceError {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Divider()
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Text(error)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Show Storage") { NSWorkspace.shared.open(store.storageDirectory) }
                        if !store.storageNeedsRecovery {
                            Button("Retry Save") { store.retrySaving() }
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.sm)
                }
                .background(.background)
            }
        }
        .buttonBorderShape(.capsule)
        .onChange(of: selectedGlossaryID) { _, _ in categoryFilter = "" }
        .onChange(of: appState.requestedGlossaryID) { _, id in
            if let id, store.packs.contains(where: { $0.id == id }) {
                selectedGlossaryID = id
                appState.requestedGlossaryID = nil
            }
        }
        .sheet(isPresented: $showCatalog, onDismiss: {
            switch catalogAction {
            case .create: glossarySheet = .new
            case .importFile: importGlossaryFromFile()
            case nil: break
            }
            catalogAction = nil
        }) {
            GlossaryCatalogView(store: store, onImport: { selectedGlossaryID = $0 },
                onCreate: { catalogAction = .create; showCatalog = false },
                onImportFile: { catalogAction = .importFile; showCatalog = false },
                initiallyInstalled: selectedPack?.subscription != nil)
        }
        .sheet(item: $wordSheet, content: wordSheetContent)
        .sheet(item: $glossarySheet, content: glossarySheetContent)
        .sheet(isPresented: $showVocabularyInfo) {
            InfoSheet(topic: .vocabulary)
        }
        .sheet(isPresented: $showSpeechProfile) {
            SpeechProfileSheet(appState: appState)
        }
        .task {
            await DictionaryTip.visited.donate()
            if let id = appState.requestedGlossaryID, store.packs.contains(where: { $0.id == id }) {
                selectedGlossaryID = id
                appState.requestedGlossaryID = nil
            } else if selectedGlossaryID == nil {
                selectedGlossaryID = store.packs.first?.id
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedGlossaryID) {
            Section("Glossaries") {
                ForEach(store.packs) { pack in
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Label(pack.name, systemImage: pack.subscription != nil ? "arrow.down.circle" : "book.closed")
                            .lineLimit(2)
                        Text("\(pack.terms.count) \(pack.terms.count == 1 ? "word" : "words") \u{00B7} \(pack.isEnabled ? "On" : "Off")")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 26)
                    }
                    .opacity(isDimmedInSearch(pack, query: activeVocabSearchQuery) ? 0.4 : 1)
                    .tag(pack.id)
                    .contextMenu { contextMenu(for: pack) }
                }
            }
        }
        .listStyle(.sidebar)
        .disclosureGroupStyle(.automatic)
        .overlay {
            if store.packs.isEmpty {
                Text("No glossaries yet")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Button { showCatalog = true } label: {
                    Label("Browse Bundles", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                sidebarFooter
            }
        }
    }

    private var activeVocabSearchQuery: String {
        vocabSearchText.trimmingCharacters(in: .whitespaces)
    }

    /// Returns true if a global vocab search is active AND the given pack
    /// has no matches. Drives the sidebar row's opacity so non-matching
    /// glossaries gray out and the user's eye lands on the relevant one.
    private func isDimmedInSearch(_ pack: VocabPack, query q: String) -> Bool {
        guard !q.isEmpty else { return false }
        return !packMatchesSearch(pack, query: q)
    }

    private func packMatchesSearch(_ pack: VocabPack, query q: String) -> Bool {
        if pack.name.range(of: q, options: .caseInsensitive) != nil { return true }
        for term in pack.terms {
            if term.canonical.range(of: q, options: .caseInsensitive) != nil { return true }
            if term.aliases.contains(where: { $0.range(of: q, options: .caseInsensitive) != nil }) { return true }
            if let def = term.definition, def.range(of: q, options: .caseInsensitive) != nil { return true }
            if term.pronunciation?.localizedCaseInsensitiveContains(q) == true { return true }
            if term.category?.localizedCaseInsensitiveContains(q) == true { return true }
        }
        return false
    }

    @ViewBuilder
    private func contextMenu(for pack: VocabPack) -> some View {
        if pack.isReadOnly {
            if pack.subscription != nil { Button("Manage Bundle and Updates") { showCatalog = true } }
            Button {
                if let newID = store.cloneBuiltIn(pack.id) {
                    selectedGlossaryID = newID
                }
            } label: {
                Label("Make a Personal Copy", systemImage: "doc.on.doc")
            }
        } else {
            Button {
                glossarySheet = .rename(packID: pack.id, currentName: pack.name)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button {
                if let newID = store.cloneBuiltIn(pack.id) {
                    selectedGlossaryID = newID
                }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                let nextID = store.packs.first(where: { $0.id != pack.id })?.id
                store.deleteUserPack(pack.id)
                selectedGlossaryID = nextID
            } label: {
                Label("Delete Glossary", systemImage: "trash")
            }
        }
    }

    /// Add, import, and export; the local-model helpers; and the estimated
    /// prompt size of the enabled glossaries.
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.sm) {
                Menu {
                    Button {
                        glossarySheet = .new
                    } label: {
                        Label("New Glossary\u{2026}", systemImage: "plus")
                    }
                    Divider()
                    Button {
                        importGlossaryFromFile()
                    } label: {
                        Label("Import Glossary…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        exportAllGlossaries()
                    } label: {
                        Label("Export All…", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(store.packs.allSatisfy(\.isReadOnly))
                } label: {
                    Image(systemName: "plus")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New glossary, import, or export")
                .accessibilityLabel("New glossary, import, or export")
                .popoverTip(dictionaryTip, arrowEdge: .leading)

                Menu {
                    Button {
                        glossarySheet = .describe
                    } label: {
                        Label("Describe Your Field\u{2026}", systemImage: "text.bubble")
                    }
                    Divider()
                    Button {
                        showSpeechProfile = true
                    } label: {
                        Label("Speech Profile\u{2026}", systemImage: "person.wave.2")
                    }
                } label: {
                    Image(systemName: "text.book.closed")
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Build a glossary or a speech profile with a local model")
                .accessibilityLabel("Build a glossary or a speech profile with a local model")

                Spacer()

                if vocabTokenEstimate > 0 {
                    Text("~\(vocabTokenEstimate) tokens")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help("Approximate prompt cost of all currently enabled glossaries.")
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
    }

    private var vocabTokenEstimate: Int {
        let enabled = store.packs.filter(\.isEnabled)
        var charCount = 0
        for pack in enabled {
            charCount += pack.contextBlurb.count
            for term in pack.terms {
                charCount += term.canonical.count
                charCount += term.aliases.joined(separator: ", ").count
                charCount += (term.definition ?? "").count
            }
        }
        return max(0, (charCount + 3) / 4)
    }

    // MARK: - Import / Export

    /// Pick a .json glossary file and import it. Tolerant + validated in the
    /// store; a new user glossary is created (never overwrites) and selected.
    private func importGlossaryFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a glossary file to import"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else {
                appState.showToast("Couldn't read that file", icon: "exclamationmark.triangle")
                return
            }
            let newIDs = store.importGlossaries(from: data)
            if let first = newIDs.first {
                selectedGlossaryID = first
                let count = newIDs.count
                appState.showToast(
                    count == 1 ? "Imported 1 glossary" : "Imported \(count) glossaries",
                    icon: "square.and.arrow.down"
                )
            } else {
                appState.showToast("Nothing to import from that file", icon: "exclamationmark.triangle")
            }
        }
    }

    /// Export one glossary to a portable .json file the user picks.
    private func exportGlossary(_ pack: VocabPack) {
        guard let data = store.exportData(for: pack.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = exportFileName(for: pack.name)
        panel.canCreateDirectories = true
        panel.message = "Export \"\(pack.name)\" as a portable glossary file"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                appState.showToast("Export failed", icon: "exclamationmark.triangle")
            }
        }
    }

    /// Export every custom glossary into one portable .json file.
    private func exportAllGlossaries() {
        guard let data = store.exportAllUserPacksData() else {
            appState.showToast("No custom glossaries to export", icon: "exclamationmark.triangle")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "sidewave-glossaries.json"
        panel.canCreateDirectories = true
        panel.message = "Export all your custom glossaries"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                appState.showToast("Export failed", icon: "exclamationmark.triangle")
            }
        }
    }

    /// Filesystem-safe default filename for a glossary export.
    private func exportFileName(for name: String) -> String {
        let safe = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let base = safe.isEmpty ? "glossary" : safe.lowercased()
        return "\(base).json"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let query = activeVocabSearchQuery
        VStack(spacing: 0) {
            detailTopBar
            Divider()
            if let pack = selectedPack {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        detailHeader(pack)
                        aboutSection(pack)
                        wordsSection(pack, query: query)
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .softScrollEdge()
            } else {
                detailEmptyState
            }
        }
    }

    /// Search stays above the scrolling detail. It filters the selected
    /// glossary's words and dims glossaries in the sidebar with no match.
    private var detailTopBar: some View {
        HStack(spacing: Spacing.sm) {
            SearchField("Search words and glossaries", text: $vocabSearchText)
                .onChange(of: vocabSearchText) { _, newValue in
                    autoSelectMatchingGlossary(for: newValue)
                }
            HelpLink { showVocabularyInfo = true }
                .help("How Vocabulary works")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
    }

    /// When the search text changes, jump to the first matching glossary
    /// if the currently-selected one has no matches. Keeps the user
    /// inside the relevant glossary instead of staring at an "empty"
    /// list while their match is one row over.
    private func autoSelectMatchingGlossary(for searchText: String) {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return }
        if let current = selectedPack, packMatchesSearch(current, query: q) {
            return
        }
        if let firstMatch = store.packs.first(where: { packMatchesSearch($0, query: q) }) {
            selectedGlossaryID = firstMatch.id
        }
    }

    @ViewBuilder
    private func detailHeader(_ pack: VocabPack) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(pack.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                detailSubtitle(pack)
            }
            Spacer(minLength: Spacing.sm)
            HStack(spacing: Spacing.sm) {
                Toggle("", isOn: Binding(
                    get: { pack.isEnabled },
                    set: { store.setEnabled(pack.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(pack.isEnabled ? "Enabled" : "Disabled")
                .accessibilityLabel("\(pack.name) glossary, \(pack.isEnabled ? "enabled" : "disabled")")
                glossaryMenu(pack)
            }
        }
    }

    @ViewBuilder
    private func detailSubtitle(_ pack: VocabPack) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(pack.subscription != nil ? "Subscribed bundle" : (pack.isReadOnly ? "Read-only glossary" : "Custom glossary"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !pack.linkedTemplates.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(linkedTemplatesLabel(pack))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func linkedTemplatesLabel(_ pack: VocabPack) -> String {
        let names = pack.linkedTemplates.compactMap {
            DictationFormatterService.Template(rawValue: $0)?.displayName
        }
        if names.isEmpty { return "" }
        if names.count == 1 { return "Auto-enables for \(names[0])" }
        return "Auto-enables for \(names.count) templates"
    }

    @ViewBuilder
    private func glossaryMenu(_ pack: VocabPack) -> some View {
        Menu {
            if pack.isReadOnly {
                if pack.subscription != nil { Button("Manage Bundle and Updates") { showCatalog = true } }
                Button {
                    if let newID = store.cloneBuiltIn(pack.id) {
                        selectedGlossaryID = newID
                    }
                } label: {
                    Label("Make a Personal Copy", systemImage: "doc.on.doc")
                }
            } else {
                Button {
                    glossarySheet = .rename(packID: pack.id, currentName: pack.name)
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button {
                    if let newID = store.cloneBuiltIn(pack.id) {
                        selectedGlossaryID = newID
                    }
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                Button {
                    glossarySheet = .bulkImport(packID: pack.id)
                } label: {
                    Label("Import Words from CSV…", systemImage: "square.and.arrow.down")
                }
                Divider()
                Button(role: .destructive) {
                    let nextID = store.packs.first(where: { $0.id != pack.id })?.id
                    store.deleteUserPack(pack.id)
                    selectedGlossaryID = nextID
                } label: {
                    Label("Delete Glossary", systemImage: "trash")
                }
            }
            Divider()
            Button {
                exportGlossary(pack)
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            Menu {
                let availableTemplates = DictationFormatterService.Template.allCases
                ForEach(availableTemplates) { template in
                    let isLinked = pack.linkedTemplates.contains(template.rawValue)
                    Button {
                        var updated = pack.linkedTemplates
                        if isLinked {
                            updated.removeAll { $0 == template.rawValue }
                        } else {
                            updated.append(template.rawValue)
                        }
                        store.setLinkedTemplates(pack.id, templates: updated)
                    } label: {
                        HStack {
                            Text(template.displayName)
                            if isLinked { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Link to Templates", systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.callout).frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options for this glossary")
        .accessibilityLabel("More options for this glossary")
    }

    // MARK: - About this glossary

    @ViewBuilder
    private func aboutSection(_ pack: VocabPack) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("About this glossary")
                    .font(.headline)
                Spacer()
            }

            if pack.isReadOnly {
                Text(pack.description.isEmpty
                     ? "Duplicate this read-only glossary to customize it."
                     : pack.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = pack.subscription {
                    HStack {
                        Text("Version \(source.version) · \(source.automaticallyUpdates ? "Automatic updates" : "Manual updates")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Manage Bundle") { showCatalog = true }
                    }
                }
            } else {
                AboutBlurbEditor(pack: pack)
                Text("Optional. Sent to the Refine model so it understands the context behind these words.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Words

    @ViewBuilder
    private func wordsSection(_ pack: VocabPack, query: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Text("Words")
                    .font(.headline)
                Text("\(pack.terms.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if !pack.isReadOnly {
                    Button {
                        wordSheet = .add(packID: pack.id)
                    } label: {
                        Label("Add Word", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                    .prominentActionButton()
                    .help("Add a word to this glossary")
                }
            }

            let categories = Array(Set(pack.terms.compactMap { $0.category }.filter { !$0.isEmpty })).sorted()
            if !categories.isEmpty {
                Picker("Category", selection: $categoryFilter) {
                    Text("All categories").tag("")
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
            }
            wordsBody(pack, query: query)
        }
    }

    @ViewBuilder
    private func wordsBody(_ pack: VocabPack, query: String) -> some View {
        let words = filteredWords(in: pack, query: query).filter { categoryFilter.isEmpty || $0.category == categoryFilter }
        if pack.terms.isEmpty {
            wordsEmptyState(pack)
        } else if words.isEmpty {
            Text("No words match \"\(vocabSearchText)\"")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Spacing.xl)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(words.enumerated()), id: \.1.id) { idx, term in
                    if idx > 0 {
                        Divider().padding(.leading, Spacing.md)
                    }
                    WordRow(
                        term: term,
                        isReadOnly: pack.isReadOnly,
                        isLocallyDisabled: pack.subscription?.hiddenWords.contains(term.canonical.lowercased()) == true,
                        onEdit: {
                            wordSheet = .edit(packID: pack.id, term: term)
                        },
                        onDelete: {
                            if reduceMotion {
                                store.removeTerm(fromPack: pack.id, termID: term.id)
                            } else {
                                withAnimation(Animate.quick) {
                                    store.removeTerm(fromPack: pack.id, termID: term.id)
                                }
                            }
                        }
                    )
                }
            }
            .background(Color.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: CornerRadius.md))
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.md).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func wordsEmptyState(_ pack: VocabPack) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Add your first word").font(.headline)
            Text("Use a preferred spelling, then add how it sounds or how it is sometimes misheard. Words can be grouped by category.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add Word") { wordSheet = .add(packID: pack.id) }.prominentActionButton()
                Button("Import a Word List") { glossarySheet = .bulkImport(packID: pack.id) }.actionButton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.lg)
    }

    private func filteredWords(in pack: VocabPack, query q: String) -> [VocabTerm] {
        guard !q.isEmpty else { return pack.terms }
        return pack.terms.filter { term in
            term.canonical.range(of: q, options: .caseInsensitive) != nil
            || term.aliases.contains { $0.range(of: q, options: .caseInsensitive) != nil }
            || (term.definition?.range(of: q, options: .caseInsensitive) != nil)
            || (term.pronunciation?.range(of: q, options: .caseInsensitive) != nil)
            || (term.category?.range(of: q, options: .caseInsensitive) != nil)
        }
    }

    // MARK: - Detail empty state

    @ViewBuilder
    private var detailEmptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("Your vocabulary").font(.title2.weight(.semibold))
            Text("Create a glossary for names, acronyms, and specialist terms. Add the spelling you want and the phrases SideWave should replace.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.sm) {
                Button("New Glossary") { glossarySheet = .new }.prominentActionButton()
                Button("Browse Bundles") { showCatalog = true }.actionButton()
            }
            Divider()
            Button("Import a Glossary File") { importGlossaryFromFile() }.buttonStyle(.link)
            Button("Create Words from a Description") { glossarySheet = .describe }.buttonStyle(.link)
            Text("No glossaries are included automatically. You choose the words that apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func wordSheetContent(_ sheet: WordSheetKind) -> some View {
        switch sheet {
        case .add(let packID):
            WordEditSheet(packID: packID, term: nil, store: store)
        case .edit(let packID, let term):
            WordEditSheet(packID: packID, term: term, store: store)
        }
    }

    @ViewBuilder
    private func glossarySheetContent(_ sheet: GlossarySheetKind) -> some View {
        switch sheet {
        case .new:
            NewCollectionSheet { name in
                let id = store.createUserPack(name: name)
                selectedGlossaryID = id
            }
        case .rename(let packID, let currentName):
            NewCollectionSheet(initialName: currentName) { newName in
                store.renamePack(packID, to: newName)
            }
        case .describe:
            DescribeVocabularySheet(appState: appState) { name, terms in
                let packID = store.createUserPack(name: name)
                store.addTerms(toPack: packID, terms: terms)
                selectedGlossaryID = packID
            }
        case .bulkImport(let packID):
            BulkImportSheet { terms in
                store.addTerms(toPack: packID, terms: terms)
            }
        }
    }
}

#if DEBUG
#Preview("Vocabulary - Light") {
    VocabularyView()
        .environment(AppState())
        .frame(width: 880, height: 600)
        .preferredColorScheme(.light)
}

#Preview("Vocabulary - Dark") {
    VocabularyView()
        .environment(AppState())
        .frame(width: 880, height: 600)
        .preferredColorScheme(.dark)
}
#endif
