// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Carried output-hygiene passes: everything a small on-device model does
/// wrong on the way out, stripped deterministically in Swift. Applied by
/// both refiner backends after generation, before the ratio gate.
enum RefineHygiene {

    static func cleanupModelOutput(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip wrapping quotes
        if cleaned.count > 2,
            (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\""))
                || (cleaned.hasPrefix("'") && cleaned.hasSuffix("'"))
        {
            cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip common model preambles
        let preambles = [
            "Here is the corrected text:",
            "Here's the cleaned up text:",
            "Here is the cleaned text:",
            "Corrected text:",
            "Cleaned text:",
            "Cleaned up:",
        ]
        for p in preambles {
            if cleaned.lowercased().hasPrefix(p.lowercased()) {
                cleaned = String(cleaned.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Strip markdown code fences if present
        if cleaned.hasPrefix("```") {
            if let endRange = cleaned.range(of: "```", options: .backwards),
                let firstNewline = cleaned.firstIndex(of: "\n")
            {
                let body = cleaned[cleaned.index(after: firstNewline)..<endRange.lowerBound]
                cleaned = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // AFM occasionally fabricates a partial restart at the end of its
        // output; detect a repeated 4-5 word tail and strip it.
        cleaned = stripTrailingRepeat(cleaned)

        // AFM (Standard) sometimes inserts a period mid-thought followed by
        // a coordinating conjunction; merge conservatively.
        cleaned = mergeMidSentenceConjunctions(cleaned)

        return cleaned
    }

    /// Merges `<short clause <=8 words>. (And|But|Or|So|Yet|Nor) <word>`
    /// into one sentence by dropping the period and lowercasing the
    /// conjunction. Conservative: capitalized coordinating conjunctions
    /// only, short back-look only.
    static func mergeMidSentenceConjunctions(_ text: String) -> String {
        let conjunctions: Set<String> = ["And", "But", "Or", "So", "Yet", "Nor"]
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex {
            guard let dotRange = result.range(of: ". ", range: searchStart..<result.endIndex) else { break }
            let afterDot = dotRange.upperBound
            guard afterDot < result.endIndex else { break }
            var wordEnd = afterDot
            while wordEnd < result.endIndex, !result[wordEnd].isWhitespace {
                wordEnd = result.index(after: wordEnd)
            }
            let nextWord = String(result[afterDot..<wordEnd])
            guard conjunctions.contains(nextWord) else {
                searchStart = afterDot
                continue
            }
            let beforeDot = result[result.startIndex..<dotRange.lowerBound]
            let prevTerminatorIdx =
                beforeDot.lastIndex(where: { ".!?".contains($0) }) ?? beforeDot.startIndex
            let clauseSlice = beforeDot[prevTerminatorIdx..<beforeDot.endIndex]
            let clauseWordCount = clauseSlice.split(whereSeparator: \.isWhitespace).count
            guard clauseWordCount <= 8 else {
                searchStart = afterDot
                continue
            }
            let lowercasedFirst = String(nextWord.first!).lowercased()
            let rest = String(nextWord.dropFirst())
            let replacement = " " + lowercasedFirst + rest
            result = result.replacingCharacters(in: dotRange.lowerBound..<wordEnd, with: replacement)
            searchStart = result.startIndex
        }
        return result
    }

    /// Strip a trailing 4-5 word phrase that also appears earlier in the
    /// same output (the AFM "partial restart" failure mode).
    static func stripTrailingRepeat(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 10 else { return text }
        for tailLen in stride(from: 5, through: 4, by: -1) {
            guard words.count >= tailLen * 2 else { continue }
            let tail = Array(words.suffix(tailLen))
            let searchEnd = words.count - tailLen
            for start in 0..<searchEnd {
                let candidate = Array(words[start..<(start + tailLen)])
                if zip(candidate, tail).allSatisfy({ $0.lowercased() == $1.lowercased() }) {
                    var keep = Array(words.prefix(words.count - tailLen))
                    if let last = keep.last,
                        last.count <= 3,
                        ["an", "a", "and", "the", "or"].contains(last.lowercased())
                    {
                        keep.removeLast()
                    }
                    // Slice the original text rather than rejoin with
                    // spaces — rejoining would flatten every newline.
                    if let endIdx = endIndexAfterWords(in: trimmed, count: keep.count) {
                        return String(trimmed[trimmed.startIndex..<endIdx])
                    }
                    return keep.joined(separator: " ")
                }
            }
        }
        return text
    }

    /// Index just past the end of the `count`-th whitespace-separated word.
    static func endIndexAfterWords(in s: String, count: Int) -> String.Index? {
        guard count > 0 else { return nil }
        var wordsSeen = 0
        var inWord = false
        var lastWordEnd: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                if inWord {
                    wordsSeen += 1
                    lastWordEnd = i
                    if wordsSeen == count { return lastWordEnd }
                    inWord = false
                }
            } else {
                inWord = true
            }
            i = s.index(after: i)
        }
        if inWord {
            wordsSeen += 1
            if wordsSeen == count { return s.endIndex }
        }
        return nil
    }

    /// Gemma thinking mode emits a hidden thought block before the answer;
    /// strip everything through the closing think tag. No-op when absent.
    static func stripGemmaThinkBlock(_ text: String) -> String {
        for closer in ["<|/think|>", "</think>"] {
            if let range = text.range(of: closer) {
                return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// Word-ratio sanity gate: reject refined output whose length is
    /// implausible for the template (hallucinated growth or dropped
    /// content). Returns the offending ratio when out of bounds.
    static func ratioViolation(
        input: String, output: String, template: RefineTemplate
    ) -> Double? {
        let inputWords = wordCount(input)
        let outputWords = wordCount(output)
        guard inputWords > 0 else { return nil }
        // Very short inputs have noisy ratios ("ok" -> "Okay." is 1 word
        // to 1 word, but "hi there" -> "Hi there!" style edits swing
        // wide); the guard exists for real dictation lengths.
        guard inputWords >= 8 else { return nil }
        let ratio = Double(outputWords) / Double(inputWords)
        let bounds = template.outputRatioBounds
        if ratio < bounds.min || ratio > bounds.max {
            return ratio
        }
        return nil
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
