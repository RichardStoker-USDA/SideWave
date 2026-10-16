// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import Foundation

/// Manages custom word replacements for transcription output.
@MainActor
struct CustomDictionary {

    // MARK: - Pattern Cache

    private static var cachedPatterns: [(NSRegularExpression, String)]?
    private static var cachedEntriesHash: Int?

    /// Applies every enabled substitution entry from VocabularyStore to the text, so turning a
    /// glossary on or off shows up right away. Patterns are compiled once and cached until the
    /// entries change.
    static func apply(to text: String) -> String {
        let entries = VocabularyStore.shared.substitutionEntries()
        guard !entries.isEmpty else { return text }

        let hash = entries.hashValue
        if hash != cachedEntriesHash {
            rebuildPatterns(from: entries)
            cachedEntriesHash = hash
        }

        guard let patterns = cachedPatterns, !patterns.isEmpty else { return text }

        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var matches: [(range: NSRange, replacement: String, priority: Int)] = []
        for (priority, pattern) in patterns.enumerated() {
            for match in pattern.0.matches(in: text, range: fullRange) {
                matches.append((match.range, pattern.1, priority))
            }
        }
        // Prefer the longest alias at each position. Match the original text
        // once so one replacement can never trigger another replacement.
        matches.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.priority < $1.priority
        }
        var result = ""
        var cursor = 0
        for match in matches where match.range.location >= cursor {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += match.replacement
            cursor = NSMaxRange(match.range)
        }
        result += source.substring(from: cursor)
        return result
    }

    /// Force-invalidate the pattern cache (call after saving new entries).
    static func invalidateCache() {
        cachedEntriesHash = nil
        cachedPatterns = nil
    }

    // MARK: - CTC Vocabulary Boosting

    /// Converts every active vocabulary entry, whatever its scope, into CTC boost terms: the
    /// preferred spelling as the text, with its aliases. Boosting replaces a word only when the
    /// audio favors the term, though extra terms can still cause false positives. Terms under 3
    /// characters are skipped.
    static func buildVocabularyTerms() -> [CustomVocabularyTerm] {
        let terms = VocabularyStore.shared.activeEntries()
        return terms.compactMap { term in
            let text = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3 else { return nil }
            let aliases = term.aliases.filter { !$0.isEmpty }
            return CustomVocabularyTerm(
                text: text,
                weight: 10.0,
                aliases: aliases.isEmpty ? nil : aliases
            )
        }
    }

    // MARK: - Private

    private static func rebuildPatterns(from entries: [VocabTerm]) {
        var patterns: [(NSRegularExpression, String)] = []
        for entry in entries {
            for trigger in entry.aliases where !trigger.isEmpty {
                let escaped = NSRegularExpression.escapedPattern(for: trigger)
                // `\b` only matches between word and non-word characters, so an alias that starts or ends with
                // punctuation ("c++", ".NET") never matched. Anchor only the edges that are word characters.
                let lead = trigger.first.map(Self.isWordEdge) == true ? "\\b" : ""
                let trail = trigger.last.map(Self.isWordEdge) == true ? "\\b" : ""
                let pattern = "\(lead)\(escaped)\(trail)"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    patterns.append((regex, entry.canonical))
                }
            }
        }
        cachedPatterns = patterns
    }

    /// The characters `\b` treats as word characters (letters, digits, underscore).
    private static func isWordEdge(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
