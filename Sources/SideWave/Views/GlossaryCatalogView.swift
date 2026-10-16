// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

struct GlossaryCatalogView: View {
    let store: VocabularyStore
    let onImport: (UUID) -> Void
    let onOpen: (UUID) -> Void
    var loadCatalog: () async throws -> GlossaryCatalog = { try await GlossaryCatalog.fetchIndex() }
    var onCreate: (() -> Void)? = nil
    var onImportFile: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showInstalled = false
    @State private var refreshID = 0
    @State private var history: VocabPack?
    @State private var pendingRemoval: VocabPack?
    @State private var manager: GlossaryBundleManager

    init(store: VocabularyStore, onImport: @escaping (UUID) -> Void,
         loadCatalog: @escaping () async throws -> GlossaryCatalog = { try await GlossaryCatalog.fetchIndex() },
         onCreate: (() -> Void)? = nil, onImportFile: (() -> Void)? = nil,
         initiallyInstalled: Bool = false, onOpen: ((UUID) -> Void)? = nil) {
        self.store = store; self.onImport = onImport; self.loadCatalog = loadCatalog
        self.onOpen = onOpen ?? onImport
        self.onCreate = onCreate; self.onImportFile = onImportFile
        _showInstalled = State(initialValue: initiallyInstalled)
        _manager = State(initialValue: store === VocabularyStore.shared ? .shared : GlossaryBundleManager(store: store))
    }

    private var installed: [VocabPack] { store.packs.filter { $0.subscription != nil } }
    private func matches(_ text: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Glossary bundles").font(.title2.weight(.semibold))
                    Text("Download optional word collections and manage their updates.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Show", selection: $showInstalled) {
                Text("Browse").tag(false)
                Text("Installed (\(installed.count))").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            TextField("Search bundles", text: $query).textFieldStyle(.roundedBorder)
            if let message = manager.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    if showInstalled {
                        if installed.isEmpty { emptyState("No bundles installed", detail: "Browse the catalog to add optional word collections. Updates are manual unless you turn them on for a bundle.") }
                        if !installed.isEmpty && installed.allSatisfy({ !matches($0.name + " " + $0.description) }) {
                            Text("No installed bundles match your search.").foregroundStyle(.secondary)
                        }
                        ForEach(installed.filter { matches($0.name + " " + $0.description) }) { pack in
                            installedRow(pack)
                            Divider()
                        }
                    } else {
                        if manager.isChecking && manager.entries.isEmpty {
                            ProgressView("Checking the catalog\u{2026}").padding(.vertical, Spacing.xl)
                        } else if manager.entries.isEmpty {
                            emptyState("No bundles available", detail: "No bundles are available yet. Create a personal glossary or import a glossary file to get started.")
                            HStack {
                                if let onCreate { Button("Create a Glossary", action: onCreate) }
                                if let onImportFile { Button("Import a File", action: onImportFile) }
                            }
                        }
                        if !manager.entries.isEmpty && manager.entries.allSatisfy({ !matches(([$0.name, $0.description] + $0.tags).joined(separator: " ")) }) {
                            Text("No bundles match your search.").foregroundStyle(.secondary)
                        }
                        ForEach(manager.entries.filter { matches(([$0.name, $0.description] + $0.tags).joined(separator: " ")) }) { entry in
                            catalogRow(entry)
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Spacing.sm)
            }
            Divider()
            HStack(alignment: .center) {
                Text("Downloads from GitHub. No words or usage data are uploaded.\nTransfers appear in Data Transparency.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if manager.isChecking { ProgressView().controlSize(.small) }
                Button("Check for Updates") { refreshID += 1 }
                    .disabled(manager.isChecking || !manager.busyIDs.isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 620, height: 540)
        .buttonBorderShape(.capsule)
        .task(id: refreshID) { await manager.refresh(load: loadCatalog) }
        .sheet(item: $history) { pack in
            GlossaryBundleHistoryView(pack: pack)
        }
        .confirmationDialog("Remove this bundle?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove Bundle", role: .destructive) {
                if let pack = pendingRemoval {
                    do { try store.removeBundle(pack.id) }
                    catch { manager.message = GlossaryBundleManager.userMessage(error) }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { Text("Personal copies and other glossaries are kept. You can download this bundle again.") }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, Spacing.md)
    }

    private func catalogRow(_ entry: GlossaryCatalog.Entry) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(entry.name).font(.headline)
                Text(entry.description).font(.callout).foregroundStyle(.secondary)
                Text("\(entry.termCount) \(entry.termCount == 1 ? "word" : "words") · \(Int64(entry.bytes).byteCountText) · \(entry.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let pack = store.subscribedPack(entry.id) {
                Button("Manage") { showInstalled = true; query = ""; onImport(pack.id) }
            } else { syncButton(entry, title: "Download") }
        }
    }

    @ViewBuilder
    private func installedRow(_ pack: VocabPack) -> some View {
        if let source = pack.subscription {
            let entry = manager.entries.first { $0.id == source.catalogID }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(pack.name).font(.headline)
                        Text("\(pack.terms.count) \(pack.terms.count == 1 ? "word" : "words") · Version \(source.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let entry {
                        syncButton(entry, title: store.bundleIsCurrent(entry) ? "Up to date" : "Update to \(entry.version)")
                    }
                    Menu {
                        Button("Show Words") { onOpen(pack.id); dismiss() }
                        Button("Make a Personal Copy") {
                            if let id = store.cloneBuiltIn(pack.id) { onOpen(id); dismiss() }
                            else { manager.message = store.persistenceError ?? GlossaryBundleError.storage.localizedDescription }
                        }
                        Button("Update History") { history = pack }
                        Divider()
                        Button("Remove Bundle…", role: .destructive) { pendingRemoval = pack }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Options for \(pack.name)")
                }
                Toggle("Update automatically", isOn: Binding(get: { source.automaticallyUpdates }, set: { enabled in
                    do { try store.updateSubscription(pack.id) { $0.automaticallyUpdates = enabled } }
                    catch { manager.message = GlossaryBundleManager.userMessage(error) }
                })).toggleStyle(.switch).controlSize(.small)
                    .disabled(manager.busyIDs.contains(source.catalogID))
                Text(source.automaticallyUpdates ? "Checks once a day while SideWave is open. Only this bundle changes." : "Manual updates. Make a personal copy to edit words without syncing.")
                    .font(.caption).foregroundStyle(.secondary)
                if let checked = source.lastChecked {
                    Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func syncButton(_ entry: GlossaryCatalog.Entry, title: String) -> some View {
        if manager.busyIDs.contains(entry.id) {
            HStack(spacing: Spacing.xs) { ProgressView().controlSize(.small); Text("Downloading…").font(.caption) }
        } else {
            Button(title) {
                Task { if let id = await manager.sync(entry) { onImport(id) } }
            }.disabled(store.bundleIsCurrent(entry))
        }
    }
}

struct GlossaryBundleHistoryView: View {
    let pack: VocabPack
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Update history").font(.title2.weight(.semibold))
                    Text(pack.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(pack.subscription?.changes ?? []) { change in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("Version \(change.version)").font(.headline)
                            Text(change.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            if let notes = change.notes, !notes.isEmpty { Text(notes).font(.callout) }
                            changes("Added", words: change.added)
                            changes("Edited", words: change.edited)
                            changes("Removed", words: change.removed)
                            if change.added.isEmpty && change.edited.isEmpty && change.removed.isEmpty {
                                Text("Bundle information updated; words unchanged.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("The latest 100 updates are kept on this Mac. Personal copies never change during sync.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(Spacing.xl).frame(width: 560, height: 500).buttonBorderShape(.capsule)
    }
    @ViewBuilder private func changes(_ title: String, words: [String]) -> some View {
        if !words.isEmpty {
            DisclosureGroup("\(title) (\(words.count))") {
                Text(words.joined(separator: ", ")).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, Spacing.xs)
            }
            .disclosureGroupStyle(.row)
        }
    }
}
