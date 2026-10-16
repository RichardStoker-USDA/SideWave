// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Where a vocabulary entry is used; an entry can be in both.
///
/// `substitution`: replaces any alias in the transcript with the preferred spelling, whether or not
/// Refine is on. Also feeds CTC vocabulary boosting during recognition.
///
/// `refineHint`: adds the entry to the Refine prompt so the model uses the preferred spelling and
/// knows what the term means. Only when Refine is on.
struct VocabularyScope: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let substitution = VocabularyScope(rawValue: 1 << 0)
    static let refineHint   = VocabularyScope(rawValue: 1 << 1)
    static let both: VocabularyScope = [.substitution, .refineHint]
}

/// One entry in a glossary: a preferred spelling, known aliases (usually how recognition mishears
/// it), an optional definition for Refine, and an optional usage note for words with more than one
/// meaning.
struct VocabTerm: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var canonical: String
    var aliases: [String]
    var definition: String?
    var usageNote: String?
    var pronunciation: String?
    var category: String?
    /// Prompt priority. 1 means always offered to Refine, even when the word isn't in the
    /// dictation; anything else means included only when the word appears (exactly or
    /// approximately).
    var priority: Int
    /// Where this entry applies. Defaults to `.refineHint` so older saved glossaries keep their
    /// behavior; migrated corrections use `.substitution`, and new entries default to both.
    var scope: VocabularyScope

    init(id: UUID = UUID(),
         canonical: String,
         aliases: [String] = [],
         definition: String? = nil,
         usageNote: String? = nil,
         pronunciation: String? = nil,
         category: String? = nil,
         priority: Int = 2,
         scope: VocabularyScope = .refineHint)
    {
        self.id = id
        self.canonical = canonical
        self.aliases = aliases
        self.definition = definition
        self.usageNote = usageNote
        self.pronunciation = pronunciation
        self.category = category
        self.priority = priority
        self.scope = scope
    }

    // Custom decoding so older on-disk pack files without `scope` still
    // decode cleanly. Missing key = .refineHint (preserves old Glossary
    // behavior for pre-upgrade data).
    enum CodingKeys: String, CodingKey {
        case id, canonical, aliases, definition, usageNote, pronunciation, category, priority, scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.canonical = try c.decode(String.self, forKey: .canonical)
        self.aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        self.definition = try? c.decodeIfPresent(String.self, forKey: .definition)
        self.usageNote = try? c.decodeIfPresent(String.self, forKey: .usageNote)
        self.pronunciation = try? c.decodeIfPresent(String.self, forKey: .pronunciation)
        self.category = try? c.decodeIfPresent(String.self, forKey: .category)
        self.priority = (try? c.decode(Int.self, forKey: .priority)) ?? 2
        self.scope = (try? c.decode(VocabularyScope.self, forKey: .scope)) ?? .refineHint
    }

    var recognitionAliases: [String] {
        guard let pronunciation, !pronunciation.isEmpty,
              !aliases.contains(where: { $0.caseInsensitiveCompare(pronunciation) == .orderedSame }) else { return aliases }
        return aliases + [pronunciation]
    }

    var recognitionTerm: VocabTerm {
        var result = self
        result.aliases = recognitionAliases
        return result
    }

}

/// A user glossary. The legacy built-in flag remains readable for older exports.
struct VocabPack: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Display name shown in Settings. Short.
    var name: String
    /// One-line purpose. Shown in the Settings pack list.
    var description: String
    /// A paragraph telling the model what the user does and what jargon to expect. Limited to
    /// `VocabularyStore.blurbCharCap` characters; the total across enabled glossaries is limited by
    /// `promptBlurbBudget` when the prompt is built.
    var contextBlurb: String
    /// When true, this pack is read-only (built-in). Users editing a built-in
    /// get a clone-to-edit path that produces a user-owned copy.
    var isBuiltIn: Bool
    /// Whether this pack contributes to the Refine prompt and the
    /// dictation-time CTC boost vocabulary.
    var isEnabled: Bool
    var terms: [VocabTerm]
    /// Schema migration bump point. Current schema is 1.
    var schemaVersion: Int
    /// Templates this glossary is linked to. Switching to a template turns on its linked glossaries
    /// and turns off glossaries linked only to other templates. Unlinked glossaries stay as set.
    var linkedTemplates: [String]
    var subscription: GlossarySubscription?

    var isReadOnly: Bool { isBuiltIn || subscription != nil }

    init(id: UUID = UUID(),
         name: String,
         description: String,
         contextBlurb: String = "",
         isBuiltIn: Bool = false,
         isEnabled: Bool = false,
         terms: [VocabTerm] = [],
         schemaVersion: Int = 1,
         linkedTemplates: [String] = [],
         subscription: GlossarySubscription? = nil)
    {
        self.id = id
        self.name = name
        self.description = description
        self.contextBlurb = contextBlurb
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.terms = terms
        self.schemaVersion = schemaVersion
        self.linkedTemplates = linkedTemplates
        self.subscription = subscription
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, contextBlurb, isBuiltIn, isEnabled, terms, schemaVersion, linkedTemplates, subscription
    }

    // Tolerant decoder, like VocabTerm's. `linkedTemplates` came later, and a synthesized decoder
    // rejected every older glossary. Only `name` and `terms` are required. A malformed term still
    // throws, so the file goes to the field-by-field salvage path, which keeps every recoverable
    // term.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        self.contextBlurb = (try? c.decodeIfPresent(String.self, forKey: .contextBlurb)) ?? ""
        self.isBuiltIn = (try? c.decodeIfPresent(Bool.self, forKey: .isBuiltIn)) ?? false
        self.isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        self.terms = try c.decode([VocabTerm].self, forKey: .terms)
        self.schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        self.linkedTemplates = (try? c.decodeIfPresent([String].self, forKey: .linkedTemplates)) ?? []
        self.subscription = try c.decodeIfPresent(GlossarySubscription.self, forKey: .subscription)
    }
}
