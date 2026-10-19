// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Persists personal glossaries and optional publisher subscriptions locally.
@Observable
@MainActor
final class VocabularyStore {
    static let shared = VocabularyStore()

    private static let userFileName = "vocabulary.json"
    /// Name of the pack that holds CustomDictionary entries migrated from
    /// the legacy UserDefaults store. Visible to users as a Custom pack.
    static let migratedCorrectionsPackName = "My Corrections"
    /// Set after the one-time migration of old corrections into the vocabulary store.
    private static let correctionsMigrationFlagKey = "vocabCorrectionsMigratedV1"
    /// Enabled built-in glossary IDs, as a JSON array. Built-in glossaries aren't saved to
    /// vocabulary.json, so their on and off state lives here.
    private static let builtInEnabledIDsKey = "vocabEnabledBuiltInPackIDs"
    /// Template links for built-in glossaries, as JSON (`[uuidString: [templateRawValue]]`).
    /// Built-ins are rebuilt from the bundle at launch, so their links are stored here.
    private static let builtInLinkedTemplatesKey = "vocabBuiltInLinkedTemplates"

    /// Max terms included in a single Refine prompt, totaled across all
    /// enabled packs after relevance filtering. Keeps AFM's 4K context safe.
    nonisolated static let promptTermBudget = 30
    /// Upper limit for the whole vocabulary section, about 750 tokens. The per-term and blurb
    /// budgets cover normal use; this only trims very large glossary sets.
    nonisolated static let promptSectionCharCap = 3000
    /// Max context blurb chars included in a single prompt (sum across enabled
    /// packs after concatenation).
    nonisolated static let promptBlurbBudget = 600
    /// Maximum length of one glossary's context paragraph, enforced in the editor, on load, and in
    /// sanitizeBlurb. The total across glossaries is limited separately when the prompt is built.
    nonisolated static let blurbCharCap = 400

    // Internal setter (not `private(set)`) so SideWaveTests can seed packs via @testable.
    var packs: [VocabPack] = []
    private(set) var persistenceError: String?
    private(set) var storageNeedsRecovery = false
    private var storageURL: URL?

    /// Uses a caller-owned file without loading bundled packs or migrating defaults.
    init(storageURL: URL) {
        self.storageURL = storageURL
        packs = loadUserPacks()
    }

    private init() {
        loadAndMergeBuiltIns()
        migrateLegacyDictionaryEntriesIfNeeded()
    }

    /// One-time migration of old corrections from UserDefaults into a "My Corrections" glossary with
    /// `.substitution` scope. The old key stays so an older version can still read it.
    private func migrateLegacyDictionaryEntriesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.correctionsMigrationFlagKey) else { return }

        // Decode legacy entries. Keep keys untouched so a future rollback or
        // support read still works.
        struct LegacyEntry: Decodable {
            let id: UUID?
            let triggers: [String]
            let replacement: String
        }
        let legacy: [LegacyEntry]
        if let data = defaults.data(forKey: "customDictionaryEntries"),
           let decoded = try? JSONDecoder().decode([LegacyEntry].self, from: data)
        {
            legacy = decoded
        } else {
            legacy = []
        }

        guard !legacy.isEmpty else {
            // Nothing to migrate; set the flag so launch doesn't check again.
            defaults.set(true, forKey: Self.correctionsMigrationFlagKey)
            return
        }

        let migratedTerms: [VocabTerm] = legacy.compactMap { entry in
            let canonical = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { return nil }
            let aliases = entry.triggers
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return VocabTerm(
                canonical: canonical,
                aliases: aliases,
                priority: 2,
                scope: .substitution
            )
        }

        guard !migratedTerms.isEmpty else {
            defaults.set(true, forKey: Self.correctionsMigrationFlagKey)
            return
        }

        let pack = VocabPack(
            name: Self.migratedCorrectionsPackName,
            description: "Words moved from your old Dictionary. These correct ASR mis-hearings whether Refine is on or off.",
            isBuiltIn: false,
            isEnabled: true,
            terms: migratedTerms
        )
        packs.append(pack)
        // Mark the migration done only after the file is written. If vocabulary.json couldn't be
        // written, the glossary exists only for this session, and the migration runs again next
        // launch.
        guard saveUserPacks() else {
            SWLog.note("[VocabularyStore] Migration write failed; will retry next launch")
            return
        }
        defaults.set(true, forKey: Self.correctionsMigrationFlagKey)
        SWLog.note("[VocabularyStore] Migrated \(migratedTerms.count) legacy dictionary entries into '\(Self.migratedCorrectionsPackName)'")
    }

    // MARK: - Scope-aware accessors (new unified model)

    /// Every `.substitution` entry across enabled glossaries, for text replacement after
    /// recognition.
    func substitutionEntries() -> [VocabTerm] {
        effectivePacks
            .flatMap { $0.terms.filter { $0.scope.contains(.substitution) }.map(\.recognitionTerm) }
    }

    /// Every entry across enabled glossaries, for CTC vocabulary boosting. Boosting only replaces a
    /// word when the audio matches the term better, so extra terms don't cause false replacements,
    /// and Refine-only entries benefit too.
    func activeEntries() -> [VocabTerm] {
        effectivePacks.flatMap { $0.terms.map(\.recognitionTerm) }
    }

    /// Personal terms take precedence. Locally hidden bundle words stay hidden after sync.
    var effectivePacks: [VocabPack] {
        let enabled = packs.filter { $0.isEnabled }
        let ordered = enabled.filter { !$0.isReadOnly } + enabled.filter { $0.isReadOnly }
        var seen = Set(enabled.filter { !$0.isReadOnly }.flatMap(\.terms).map { $0.canonical.lowercased() })
        return ordered.map { pack in
            var result = pack
            result.terms = pack.terms.filter { term in
                let key = term.canonical.lowercased()
                guard pack.subscription?.hiddenWords.contains(key) != true else { return false }
                guard pack.isReadOnly else { return true }
                return seen.insert(key).inserted
            }
            return result
        }
    }

    // MARK: - Persistence

    private var userFileURL: URL {
        storageURL ?? AppPaths.applicationSupportDirectory().appendingPathComponent(Self.userFileName)
    }

    /// Set when the last loadUserPacks() had to rebuild packs from a legacy
    /// on-disk schema. loadAndMergeBuiltIns rewrites the file forward in the
    /// current schema afterward so the recovery happens at most once.
    private var userPacksNeedResave = false

    /// Load the user's vocabulary.json. Never destructive: a schema change
    /// migrates forward, and only bytes that aren't valid JSON at all get
    /// quarantined. Every recoverable entry is preserved.
    private func loadUserPacks() -> [VocabPack] {
        guard FileManager.default.fileExists(atPath: userFileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: userFileURL)
        } catch {
            storageNeedsRecovery = true
            persistenceError = "Vocabulary could not be read. The existing file is unchanged. Restore access to vocabulary.json, then restart SideWave."
            return []
        }

        // 1. Current schema. VocabPack + VocabTerm both default every
        //    non-core key, so any historical file that carried a name and
        //    well-formed terms decodes here without touching recovery.
        if let decoded = try? JSONDecoder().decode([VocabPack].self, from: data) {
            return decoded.map(Self.sanitizePackContent)
        }

        // The typed decode failed (a key renamed in an older version, or one malformed term).
        // Rebuild each glossary field by field from the JSON so no words are lost, and save again
        // in the current format.
        if let salvaged = Self.salvageLegacyPacks(from: data) {
            userPacksNeedResave = true
            SWLog.note("[VocabularyStore] Recovered \(salvaged.count) user pack(s) from a legacy \(Self.userFileName) schema")
            return salvaged.map(Self.sanitizePackContent)
        }

        // 3. The bytes aren't structured vocabulary JSON at all. Preserve
        //    the file untouched (dated sidecar, owner-only) so nothing is
        //    lost, and start clean rather than overwriting it on next save.
        let fm = FileManager.default
        let ts = Int(Date().timeIntervalSince1970)
        let backupURL = userFileURL.appendingPathExtension("corrupt-\(ts)")
        do {
            try fm.moveItem(at: userFileURL, to: backupURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            persistenceError = "Vocabulary could not be decoded. The original file is saved as \(backupURL.lastPathComponent)."
        } catch {
            storageNeedsRecovery = true
            persistenceError = "Vocabulary could not be recovered safely. The existing file is unchanged. Restore access to vocabulary.json, then restart SideWave."
        }
        return []
    }

    /// Recovery when vocabulary.json can't be decoded normally: rebuilds glossaries from the JSON
    /// with defaults for missing fields. Returns nil only when the data isn't glossary JSON at all,
    /// which is the only case loadUserPacks moves aside.
    nonisolated static func salvageLegacyPacks(from data: Data) -> [VocabPack]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rawPacks: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            rawPacks = arr
        } else if let obj = root as? [String: Any], let arr = obj["packs"] as? [[String: Any]] {
            rawPacks = arr
        } else if let obj = root as? [String: Any] {
            rawPacks = [obj]
        } else {
            return nil
        }
        guard rawPacks.allSatisfy({ $0["name"] is String || $0["terms"] is [Any] }) else { return nil }
        return rawPacks.map { salvagePack(from: $0) }
    }

    nonisolated private static func salvagePack(from dict: [String: Any]) -> VocabPack {
        let id = (dict["id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
        let rawTerms = (dict["terms"] as? [[String: Any]]) ?? []
        return VocabPack(
            id: id,
            name: (dict["name"] as? String) ?? "Recovered glossary",
            description: (dict["description"] as? String) ?? "",
            contextBlurb: (dict["contextBlurb"] as? String) ?? "",
            isBuiltIn: (dict["isBuiltIn"] as? Bool) ?? false,
            isEnabled: (dict["isEnabled"] as? Bool) ?? false,
            terms: rawTerms.compactMap { salvageTerm(from: $0) },
            schemaVersion: (dict["schemaVersion"] as? Int) ?? 1,
            linkedTemplates: (dict["linkedTemplates"] as? [String]) ?? [],
            subscription: dict["subscription"].flatMap { value in
                guard !(value is NSNull) else { return nil }
                guard let data = try? JSONSerialization.data(withJSONObject: value),
                      let subscription = try? JSONDecoder().decode(GlossarySubscription.self, from: data)
                else { return .unavailable }
                return subscription
            }
        )
    }

    nonisolated private static func salvageTerm(from dict: [String: Any]) -> VocabTerm? {
        guard let canonical = dict["canonical"] as? String, !canonical.isEmpty else { return nil }
        let id = (dict["id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
        let scope: VocabularyScope = (dict["scope"] as? Int).map { VocabularyScope(rawValue: $0) } ?? .refineHint
        return VocabTerm(
            id: id,
            canonical: canonical,
            aliases: (dict["aliases"] as? [String]) ?? [],
            definition: dict["definition"] as? String,
            usageNote: dict["usageNote"] as? String,
            pronunciation: dict["pronunciation"] as? String,
            category: dict["category"] as? String,
            priority: (dict["priority"] as? Int) ?? 2,
            scope: scope
        )
    }

    /// Writes user glossaries to vocabulary.json. Returns true only when the write succeeded, so
    /// one-time steps don't mark themselves done after a failed write.
    @discardableResult
    func saveUserPacks() -> Bool {
        guard !storageNeedsRecovery else { return false }
        let userOnly = packs.filter { !$0.isBuiltIn }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(userOnly)
            try data.write(to: userFileURL, options: [.atomic, .completeFileProtection])
            // Owner-only permissions, like history.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: userFileURL.path
            )
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Vocabulary changes are only in memory. Export your glossaries or retry saving before quitting SideWave."
            return false
        }
    }

    @discardableResult
    func retrySaving() -> Bool {
        saveUserPacks()
    }

    /// A failed bundle write must not change the active vocabulary or its installed revision.
    func commitBundleChange(_ updated: [VocabPack]) throws {
        let previous = packs
        packs = updated
        guard saveUserPacks() else {
            packs = previous
            persistenceError = GlossaryBundleError.storage.localizedDescription
            throw GlossaryBundleError.storage
        }
    }

    var storageDirectory: URL { userFileURL.deletingLastPathComponent() }

    /// Optional catalog downloads are imported explicitly; no glossaries ship enabled or bundled.
    private func loadAndMergeBuiltIns() {
        packs = loadUserPacks().filter { !$0.isBuiltIn }
        if userPacksNeedResave {
            saveUserPacks()
            userPacksNeedResave = false
        }
    }

    /// Load the set of enabled built-in pack UUIDs from UserDefaults. Missing
    /// or malformed data means "no built-ins enabled".
    private func loadEnabledBuiltInIDs() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: Self.builtInEnabledIDsKey) else {
            return []
        }
        do {
            let ids = try JSONDecoder().decode([UUID].self, from: data)
            return Set(ids)
        } catch {
            return []
        }
    }

    /// Persist the set of enabled built-in pack UUIDs.
    func saveEnabledBuiltInIDs() {
        let enabled = packs.filter { $0.isBuiltIn && $0.isEnabled }.map(\.id)
        do {
            let data = try JSONEncoder().encode(enabled)
            UserDefaults.standard.set(data, forKey: Self.builtInEnabledIDsKey)
        } catch {
            SWLog.note("[VocabularyStore] saveEnabledBuiltInIDs failed: \(error)")
        }
    }

    /// Load per-built-in-pack template links (uuidString -> template raw
    /// values). Missing or malformed data means "no overrides".
    private func loadBuiltInLinkedTemplates() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: Self.builtInLinkedTemplatesKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    /// Saves template links for built-in glossaries that have any; empty entries are removed.
    func saveBuiltInLinkedTemplates() {
        var map: [String: [String]] = [:]
        for pack in packs where pack.isBuiltIn && !pack.linkedTemplates.isEmpty {
            map[pack.id.uuidString] = pack.linkedTemplates
        }
        do {
            let data = try JSONEncoder().encode(map)
            UserDefaults.standard.set(data, forKey: Self.builtInLinkedTemplatesKey)
        } catch {
            SWLog.note("[VocabularyStore] saveBuiltInLinkedTemplates failed: \(error)")
        }
    }

}
