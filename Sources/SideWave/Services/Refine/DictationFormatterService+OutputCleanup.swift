// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

@MainActor
extension DictationFormatterService {
    nonisolated static func cleanupModelOutput(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip wrapping quotes
        if cleaned.count > 2,
           (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) ||
           (cleaned.hasPrefix("'") && cleaned.hasSuffix("'"))
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
                let body = cleaned[cleaned.index(after: firstNewline) ..< endRange.lowerBound]
                cleaned = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Apple Intelligence sometimes restarts the end of its output ("...over a quarter. an
        // incrementally over a quarter") despite the schema rule. Remove a 3 to 5 word tail that
        // also appears earlier.
        cleaned = stripTrailingRepeat(cleaned)

        // Apple Intelligence (Standard) sometimes ends a sentence mid-thought before a conjunction
        // ("...go to the store. And then home") when the speaker said one sentence. Merge `<clause
        // of 8 words or fewer>. <And|But|Or|So|Yet|Nor>` by dropping the period and lowercasing the
        // conjunction. These rarely start a real sentence after such a short clause in dictation.
        cleaned = mergeMidSentenceConjunctions(cleaned)

        return cleaned
    }

    /// Merges `<clause of 8 words or fewer>. (And|But|Or|So|Yet|Nor) <word>` into one sentence.
    /// Only capitalized coordinating conjunctions after short clauses, so "Yes. And then we..." in
    /// a longer context is kept.
    nonisolated static func mergeMidSentenceConjunctions(_ text: String) -> String {
        let conjunctions: Set<String> = ["And", "But", "Or", "So", "Yet", "Nor"]
        // Walk through the text finding `. <Conj>` occurrences.
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex {
            guard let dotRange = result.range(of: ". ", range: searchStart..<result.endIndex) else { break }
            let afterDot = dotRange.upperBound
            guard afterDot < result.endIndex else { break }
            // Read the next word (until whitespace).
            var wordEnd = afterDot
            while wordEnd < result.endIndex, !result[wordEnd].isWhitespace {
                wordEnd = result.index(after: wordEnd)
            }
            let nextWord = String(result[afterDot..<wordEnd])
            guard conjunctions.contains(nextWord) else {
                searchStart = afterDot
                continue
            }
            // Count words from previous terminator to the dot. If ≤8,
            // it's likely an AFM-inserted mid-thought period.
            let beforeDot = result[result.startIndex..<dotRange.lowerBound]
            let prevTerminatorIdx = beforeDot.lastIndex(where: { ".!?".contains($0) })
                                 ?? beforeDot.startIndex
            let clauseSlice = beforeDot[prevTerminatorIdx..<beforeDot.endIndex]
            let clauseWordCount = clauseSlice.split(whereSeparator: \.isWhitespace).count
            guard clauseWordCount <= 8 else {
                searchStart = afterDot
                continue
            }
            // Merge: drop the period + lowercase the conjunction.
            let lowercasedFirst = String(nextWord.first!).lowercased()
            let rest = String(nextWord.dropFirst())
            let replacement = " " + lowercasedFirst + rest
            // Replace ". And" → " and"
            let merged = result.replacingCharacters(
                in: dotRange.lowerBound..<wordEnd,
                with: replacement
            )
            result = merged
            // Restart search from beginning of replacement to handle
            // cascading merges ("X. And Y. But Z." → "X and Y but Z.").
            searchStart = result.startIndex
        }
        return result
    }

    /// Removes a trailing 4 or 5 word phrase that already appears earlier in the output (Apple
    /// Intelligence's partial restart). Four words minimum, so phrases like "day by day, week by
    /// week" are kept.
    nonisolated static func stripTrailingRepeat(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Split by whitespace, keep the original casing. Punctuation stays
        // attached to the word.
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 10 else { return text }
        // Try 5 words, then 4; the longest match wins.
        for tailLen in stride(from: 5, through: 4, by: -1) {
            guard words.count >= tailLen * 2 else { continue }
            let tail = Array(words.suffix(tailLen))
            // Look for an earlier occurrence — must not overlap with the
            // tail itself, so search the prefix up to length - tailLen.
            let searchEnd = words.count - tailLen
            for start in 0..<searchEnd {
                let candidate = Array(words[start..<(start + tailLen)])
                // Case-insensitive comparison so "And the same" matches
                // "and the same" — common at AFM-fabricated boundaries.
                if zip(candidate, tail).allSatisfy({ $0.lowercased() == $1.lowercased() }) {
                    // Drop the tail, plus a short connector such as "an" or "a" that often precedes
                    // the repeat.
                    var keep = Array(words.prefix(words.count - tailLen))
                    if let last = keep.last,
                       last.count <= 3,
                       ["an", "a", "and", "the", "or"].contains(last.lowercased())
                    {
                        keep.removeLast()
                    }
                    // Cut the original text after the last kept word instead of rejoining tokens
                    // with spaces, which would flatten line breaks in multi-line output.
                    if let endIdx = Self.endIndexAfterWords(in: trimmed, count: keep.count) {
                        return String(trimmed[trimmed.startIndex..<endIdx])
                    }
                    return keep.joined(separator: " ")
                }
            }
        }
        return text
    }

    /// Index just past the `count`-th whitespace-separated word, so trimming keeps interior
    /// whitespace.
    nonisolated private static func endIndexAfterWords(in s: String, count: Int) -> String.Index? {
        guard count > 0 else { return nil }
        var seen = 0
        var i = s.startIndex
        var lastWordEnd: String.Index? = nil
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
            seen += 1
            lastWordEnd = i
            if seen == count { return lastWordEnd }
        }
        return lastWordEnd
    }
}
