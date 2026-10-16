// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Undo the ITN library's over-eager ordinal conversion in running prose.
///
/// NeMo ITN turns every spoken ordinal into digits, so "first, second,
/// and third" dictated as discourse becomes "1st, 2nd, and 3rd". Real
/// positional uses ("2nd place", "the 3rd of July") should stay digits.
/// ASR emits ordinals as words, so any 1st-10th token at this point in
/// the pipeline came from ITN; reverting is safe unless the neighboring
/// words mark a genuinely positional use.
enum ProseOrdinalReverter {

    private static let words: [String: String] = [
        "1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth",
        "5th": "fifth", "6th": "sixth", "7th": "seventh", "8th": "eighth",
        "9th": "ninth", "10th": "tenth",
    ]

    /// Following words that mark a positional ordinal worth keeping as
    /// digits ("2nd place", "3rd floor", "1st of July").
    private static let keepers: Set<String> = [
        "place", "of", "floor", "grade", "base", "quarter", "round",
        "gear", "edition", "birthday", "anniversary", "century", "street",
        "avenue", "time", "attempt", "try", "row", "inning", "period",
        "half", "down", "amendment", "district", "gen", "generation",
    ]

    static func revert(_ text: String) -> String {
        guard text.contains(where: { $0.isNumber }) else { return text }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in tokens.indices {
            let token = tokens[index]
            // Split trailing punctuation off ("2nd," -> "2nd" + ",").
            let core = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard let word = words[core.lowercased()] else { continue }

            // Keep digits when the next word marks a positional use.
            if let next = nextWord(in: tokens, after: index),
                keepers.contains(next.lowercased())
            {
                continue
            }

            // Sentence-start ordinals get their capital back.
            let replacement = isSentenceStart(tokens: tokens, index: index)
                ? word.prefix(1).uppercased() + word.dropFirst()
                : word
            tokens[index] = token.replacingOccurrences(of: core, with: replacement)
        }
        return tokens.joined(separator: " ")
    }

    private static func nextWord(in tokens: [String], after index: Int) -> String? {
        guard index + 1 < tokens.count else { return nil }
        let next = tokens[index + 1].trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return next.isEmpty ? nil : next
    }

    private static func isSentenceStart(tokens: [String], index: Int) -> Bool {
        guard index > 0 else { return true }
        return tokens[index - 1].hasSuffix(".") || tokens[index - 1].hasSuffix("!")
            || tokens[index - 1].hasSuffix("?")
    }
}
