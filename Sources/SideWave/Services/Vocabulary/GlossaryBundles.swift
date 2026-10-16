// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

struct GlossarySubscription: Codable, Hashable, Sendable {
    var catalogID: String
    var version: String
    var digest: String
    var automaticallyUpdates = false
    var lastChecked: Date?
    var hiddenWords: Set<String> = []
    var changes: [Change] = []

    struct Change: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var date: Date
        var version: String
        var added: [String]
        var edited: [String]
        var removed: [String]
        var notes: String?
    }

    static let unavailable = Self(catalogID: "", version: "Unknown", digest: "")
}

enum GlossaryBundleError: LocalizedError {
    case storage, missing, destination, invalid
    var errorDescription: String? {
        switch self {
        case .storage: "The glossary could not be saved. Its previous version is still active. Check storage access and try again."
        case .missing: "This bundle is no longer in the catalog. Your installed words are kept. You can make a personal copy or remove the bundle."
        case .destination: "Choose a personal glossary without this word, or create a new glossary."
        case .invalid: "This bundle contains invalid or duplicate words. Your installed glossaries are unchanged."
        }
    }
}

extension VocabularyStore {
    func subscribedPack(_ catalogID: String) -> VocabPack? {
        packs.first { $0.subscription?.catalogID == catalogID }
    }

    func bundleIsCurrent(_ entry: GlossaryCatalog.Entry) -> Bool {
        guard let pack = subscribedPack(entry.id) else { return false }
        return pack.subscription?.digest == entry.sha256.lowercased()
            && pack.subscription?.version == entry.version
            && pack.name == Self.sanitizeSingleLine(entry.name, maxLength: Self.glossaryNameMaxLength)
            && pack.description == Self.sanitizeSingleLine(entry.description, maxLength: 200)
    }

    @discardableResult
    func installBundle(_ data: Data, entry: GlossaryCatalog.Entry, now: Date = Date()) throws -> UUID {
        try GlossaryCatalog.verify(data, entry: entry)
        guard let glossary = Self.decodeGlossaries(from: data)?.first else { throw GlossaryBundleError.invalid }
        let previous = subscribedPack(entry.id)
        let previousTerms = Dictionary(previous?.terms.map { ($0.canonical.lowercased(), $0) } ?? [],
                                       uniquingKeysWith: { first, _ in first })
        var keys = Set<String>()
        let terms = try glossary.terms.map { raw -> VocabTerm in
            let term = Self.sanitizedTerm(VocabTerm(
                canonical: raw.canonical, aliases: raw.aliases, definition: raw.definition,
                usageNote: raw.usageNote, pronunciation: raw.pronunciation, category: raw.category,
                priority: raw.priority == 1 ? 1 : 2, scope: VocabularyScope(rawValue: raw.scope)))
            let key = term.canonical.lowercased()
            guard !key.isEmpty, keys.insert(key).inserted, (1...3).contains(raw.scope) else {
                throw GlossaryBundleError.invalid
            }
            var stable = term
            stable.id = previousTerms[key]?.id ?? term.id
            return stable
        }
        var subscription = previous?.subscription ?? GlossarySubscription(
            catalogID: entry.id, version: entry.version, digest: entry.sha256.lowercased())
        if !bundleIsCurrent(entry) {
            let change = GlossarySubscription.Change(date: now, version: entry.version,
                added: terms.filter { previousTerms[$0.canonical.lowercased()] == nil }.map(\.canonical),
                edited: terms.filter { term in
                    guard let old = previousTerms[term.canonical.lowercased()] else { return false }
                    return old != term
                }.map(\.canonical),
                removed: (previous?.terms ?? []).filter { !keys.contains($0.canonical.lowercased()) }.map(\.canonical),
                notes: entry.releaseNotes)
            subscription.changes.insert(change, at: 0)
            subscription.changes = Array(subscription.changes.prefix(100))
        }
        subscription.version = entry.version
        subscription.digest = entry.sha256.lowercased()
        subscription.lastChecked = now
        let pack = VocabPack(id: previous?.id ?? UUID(),
            name: Self.sanitizeSingleLine(entry.name, maxLength: Self.glossaryNameMaxLength),
            description: Self.sanitizeSingleLine(entry.description, maxLength: 200),
            contextBlurb: Self.sanitizeBlurb(glossary.contextBlurb),
            isEnabled: previous?.isEnabled ?? true, terms: terms,
            linkedTemplates: previous?.linkedTemplates ?? [], subscription: subscription)
        var updated = packs
        if let index = updated.firstIndex(where: { $0.id == pack.id }) { updated[index] = pack }
        else { updated.append(pack) }
        try commitBundleChange(updated)
        return pack.id
    }

    func updateSubscription(_ id: UUID, change: (inout GlossarySubscription) -> Void) throws {
        var updated = packs
        guard let index = updated.firstIndex(where: { $0.id == id }), var value = updated[index].subscription else { return }
        change(&value)
        updated[index].subscription = value
        try commitBundleChange(updated)
    }

    func removeBundle(_ id: UUID) throws {
        guard packs.contains(where: { $0.id == id && $0.subscription != nil }) else { return }
        try commitBundleChange(packs.filter { $0.id != id })
    }

    /// Copying is explicit and never overwrites an existing personal word.
    func copyWord(_ term: VocabTerm, to destination: UUID) throws {
        var updated = packs
        guard let index = updated.firstIndex(where: { $0.id == destination && !$0.isReadOnly }),
              !updated[index].terms.contains(where: { $0.canonical.caseInsensitiveCompare(term.canonical) == .orderedSame })
        else { throw GlossaryBundleError.destination }
        var copy = term
        copy.id = UUID()
        updated[index].terms.append(copy)
        try commitBundleChange(updated)
    }
}

@Observable @MainActor
final class GlossaryBundleManager {
    static let shared = GlossaryBundleManager(store: .shared)
    let store: VocabularyStore
    private(set) var entries: [GlossaryCatalog.Entry] = []
    private(set) var isChecking = false
    private(set) var busyIDs: Set<String> = []
    var message: String?
    private var scheduler: Task<Void, Never>?
    private var lastAutomaticAttempt: Date?

    private let loadIndex: () async throws -> GlossaryCatalog
    private let loadBundle: (GlossaryCatalog.Entry) async throws -> Data

    init(store: VocabularyStore,
         loadIndex: @escaping () async throws -> GlossaryCatalog = { try await GlossaryCatalog.fetchIndex() },
         loadBundle: @escaping (GlossaryCatalog.Entry) async throws -> Data = { try await GlossaryCatalog.fetchGlossary($0) }) {
        self.store = store; self.loadIndex = loadIndex; self.loadBundle = loadBundle
    }

    func startAutomaticUpdates() {
        guard scheduler == nil, !AppPaths.isTestHost else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAutomaticUpdates()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func refresh(load: (() async throws -> GlossaryCatalog)? = nil) async {
        guard !isChecking else { return }
        isChecking = true; message = nil
        defer { isChecking = false }
        do { entries = try await (load ?? loadIndex)().glossaries }
        catch is CancellationError { }
        catch { message = Self.userMessage(error) }
    }

    @discardableResult
    func sync(_ entry: GlossaryCatalog.Entry) async -> UUID? {
        guard busyIDs.insert(entry.id).inserted else { return nil }
        defer { busyIDs.remove(entry.id) }
        message = nil
        let originalID = store.subscribedPack(entry.id)?.id
        do {
            if let current = store.subscribedPack(entry.id), store.bundleIsCurrent(entry) {
                try store.updateSubscription(current.id) { $0.lastChecked = Date() }
                return current.id
            }
            let data = try await loadBundle(entry)
            try Task.checkCancellation()
            if let originalID, store.subscribedPack(entry.id)?.id != originalID { return nil }
            return try store.installBundle(data, entry: entry)
        } catch is CancellationError { return nil }
        catch { message = Self.userMessage(error); return nil }
    }

    func checkAutomaticUpdates(now: Date = Date()) async {
        guard !isChecking, busyIDs.isEmpty,
              lastAutomaticAttempt.map({ now.timeIntervalSince($0) >= 86400 }) ?? true else { return }
        let due = store.packs.compactMap { pack -> String? in
            guard let source = pack.subscription, source.automaticallyUpdates,
                  source.lastChecked.map({ now.timeIntervalSince($0) >= 86400 }) ?? true else { return nil }
            return source.catalogID
        }
        guard !due.isEmpty else { return }
        lastAutomaticAttempt = now
        await refresh()
        guard message == nil else { return }
        for id in due {
            guard store.subscribedPack(id)?.subscription?.automaticallyUpdates == true else { continue }
            if let entry = entries.first(where: { $0.id == id }) { await sync(entry) }
            else { message = GlossaryBundleError.missing.localizedDescription }
        }
    }

    static func userMessage(_ error: Error) -> String {
        if let error = error as? GlossaryCatalog.CatalogError { return error.localizedDescription }
        if let error = error as? GlossaryBundleError { return error.localizedDescription }
        return "Could not reach the glossary catalog. Your installed words are unchanged. Try again when connected."
    }
}
