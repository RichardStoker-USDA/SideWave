// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import Foundation
import os

/// Removes words TDT produced from silence: a pause inside a segment, the quiet before speech
/// starts, or the quiet after the speaker stopped. TDT can turn a pause, a breath, or the stop key
/// into a short word ("Yeah.", "you know") that the streaming engine never produced. A word is
/// removed only when both checks agree:
/// - the streaming engine, which heard the same audio, has no matching word, and
/// - no voiced Silero VAD chunk is near the word's start.
///
/// Real words the streaming engine missed are voiced, so VAD keeps them. Words both engines heard
/// are kept whatever VAD says.
enum GhostWordFilter {
    /// Release-visible numbers for field reports. Never logs text.
    static let log = Logger(subsystem: SWLog.subsystem, category: "recognition")

    /// Silero's usual speech threshold. A VAD chunk at or above it counts as voiced here. Lower than
    /// the 0.75 segmentation threshold, so soft speech keeps its words.
    static let voicedProbability: Float = 0.5

    /// One encoder frame, for token timing error.
    static let startAllowance: TimeInterval = 0.08

    /// Longest run of words removed together. Observed ghosts run one to five words. A longer run
    /// that both checks flag points to a VAD or streaming fault, so it is kept.
    static let maxRunWords = 5

    struct Word: Equatable {
        var text: String
        /// Seconds from the segment start.
        let start: TimeInterval
    }

    /// Groups TDT tokens into words. A token that starts with a space begins a word; subword pieces
    /// and punctuation attach to the word before.
    static func words(from timings: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        for timing in timings {
            let trimmed = timing.token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let startsWord = timing.token.first == " " && !normalize(trimmed).isEmpty
            if startsWord || words.isEmpty {
                words.append(Word(text: trimmed, start: timing.startTime))
            } else {
                words[words.count - 1].text += trimmed
            }
        }
        return words
    }

    /// Indices of the words to remove, ascending.
    /// - Parameters:
    ///   - heard: the streaming engine's words for this audio that no earlier segment took.
    ///   - voiced: voiced VAD chunks, in seconds from the segment start. Empty when VAD heard no
    ///     speech near the segment or isn't running, which removes nothing.
    ///   - vadThrough: seconds of the segment VAD has processed. Words starting past it are unknown
    ///     and kept.
    static func ghostIndices(
        words: [Word],
        heard: [String],
        voiced: [Range<TimeInterval>],
        vadThrough: TimeInterval
    ) -> [Int] {
        guard !words.isEmpty, !voiced.isEmpty else { return [] }
        let heardWords = heardIndices(segment: words.map(\.text), heard: heard)
        func nearVoice(_ start: TimeInterval) -> Bool {
            voiced.contains { start >= $0.lowerBound - startAllowance && start < $0.upperBound + startAllowance }
        }
        var ghosts: [Int] = []
        var run: [Int] = []
        func closeRun() {
            if run.count <= maxRunWords { ghosts += run }
            run = []
        }
        for (index, word) in words.enumerated() {
            let silent = !heardWords.contains(index) && !normalize(word.text).isEmpty
                && word.start < vadThrough && !nearVoice(word.start)
            if silent { run.append(index) } else { closeRun() }
        }
        closeRun()
        return ghosts
    }

    /// Removes the words at `indices` from `text`, which may be CTC-rescored. Returns `text`
    /// unchanged when it can't tell which of its words those are. A removed word that ended a
    /// sentence moves its mark to the word before, and one that started a sentence passes the
    /// capital to the word after.
    static func strip(_ text: String, words: [Word], removing indices: [Int]) -> String {
        let remove = Set(indices.filter { words.indices.contains($0) })
        guard !remove.isEmpty else { return text }
        var textWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let aligned = textWords.count == words.count
            && remove.allSatisfy { normalize(textWords[$0]) == normalize(words[$0].text) }
        if aligned { return removing(remove, from: &textWords) }
        // Rescoring can merge or split words. Then only a trailing run can be placed, by its suffix.
        let count = remove.count
        guard remove == Set((words.count - count)..<words.count), textWords.count >= count,
              Array(textWords.suffix(count)) == words.suffix(count).map(\.text) else { return text }
        return removing(Set((textWords.count - count)..<textWords.count), from: &textWords)
    }

    private static func removing(_ remove: Set<Int>, from textWords: inout [String]) -> String {
        var kept: [String] = []
        var index = 0
        while index < textWords.count {
            guard remove.contains(index) else {
                kept.append(textWords[index])
                index += 1
                continue
            }
            var end = index
            while end + 1 < textWords.count, remove.contains(end + 1) { end += 1 }
            if let mark = textWords[end].last, ".?!".contains(mark),
               let previous = kept.last, let current = previous.last, !".?!,;:".contains(current) {
                kept[kept.count - 1] = previous + String(mark)
            }
            let startsSentence = kept.last.map { $0.last.map { ".?!".contains($0) } ?? false } ?? true
            let wasCapitalized = textWords[index].first?.isUppercase ?? false
            if startsSentence, wasCapitalized, end + 1 < textWords.count {
                textWords[end + 1] = capitalizingFirstLetter(textWords[end + 1])
            }
            index = end + 1
        }
        return kept.joined(separator: " ")
    }

    /// Indices of segment words that line up with a heard word, by longest common subsequence, so
    /// words either engine added elsewhere don't shift the match.
    static func heardIndices(segment: [String], heard: [String]) -> Set<Int> {
        let a = segment.map(normalize)
        let b = heard.suffix(400).map(normalize)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // suffix[i][j] is the match length of a[i...] against b[j...].
        var suffix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                suffix[i][j] = similar(a[i], b[j])
                    ? suffix[i + 1][j + 1] + 1
                    : max(suffix[i + 1][j], suffix[i][j + 1])
            }
        }
        var matched = Set<Int>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if similar(a[i], b[j]), suffix[i][j] == suffix[i + 1][j + 1] + 1 {
                matched.insert(i)
                i += 1
                j += 1
            } else if suffix[i + 1][j] >= suffix[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matched
    }

    /// Same word, or a different ending of it ("electron" and "electronics"). The two engines often
    /// disagree on endings, and those words are still heard.
    static func similar(_ x: String, _ y: String) -> Bool {
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard min(x.count, y.count) >= 4 else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// Lowercase letters and digits only.
    static func normalize<S: StringProtocol>(_ word: S) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    private static func capitalizingFirstLetter(_ word: String) -> String {
        guard let first = word.first, first.isLowercase else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
