// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

@MainActor
extension VocabularyStore {
    // MARK: - Mutation API

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = packs.firstIndex(where: { $0.id == id }) else { return }
        packs[idx].isEnabled = enabled
        // User glossaries save to vocabulary.json; built-ins save their on and off state to
        // UserDefaults, since the bundle isn't written to.
        if packs[idx].isBuiltIn {
            saveEnabledBuiltInIDs()
        } else {
            saveUserPacks()
        }
    }



    func reconcileForTemplate(_ templateRawValue: String) {
        var userChanged = false
        var builtInChanged = false
        for idx in packs.indices {
            let links = packs[idx].linkedTemplates
            guard !links.isEmpty else { continue }
            let shouldEnable = links.contains(templateRawValue)
            if packs[idx].isEnabled != shouldEnable {
                packs[idx].isEnabled = shouldEnable
                if packs[idx].isBuiltIn { builtInChanged = true }
                else { userChanged = true }
            }
        }
        if userChanged { saveUserPacks() }
        if builtInChanged { saveEnabledBuiltInIDs() }
    }

    func setLinkedTemplates(_ id: UUID, templates: [String]) {
        guard let idx = packs.firstIndex(where: { $0.id == id }) else { return }
        packs[idx].linkedTemplates = templates
        if packs[idx].isBuiltIn {
            saveBuiltInLinkedTemplates()
        } else {
            saveUserPacks()
        }
    }

    func updateContextBlurb(_ id: UUID, blurb: String) {
        guard let idx = packs.firstIndex(where: { $0.id == id }), !packs[idx].isReadOnly else { return }
        packs[idx].contextBlurb = Self.sanitizeBlurb(blurb)
        saveUserPacks()
    }

    /// Glossary names are short because they share a narrow sidebar column with a word count. A
    /// tooltip shows a truncated name in full.
    nonisolated static let glossaryNameMaxLength: Int = 30

    func createUserPack(name: String) -> UUID {
        let pack = VocabPack(
            name: uniquePackName(from: Self.sanitizeSingleLine(name, maxLength: Self.glossaryNameMaxLength)),
            description: "Custom glossary.",
            isBuiltIn: false,
            isEnabled: true,
            terms: []
        )
        packs.append(pack)
        saveUserPacks()
        return pack.id
    }

    func renamePack(_ id: UUID, to newName: String) {
        guard let idx = packs.firstIndex(where: { $0.id == id }), !packs[idx].isReadOnly else { return }
        packs[idx].name = Self.sanitizeSingleLine(newName, maxLength: Self.glossaryNameMaxLength)
        saveUserPacks()
    }

    func deleteUserPack(_ id: UUID) {
        guard let idx = packs.firstIndex(where: { $0.id == id }), !packs[idx].isBuiltIn else { return }
        packs.remove(at: idx)
        saveUserPacks()
    }

    /// Clone any pack into a user-owned editable copy.
    func cloneBuiltIn(_ id: UUID) -> UUID? {
        guard let idx = packs.firstIndex(where: { $0.id == id }) else { return nil }
        let source = packs[idx]
        var copy = source
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.subscription = nil
        copy.terms = source.terms.map { term in var copy = term; copy.id = UUID(); return copy }
        copy.isEnabled = true
        copy.name = uniquePackName(from: String(source.name.prefix(Self.glossaryNameMaxLength - 7)) + " (copy)")
        do { try commitBundleChange(packs + [copy]) }
        catch { return nil }
        return copy.id
    }

    func addTerm(toPack packID: UUID, term: VocabTerm) {
        guard let idx = packs.firstIndex(where: { $0.id == packID }), !packs[idx].isReadOnly else { return }
        let sanitized = Self.sanitizedTerm(term)
        guard !sanitized.canonical.isEmpty else { return }
        packs[idx].terms.append(sanitized)
        saveUserPacks()
    }

    /// Batch-add multiple terms with one disk write. Drops duplicates by
    /// canonical-lowercased against the target pack's existing terms so a
    /// repeated import doesn't double up.
    func addTerms(toPack packID: UUID, terms: [VocabTerm]) {
        guard let idx = packs.firstIndex(where: { $0.id == packID }), !packs[idx].isReadOnly else { return }
        let existing = Set(packs[idx].terms.map { $0.canonical.lowercased() })
        var added: [VocabTerm] = []
        for t in terms {
            let s = Self.sanitizedTerm(t)
            guard !s.canonical.isEmpty else { continue }
            guard !existing.contains(s.canonical.lowercased()) else { continue }
            guard !added.contains(where: { $0.canonical.lowercased() == s.canonical.lowercased() }) else { continue }
            added.append(s)
        }
        guard !added.isEmpty else { return }
        packs[idx].terms.append(contentsOf: added)
        saveUserPacks()
    }

    /// Strip and cap one term's fields. Nonisolated so both the mutation
    /// APIs and the on-load re-sanitization (loadUserPacks) share one path.
    nonisolated static func sanitizedTerm(_ term: VocabTerm) -> VocabTerm {
        var s = term
        s.canonical = sanitizeSingleLine(term.canonical, maxLength: 80)
        s.aliases = term.aliases
            .map { sanitizeSingleLine($0, maxLength: 80) }
            .filter { !$0.isEmpty }
        // Definitions are limited to 120 characters, so 30 terms add at most about 3600 characters
        // to a prompt, which fits Apple Intelligence's 4K-token window with the rest of the prompt.
        s.definition = term.definition.map { sanitizeSingleLine($0, maxLength: 120) }
        s.usageNote = term.usageNote.map { sanitizeSingleLine($0, maxLength: 120) }
        s.pronunciation = term.pronunciation.map { sanitizeSingleLine($0, maxLength: 80) }
        s.category = term.category.map { sanitizeSingleLine($0, maxLength: 40) }
        return s
    }

    /// Sanitizes a loaded glossary's text again, so an edited or synced file can't bring in
    /// multi-line definitions, chat-template tokens, or an oversized paragraph.
    nonisolated static func sanitizePackContent(_ pack: VocabPack) -> VocabPack {
        var p = pack
        p.name = sanitizeSingleLine(p.name, maxLength: glossaryNameMaxLength)
        p.contextBlurb = sanitizeBlurb(p.contextBlurb)
        p.terms = p.terms.map(sanitizedTerm)
        return p
    }

    func removeTerm(fromPack packID: UUID, termID: UUID) {
        guard let idx = packs.firstIndex(where: { $0.id == packID }), !packs[idx].isReadOnly else { return }
        packs[idx].terms.removeAll { $0.id == termID }
        saveUserPacks()
    }

    /// Replace a term in place by id, keeping its position in the pack's term
    /// list. Editing a word this way leaves the row where it is; a remove +
    /// re-add would jump it to the end.
    func updateTerm(_ term: VocabTerm, in packID: UUID) {
        guard let idx = packs.firstIndex(where: { $0.id == packID }), !packs[idx].isReadOnly else { return }
        guard let termIdx = packs[idx].terms.firstIndex(where: { $0.id == term.id }) else { return }
        let sanitized = Self.sanitizedTerm(term)
        guard !sanitized.canonical.isEmpty else { return }
        packs[idx].terms[termIdx] = sanitized
        saveUserPacks()
    }

    // MARK: - AI-assist candidate dedup

    /// Lowercased preferred spelling of every term in every glossary. The vocabulary assistants
    /// filter their suggestions against it so the user isn't offered words they already have.
    func existingCanonicalKeys() -> Set<String> {
        var keys = Set<String>()
        for pack in packs {
            for term in pack.terms {
                if let k = Self.canonicalKey(term.canonical) { keys.insert(k) }
            }
        }
        return keys
    }

    /// Removes items whose preferred spelling is already in `existing`, ignoring case and spaces,
    /// and duplicates within the list, keeping the first. Shared by the assistants and tests.
    nonisolated static func dedupeByCanonical<T>(
        _ items: [T],
        existing: Set<String>,
        canonical: (T) -> String
    ) -> [T] {
        var seen = existing
        var out: [T] = []
        for item in items {
            guard let key = canonicalKey(canonical(item)) else { continue }
            guard seen.insert(key).inserted else { continue }
            out.append(item)
        }
        return out
    }

    /// Normalized match key for a canonical: trimmed + lowercased, nil when
    /// blank. Single source of truth so `existingCanonicalKeys` and
    /// `dedupeByCanonical` can't disagree about what counts as the same word.
    nonisolated static func canonicalKey(_ raw: String) -> String? {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return k.isEmpty ? nil : k
    }
}
