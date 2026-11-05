// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Deterministic fixes applied after a model refine.
enum RefineHygieneRules {
    private static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday",
                                                "saturday", "sunday"]
    /// Words ending in a period that don't end a sentence.
    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "approx.", "a.m.", "p.m.",
                                                     "mr.", "mrs.", "ms.", "dr.", "st.", "no.", "inc.", "jr.", "sr.", "u.s."]

    /// Capitalizes the first letter after a sentence end, the opening word when `prior` ended a
    /// sentence or there is no earlier text, and weekday names. Never lowercases anything, and an
    /// opening that continues an unfinished sentence stays as written.
    static func restoreCapitals(_ text: String, after prior: String?) -> String {
        let priorText = (prior ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var capitalizeNext = priorText.isEmpty || endsSentence(priorText.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "")
        var output = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            var word = token
            let core = word.lowercased().filter(\.isLetter)
            if weekdays.contains(core) || weekdays.contains(String(core.dropLast()).lowercased()) && core.hasSuffix("s") {
                word = capitalizingFirstLetter(word)
            }
            if capitalizeNext { word = capitalizingFirstLetter(word) }
            capitalizeNext = endsSentence(token)
            output += word
            token = ""
        }
        for character in text {
            if character.isWhitespace {
                flush()
                output.append(character)
            } else {
                token.append(character)
            }
        }
        flush()
        return output
    }

    private static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        guard let last = trimmed.last, ".!?".contains(last) else { return false }
        if trimmed.hasSuffix("..") || trimmed.hasSuffix("…") { return false }
        return !abbreviations.contains(trimmed.lowercased())
    }

    /// Capitalizes a plain lowercase word. Mixed-case names ("gVisor", "iPhone"), paths, addresses,
    /// and file names stay as written.
    private static func capitalizingFirstLetter(_ word: String) -> String {
        guard !word.contains(where: \.isUppercase), !word.contains(where: { "/@_".contains($0) }),
              !String(word.reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed()).contains("."),
              let index = word.firstIndex(where: \.isLetter), word[index].isLowercase else { return word }
        return word.replacingCharacters(in: index...index, with: String(word[index]).uppercased())
    }
}
