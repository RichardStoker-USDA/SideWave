// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import Foundation
import os

/// Removes words TDT added after the speaker stopped, at the end of a dictation's last segment.
/// TDT can turn the quiet before the stop key, and the key itself, into a short word ("Yeah.",
/// "a little bit.") that the streaming engine never produced. A trailing word is removed only when
/// both checks agree:
/// - the streaming engine, which heard the same audio, has no matching word, and
/// - Silero VAD heard no speech from where the word starts to the end of the audio it processed.
///
/// Real words the streaming engine missed are voiced, so VAD keeps them. Words both engines heard
/// are kept whatever VAD says.
enum TrailingGhostFilter {
    /// Release-visible numbers for field reports. Never logs text.
    static let log = Logger(subsystem: SWLog.subsystem, category: "recognition")

    /// Silero's usual speech threshold. A VAD chunk at or above it counts as voiced here. Lower than
    /// the 0.75 segmentation threshold, so soft speech keeps its words.
    static let voicedProbability: Float = 0.5

    /// One encoder frame, for token timing error.
    static let startAllowance: TimeInterval = 0.08

    /// Most words removed at once. Observed ghosts run one to five words. A longer run that both
    /// checks flag points to a VAD or streaming fault, so it is kept.
    static let maxWords = 5

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

    /// How many trailing words to remove.
    /// - Parameters:
    ///   - heard: the streaming engine's words for the same audio, after it finished.
    ///   - voicedEnd: seconds from the segment start to the end of the last voiced VAD chunk; nil
    ///     when VAD heard no speech in the segment or isn't running, which removes nothing.
    ///   - vadThrough: seconds of the segment VAD has processed. Words starting past it are unknown
    ///     and kept.
    static func ghostCount(
        words: [Word],
        heard: [String],
        voicedEnd: TimeInterval?,
        vadThrough: TimeInterval
    ) -> Int {
        guard let voicedEnd, !words.isEmpty else { return 0 }
        let lastHeard = lastHeardIndex(segment: words.map(\.text), heard: heard)
        var count = 0
        var index = words.count - 1
        while index > lastHeard {
            let word = words[index]
            guard word.start >= voicedEnd + startAllowance, word.start < vadThrough else { break }
            count += 1
            index -= 1
        }
        return count > maxWords ? 0 : count
    }

    /// Removes the last `count` words from `text`, which may be CTC-rescored. Returns `text` unchanged
    /// when its last words aren't the ghost tokens. When the removed words ended a sentence and the new
    /// last word doesn't, the sentence mark moves to it.
    static func strip(_ text: String, words: [Word], count: Int) -> String {
        guard count > 0, count <= words.count else { return text }
        var textWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let removed = words.suffix(count).map(\.text)
        guard textWords.count >= count, Array(textWords.suffix(count)) == removed else { return text }
        textWords.removeLast(count)
        guard var last = textWords.last else { return "" }
        if let mark = removed.last?.last, ".?!".contains(mark),
           let current = last.last, !".?!,;:".contains(current) {
            last.append(mark)
            textWords[textWords.count - 1] = last
        }
        return textWords.joined(separator: " ")
    }

    /// Index of the last segment word that lines up with a heard word, or -1. Uses a longest common
    /// subsequence, so words either engine added elsewhere don't shift the match.
    static func lastHeardIndex(segment: [String], heard: [String]) -> Int {
        let a = segment.map(normalize)
        let b = heard.map(normalize)
        guard !a.isEmpty, !b.isEmpty else { return -1 }
        // suffix[i][j] is the match length of a[i...] against b[j...].
        var suffix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                suffix[i][j] = similar(a[i], b[j])
                    ? suffix[i + 1][j + 1] + 1
                    : max(suffix[i + 1][j], suffix[i][j + 1])
            }
        }
        var i = 0, j = 0, last = -1
        while i < a.count, j < b.count {
            if similar(a[i], b[j]), suffix[i][j] == suffix[i + 1][j + 1] + 1 {
                last = i
                i += 1
                j += 1
            } else if suffix[i + 1][j] >= suffix[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return last
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
}
