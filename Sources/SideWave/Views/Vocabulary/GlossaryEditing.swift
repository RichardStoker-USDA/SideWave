// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import TipKit
import UniformTypeIdentifiers

// MARK: - About Blurb Editor

/// Inline editor for the per-glossary contextBlurb (sent to Refine).
/// Hydrates a local draft once per pack and writes back on submit /
/// when the user navigates away. The cap matches VocabularyStore's
/// single source of truth so the editor, the on-load sanitizer, and the
/// backend never disagree about the limit.
struct AboutBlurbEditor: View {
    let pack: VocabPack
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: String = ""
    @State private var hydratedForPackID: UUID? = nil

    private static let placeholder: String =
        "e.g. Plant genetics research: drought tolerance, phenotyping, metabolomics. We use field trials and statistical analysis."
    private static let charCap: Int = VocabularyStore.blurbCharCap

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(Self.placeholder)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.sm + 5)
                        .padding(.top, Spacing.sm + 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.callout)
                    .frame(minHeight: 64, maxHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
            }
            .background(Color.cardBackground(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
            )
            .onChange(of: draft) { _, newValue in
                if newValue.count > Self.charCap {
                    draft = String(newValue.prefix(Self.charCap))
                }
            }
            HStack {
                Spacer()
                Text("\(draft.count)/\(Self.charCap)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear { hydrateIfNeeded() }
        .onChange(of: pack.id) { _, _ in
            commit()
            hydratedForPackID = nil
            hydrateIfNeeded()
        }
        .onDisappear { commit() }
    }

    private func hydrateIfNeeded() {
        guard hydratedForPackID != pack.id else { return }
        draft = pack.contextBlurb
        hydratedForPackID = pack.id
    }

    private func commit() {
        // Commit the draft against the pack it was hydrated from, not the
        // view's current `pack`. On a glossary switch SwiftUI has already
        // swapped `pack` to the new selection before onChange fires, so
        // reading it here would write the old draft into the new glossary and
        // lose the old glossary's edit. Look the source pack up fresh from the
        // store for the built-in / no-change guards.
        guard let id = hydratedForPackID,
              let target = VocabularyStore.shared.packs.first(where: { $0.id == id })
        else { return }
        guard !target.isReadOnly else { return }
        guard draft != target.contextBlurb else { return }
        VocabularyStore.shared.updateContextBlurb(id, blurb: draft)
    }
}

// MARK: - Word Row

/// One row in the words table. Click to edit, hover to reveal delete.
/// Behavior labels (Replace · Refine) appear in the trailing edge so users
/// can read both states at a glance without opening the editor.
struct WordRow: View {
    let term: VocabTerm
    let isReadOnly: Bool
    let isLocallyDisabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(term.canonical).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    if isLocallyDisabled {
                        Text("Off on this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    if let pronunciation = term.pronunciation, !pronunciation.isEmpty {
                        Text("Sounds like \(pronunciation)").font(.caption).foregroundStyle(.secondary)
                    } else if !term.aliases.isEmpty {
                        Text("Replaces \(term.aliases.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    } else if let definition = term.definition, !definition.isEmpty {
                        Text(definition).font(.caption).foregroundStyle(.secondary)
                    }
                    if let category = term.category, !category.isEmpty {
                        Text(category).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isReadOnly ? "View word and copy options" : "Edit word")
            Menu {
                Button(isReadOnly ? "View word and copy options" : "Edit word", action: onEdit)
                if !isReadOnly { Button("Delete Word", role: .destructive, action: onDelete) }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(term.canonical)")
        }
        .padding(Spacing.md)
    }
}

// MARK: - New / Rename Glossary Sheet

struct NewCollectionSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    private let isRenaming: Bool

    init(initialName: String = "", onCreate: @escaping (String) -> Void) {
        self.onCreate = onCreate
        self.isRenaming = !initialName.isEmpty
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(isRenaming ? "Rename Glossary" : "New Glossary")
                .font(.headline)
            SettingsDivider()
            Text(isRenaming ? "Choose a name you can find quickly." : "Keep related words together. You can turn a whole glossary on or off without deleting its words.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Name").font(.callout.weight(.medium))
                TextField("For example: Research terms", text: $name)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .onChange(of: name) { _, value in if value.count > 60 { name = String(value.prefix(60)) } }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .actionButton()
                    .keyboardShortcut(.cancelAction)
                Button(isRenaming ? "Rename" : "Create") {
                    onCreate(name)
                    dismiss()
                }
                .prominentActionButton()
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420, height: 250)
        .buttonBorderShape(.capsule)
    }
}
