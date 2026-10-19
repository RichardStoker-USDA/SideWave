// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

// MARK: - Import / Export

extension VocabularyStore {

    /// Portable glossary file format. Only user-written content is exported: name, description,
    /// context paragraph, and each term's fields. Internal identity (ID, built-in flag, on and off
    /// state, template links) isn't, so an import always creates a new user glossary.
    struct GlossaryFile: Codable {
        static let formatTag = "sidewave.glossary"
        static let currentVersion = 1

        var format: String
        var version: Int
        var glossaries: [Glossary]

        init(format: String = GlossaryFile.formatTag, version: Int = GlossaryFile.currentVersion, glossaries: [Glossary]) {
            self.format = format
            self.version = version
            self.glossaries = glossaries
        }

        enum CodingKeys: String, CodingKey { case format, version, glossaries }

        // Tolerant: a bare export missing format/version still imports.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.format = (try? c.decodeIfPresent(String.self, forKey: .format)) ?? GlossaryFile.formatTag
            self.version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? GlossaryFile.currentVersion
            self.glossaries = try c.decode([Glossary].self, forKey: .glossaries)
        }

        struct Glossary: Codable {
            var name: String
            var description: String
            var contextBlurb: String
            var terms: [Term]

            init(name: String, description: String, contextBlurb: String, terms: [Term]) {
                self.name = name
                self.description = description
                self.contextBlurb = contextBlurb
                self.terms = terms
            }

            enum CodingKeys: String, CodingKey { case name, description, contextBlurb, terms }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.name = try c.decode(String.self, forKey: .name)
                self.description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
                self.contextBlurb = (try? c.decodeIfPresent(String.self, forKey: .contextBlurb)) ?? ""
                self.terms = (try? c.decode([Term].self, forKey: .terms)) ?? []
            }
        }

        struct Term: Codable {
            var canonical: String
            var aliases: [String]
            var definition: String?
            var usageNote: String?
            var pronunciation: String?
            var category: String?
            var priority: Int
            /// VocabularyScope rawValue (1 = Replace, 2 = Refine, 3 = both).
            var scope: Int

            init(canonical: String, aliases: [String], definition: String?, usageNote: String?, pronunciation: String? = nil, category: String? = nil, priority: Int, scope: Int) {
                self.canonical = canonical
                self.aliases = aliases
                self.definition = definition
                self.usageNote = usageNote
                self.pronunciation = pronunciation
                self.category = category
                self.priority = priority
                self.scope = scope
            }

            enum CodingKeys: String, CodingKey { case canonical, aliases, definition, usageNote, pronunciation, category, priority, scope }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.canonical = try c.decode(String.self, forKey: .canonical)
                self.aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
                self.definition = try? c.decodeIfPresent(String.self, forKey: .definition)
                self.usageNote = try? c.decodeIfPresent(String.self, forKey: .usageNote)
                self.pronunciation = try? c.decodeIfPresent(String.self, forKey: .pronunciation)
                self.category = try? c.decodeIfPresent(String.self, forKey: .category)
                self.priority = (try? c.decode(Int.self, forKey: .priority)) ?? 2
                self.scope = (try? c.decode(Int.self, forKey: .scope)) ?? VocabularyScope.both.rawValue
            }
        }
    }

    /// Reject oversized import files before decoding (a hand-crafted or corrupt
    /// file shouldn't be able to exhaust memory).
    nonisolated static let maxImportBytes = 8 * 1024 * 1024
    nonisolated static let maxImportedGlossaries = 50
    nonisolated static let maxTermsPerImportedPack = 5000

    // MARK: Export

    /// Portable JSON for a single glossary (built-in or user). Nil if unknown.
    func exportData(for packID: UUID) -> Data? {
        guard let pack = packs.first(where: { $0.id == packID }) else { return nil }
        return Self.encode(Self.exportFile(from: [pack]))
    }

    /// Portable JSON for every user (custom) glossary in one file. Nil when
    /// there are no custom glossaries to export.
    func exportAllUserPacksData() -> Data? {
        let custom = packs.filter { !$0.isBuiltIn }
        guard !custom.isEmpty else { return nil }
        return Self.encode(Self.exportFile(from: custom))
    }

    private nonisolated static func exportFile(from packs: [VocabPack]) -> GlossaryFile {
        GlossaryFile(glossaries: packs.map { pack in
            GlossaryFile.Glossary(
                name: pack.name,
                description: pack.description,
                contextBlurb: pack.contextBlurb,
                terms: pack.terms.map { term in
                    GlossaryFile.Term(
                        canonical: term.canonical,
                        aliases: term.aliases,
                        definition: term.definition,
                        usageNote: term.usageNote,
                        pronunciation: term.pronunciation,
                        category: term.category,
                        priority: term.priority,
                        scope: term.scope.rawValue
                    )
                }
            )
        })
    }

    nonisolated static func encode(_ file: GlossaryFile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(file)
    }

    // MARK: Import

    /// Imports glossaries from JSON: the versioned format, an array, a single glossary, or a raw
    /// vocabulary.json. Every field is sanitized, counts are limited, and each becomes a new user
    /// glossary with a numbered name if the name exists. Returns the new IDs, empty on failure.
    @discardableResult
    func importGlossaries(from data: Data) -> [UUID] {
        guard data.count <= Self.maxImportBytes else {
            SWLog.note("[VocabularyStore] Import rejected: \(data.count) bytes exceeds cap")
            return []
        }
        guard let glossaries = Self.decodeGlossaries(from: data), !glossaries.isEmpty else {
            SWLog.note("[VocabularyStore] Import failed: no glossaries decoded")
            return []
        }

        var newIDs: [UUID] = []
        for glossary in glossaries.prefix(Self.maxImportedGlossaries) {
            let sanitizedTerms: [VocabTerm] = glossary.terms.prefix(Self.maxTermsPerImportedPack).compactMap { t in
                let scopeRaw = t.scope == 0 ? VocabularyScope.both.rawValue : t.scope
                let term = Self.sanitizedTerm(VocabTerm(
                    canonical: t.canonical,
                    aliases: t.aliases,
                    definition: t.definition,
                    usageNote: t.usageNote,
                    pronunciation: t.pronunciation,
                    category: t.category,
                    priority: t.priority == 1 ? 1 : 2,
                    scope: VocabularyScope(rawValue: scopeRaw)
                ))
                return term.canonical.isEmpty ? nil : term
            }

            let baseName = Self.sanitizeSingleLine(glossary.name, maxLength: Self.glossaryNameMaxLength)
            let name = uniquePackName(from: baseName)
            let pack = VocabPack(
                name: name,
                description: Self.sanitizeSingleLine(glossary.description, maxLength: 200),
                contextBlurb: Self.sanitizeBlurb(glossary.contextBlurb),
                isBuiltIn: false,
                isEnabled: true,
                terms: dedupeTermsByCanonical(sanitizedTerms)
            )
            packs.append(pack)
            newIDs.append(pack.id)
        }

        if !newIDs.isEmpty { saveUserPacks() }
        return newIDs
    }

    /// Tolerant decode cascade. Returns nil only when the bytes aren't any
    /// recognizable glossary shape.
    nonisolated static func decodeGlossaries(from data: Data) -> [GlossaryFile.Glossary]? {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(GlossaryFile.self, from: data), !file.glossaries.isEmpty {
            return file.glossaries
        }
        if let bare = try? decoder.decode([GlossaryFile.Glossary].self, from: data), !bare.isEmpty {
            return bare
        }
        if let one = try? decoder.decode(GlossaryFile.Glossary.self, from: data) {
            return [one]
        }
        // Last resort: an internal vocabulary.json (or a single VocabPack).
        if let salvaged = salvageLegacyPacks(from: data), !salvaged.isEmpty {
            return salvaged.map { pack in
                GlossaryFile.Glossary(
                    name: pack.name,
                    description: pack.description,
                    contextBlurb: pack.contextBlurb,
                    terms: pack.terms.map { term in
                        GlossaryFile.Term(
                            canonical: term.canonical,
                            aliases: term.aliases,
                            definition: term.definition,
                            usageNote: term.usageNote,
                            pronunciation: term.pronunciation,
                            category: term.category,
                            priority: term.priority,
                            scope: term.scope.rawValue
                        )
                    }
                )
            }
        }
        return nil
    }

    /// A glossary name not already in use (case-insensitive across all packs),
    /// suffixing " (imported)" on collision so an import never overwrites.
    func uniquePackName(from base: String) -> String {
        Self.uniquePackName(from: base, existingNames: packs.map(\.name))
    }

    nonisolated static func uniquePackName(from base: String, existingNames: [String]) -> String {
        let existing = Set(existingNames.map { $0.lowercased() })
        let cleaned = sanitizeSingleLine(base, maxLength: glossaryNameMaxLength)
        let root = cleaned.isEmpty ? "Imported glossary" : cleaned
        if !existing.contains(root.lowercased()) { return root }
        var index = 1
        while true {
            let suffix = index == 1 ? " (imported)" : " (imported \(index))"
            // Reserve the suffix before truncating so every collision makes
            // progress, including names already at the length limit.
            let prefix = String(root.prefix(max(0, glossaryNameMaxLength - suffix.count)))
                .trimmingCharacters(in: .whitespaces)
            let candidate = prefix + suffix
            if !existing.contains(candidate.lowercased()) { return candidate }
            index += 1
        }
    }

    private func dedupeTermsByCanonical(_ terms: [VocabTerm]) -> [VocabTerm] {
        var seen = Set<String>()
        var out: [VocabTerm] = []
        for term in terms {
            let key = term.canonical.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(term)
        }
        return out
    }
}
