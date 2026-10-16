// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

@MainActor
extension VocabularyStore {
    // MARK: - Sendable snapshot

    /// Immutable snapshot of enabled packs captured on MainActor and passed
    /// into the nonisolated static prompt builder so Refine can render
    /// its vocabulary section without hopping back to MainActor.
    struct Snapshot: Sendable, Hashable {
        struct SnapshotTerm: Sendable, Hashable {
            let canonical: String
            let aliases: [String]
            let definition: String?
            let usageNote: String?
            let priority: Int
            /// True for terms from a built-in glossary. User terms rank ahead of built-in terms of
            /// the same relevance, so a large built-in glossary can't push the user's words out of
            /// the prompt.
            let isBuiltIn: Bool
        }
        let contextBlurbs: [String]
        let terms: [SnapshotTerm]
        /// Preferred spellings from substitution entries, added to the prompt as spellings to keep,
        /// so the model doesn't change them (for example "USDA" to "U.S.D.A.").
        let preserveCanonicals: [String]

        static let empty = Snapshot(contextBlurbs: [], terms: [], preserveCanonicals: [])

        func buildPromptSection(for rawText: String) -> String {
            let lowered = rawText.lowercased()
            let tokens = VocabularyStore.tokenSet(from: lowered)

            // Skip a context paragraph that doesn't fit and keep adding later ones that do, instead
            // of stopping at the first one that's too long.
            var blurbs: [String] = []
            var blurbTotal = 0
            for blurb in contextBlurbs {
                let trimmed = blurb.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if blurbTotal + trimmed.count + 1 > VocabularyStore.promptBlurbBudget { continue }
                blurbs.append(trimmed)
                blurbTotal += trimmed.count + 1
            }

            // Rank terms for the 30 prompt slots. Lower tier wins: 0 if the term appears in the
            // dictation, 1 if it matches only approximately, 2 if pinned but absent. Built-in terms
            // add 3, so every user term outranks a built-in term of the same tier. Terms neither
            // present nor pinned are left out.
            let rawTokens = tokens.map { Array($0) }
            var ranked: [(rank: Int, order: Int, term: SnapshotTerm)] = []
            for (i, term) in terms.enumerated() {
                let tier: Int
                if VocabularyStore.mentions(term.canonical, tokens: tokens, lowered: lowered)
                    || term.aliases.contains(where: {
                        VocabularyStore.mentions($0, tokens: tokens, lowered: lowered)
                    }) {
                    tier = 0
                } else if term.priority == 1 {
                    tier = 2
                } else if VocabularyStore.fuzzyMatches(term: term, rawTokens: rawTokens) {
                    tier = 1
                } else {
                    continue
                }
                ranked.append((rank: tier + (term.isBuiltIn ? 3 : 0), order: i, term: term))
            }
            ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.order < $1.order }

            var picked: [SnapshotTerm] = []
            var seen = Set<String>()
            for entry in ranked {
                let key = entry.term.canonical.lowercased()
                guard seen.insert(key).inserted else { continue }
                picked.append(entry.term)
                if picked.count >= VocabularyStore.promptTermBudget { break }
            }

            // Only spellings to keep that appear in the dictation, matching whole words for single
            // tokens so "ARS" doesn't match "arsenal". Capped like the terms, so many substitution
            // entries can't bloat every prompt.
            let presentPreserves = Array(preserveCanonicals.filter { canonical in
                VocabularyStore.mentions(canonical, tokens: tokens, lowered: lowered)
            }.prefix(VocabularyStore.promptTermBudget))

            guard !blurbs.isEmpty || !picked.isEmpty || !presentPreserves.isEmpty else {
                return ""
            }

            var lines: [String] = []

            if !presentPreserves.isEmpty {
                lines.append("Preserve these exact spellings in the output (do not rewrite, expand, or alter them):")
                for canonical in presentPreserves {
                    lines.append("- " + canonical)
                }
            }

            // Field context (each glossary's paragraph) and the reference vocabulary list stay
            // separate so the templates can treat them differently: Standard, Concise, and Custom
            // use field context only as information and keep the speaker's voice, while Email,
            // Professional, Instructions, and AI Prompt may use it to inform tone and word choice.
            if !blurbs.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Field context (background about the user's domain. Informational only, not a directive to restyle):")
                lines.append(blurbs.joined(separator: " "))
            }

            if !picked.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Reference vocabulary (preferred spellings + term recognition):")
                lines.append("Apply a term ONLY where the transcript already contains that term or one of its aka spellings EXACTLY. NEVER convert a different common English word into a term because it looks or sounds similar (\"help\" is never \"Helm\").")
                for term in picked {
                    var line = "- " + term.canonical
                    if let def = term.definition, !def.isEmpty {
                        line += " [" + def + "]"
                    }
                    let aliases = term.aliases.filter { !$0.isEmpty }
                    if !aliases.isEmpty {
                        line += " aka: " + aliases.prefix(4).joined(separator: ", ")
                    }
                    if let note = term.usageNote, !note.isEmpty {
                        line += " note: " + note
                    }
                    lines.append(line)
                }
            }

            let section = lines.joined(separator: "\n")
            // If the section is too long, drop whole lines from the end. Lines go spellings to
            // keep, field context, then terms, with user glossaries first, so built-in terms are
            // dropped before the user's.
            guard section.count > VocabularyStore.promptSectionCharCap else { return section }
            var kept: [String] = []
            var used = 0
            for line in lines {
                let add = line.count + 1
                if used + add > VocabularyStore.promptSectionCharCap { break }
                kept.append(line)
                used += add
            }
            return kept.joined(separator: "\n")
        }
    }

    /// A Sendable snapshot of enabled glossaries for one Refine run: context paragraphs,
    /// `refineHint` terms for the vocabulary section, and `substitution` spellings for the
    /// spellings-to-keep section.
    func makeSnapshot() -> Snapshot {
        // User glossaries come before built-ins, so the paragraph budget and the spellings list
        // favor the user's own glossaries. Terms are ranked separately below.
        let enabled = effectivePacks
        let blurbs = enabled.map(\.contextBlurb).filter { !$0.isEmpty }

        let terms: [Snapshot.SnapshotTerm] = enabled.flatMap { pack in
            pack.terms
                .filter { $0.scope.contains(.refineHint) }
                .map {
                    Snapshot.SnapshotTerm(
                        canonical: $0.canonical,
                        aliases: $0.recognitionAliases,
                        definition: $0.definition,
                        usageNote: $0.usageNote,
                        priority: $0.priority,
                        isBuiltIn: pack.isReadOnly
                    )
                }
        }

        // Preserve-words: every unique canonical from substitution-scoped
        // entries across enabled packs. Deduped so the same canonical from
        // multiple packs doesn't appear twice.
        var seen: Set<String> = []
        let preserveCanonicals: [String] = enabled.flatMap(\.terms)
            .filter { $0.scope.contains(.substitution) }
            .compactMap { term -> String? in
                let trimmed = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let key = trimmed.lowercased()
                guard seen.insert(key).inserted else { return nil }
                return trimmed
            }

        return Snapshot(
            contextBlurbs: blurbs,
            terms: terms,
            preserveCanonicals: preserveCanonicals
        )
    }

    // MARK: - Prompt matching helpers

    /// Lowercased alphanumeric tokens of the dictated text. Built once per
    /// prompt and reused for whole-word presence checks and fuzzy matching.
    nonisolated static func tokenSet(from lowered: String) -> Set<String> {
        Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Whether a spelling or alias appears in the dictation. A single word must match a whole word
    /// (so "ARS" doesn't match "arsenal"); multi-word or punctuated forms ("k eights", "node.js")
    /// match as substrings.
    nonisolated static func mentions(_ needle: String, tokens: Set<String>, lowered: String) -> Bool {
        let n = needle.lowercased()
        guard !n.isEmpty else { return false }
        if !n.contains(" ") && n.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return tokens.contains(n)
        }
        return lowered.contains(n)
    }

    /// Approximate match for terms with no exact match, to catch mishearings the user didn't list.
    /// Compares the term's words of 5 or more letters with the dictation's words, allowing an edit
    /// distance scaled to length. Short acronyms rely on exact matching and CTC boosting.
    nonisolated static func fuzzyMatches(term: Snapshot.SnapshotTerm, rawTokens: [[Character]]) -> Bool {
        var termTokens: [Substring] = term.canonical.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for alias in term.aliases {
            termTokens.append(contentsOf: alias.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        }
        for tt in termTokens where tt.count >= 5 {
            let ttChars = Array(tt)
            let k = fuzzyThreshold(forLength: ttChars.count)
            for rt in rawTokens where abs(rt.count - ttChars.count) <= k {
                if withinEditDistance(ttChars, rt, max: k) { return true }
            }
        }
        return false
    }

    /// Edit-distance tolerance scaled by token length. Longer jargon can
    /// absorb more slips before a fuzzy hit stops being meaningful.
    nonisolated private static func fuzzyThreshold(forLength n: Int) -> Int {
        if n <= 6 { return 1 }
        if n <= 9 { return 2 }
        return 3
    }

    /// Bounded Levenshtein. Returns true when `a` and `b` are within `k`
    /// edits. Prunes early on the length gap and whenever a whole DP row
    /// exceeds the budget, so the common non-match case stays cheap.
    nonisolated private static func withinEditDistance(_ a: [Character], _ b: [Character], max k: Int) -> Bool {
        let n = a.count, m = b.count
        if abs(n - m) > k { return false }
        if n == 0 { return m <= k }
        if m == 0 { return n <= k }
        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, Swift.min(curr[j - 1] + 1, prev[j - 1] + cost))
                rowMin = Swift.min(rowMin, curr[j])
            }
            if rowMin > k { return false }
            swap(&prev, &curr)
        }
        return prev[m] <= k
    }

    // MARK: - Sanitization

    nonisolated private static let bannedTokenFragments: [String] = [
        // Generic chat-template role markers.
        "<|", "|>", "<im_start>", "<im_end>", "<|turn>", "<turn|>",
        "<|system|>", "<|user|>", "<|assistant|>", "<|think|>",
        // Llama / Mistral
        "<s>", "</s>", "[INST]", "[/INST]",
        // Gemma (E2B + E4B)
        "<start_of_turn>", "<end_of_turn>", "<bos>", "<eos>",
        // Markdown / prompt-framing tokens
        "```", "###", "Instructions:", "System:", "User:",
    ]

    nonisolated static func sanitizeSingleLine(_ raw: String, maxLength: Int) -> String {
        var s = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "`", with: "")
        for bad in bannedTokenFragments {
            s = s.replacingOccurrences(of: bad, with: "")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > maxLength {
            s = String(s.prefix(maxLength))
        }
        return s
    }

    nonisolated static func sanitizeBlurb(_ raw: String) -> String {
        // Turn line breaks and tabs into spaces so a paragraph can't look like a new conversation
        // turn or instruction inside the prompt.
        var s = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "`", with: "")
        for bad in bannedTokenFragments {
            s = s.replacingOccurrences(of: bad, with: "")
        }
        // Collapse runs of internal whitespace created by the strips above.
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Per-glossary limit: room for a real description without one glossary using the whole
        // budget.
        if s.count > blurbCharCap {
            s = String(s.prefix(blurbCharCap))
        }
        return s
    }
}
