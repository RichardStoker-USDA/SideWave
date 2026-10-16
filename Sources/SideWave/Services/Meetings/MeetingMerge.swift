// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
@preconcurrency import AVFAudio
import FluidAudio
import Foundation

// MARK: - Attribution (pure, isolation-free)

/// Word→speaker attribution and word grouping. Free functions over Sendable
/// value types so both the off-main engine and the service can call them.
enum MeetingMerge {
    /// A word reconstructed from consecutive Parakeet tokens with the time span
    /// those tokens cover. `mid` selects the owning speaker on ties.
    struct TimedWord {
        var text: String
        var start: Double
        var end: Double
        var mid: Double { (start + end) / 2 }
    }

    /// Groups token timings into words. FluidAudio turns the word-boundary marker into a leading
    /// space, so a token starting with a space begins a word. Grouping first keeps a word from
    /// being split between speakers.
    static func groupTokensIntoWords(_ timings: [TokenTiming]) -> [TimedWord] {
        let sorted = timings.sorted { $0.startTime < $1.startTime }
        var words: [TimedWord] = []
        for t in sorted {
            let trimmed = t.token.trimmingCharacters(in: .whitespaces)
            let startsWord = t.token.hasPrefix(" ") || words.isEmpty
            if startsWord {
                if trimmed.isEmpty {
                    if !words.isEmpty {
                        words[words.count - 1].end = max(words[words.count - 1].end, t.endTime)
                    }
                    continue
                }
                words.append(TimedWord(text: trimmed, start: t.startTime, end: t.endTime))
            } else {
                words[words.count - 1].text += trimmed
                words[words.count - 1].end = max(words[words.count - 1].end, t.endTime)
            }
        }
        return words.filter { !$0.text.isEmpty }
    }

    /// Merge adjacent same-speaker segments so a pause inside one person's turn
    /// doesn't fragment the transcript. A speaker change is the only boundary.
    static func mergeSameSpeaker(_ segs: [MeetingDiarSeg]) -> [MeetingDiarSeg] {
        var merged: [MeetingDiarSeg] = []
        for seg in segs.sorted(by: { $0.start < $1.start }) {
            guard seg.end > seg.start else { continue }
            if let last = merged.last, last.speakerId == seg.speakerId {
                merged[merged.count - 1] = MeetingDiarSeg(speakerId: last.speakerId, start: last.start, end: seg.end)
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    /// The segment a word belongs to, by the largest time overlap. Short interjections and
    /// overlapping speech go to the right speaker instead of the one who started earlier. Ties go
    /// to the nearest segment midpoint; a word in a gap goes to the nearest segment.
    static func bestSegmentIndex(for word: TimedWord, in merged: [MeetingDiarSeg]) -> Int {
        var bestIdx = 0
        var bestOverlap = -1.0
        var bestMidDist = Double.greatestFiniteMagnitude
        for (i, seg) in merged.enumerated() {
            let overlap = max(0, min(word.end, seg.end) - max(word.start, seg.start))
            let midDist = abs(word.mid - (seg.start + seg.end) / 2)
            if overlap > bestOverlap || (overlap == bestOverlap && midDist < bestMidDist) {
                bestOverlap = overlap
                bestMidDist = midDist
                bestIdx = i
            }
        }
        return bestIdx
    }

    /// Builds speaker-attributed segments from speaker segments and token timings. If speaker
    /// detection found nothing but there is text, it becomes a single-speaker transcript. Without
    /// timings (older cached data), text is split proportionally, which is known to be inexact.
    static func buildRawSegments(
        diarSegs: [MeetingDiarSeg],
        timings: [TokenTiming],
        fullText: String,
        totalDuration: Double
    ) -> [MeetingRawSegment] {
        let merged = mergeSameSpeaker(diarSegs)

        // Zero-diarizer fallback: keep the ASR output as one speaker.
        guard !merged.isEmpty else {
            let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [MeetingRawSegment(speakerId: "Speaker 0", start: 0, end: max(totalDuration, 0), rawText: text)]
        }

        // Preferred: real per-token timestamps → max-overlap attribution.
        let words = groupTokensIntoWords(timings)
        if !words.isEmpty {
            var buckets: [[TimedWord]] = Array(repeating: [], count: merged.count)
            for word in words {
                buckets[bestSegmentIndex(for: word, in: merged)].append(word)
            }
            var result: [MeetingRawSegment] = []
            for (i, seg) in merged.enumerated() {
                let text = buckets[i].map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // A segment that lost all its words keeps no text (fine). Its
                // words already went to whichever speaker actually overlapped
                // them, so nothing leaks to the wrong speaker.
                guard !text.isEmpty else { continue }
                result.append(MeetingRawSegment(speakerId: seg.speakerId, start: seg.start, end: seg.end, rawText: text))
            }
            return result
        }

        // Last resort: proportional distribution over the processed text. Known
        // inaccurate when speakers talk at different rates; reached only when the
        // ASR pass returned no token timings.
        return proportional(merged: merged, fullText: fullText, totalDuration: totalDuration)
    }

    private static func proportional(
        merged: [MeetingDiarSeg],
        fullText: String,
        totalDuration: Double
    ) -> [MeetingRawSegment] {
        let words = fullText.split(separator: " ").map(String.init)
        guard !words.isEmpty, totalDuration > 0 else { return [] }
        var result: [MeetingRawSegment] = []
        var wordIndex = 0
        for seg in merged {
            let segDuration = seg.end - seg.start
            guard segDuration > 0 else { continue }
            let count = max(1, Int(round(segDuration / totalDuration * Double(words.count))))
            let end = min(wordIndex + count, words.count)
            guard wordIndex < end else { continue }
            let text = words[wordIndex..<end].joined(separator: " ")
            wordIndex = end
            guard !text.isEmpty else { continue }
            result.append(MeetingRawSegment(speakerId: seg.speakerId, start: seg.start, end: seg.end, rawText: text))
        }
        if wordIndex < words.count, !result.isEmpty {
            let remaining = words[wordIndex...].joined(separator: " ")
            let last = result.removeLast()
            result.append(MeetingRawSegment(
                speakerId: last.speakerId, start: last.start, end: last.end,
                rawText: last.rawText + " " + remaining))
        }
        return result
    }
}
