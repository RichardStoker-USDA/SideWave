// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Keeps recent sentences editable while bounding each inference request.
struct RefinementWindow: Sendable {
    let prefix: String
    let editable: String

    /// `lockedCount` characters at the start of `refinedBody` stay out of the editable part. The stop
    /// pass locks text the model declined, so the next request doesn't send it again.
    init(refinedBody: String, unrefinedTail: String, lockedCount: Int = 0) {
        let open = String(refinedBody.dropFirst(lockedCount))
        let split = Self.splitBoundary(open)
        if lockedCount > 0 {
            // Keep the original gap after the locked text, such as a paragraph break. When nothing
            // after the lock reopens, the gap is the one before the tail.
            let reopens = !split.tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let gap = String((reopens ? open : unrefinedTail).prefix(while: \.isWhitespace))
            prefix = String(refinedBody.prefix(lockedCount)) + gap + split.prefix.drop(while: \.isWhitespace)
        } else {
            prefix = split.prefix
        }
        editable = Self.join(split.tail, unrefinedTail)
    }

    var context: String {
        Self.recentContext(prefix)
    }

    static func recentContext(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).suffix(400).joined(separator: " ")
    }

    /// ASR can insert a period at a pause, so retain two sentences, up to 64 words.
    static func splitBoundary(_ text: String) -> (prefix: String, tail: String) {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return ("", "") }
        let floor = max(0, words.count - 64)
        var start = floor
        var boundaries = 0
        if words.count > 1 {
            for index in stride(from: words.count - 2, through: floor, by: -1) {
                if endsSentence(words[index]) {
                    boundaries += 1
                    if boundaries == 2 { start = index + 1; break }
                }
            }
        }
        let boundary = words[start].startIndex
        return (String(text[..<boundary]).trimmingCharacters(in: .whitespaces), String(text[boundary...]))
    }

    /// A backlog is processed in bounded pieces. No words are dropped at the limit.
    static func nextChunk(_ text: String) -> (chunk: String, remaining: String) {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > 160 else { return (text, "") }
        var end = 160
        for index in stride(from: 159, through: 80, by: -1) {
            if endsSentence(words[index]) { end = index + 1; break }
        }
        let boundary = words[end - 1].endIndex
        return (String(text[..<boundary]), String(text[boundary...]).trimmingCharacters(in: .whitespaces))
    }

    /// The words through the first sentence end, at most 64, and the rest. Pending text that stops
    /// mid-sentence takes this head from the refined text after it, so the stop pass refines the
    /// whole sentence across the junction.
    static func splitLeadingSentence(_ text: String) -> (head: String, rest: String) {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return ("", "") }
        let limit = min(words.count, 64)
        let end = (0..<limit).first { endsSentence(words[$0]) }.map { $0 + 1 } ?? limit
        let boundary = words[end - 1].endIndex
        return (String(text[..<boundary]), String(text[boundary...]).trimmingCharacters(in: .whitespaces))
    }

    static func endsSentence(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).last.map(endsSentence) ?? false
    }

    static func join(_ first: String, _ second: String) -> String {
        let left = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        let trailing = first.reversed().prefix(while: \.isWhitespace).reversed()
        let leading = second.prefix(while: \.isWhitespace)
        let gap = String(trailing) + leading
        let lineBreaks = gap.filter { $0 == "\n" }.count
        let separator = lineBreaks > 0 ? String(repeating: "\n", count: lineBreaks) : " "
        return left + separator + right
    }

    private static func endsSentence(_ word: Substring) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}"))
        return trimmed.last.map { ".!?。！？".contains($0) } ?? false
    }
}
