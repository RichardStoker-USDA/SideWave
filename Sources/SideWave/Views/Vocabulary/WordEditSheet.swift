// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import TipKit
import UniformTypeIdentifiers

// MARK: - Word Edit Sheet

/// Focused modal for adding or editing one word. Four fields:
///   1. Word. The correct spelling (required)
///   2. Common mistranscriptions. Comma-separated aliases (optional)
///   3. Description. 120-char hint sent to Refine (optional)
///   4. Behavior. Two independent toggles for Replace + Refine hint
/// Comfortable reading width, all fields visible without scroll.
struct WordEditSheet: View {
    let packID: UUID
    let term: VocabTerm?
    let store: VocabularyStore

    @Environment(\.dismiss) private var dismiss
    @State private var canonical: String
    @State private var aliasesText: String
    @State private var definition: String
    @State private var usageNote: String
    @State private var pronunciation: String
    @State private var category: String
    @State private var showRefineContext = false
    @State private var replaceAtDictation: Bool
    @State private var hintToRefine: Bool
    @State private var isPinned: Bool
    @State private var showBehaviorInfo: Bool = false
    @State private var bundleMessage: String?

    init(packID: UUID, term: VocabTerm?, store: VocabularyStore) {
        self.packID = packID
        self.term = term
        self.store = store
        if let t = term {
            _canonical = State(initialValue: t.canonical)
            _aliasesText = State(initialValue: t.aliases.joined(separator: ", "))
            _definition = State(initialValue: t.definition ?? "")
            _usageNote = State(initialValue: t.usageNote ?? "")
            _pronunciation = State(initialValue: t.pronunciation ?? "")
            _category = State(initialValue: t.category ?? "")
            _replaceAtDictation = State(initialValue: t.scope.contains(.substitution))
            _hintToRefine = State(initialValue: t.scope.contains(.refineHint))
            _isPinned = State(initialValue: t.priority == 1)
        } else {
            _canonical = State(initialValue: "")
            _aliasesText = State(initialValue: "")
            _definition = State(initialValue: "")
            _usageNote = State(initialValue: "")
            _pronunciation = State(initialValue: "")
            _category = State(initialValue: "")
            _replaceAtDictation = State(initialValue: true)
            _hintToRefine = State(initialValue: true)
            _isPinned = State(initialValue: false)
        }
    }

    private var isAdding: Bool { term == nil }
    private var isReadOnly: Bool { store.packs.first(where: { $0.id == packID })?.isReadOnly == true }

    /// Compose the OptionSet scope from the two independent toggles.
    private var composedScope: VocabularyScope {
        var s: VocabularyScope = []
        if replaceAtDictation { s.insert(.substitution) }
        if hintToRefine { s.insert(.refineHint) }
        return s
    }

    private var duplicateWord: Bool {
        let word = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.packs.first(where: { $0.id == packID })?.terms.contains {
            $0.id != term?.id && $0.canonical.compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        } == true
    }

    private var canSave: Bool {
        !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !duplicateWord
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Text(isReadOnly ? "Word Details" : (isAdding ? "Add Word" : "Edit Word"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            SettingsDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if isReadOnly, let term {
                        Text(term.canonical).font(.headline).textSelection(.enabled)
                        if let pronunciation = term.pronunciation, !pronunciation.isEmpty {
                            LabeledContent("Pronunciation", value: pronunciation).textSelection(.enabled)
                                .accessibilityElement(children: .ignore).accessibilityLabel("Pronunciation: \(pronunciation)")
                        }
                        if let category = term.category, !category.isEmpty {
                            LabeledContent("Category", value: category).textSelection(.enabled)
                                .accessibilityElement(children: .ignore).accessibilityLabel("Category: \(category)")
                        }
                        LabeledContent("Replace at dictation", value: term.scope.contains(.substitution) ? "On" : "Off")
                            .accessibilityElement(children: .ignore).accessibilityLabel("Replace at dictation: \(term.scope.contains(.substitution) ? "On" : "Off")")
                        LabeledContent("Send hint to Refine", value: term.scope.contains(.refineHint) ? "On" : "Off")
                            .accessibilityElement(children: .ignore).accessibilityLabel("Send hint to Refine: \(term.scope.contains(.refineHint) ? "On" : "Off")")
                        if term.scope.contains(.refineHint), term.priority == 1 {
                            Text("Always included in Refine context.").font(.caption).foregroundStyle(.secondary)
                        }
                        if !term.aliases.isEmpty {
                            Text("Mistranscriptions: " + term.aliases.joined(separator: ", ")).textSelection(.enabled)
                        }
                        if let definition = term.definition, !definition.isEmpty {
                            Text(definition).textSelection(.enabled)
                        }
                        if let note = term.usageNote, !note.isEmpty {
                            Text(note).textSelection(.enabled)
                        }
                        Text("Publisher words are read-only. Copy this word to a personal glossary to customize it. Enabled personal words take priority.")
                            .foregroundStyle(.secondary)
                        Menu("Copy to Personal Glossary") {
                            ForEach(store.packs.filter { !$0.isReadOnly }) { destination in
                                Button(destination.name) {
                                    do { try store.copyWord(term, to: destination.id); bundleMessage = "Copied to \(destination.name)." }
                                    catch { bundleMessage = GlossaryBundleManager.userMessage(error) }
                                }
                            }
                            Divider()
                            Button("New Personal Glossary") {
                                let id = store.createUserPack(name: "My words")
                                do {
                                    try store.copyWord(term, to: id)
                                    let name = store.packs.first(where: { $0.id == id })?.name ?? "your glossary"
                                    bundleMessage = "Copied to \(name). Open it in Vocabulary to edit."
                                }
                                catch { bundleMessage = GlossaryBundleManager.userMessage(error) }
                            }
                        }
                        if let source = store.packs.first(where: { $0.id == packID })?.subscription {
                            Toggle("Use this bundle word", isOn: Binding(
                                get: { !source.hiddenWords.contains(term.canonical.lowercased()) },
                                set: { enabled in
                                    do {
                                        try store.updateSubscription(packID) {
                                            if enabled { $0.hiddenWords.remove(term.canonical.lowercased()) }
                                            else { $0.hiddenWords.insert(term.canonical.lowercased()) }
                                        }
                                    } catch { bundleMessage = GlossaryBundleManager.userMessage(error) }
                                })).toggleStyle(.switch).controlSize(.small)
                            Text("Turning this off affects only this Mac and stays off after bundle updates.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let bundleMessage { Text(bundleMessage).font(.callout).foregroundStyle(.secondary) }
                    } else {
                        wordField
                        pronunciationField
                        mistranscriptionsField
                        categoryField
                        behaviorSection
                        DisclosureGroup("Refine context", isExpanded: $showRefineContext) {
                            VStack(alignment: .leading, spacing: Spacing.md) {
                                descriptionField
                                usageNoteField
                            }
                            .padding(.top, Spacing.sm)
                        }
                        .disclosureGroupStyle(.row)
                    }
                }
                .padding(.vertical, 1)
            }
            .softScrollEdge()

            HStack {
                Spacer()
                Button(isReadOnly ? "Done" : "Cancel") { dismiss() }
                    .actionButton()
                    .keyboardShortcut(.cancelAction)
                if !isReadOnly {
                    Button(isAdding ? "Add Word" : "Save") { save() }
                        .prominentActionButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520, height: 640)
        .buttonBorderShape(.capsule)
    }

    private var wordField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Word")
                .font(.callout.weight(.medium))
            TextField("e.g. USDA, React.js, phenotype", text: $canonical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            if duplicateWord {
                Text("This word is already in this glossary. Edit its existing entry to add pronunciations or mistranscriptions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("The correct spelling, exactly how it should appear in your text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pronunciationField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Pronunciation").font(.callout.weight(.medium))
            TextField("For example: you ess dee ay", text: $pronunciation).textFieldStyle(.roundedBorder)
            Text("Write how it sounds using ordinary words. With replacement enabled, that phrase becomes the spelling above.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Category").font(.callout.weight(.medium))
            TextField("Optional, such as Acronyms or People", text: $category).textFieldStyle(.roundedBorder)
        }
    }

    private var mistranscriptionsField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Common mistranscriptions")
                .font(.callout.weight(.medium))
            TextField("e.g. you es dee ay, u.s.d.a.", text: $aliasesText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            Text("Other ways dictation might transcribe this word. Each one gets replaced with the spelling above. Comma-separated. Leave blank if dictation already hears it correctly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Description")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(definition.count)/120")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            TextField("Optional. Tell Refine what this means.", text: $definition, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .lineLimit(2...3)
                .onChange(of: definition) { _, newValue in
                    if newValue.count > 120 {
                        definition = String(newValue.prefix(120))
                    }
                }
            Text("A short hint for this one word: what it means or how to use it. The Refine model sees it only when this word appears in your dictation. Different from About this glossary, which always applies to the whole collection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usageNoteField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Usage note")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(usageNote.count)/120")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            TextField("Optional. Disambiguate when the word has more than one meaning.", text: $usageNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .lineLimit(1...2)
                .onChange(of: usageNote) { _, newValue in
                    if newValue.count > 120 {
                        usageNote = String(newValue.prefix(120))
                    }
                }
            Text("For words that mean different things in different contexts. Refine sees it alongside the word to pick the right sense.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                Text("Behavior")
                    .font(.callout.weight(.medium))
                Button {
                    showBehaviorInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About this setting")
                .popover(isPresented: $showBehaviorInfo, arrowEdge: .trailing) {
                    behaviorInfoPopover
                }
                Spacer()
            }
            behaviorToggle("Replace at dictation", detail: "Fix mishearings with or without Refine.", isOn: $replaceAtDictation)
            behaviorToggle("Send hint to Refine", detail: "Help the local model recognize your terminology.", isOn: $hintToRefine)
            behaviorToggle("Always include in Refine", detail: "Keep a few important words in the prompt, even when they are not heard.", isOn: $isPinned)
            .disabled(!hintToRefine)
            .help(hintToRefine
                  ? "Keep this word in the Refine prompt on every dictation."
                  : "Turn on Send hint to Refine to pin this word.")
        }
    }

    private func behaviorToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(title)
        }.padding(.vertical, 5)
    }

    @ViewBuilder
    private var behaviorInfoPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Replace at dictation")
                    .font(.callout.weight(.semibold))
                Text("Runs every time you dictate, even when Refine is off. Mistranscriptions get swapped for the correct spelling, and the speech recognizer also boosts the word at the acoustic level so it's likelier to be heard correctly in the first place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Send hint to Refine")
                    .font(.callout.weight(.semibold))
                Text("Adds this word and its description to the prompt the local language model sees during each Refine pass. Helps the model understand your terminology in context. Only runs when Refine is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Always include in Refine pins a word in the prompt even when it was not heard. Use it for a small set of important terms. Most words only need Replace and Send hint enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        }
        .padding(Spacing.md)
        .frame(width: 300)
    }

    private func save() {
        guard !isReadOnly, canSave else { return }
        let aliases = aliasesText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let trimmedDef = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = usageNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTerm = VocabTerm(
            id: term?.id ?? UUID(),
            canonical: canonical.trimmingCharacters(in: .whitespaces),
            aliases: aliases,
            definition: trimmedDef.isEmpty ? nil : trimmedDef,
            usageNote: trimmedNote.isEmpty ? nil : trimmedNote,
            pronunciation: pronunciation.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: isPinned ? 1 : 2,
            scope: composedScope
        )
        if term != nil {
            // Update in place so the edited row keeps its position instead of
            // jumping to the end (remove + re-add reorders it).
            store.updateTerm(newTerm, in: packID)
        } else {
            store.addTerm(toPack: packID, term: newTerm)
        }
        dismiss()
    }
}
