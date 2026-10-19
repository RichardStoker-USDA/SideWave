// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import Observation
import os

/// Staged-transcript tracing, DEBUG-only like `dictationTraceLog`. Filter via
/// Console.app: `subsystem == "com.sidewave.dev" AND category == "staged-transcript"`.
private let stagedLog: Logger = {
    #if DEBUG
    return Logger(subsystem: "com.sidewave.dev", category: "staged-transcript")
    #else
    return Logger(OSLog.disabled)
    #endif
}()

/// Transcript model for the multi-stage live preview. Text passes through up to three stages, and
/// each replaces the one before it on screen:
///
/// 1. **EOU live**: Parakeet streaming partials, about 160 ms behind speech, unpunctuated. The
///    leading edge of the preview.
/// 2. **TDT confirmed**: Parakeet TDT output for a finished segment, about 600 ms behind, with
///    vocabulary boosting and punctuation. Replaces the matching streaming words.
/// 3. **Refined**: the Apple Intelligence or Gemma refine of a segment.
///
/// `confirmedSpans` holds TDT and refined spans in order; `liveEouTail` is the streaming text not
/// yet confirmed. Spans keep a stable `UUID` so views keep their identity through stage changes.
@Observable
@MainActor
final class StagedTranscript {
    private let now: () -> TimeInterval
    private var postPauseBoundary: Int?

    init(now: @escaping () -> TimeInterval = { CFAbsoluteTimeGetCurrent() }) {
        self.now = now
    }
    enum Stage {
        case eou
        case tdt
        case refined
    }

    struct Span: Identifiable, Equatable, Sendable {
        let id: UUID
        var stage: Stage
        var text: String {
            didSet {
                precomputedWords = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            }
        }
        /// How many streaming words this span covers, counted when TDT committed it. Used to remove
        /// that prefix from the live tail. Refining changes the text but not this count.
        let eouCoverageWords: Int
        /// The text at commit time, before refinement. Never changes; History shows it under "Show
        /// original".
        let originalText: String
        /// When the span was confirmed (TDT commit or direct commit). Each word animates from gray
        /// to white starting at `tdtCommittedAt + i * stagger`. A boundary merge keeps the original
        /// time so words don't animate again.
        var tdtCommittedAt: TimeInterval?
        /// When the span became `.refined`. Set by `refineSpan`, `applyBoundaryMerge`, and
        /// `markRefinedNoChange`.
        var refinedAt: TimeInterval?
        /// Per-word start times survive boundary moves and unchanged model output.
        var refinementRevealStarts: [TimeInterval?] = []
        /// The streaming words for this span's audio at finalize time, unpunctuated. The two-stage
        /// preview shows them in gray until the refined text arrives. Empty for direct-mode spans,
        /// whose text is already the streaming version.
        var originalEouText: String

        /// Cached array of words to optimize rendering loop performance.
        private(set) var precomputedWords: [String] = []
        /// Cached array of original (unrefined) words to optimize rendering loop performance in specialty mode.
        private(set) var precomputedOriginalWords: [String] = []

        init(
            id: UUID,
            stage: Stage,
            text: String,
            eouCoverageWords: Int,
            originalText: String,
            tdtCommittedAt: TimeInterval? = nil,
            refinedAt: TimeInterval? = nil,
            refinementRevealStarts: [TimeInterval?]? = nil,
            originalEouText: String
        ) {
            self.id = id
            self.stage = stage
            self.text = text
            self.eouCoverageWords = eouCoverageWords
            self.originalText = originalText
            self.tdtCommittedAt = tdtCommittedAt
            self.refinedAt = refinedAt
            self.originalEouText = originalEouText
            self.precomputedWords = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            self.precomputedOriginalWords = originalText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            self.refinementRevealStarts = refinementRevealStarts ?? precomputedWords.indices.map { index in
                refinedAt.map { $0 + Double(index) * StagedTranscript.revealStagger(wordCount: precomputedWords.count) }
            }
        }
    }

    /// TDT-confirmed and refined spans, in audio order.
    private(set) var confirmedSpans: [Span] = []

    /// Spans whose translate refine failed after retries and still hold source-language text. They
    /// aren't pasted as the translation: `refinedBodyAndUnrefinedTail` starts the unrefined tail at
    /// the earliest held span, so the stop pass translates it and everything after. Empty when not
    /// translating or when nothing failed. Cleared on `reset()`.
    private(set) var heldSourceLanguageSpanIDs: Set<UUID> = []

    /// Words at the leading edge of EOU's live transcript that haven't been
    /// covered by a TDT span yet. Updated on every EOU partial callback.
    private(set) var liveEouTail: String = ""

    /// TDT's latest transcription of the segment in progress, before it commits; cleared at
    /// finalize. The animated preview uses it so words the pointer reaches show TDT's corrected
    /// text. Words beyond it stay in `liveEouTail` and render gray.
    private(set) var streamingTdtText: String = ""

    /// All streaming text so far, kept to recompute `liveEouTail` after a TDT span lands.
    private var eouAccumulated: String = ""

    /// Cached split words of eouAccumulated to avoid redundant O(N) string splitting on the display/paste path.
    private var eouAccumulatedWords: [Substring] = []

    /// Sum of `eouCoverageWords` across all confirmed spans. Used by
    /// `originalText()` and `finalText()` for paste assembly.
    private var confirmedWordCount: Int = 0

    /// The streaming word count at the last TDT commit; the live tail is the words after it. This
    /// is separate from `confirmedWordCount`, which counts TDT words and can run ahead of the
    /// streaming text. If the streaming accumulator shrinks, `recomputeLiveTail` resets this to 0.
    private var eouTailStartIndex: Int = 0

    /// Coverage committed in earlier accumulator epochs. The streaming engine can restart its
    /// accumulator mid-session (after feeder errors, device recovery, or a long session), and spans
    /// from before a restart can't be found in the new text. Excluding their coverage keeps the
    /// shrink check from firing on every partial afterward, which turned the whole new accumulator
    /// into a gray tail that repeated refined text.
    private var coverageEpochBase: Int = 0

    /// Index of the first span committed in the current epoch. A restarted accumulator only holds
    /// this epoch's speech, so the rebuild check compares against this span, not the session's
    /// first.
    private var epochFirstSpanIndex: Int = 0

    /// The previous streaming text, for callers that want to know whether a partial added anything.
    /// The tail itself stays visible after the user stops speaking, until TDT covers the last
    /// words.
    private var lastIngestedEouAccumulated: String = ""

    /// Time of the last changed partial. Capture a pause before replacing this
    /// stamp, then retain protection until TDT covers that tail boundary.
    private var lastEouAdvanceAt: TimeInterval = 0

    /// Replaces `streamingTdtText` with the latest poll result for the segment in progress, about 2
    /// to 3 times a second. TranscriptionService already keeps it word-stable.
    func ingestTdtStreaming(_ text: String) {
        streamingTdtText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Updates the live tail from a streaming partial. The tail shows the words past the confirmed
    /// count, and stays visible when the user pauses until TDT covers them. Returns early when the
    /// engine repeats the same text, as it does every 160 ms during silence.
    func ingestEouPartial(_ accumulated: String) {
        // `showLiveGhostText` only affects display. Paste and history read `eouAccumulated` through
        // uncoveredEouTailForPaste(), so it must never clear the accumulator; recomputeLiveTail hides the
        // rendered tail instead.
        if accumulated == eouAccumulated { return }
        let timestamp = now()
        if lastEouAdvanceAt > 0, timestamp - lastEouAdvanceAt > 1 {
            postPauseBoundary = max(eouTailStartIndex, confirmedWordCount)
        }
        lastEouAdvanceAt = timestamp

        let words = accumulated.split(whereSeparator: \.isWhitespace)
        let prevWords = eouAccumulatedWords

        let totalCoverage = confirmedSpans.reduce(0) { $0 + $1.eouCoverageWords }
        // Only the CURRENT epoch's coverage can exist in the current
        // accumulator. Comparing against session-lifetime coverage is what
        // armed the permanent re-zeroing latch (see coverageEpochBase doc).
        let epochCoverage = max(0, totalCoverage - coverageEpochBase)

        // Detect if the EOU accumulator shrank significantly (engine reset,
        // or the per-partial filter chain collapsing a multi-word region).
        if words.count < prevWords.count - 3 || words.count < epochCoverage || accumulated.isEmpty {
            if headMatchesSpans(startingAt: 0, words: words) {
                // The accumulator still carries the whole session (filters shortened it, or the
                // engine sent everything again). All coverage applies and the epoch split ends.
                coverageEpochBase = 0
                epochFirstSpanIndex = 0
                confirmedWordCount = totalCoverage
                eouTailStartIndex = min(totalCoverage, words.count)
            } else if epochFirstSpanIndex > 0, headMatchesSpans(startingAt: epochFirstSpanIndex, words: words) {
                // Cumulative within the current (post-restart) epoch: the
                // accumulator's head matches the first words this epoch
                // committed, so only the epoch's own coverage applies.
                confirmedWordCount = epochCoverage
                eouTailStartIndex = min(epochCoverage, words.count)
            } else {
                // The engine restarted and the new text shares nothing with committed text: start a
                // new epoch. Existing coverage moves before the epoch, so the shrink check doesn't
                // fire on every later partial.
                coverageEpochBase = totalCoverage
                epochFirstSpanIndex = confirmedSpans.count
                eouTailStartIndex = 0
                confirmedWordCount = 0
                if !confirmedSpans.isEmpty {
                    stagedLog.notice("eou epoch rollover: preEpochCoverage=\(totalCoverage, privacy: .public) spans=\(self.confirmedSpans.count, privacy: .public) newWords=\(words.count, privacy: .public)")
                }
            }
        } else if coverageEpochBase > 0, words.count >= 3,
                  headMatchesSpans(startingAt: 0, words: words) {
            // Undo a false epoch: a brief empty or glitched partial can start an epoch without a
            // real restart. If the accumulator still starts with the session's first span, restore
            // full coverage so covered words don't reappear in the gray tail. This has to work
            // after commits too, since a finalize can land between the glitch and the next partial;
            // spans committed in the young epoch are already in totalCoverage.
            coverageEpochBase = 0
            epochFirstSpanIndex = 0
            confirmedWordCount = totalCoverage
            eouTailStartIndex = min(totalCoverage, words.count)
            stagedLog.notice("eou epoch rollback: accumulator re-carried session history (words=\(words.count, privacy: .public))")
        }
        
        eouAccumulated = accumulated
        eouAccumulatedWords = words
        lastIngestedEouAccumulated = accumulated
        // Reuse the split computed above instead of splitting the accumulator again.
        recomputeLiveTail(precomputedWords: words)
    }

    /// Whether the accumulator's first words match the first words of the spans from `startIndex`.
    /// Compares with each span's `originalEouText` when available, since TDT text tokenizes numbers
    /// differently ("25" against "twenty five").
    private func headMatchesSpans(startingAt startIndex: Int, words: [Substring]) -> Bool {
        guard startIndex < confirmedSpans.count else { return false }
        var referenceWords: [String] = []
        for span in confirmedSpans[startIndex...] {
            if !span.originalEouText.isEmpty {
                referenceWords.append(contentsOf: span.originalEouText.split(separator: " ", omittingEmptySubsequences: true).map(String.init))
            } else if !span.originalText.isEmpty {
                referenceWords.append(contentsOf: span.precomputedOriginalWords)
            } else {
                referenceWords.append(contentsOf: span.precomputedWords)
            }
            if referenceWords.count >= 3 { break }
        }
        let prefixLen = min(3, referenceWords.count)
        guard prefixLen > 0, words.count >= prefixLen else { return false }
        let accPrefix = words.prefix(prefixLen).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let refPrefix = referenceWords.prefix(prefixLen).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        return accPrefix == refPrefix
    }

    /// Promotes a chunk of TDT-confirmed text to a new span. Called when a
    /// segment finalizes (or, in v2, when a sentence-ender appears mid-poll).
    /// Returns the new span's ID so callers can track it for refinement.
    @discardableResult
    func ingestTdtCommitted(_ text: String) -> UUID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return UUID() }
        
        // Coverage follows the accumulator, independent of preview visibility
        // and any echo stripping applied by the renderer.
        let startIndex = min(max(0, eouTailStartIndex), eouAccumulatedWords.count)
        let liveEouWords = Array(eouAccumulatedWords.dropFirst(startIndex))
        let coverage = Self.findEouCoverage(tdtText: trimmed, eouWords: liveEouWords)
        // The alignment only looks at the first n + 20 tail words. A tail much longer than the
        // segment means coverage is drifting, so trace it.
        let tdtWordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        if liveEouWords.count > tdtWordCount + 20 {
            stagedLog.warning("tdt commit against oversized tail: tdtWords=\(tdtWordCount, privacy: .public) tailWords=\(liveEouWords.count, privacy: .public) coverage=\(coverage, privacy: .public)")
        }

        // Save this segment's streaming words before `eouTailStartIndex` moves, limited to the first
        // `coverage` words. Words beyond that belong to the next speech, and including them would strip
        // new words later.
        let segmentEouWords = Array(liveEouWords.prefix(coverage))
        let eouSnapshot = segmentEouWords.joined(separator: " ")
        let span = Span(
            id: UUID(),
            stage: .tdt,
            text: trimmed,
            eouCoverageWords: segmentEouWords.count,
            originalText: trimmed,
            tdtCommittedAt: CFAbsoluteTimeGetCurrent(),
            refinedAt: nil,
            originalEouText: eouSnapshot
        )
        confirmedSpans.append(span)
        confirmedWordCount += segmentEouWords.count
        // The segment is now a confirmed span, so clear the streaming TDT text until the next poll.
        streamingTdtText = ""
        // Start the next tail at TDT's coverage, not at the streaming word count, so words that
        // streamed past TDT's boundary before the finalize stay visible; streaming usually runs
        // ahead of TDT. The overlap strip in recomputeLiveTail() hides any duplicated words. Clamp
        // to the streaming word count, since TDT can count more words for the same audio
        // ("in-house" as two) and an index past the end would dump the whole accumulator into the
        // tail.
        let currentEouWordCount = eouAccumulatedWords.count
        eouTailStartIndex = min(confirmedWordCount, currentEouWordCount)
        recomputeLiveTail()
        return span.id
    }

    /// Direct mode: commits the streaming text since the last boundary as an `.eou` span. It
    /// renders like a `.tdt` span; refine still marks it `.refined`.
    @discardableResult
    func ingestEouCommitted(_ text: String) -> UUID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return UUID() }
        let coverage = trimmed.split(whereSeparator: \.isWhitespace).count
        let span = Span(
            id: UUID(),
            stage: .eou,
            text: trimmed,
            eouCoverageWords: coverage,
            originalText: trimmed,
            tdtCommittedAt: CFAbsoluteTimeGetCurrent(),
            refinedAt: nil,
            // Direct-EOU mode: span text already IS the EOU version,
            // no separate snapshot needed. Empty signals "use span.text
            // as gray representation" to the renderer.
            originalEouText: ""
        )
        confirmedSpans.append(span)
        confirmedWordCount += coverage
        eouTailStartIndex = eouAccumulatedWords.count
        recomputeLiveTail()
        return span.id
    }

    /// Replaces a span's text with its refined version and marks it `.refined`. Does nothing if the
    /// span is gone. Coverage doesn't change.
    func refineSpan(spanID: UUID, refinedText: String) {
        guard let idx = confirmedSpans.firstIndex(where: { $0.id == spanID }) else { return }
        let trimmed = refinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let output = Self.capitalizeInternalSentenceStarts(trimmed)
        let timestamp = now()
        let starts = Self.revealStarts(previous: [confirmedSpans[idx]],
            words: output.split(separator: " ").map(String.init), at: timestamp)
        confirmedSpans[idx].stage = .refined
        confirmedSpans[idx].text = output
        confirmedSpans[idx].refinedAt = timestamp
        confirmedSpans[idx].refinementRevealStarts = starts
        recomputeLiveTail()
    }

    /// A successful model pass may leave already-correct text unchanged.
    func markRefinedNoChange(spanID: UUID) {
        guard let idx = confirmedSpans.firstIndex(where: { $0.id == spanID }) else { return }
        let timestamp = now()
        let starts = Self.revealStarts(previous: [confirmedSpans[idx]],
            words: confirmedSpans[idx].precomputedWords, at: timestamp)
        confirmedSpans[idx].stage = .refined
        confirmedSpans[idx].refinedAt = timestamp
        confirmedSpans[idx].refinementRevealStarts = starts
        recomputeLiveTail()
    }

    /// Marks a span whose translate refine failed after retries. It becomes `.refined` so the
    /// preview doesn't look unfinished, but `refinedBodyAndUnrefinedTail` sends it and everything
    /// after to the stop pass for another try. Does nothing if the span is gone.
    func markHeldSourceLanguage(spanID: UUID) {
        guard let idx = confirmedSpans.firstIndex(where: { $0.id == spanID }) else { return }
        confirmedSpans[idx].stage = .refined
        confirmedSpans[idx].refinedAt = nil
        confirmedSpans[idx].refinementRevealStarts = Array(repeating: nil, count: confirmedSpans[idx].precomputedWords.count)
        heldSourceLanguageSpanIDs.insert(spanID)
        recomputeLiveTail()
    }

    /// Clears a span's held flag once a later pass successfully translated it.
    func clearHeldSourceLanguage(spanID: UUID) {
        heldSourceLanguageSpanIDs.remove(spanID)
    }

    /// Applies a boundary-merge refine. The worker refined the last words of `prevSpanID` together
    /// with `currSpanID`, and the result belongs to the current span:
    ///
    /// 1. The previous span loses its last words, which are now in the refined text.
    /// 2. The current span's text becomes the refined output and its stage `.refined`.
    ///
    /// The previous span keeps its stage.
    func applyBoundaryMerge(
        prevSpanID: UUID,
        prevTextWithoutBoundary: String,
        currSpanID: UUID,
        currRefinedText: String
    ) {
        let trimmedRefined = currRefinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRefined.isEmpty else { return }
        let trimmedPrev = prevTextWithoutBoundary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currIdx = confirmedSpans.firstIndex(where: { $0.id == currSpanID }) else { return }
        let prevIdx = confirmedSpans.firstIndex(where: { $0.id == prevSpanID })
        let previous = prevIdx.map { [confirmedSpans[$0], confirmedSpans[currIdx]] } ?? [confirmedSpans[currIdx]]
        let output = Self.capitalizeInternalSentenceStarts(Self.adjustForContinuation(
            refined: trimmedRefined, prevText: trimmedPrev))
        let prefixWords = trimmedPrev.split(separator: " ").map(String.init)
        let outputWords = output.split(separator: " ").map(String.init)
        let timestamp = now()
        let starts = Self.revealStarts(previous: previous, words: prefixWords + outputWords,
            editableStart: prefixWords.count, at: timestamp)
        if let prevIdx {
            confirmedSpans[prevIdx].text = trimmedPrev
            confirmedSpans[prevIdx].refinementRevealStarts = Array(starts.prefix(prefixWords.count))
            if trimmedPrev.isEmpty {
                confirmedSpans[prevIdx].stage = .refined
                heldSourceLanguageSpanIDs.remove(prevSpanID)
            }
        }
        confirmedSpans[currIdx].stage = .refined
        confirmedSpans[currIdx].text = output
        confirmedSpans[currIdx].refinedAt = timestamp
        confirmedSpans[currIdx].refinementRevealStarts = Array(starts.dropFirst(prefixWords.count))
        recomputeLiveTail()
    }

    nonisolated static func revealStagger(wordCount: Int) -> TimeInterval {
        guard wordCount > 1 else { return 0 }
        return min(0.06, max(0, Animate.refinedSweepTotalMs - Animate.refinedSweepWordDuration) / Double(wordCount - 1))
    }

    /// Diff once when output arrives. Rendering only reads the resulting times.
    private static func revealStarts(previous: [Span], words: [String],
                                     editableStart: Int = 0, at timestamp: TimeInterval) -> [TimeInterval?] {
        let oldWords = previous.flatMap(\.precomputedWords)
        let oldStarts = previous.flatMap { span in
            span.precomputedWords.indices.map { index -> (Bool, TimeInterval?) in
                (span.stage == .refined, span.refinementRevealStarts.indices.contains(index)
                    ? span.refinementRevealStarts[index] : nil)
            }
        }
        let difference = words.difference(from: oldWords)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        var starts = [TimeInterval?](repeating: nil, count: words.count)
        var preserved = Set<Int>()
        var oldIndex = 0
        for index in words.indices where !inserted.contains(index) {
            while removed.contains(oldIndex) { oldIndex += 1 }
            if oldStarts.indices.contains(oldIndex), oldStarts[oldIndex].0 {
                starts[index] = oldStarts[oldIndex].1
                preserved.insert(index)
            }
            oldIndex += 1
        }
        let changed = words.indices.filter { $0 >= editableStart && !preserved.contains($0) }
        let stagger = revealStagger(wordCount: changed.count)
        for (offset, index) in changed.enumerated() {
            starts[index] = timestamp + Double(offset) * stagger
        }
        return starts
    }

    /// Capitalizes the pronoun "i" and its contractions (i'm, i'll, i've, i'd). Both Gemma and
    /// Apple Intelligence are told to, and both sometimes don't. Word-bounded, so "iPhone",
    /// "Wi-Fi", and "i.e." are left alone. Idempotent.
    static func fixStandalonePronounI(_ text: String) -> String {
        guard text.contains("i") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return pronounIRegex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "I")
    }

    private static let pronounIRegex = try! NSRegularExpression(pattern: "\\bi\\b(?!\\.\\w)")

    /// Capitalizes a lowercase word after `.`, `!`, or `?` inside refined text. The prompt asks for
    /// this, but Gemma E2B sometimes misses it at a boundary-merge join ("things break. the
    /// cleanest fix"). Only all-lowercase words change, so "iPhone" and "x86_64" are kept.
    static func capitalizeInternalSentenceStarts(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let text = fixStandalonePronounI(text)
        let chars = Array(text)
        var result: [Character] = []
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            result.append(c)
            // Look for terminator. Allow optional close-quote/paren after.
            if c == "." || c == "!" || c == "?" {
                var j = i + 1
                // Skip closing punctuation that can follow a terminator.
                while j < chars.count, chars[j] == "\"" || chars[j] == "'" || chars[j] == ")" || chars[j] == "]" {
                    result.append(chars[j])
                    j += 1
                }
                // Need at least one whitespace after terminator.
                guard j < chars.count, chars[j].isWhitespace else { i += 1; continue }
                // Walk past whitespace.
                while j < chars.count, chars[j].isWhitespace {
                    result.append(chars[j])
                    j += 1
                }
                // Check the first word after the terminator.
                guard j < chars.count else { i = j; continue }
                let firstChar = chars[j]
                // Find the end of the first word.
                var wordEnd = j
                while wordEnd < chars.count, !chars[wordEnd].isWhitespace { wordEnd += 1 }
                let word = String(chars[j ..< wordEnd]).trimmingCharacters(in: CharacterSet.punctuationCharacters)
                let isCommonLowercaseWord = !word.isEmpty
                    && word.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'") }
                    && word.allSatisfy { !$0.isUppercase }
                if isCommonLowercaseWord, firstChar.isLowercase {
                    result.append(Character(String(firstChar).uppercased()))
                    j += 1
                }
                // Append the rest of the word verbatim.
                while j < wordEnd {
                    result.append(chars[j])
                    j += 1
                }
                i = wordEnd
                continue
            }
            i += 1
        }
        return String(result)
    }

    /// Lowercases the first letter of `refined` when `prevText` doesn't end a sentence and the
    /// refined text starts with a capital. Only for common sentence-start words ("The", "We",
    /// "And"), not proper nouns; the rest of the text is unchanged.
    private static func adjustForContinuation(
        refined: String,
        prevText: String
    ) -> String {
        let prevTrimmed = prevText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prevTrimmed.isEmpty else { return refined }
        // The previous text ended a sentence, so this begins a new one. Gemma E2B sometimes writes
        // "i" at a sentence start ("...things break. i think"), so capitalize the pronoun. Checks
        // only "i" and "i'", so "iPhone" and "iOS" are safe.
        if let last = prevTrimmed.last, last == "." || last == "!" || last == "?" {
            // Capitalize the first letter of a new sentence. Gemma E2B sometimes starts one with
            // "regardless" or "we" in lowercase. Only all-lowercase words, so "iPhone" and "x86_64"
            // are kept.
            let firstWord = refined.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let firstWordTrimmed = firstWord.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            let isCommonLowercaseWord = !firstWordTrimmed.isEmpty
                && firstWordTrimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'") }
                && firstWordTrimmed.allSatisfy { !$0.isUppercase }
            if isCommonLowercaseWord, let firstChar = refined.first, firstChar.isLowercase {
                var chars = Array(refined)
                chars[0] = Character(String(firstChar).uppercased())
                return String(chars)
            }
            return refined
        }
        // Mid-sentence: lowercase a capitalized common word at the start, except "I" and its
        // contractions.
        guard let firstChar = refined.first else { return refined }
        guard firstChar.isUppercase else { return refined }
        // "I", "I'm", "I'll", and "I've" are always capitalized.
        let firstWord = refined.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let firstWordTrimmed = firstWord.trimmingCharacters(in: CharacterSet.punctuationCharacters)
        if firstWordTrimmed == "I" || firstWordTrimmed.hasPrefix("I'") {
            return refined
        }
        var chars = Array(refined)
        chars[0] = Character(String(firstChar).lowercased())
        return String(chars)
    }

    /// Resets all session state. Called between recordings so the model is
    /// blank when the next session starts.
    func reset() {
        confirmedSpans = []
        heldSourceLanguageSpanIDs = []
        liveEouTail = ""
        eouAccumulated = ""
        eouAccumulatedWords = []
        lastIngestedEouAccumulated = ""
        confirmedWordCount = 0
        eouTailStartIndex = 0
        coverageEpochBase = 0
        epochFirstSpanIndex = 0
        streamingTdtText = ""
        lastEouAdvanceAt = 0
        postPauseBoundary = nil
    }

    /// Resets alignment and streaming state after audio recovery or a device switch. Starts a new
    /// epoch: the engine starts from empty, so existing coverage can't be found in its next output.
    /// Without it, the first partial would trip the shrink check and leave a permanent gray tail.
    func resetEouAlignment() {
        eouAccumulated = ""
        eouAccumulatedWords = []
        lastIngestedEouAccumulated = ""
        eouTailStartIndex = 0
        confirmedWordCount = 0
        coverageEpochBase = confirmedSpans.reduce(0) { $0 + $1.eouCoverageWords }
        epochFirstSpanIndex = confirmedSpans.count
        liveEouTail = ""
    }

    /// All streaming text: each span's `originalEouText` plus the words beyond TDT coverage, for
    /// History's earlier stages. Spans without a snapshot use `originalText`.
    func eouRawText() -> String {
        let parts: [String] = confirmedSpans.map { span in
            let raw = span.originalEouText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return raw }
            // Fallback: span never captured an EOU snapshot. The
            // closest available text is the TDT-stage originalText.
            return span.originalText
        }
        let confirmedJoined = parts.filter { !$0.isEmpty }.joined(separator: " ")
        let beyondTdt = uncoveredEouTailForPaste()
        if beyondTdt.isEmpty {
            return confirmedJoined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if confirmedJoined.isEmpty {
            return beyondTdt
        }
        return (confirmedJoined + " " + beyondTdt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All text before refinement: each span's `originalText` plus streaming words beyond TDT
    /// coverage, for History's "Show original".
    func originalText(includeRawEouTail: Bool = true) -> String {
        let originalConfirmed = confirmedSpans.map(\.originalText).joined(separator: " ")
        let beyondTdtText = includeRawEouTail ? uncoveredEouTailForPaste() : ""
        if beyondTdtText.isEmpty {
            return originalConfirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if originalConfirmed.isEmpty {
            return beyondTdtText
        }
        return (originalConfirmed + " " + beyondTdtText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text to paste at stop: each span in its latest stage, then streaming words beyond TDT
    /// coverage. Uses `eouTailStartIndex`, a streaming-side index, rather than
    /// `confirmedWordCount`, because TDT and streaming can count the same audio differently and the
    /// TDT count dropped words.
    func finalText(includeRawEouTail: Bool = true) -> String {
        let confirmedText = confirmedSpans.map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let beyondTdtText = includeRawEouTail ? uncoveredEouTailForPaste() : ""
        let joined: String
        if beyondTdtText.isEmpty {
            joined = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if confirmedText.isEmpty {
            joined = beyondTdtText
        } else {
            joined = (confirmedText + " " + beyondTdtText).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.fixSentenceBoundaryCapitalization(joined)
    }

    /// Only a contiguous run of successful passes belongs in the refined body.
    /// A failed earlier span and all later text remain eligible for the final pass.
    func refinedBodyAndUnrefinedTail(includeRawEouTail: Bool = true) -> (body: String, tail: String) {
        let beyondTdt = includeRawEouTail ? uncoveredEouTailForPaste() : ""
        let firstPending = confirmedSpans.firstIndex {
            $0.stage != .refined || heldSourceLanguageSpanIDs.contains($0.id)
        } ?? confirmedSpans.endIndex
        let bodyEndIdx = firstPending - 1
        let body = bodyEndIdx >= 0
            ? confirmedSpans[...bodyEndIdx].map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        var tailParts = confirmedSpans[(bodyEndIdx + 1)...].map(\.text).filter { !$0.isEmpty }
        if !beyondTdt.isEmpty { tailParts.append(beyondTdt) }
        let tail = tailParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (Self.fixSentenceBoundaryCapitalization(body), tail)
    }

    /// Capitalizes a lowercase letter after `.`, `!`, or `?` and a space. TDT decides
    /// capitalization per segment, so a segment can start lowercase after a sentence that ended;
    /// when the boundary refine returns its input unchanged, the stored text keeps that
    /// ("...feature flag. and migrate"). Changes letters only.
    static func fixSentenceBoundaryCapitalization(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var chars = Array(text)
        let terminators: Set<Character> = [".", "!", "?"]
        var i = 0
        while i < chars.count - 2 {
            let c = chars[i]
            if terminators.contains(c) {
                // Skip optional closing quote / paren immediately after.
                var j = i + 1
                while j < chars.count, chars[j] == "\"" || chars[j] == "'" || chars[j] == ")" || chars[j] == "]" {
                    j += 1
                }
                // Require at least one whitespace after the terminator
                // (and optional closing punctuation); otherwise things
                // like "U.S.A." get falsely uppercased on the next letter.
                if j < chars.count, chars[j].isWhitespace {
                    // Advance past whitespace.
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    if j < chars.count, chars[j].isLowercase {
                        chars[j] = Character(String(chars[j]).uppercased())
                    }
                }
            }
            i += 1
        }
        return String(chars)
    }

    /// Streaming words past the last TDT commit, as a string; empty when fully covered. Shared by
    /// `originalText()` and `finalText()`. Applies the same overlap strip as the live tail, so the
    /// paste matches what the overlay showed instead of repeating words the streaming engine caught up
    /// on.
    private func uncoveredEouTailForPaste() -> String {
        let words = eouAccumulatedWords
        guard !words.isEmpty else { return "" }
        let startIdx = min(max(0, eouTailStartIndex), words.count)
        guard startIdx < words.count else { return "" }
        // Use the same strip as the overlay (`boundaryStrippedTail`), including its post-pause
        // exemption, so the paste matches the screen. Start at `eouTailStartIndex`, not
        // confirmedWordCount, so words streamed past TDT's last boundary aren't dropped.
        let tailWords = boundaryStrippedTail(Array(words.dropFirst(startIdx)))
        return tailWords.joined(separator: " ")
    }

    /// Text the overlap strip compares against. Not the refined `span.text`: refined prose can end
    /// with common words ("the", "we", "and") that match the first words spoken after a pause, and
    /// those words would be removed. Uses `originalEouText`, then `originalText`, then `text`.
    private static func boundaryStripAnchor(for span: Span) -> String {
        let eou = span.originalEouText.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = span.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !eou.isEmpty && !original.isEmpty {
            let eouCount = eou.split(whereSeparator: \.isWhitespace).count
            let originalCount = original.split(whereSeparator: \.isWhitespace).count
            // Return the one that represents the complete segment (longer verbatim version)
            if originalCount > eouCount {
                return original
            }
            return eou
        }
        
        if !eou.isEmpty { return eou }
        if !original.isEmpty { return original }
        return span.text
    }

    /// `precomputedWords` is an existing split of `eouAccumulated`, passed by `ingestEouPartial` to
    /// avoid splitting it twice per partial. Other callers pass nil.
    func recomputeLiveTail(precomputedWords: [Substring]? = nil) {
        let enabled = UserDefaults.standard.bool(forKey: "showLiveGhostText")
        if !enabled {
            liveEouTail = ""
            return
        }
        let words = precomputedWords ?? eouAccumulatedWords
        if words.isEmpty {
            liveEouTail = ""
            return
        }
        // The accumulator shrank (an engine reset, rare). The saved index is past the end. Treat
        // the rebuilt text as covered, since it is almost all confirmed text, and let new partials
        // extend the tail; resetting to 0 would show already-refined text in gray.
        if eouTailStartIndex > words.count {
            eouTailStartIndex = words.count
        }
        if confirmedWordCount > words.count {
            confirmedWordCount = words.count
        }
        // The tail never starts before the confirmed spans' coverage. A drifted index (cadence
        // changed mid-session, an interval finalize racing a partial, a model switch) could
        // otherwise show refined text again in gray.
        let effectiveStart = max(eouTailStartIndex, confirmedWordCount)
        // The tail is the words since the last TDT commit. It grows while the user speaks, empties
        // at the next finalize, and stays visible during pauses until TDT confirms it.
        if effectiveStart >= words.count {
            liveEouTail = ""
            return
        }
        liveEouTail = boundaryStrippedTail(Array(words.dropFirst(effectiveStart)))
            .joined(separator: " ")
    }

    /// Removes words at the start of a tail that repeat confirmed text, so only new speech remains.
    /// Shared by the live tail and paste assembly so both agree. After a finalize, the streaming engine
    /// runs 200 to 500 ms behind TDT and repeats audio TDT already covered ("...test segment" + "test
    /// segment new").
    ///
    /// Two passes:
    /// - Pass 1 compares against the streaming snapshots of the last 3 spans, so repeats that cross
    ///   short spans are caught.
    /// - Pass 2 compares against the last refined span's text, for when the refined output went
    ///   beyond what streaming saw. It needs at least 5 matching words, so common words don't remove
    ///   new speech after a pause.
    ///
    /// Anchors come from `boundaryStripAnchor(for:)`. A tail that began after a pause needs a longer
    /// overlap before anything is removed, and that decision stays fixed for later partials and the
    /// paste.
    private func boundaryStrippedTail(_ tailWords: [Substring]) -> [Substring] {
        var tailWords = tailWords
        let recentSpans = confirmedSpans.filter { !$0.text.isEmpty }.suffix(3)
        guard !recentSpans.isEmpty else { return tailWords }

        let isPostPauseReset = postPauseBoundary == max(eouTailStartIndex, confirmedWordCount)

        let eouAnchor = recentSpans
            .map { Self.boundaryStripAnchor(for: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !eouAnchor.isEmpty {
            // If post-pause, require a longer match (minMatchLen: 4) to avoid coincidental word swallowing.
            // If continuous speech, default minMatchLen is 1.
            let minLen = isPostPauseReset ? 4 : 1
            tailWords = Self.stripBoundaryOverlap(
                tailWords: tailWords,
                confirmedTail: eouAnchor,
                maxKOverride: 8,
                minMatchLen: minLen
            )
        }

        if let lastRefined = recentSpans.last(where: { $0.stage == .refined }),
           !lastRefined.text.isEmpty
        {
            // For post-pause, require a longer match (minMatchLen: 6).
            // For continuous speech, minMatchLen is 5.
            let minLen = isPostPauseReset ? 6 : 5
            tailWords = Self.stripBoundaryOverlap(
                tailWords: tailWords,
                confirmedTail: lastRefined.text,
                maxKOverride: 8,
                minMatchLen: minLen
            )
        }
        return tailWords
    }

    /// Removes the longest prefix of `tailWords` matching the end of `confirmedTail`, ignoring case
    /// and punctuation, so streaming catch-up words don't repeat the last confirmed words.
    // `internal` (not `private`) so the brief-critical de-dup has direct unit
    // coverage via `@testable import`; not part of any public API.
    static func stripBoundaryOverlap(
        tailWords: [Substring],
        confirmedTail: String,
        maxKOverride: Int? = nil,
        minMatchLen: Int = 1
    ) -> [Substring] {
        let confirmedWords = confirmedTail.split(whereSeparator: \.isWhitespace)
        guard !confirmedWords.isEmpty, !tailWords.isEmpty else { return tailWords }

        let cap = maxKOverride ?? 40
        let m = min(tailWords.count, cap)
        guard m > 0 else { return tailWords }
        
        let tailPrefix = tailWords.prefix(m).map(normalizeForMatch)
        let n = min(confirmedWords.count, m + 10)
        let confirmedSuffix = confirmedWords.suffix(n).map(normalizeForMatch)
        
        var bestMatchLen = 0
        let exactMaxK = min(m, n)
        for k in 1...exactMaxK {
            if tailPrefix.prefix(k) == confirmedSuffix.suffix(k) {
                bestMatchLen = k
            }
        }
        
        if bestMatchLen == 0 {
            let N = confirmedSuffix.count
            let M = tailPrefix.count
            var dp = Array(repeating: Array(repeating: 0, count: M + 1), count: N + 1)
            
            for i in 0...N { dp[i][0] = 0 }
            for j in 0...M { dp[0][j] = j }
            
            for i in 1...N {
                for j in 1...M {
                    let cost = (confirmedSuffix[i-1] == tailPrefix[j-1]) ? 0 : 1
                    dp[i][j] = min(
                        dp[i-1][j] + 1,
                        dp[i][j-1] + 1,
                        dp[i-1][j-1] + cost
                    )
                }
            }
            
            for j in (1...M).reversed() {
                let errors = dp[N][j]
                let allowedErrors = min(5, j / 3)
                if errors <= allowedErrors && j >= minMatchLen {
                    // Backtrack to trim trailing insertions (new spoken words) from the aligned region
                    var backtrackI = N
                    var backtrackJ = j
                    while backtrackJ > 0 && backtrackI > 0 {
                        let cost = (confirmedSuffix[backtrackI-1] == tailPrefix[backtrackJ-1]) ? 0 : 1
                        if dp[backtrackI][backtrackJ] == dp[backtrackI][backtrackJ-1] + 1 {
                            // Trailing insertion in tailPrefix; trim it from the match length
                            backtrackJ -= 1
                        } else if dp[backtrackI][backtrackJ] == dp[backtrackI-1][backtrackJ-1] + cost {
                            // Match or substitution found; this is the actual boundary of the overlap!
                            break
                        } else {
                            // Deletion in confirmedSuffix
                            backtrackI -= 1
                        }
                    }
                    if backtrackJ >= minMatchLen {
                        bestMatchLen = backtrackJ
                        break
                    }
                }
            }
        }

        guard bestMatchLen >= minMatchLen else { return tailWords }
        return Array(tailWords.dropFirst(bestMatchLen))
    }

    /// Lowercase + strip leading/trailing punctuation. Used so "Test."
    /// matches "test" when comparing EOU (no punctuation, lowercase) to
    /// TDT (capitalized, punctuated) at the segment boundary.
    private static func normalizeForMatch<S: StringProtocol>(_ word: S) -> String {
        let lower = word.lowercased()
        return lower.trimmingCharacters(in: CharacterSet.punctuationCharacters)
    }

    /// How many streaming words correspond to the TDT text. The two often count differently
    /// ("in-house" against "in house", dropped or added words), so counting TDT's words would leave
    /// duplicates in the tail. Uses an edit-distance table.
    // `internal` (not `private`) for direct unit coverage via `@testable import`.
    static func findEouCoverage(tdtText: String, eouWords: [Substring]) -> Int {
        let tdtWords = tdtText.split(whereSeparator: \.isWhitespace).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let eou = eouWords.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        
        if tdtWords.isEmpty || eou.isEmpty { return 0 }
        
        let n = tdtWords.count
        // Look at most n + 20 words ahead, to bound the work and avoid matching a later sentence.
        let m = min(eou.count, n + 20)
        
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        
        // Deleting a TDT word costs 5: TDT is the reference for this segment, so its words should
        // be found in the streaming text.
        for i in 0...n { dp[i][0] = i * 5 }
        // EOU having extra words is normal (TDT drops stutters/fillers).
        for j in 0...m { dp[0][j] = j }
        
        for i in 1...n {
            for j in 1...m {
                let cost = (tdtWords[i-1] == eou[j-1]) ? 0 : 3
                dp[i][j] = min(
                    dp[i-1][j] + 5,      // deletion from TDT
                    dp[i][j-1] + 1,      // insertion into TDT (EOU has extra)
                    dp[i-1][j-1] + cost  // substitution
                )
            }
        }
        
        // Find j that minimizes dp[n][j]
        var bestJ = 0
        var bestDist = Int.max
        for j in 0...m {
            if dp[n][j] < bestDist {
                bestDist = dp[n][j]
                bestJ = j
            } else if dp[n][j] == bestDist {
                // On a tie, prefer more coverage so trailing filler isn't left in the tail.
                if j > bestJ {
                    bestJ = j
                }
            }
        }
        
        // Unmatched words belong to the next segment, even when only one
        // word is ahead. Filler removal is handled by the text pipeline.

        // If the alignment found nothing or the distance is very high, consume as many words as TDT
        // has.
        if (bestJ == 0 && n > 0) || bestDist >= n * 4 {
            return min(n, eou.count)
        }
        
        let expectedMin = min(n, eou.count)
        if expectedMin > 0 && bestJ < expectedMin {
            let dangling = expectedMin - bestJ
            if dangling >= 2 || Double(bestJ) < Double(expectedMin) * 0.85 {
                return expectedMin
            }
        }
        
        return bestJ
    }
}
