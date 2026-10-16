// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Keeps recent sentences editable while bounding each inference request.
struct RefinementWindow: Sendable {
    let prefix: String
    let editable: String

    init(refinedBody: String, unrefinedTail: String) {
        let split = Self.splitBoundary(refinedBody)
        prefix = split.prefix
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
