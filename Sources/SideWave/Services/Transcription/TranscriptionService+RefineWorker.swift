// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
import AppKit
@preconcurrency import AVFAudio
import CoreAudio
import FluidAudio
import Foundation
import os

@MainActor
extension TranscriptionService {
    // MARK: - Real-Time Refine Worker

    /// Queues a TDT span for refinement and starts the worker if needed. The worker takes one span
    /// at a time, so DictationFormatterService's cancel-previous-generation rule doesn't cancel a
    /// close neighbor.
    func enqueueRefine(spanID: UUID) {
        refineQueue.append(spanID)
        // Set when work is queued rather than when the worker takes it, so the wave doesn't flicker
        // between palettes between back-to-back refines.
        isRefining = true
        if let cont = refineQueueContinuation {
            // Hand the head of the queue to the waiting worker and remove it from the queue, so the
            // same span is never refined twice.
            refineQueueContinuation = nil
            // Mark in-flight atomically with the dequeue so awaitPendingRefines
            // never sees this span as "drained" while the worker is starting on it.
            refineInFlight = true
            cont.resume(returning: refineQueue.removeFirst())
        }
        if refineWorkerTask == nil {
            startRefineWorker()
        }
    }

    private struct RefinePreparationResult {
        let isRecording: Bool
        let formatter: DictationFormatterService?
        let formatterReady: Bool
        /// The formatter will become ready on its own (loading, downloading, or generating), unlike
        /// a terminal state. Spans dictated during startup are queued again instead of being marked
        /// refined as raw text.
        let formatterTransient: Bool
        let mergePlan: BoundaryMergePlan?
        let specialtyTemplate: DictationFormatterService.Template?
        let accumulatedTextForSpecialty: String?
        /// A real target language, not as spoken. A segment refine that returns source-language
        /// text has failed and must be retried or held, never pasted as the translation.
        let outputLanguage: DictationFormatterService.OutputLanguage
    }

    private func startRefineWorker() {
        refineWorkerGeneration += 1
        let generation = refineWorkerGeneration
        refineWorkerTask = Task.detached(priority: .utility) { [weak self] in
            defer {
                // The loop ended (queue drained after stop, or cancelled). Clear the handle so the
                // next session can start a worker; a finished task left here would block every
                // later session's refinement. The generation check keeps an old worker from
                // clearing a newer worker's handle.
                Task { @MainActor [weak self] in
                    guard let self, self.refineWorkerGeneration == generation else { return }
                    self.refineWorkerTask = nil
                }
            }
            // Startup retry counts per span. While the formatter loads, a span is queued again
            // rather than marked refined as raw text, which would also exclude it from the stop
            // pass. Bounded so a model that never loads can't loop.
            var notReadyRetries: [UUID: Int] = [:]
            let maxNotReadyRetries = 60   // ~18s at 300ms/retry
            while !Task.isCancelled {
                guard let self else { return }
                let next: UUID? = await self.popOrAwaitRefineSpan()
                guard let spanID = next else { return }
                
                let prep = await MainActor.run { [weak self] () -> RefinePreparationResult? in
                    guard let self else { return nil }
                    let recording = self.isRecording
                    let formatter = self.dictationFormatter
                    let ready = formatter?.state == .ready
                    // Transient = will become ready without user action. A
                    // terminal state (disabled / unloaded / error / unavailable)
                    // must NOT be retried or the worker spins.
                    let transient: Bool
                    switch formatter?.state {
                    case .loading, .downloading, .generating: transient = true
                    default: transient = false
                    }

                    let templateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
                    let template = DictationFormatterService.Template(rawValue: templateRaw) ?? .standard
                    let outputLanguage = DictationFormatterService.OutputLanguage.from(
                        code: UserDefaults.standard.string(forKey: "dictationOutputLanguage")
                    )

                    let plan = self.computeBoundaryMergePlan(forSpanID: spanID)

                    // Limit the status input to the last 400 words, like the context limit in
                    // computeBoundaryMergePlan. Unbounded input made each call slower and could
                    // stall the worker.
                    let accumulatedText: String? = {
                        guard template.isSpecialty else { return nil }
                        let full = self.stagedTranscript.finalText()
                        let words = full.split(separator: " ", omittingEmptySubsequences: true)
                        guard words.count > 400 else { return full }
                        return words.suffix(400).joined(separator: " ")
                    }()

                    return RefinePreparationResult(
                        isRecording: recording,
                        formatter: formatter,
                        formatterReady: ready,
                        formatterTransient: transient,
                        mergePlan: plan,
                        specialtyTemplate: template.isSpecialty ? template : nil,
                        accumulatedTextForSpecialty: accumulatedText,
                        outputLanguage: outputLanguage
                    )
                }
                
                guard let prep else { continue }
                guard prep.isRecording, let formatter = prep.formatter else {
                    dictationTraceLog.notice("refine skip (not recording / formatter gone) span=\(spanID.uuidString, privacy: .public)")
                    continue
                }
                guard prep.formatterReady else {
                    let attempts = notReadyRetries[spanID, default: 0]
                    if prep.formatterTransient && attempts < maxNotReadyRetries {
                        // The model is still loading. Queue the span again so it gets a real refine
                        // later instead of being marked refined as raw text.
                        notReadyRetries[spanID] = attempts + 1
                        await MainActor.run { [weak self] in
                            self?.enqueueRefine(spanID: spanID)
                        }
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continue
                    }
                    dictationTraceLog.notice("refine skip (formatter not ready) span=\(spanID.uuidString, privacy: .public) attempts=\(attempts, privacy: .public)")
                    notReadyRetries[spanID] = nil
                    continue
                }
                guard let plan = prep.mergePlan else {
                    continue
                }

                let segmentWordCount = wordCount(plan.toRefine)
                let traceMsg = "refine start span=\(spanID.uuidString) words=\(segmentWordCount) ctx_chars=\(plan.priorContext.count) anchor=\(plan.anchorWordCount) mutable=\(plan.mutableWordsAbsorbed)"
                dictationTraceLog.notice("\(traceMsg, privacy: .public)")

                if let specialtyTemplate = prep.specialtyTemplate, let accumulatedText = prep.accumulatedTextForSpecialty {
                    // Status generation runs on this serial worker without owning the formatter's
                    // generating state, so a stalled call would block every later refine. Abandon
                    // it after 20 s; a nil result skips the status.
                    let statusResult = await Self.raceWithHardTimeout(seconds: 20) {
                        await formatter.generateSpecialtyLiveStatus(accumulatedText, priorContext: plan.priorContext, template: specialtyTemplate)
                    }
                    if let status = statusResult ?? nil {
                        await MainActor.run { [weak self] in
                            self?.specialtyLiveStatus = status
                        }
                    }
                }

                let translating = !prep.outputLanguage.isMatch
                let translateTarget = prep.outputLanguage

                // The watchdog resumes even if the model stream stalls and ignores cancellation,
                // which a task group can't do because it must wait for the stalled child. A stalled
                // call is abandoned and the span stays eligible for the stop pass.
                //
                // In translate mode, a segment returned in the source language failed (timeout or
                // echo). Retry once after a short pause, but only if the first attempt failed
                // quickly; a full timeout means sustained load, and the stop pass covers held
                // spans. The watchdog is longer here because translation gets a larger generation
                // budget.
                var result: DictationFormatterService.RefinementResult?
                let maxTranslateAttempts = translating ? 2 : 1
                var translateAttempt = 0
                while translateAttempt < maxTranslateAttempts {
                    translateAttempt += 1
                    let startedAt = CFAbsoluteTimeGetCurrent()
                    result = await Self.raceWithHardTimeout(seconds: translating ? 55 : 45) {
                        await formatter.refine(
                            plan.toRefine,
                            forceRefine: true,
                            priorContext: plan.priorContext,
                            silentMode: true,
                            onStream: nil
                        )
                    }
                    guard translating else { break }
                    let failed = Self.translateLikelyFailed(
                        output: result?.text ?? "", input: plan.toRefine, target: translateTarget
                    )
                    if !failed { break }
                    let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                    if translateAttempt < maxTranslateAttempts && elapsed < 4.0 {
                        dictationTraceLog.notice("translate refine retry span=\(spanID.uuidString, privacy: .public) attempt=\(translateAttempt, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s")
                        try? await Task.sleep(nanoseconds: 700_000_000)
                    } else {
                        break
                    }
                }

                // If every attempt returned source-language text, don't paste it as the
                // translation. Hold the span for the stop pass and flag the session so AppState can
                // show a toast.
                func holdFailedTranslation() async {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if translating {
                            self.stagedTranscript.markHeldSourceLanguage(spanID: spanID)
                            self.translateRefineKeptSourceLanguage = true
                            self.translateHeldSegmentCount += 1
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                guard let result, result.completed else {
                    dictationTraceLog.notice("refine incomplete span=\(spanID.uuidString, privacy: .public); kept pending for the final pass")
                    await holdFailedTranslation()
                    continue
                }

                let trimmedRefined = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                if translating {
                    if Self.translateLikelyFailed(output: trimmedRefined, input: plan.toRefine, target: translateTarget) {
                        dictationTraceLog.notice("translate refine held span=\(spanID.uuidString, privacy: .public) (output stayed source language after \(translateAttempt, privacy: .public) attempt(s))")
                        await holdFailedTranslation()
                        continue
                    }
                }

                let dedupedRefined = Self.stripPriorOverlap(
                    refined: trimmedRefined,
                    priorContext: plan.priorContext,
                    mutableWordsAbsorbed: plan.mutableWordsAbsorbed
                )
                let trimmed = dedupedRefined.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let hallucinationMarkers = [
                        "AFMRefinedDictation",
                        "response format in JSON",
                        "name: AFM",
                        "@Generable",
                    ]
                    let isHallucinated = hallucinationMarkers.contains { trimmed.contains($0) }
                    let inputLen = plan.toRefine.count
                    let outputLen = trimmed.count
                    let lengthRunaway = inputLen >= 30 && outputLen > inputLen * 3
                    if isHallucinated || lengthRunaway {
                        dictationTraceLog.notice("refine reject span=\(spanID.uuidString, privacy: .public) hallucination=\(isHallucinated, privacy: .public) lengthRunaway=\(lengthRunaway, privacy: .public)")
                    } else {
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.applyBoundaryMergeResult(
                                plan: plan,
                                refinedText: trimmed
                            )
                            // The retried span is translated now, so clear its held flag.
                            self.stagedTranscript.clearHeldSourceLanguage(spanID: spanID)
                            self.refinesCompletedCount += 1
                            self.recomputeVocabOutputStat()
                        }
                        dictationTraceLog.notice("refine done span=\(spanID.uuidString, privacy: .public) words=\(wordCount(trimmed), privacy: .public)")
                    }
                } else {
                    dictationTraceLog.notice("refine empty-output span=\(spanID.uuidString, privacy: .public)")
                }
            }
        }
    }

    /// Whether a translate refine clearly failed: the output equals the input (raw fallback), or a
    /// CJK target came back with almost no characters in its script. Latin-script targets can't be
    /// told from English this cheaply, so they rely on the equality check.
    nonisolated static func translateLikelyFailed(
        output: String,
        input: String,
        target: DictationFormatterService.OutputLanguage
    ) -> Bool {
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let i = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if o.isEmpty { return true }
        if o == i { return true }
        switch target {
        case .simplifiedChinese, .japanese, .korean:
            var targetScalars = 0
            var letters = 0
            for scalar in o.unicodeScalars {
                if isEastAsianScriptScalar(scalar) { targetScalars += 1; letters += 1 }
                else if scalar.properties.isAlphabetic { letters += 1 }
            }
            guard letters > 0 else { return false }
            return Double(targetScalars) / Double(letters) < 0.3
        default:
            return false
        }
    }

    /// Han (incl. extensions), Hiragana/Katakana, and Hangul; the scripts the
    /// CJK output languages render in. Kept in sync with the probe's scorer.
    nonisolated static func isEastAsianScriptScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) ||
               (0xF900...0xFAFF).contains(v) || (0x20000...0x2A6DF).contains(v) ||
               (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) ||
               (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v)
    }

    /// Races an operation against a hard timeout without a task group, which would have to wait for
    /// a child that ignores cancellation. The loser is cancelled and abandoned; a late result is
    /// discarded.
    static func raceWithHardTimeout<T: Sendable>(
        seconds: Double,
        _ op: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let work = Task {
                let result = await op()
                let isFirst = resumed.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                if isFirst { cont.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                let isFirst = resumed.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                if isFirst {
                    work.cancel()
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Next queued span, or waits until `enqueueRefine` adds one or the session ends. Clears
    /// `isRefining` while waiting, which returns the wave to its normal palette.
    private func popOrAwaitRefineSpan() async -> UUID? {
        if !refineQueue.isEmpty {
            refineInFlight = true
            return refineQueue.removeFirst()
        }
        if !isRecording {
            isRefining = false
            refineInFlight = false
            return nil
        }
        // Nothing is queued: return the wave to its normal palette and clear the in-flight flag.
        isRefining = false
        refineInFlight = false
        return await withCheckedContinuation { (cont: CheckedContinuation<UUID?, Never>) in
            // Re-check after suspending: another enqueue may have raced.
            if !refineQueue.isEmpty {
                refineInFlight = true
                let next = refineQueue.removeFirst()
                cont.resume(returning: next)
                return
            }
            if !isRecording {
                cont.resume(returning: nil)
                return
            }
            refineQueueContinuation = cont
        }
    }

    /// How to apply a boundary-merge refine when its result comes back: the prior context for the
    /// model, the combined input to refine, and what to update in both spans afterward.
    ///
    /// The boundary region of the previous span is split in two:
    /// - The first anchor words stay in the prior context, read-only, tied to the text before them.
    /// - The last mutable words join the input, where the model may rewrite them.
    private struct BoundaryMergePlan {
        let currSpanID: UUID
        let prevSpanID: UUID?
        let prevTextAfterMutableStripped: String
        let priorContext: String
        let toRefine: String
        let anchorWordCount: Int
        let mutableWordsAbsorbed: Int
    }

    /// Revisit recent sentences so a pause or later word can repair their boundary.
    private func computeBoundaryMergePlan(forSpanID spanID: UUID) -> BoundaryMergePlan? {
        let allSpans = stagedTranscript.confirmedSpans
        guard let idx = allSpans.firstIndex(where: { $0.id == spanID }) else { return nil }
        let currSpan = allSpans[idx]
        guard idx > 0 else {
            return BoundaryMergePlan(currSpanID: spanID, prevSpanID: nil,
                prevTextAfterMutableStripped: "", priorContext: "", toRefine: currSpan.text,
                anchorWordCount: 0, mutableWordsAbsorbed: 0)
        }
        let prevSpan = allSpans[idx - 1]
        let boundary = RefinementWindow.splitBoundary(prevSpan.text)
        let prevWithoutMutable = boundary.prefix
        let absorbMutable = boundary.tail.split(whereSeparator: \.isWhitespace).count
        let effectiveAnchor = min(2, prevWithoutMutable.split(whereSeparator: \.isWhitespace).count)
        let earlier = allSpans.prefix(idx - 1).map(\.text).joined(separator: " ")
        let priorContext = RefinementWindow.recentContext(RefinementWindow.join(earlier, prevWithoutMutable))

        // toRefine: mutable tail of prev + current span's text. The LLM
        // regenerates this region; it can fix cross-boundary errors here
        // because both halves of the boundary are mutable in this input.
        let mutableTailText = boundary.tail
        var currText = currSpan.text
        // Mid-sentence boundary: when the mutable tail has no sentence terminator, the join
        // continues a sentence, but Parakeet capitalizes each segment as if it began one ("...the
        // same" + "But the cleanest fix"). The model tends to keep input casing, so lowercase the
        // first letter first. Skip "I" and words with internal capitals such as "iPhone".
        if !mutableTailText.isEmpty,
           let lastChar = mutableTailText.trimmingCharacters(in: .whitespacesAndNewlines).last,
           lastChar != ".", lastChar != "!", lastChar != "?",
           let firstChar = currText.first, firstChar.isUppercase
        {
            let firstWord = currText.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let firstWordTrimmed = firstWord.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            let restOfWord = firstWordTrimmed.dropFirst()
            let isCommonSentenceStarterWord = !firstWordTrimmed.isEmpty
                && firstWordTrimmed != "I"
                && !firstWordTrimmed.hasPrefix("I'")
                && firstWordTrimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'") }
                && restOfWord.allSatisfy { !$0.isUppercase }
            if isCommonSentenceStarterWord {
                var chars = Array(currText)
                chars[0] = Character(String(firstChar).lowercased())
                currText = String(chars)
            }
        }
        // The reverse case: when the tail ends a sentence and the next segment starts lowercase,
        // capitalize it, or the model tends to keep "...feature flag. and migrate".
        if !mutableTailText.isEmpty,
           let lastChar = mutableTailText.trimmingCharacters(in: .whitespacesAndNewlines).last,
           lastChar == "." || lastChar == "!" || lastChar == "?",
           let firstChar = currText.first, firstChar.isLowercase
        {
            var chars = Array(currText)
            chars[0] = Character(String(firstChar).uppercased())
            currText = String(chars)
        }
        let toRefine = RefinementWindow.join(mutableTailText, currText)

        return BoundaryMergePlan(
            currSpanID: spanID,
            prevSpanID: prevSpan.id,
            prevTextAfterMutableStripped: prevWithoutMutable,
            priorContext: priorContext,
            toRefine: toRefine,
            anchorWordCount: effectiveAnchor,
            mutableWordsAbsorbed: absorbMutable
        )
    }

    /// Applies the refined text to both spans together: the previous span gives up its boundary
    /// words, which are now part of the refined output, and the current span becomes `.refined`.
    /// Without a previous span, refines the current span alone.
    private func applyBoundaryMergeResult(plan: BoundaryMergePlan, refinedText: String) {
        guard isRecording else { return }
        if let prevID = plan.prevSpanID {
            stagedTranscript.applyBoundaryMerge(
                prevSpanID: prevID,
                prevTextWithoutBoundary: plan.prevTextAfterMutableStripped,
                currSpanID: plan.currSpanID,
                currRefinedText: refinedText
            )
        } else {
            stagedTranscript.refineSpan(spanID: plan.currSpanID, refinedText: refinedText)
        }
    }

    /// Removes words at the start of `refined` that repeat the end of `priorContext`, which would
    /// otherwise show up twice when the transcript is joined ("...because you" + "you know...").
    /// Checks up to 5 words for the longest match, ignoring case and punctuation. Returns `refined`
    /// unchanged when nothing overlaps.
    nonisolated private static func stripPriorOverlap(refined: String, priorContext: String, mutableWordsAbsorbed: Int = 0) -> String {
        let refinedTrimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refinedTrimmed.isEmpty, !priorContext.isEmpty else { return refined }
        let refinedWords = refinedTrimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let priorWords = priorContext.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !refinedWords.isEmpty, !priorWords.isEmpty else { return refined }
        let normalize: (String) -> String = { word in
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        // Tier 1: exact word-prefix overlap (the original heuristic).
        // Catches "...because you" + "you know..." → strips "you".
        let maxOverlap = min(refinedWords.count, priorWords.count, 5)
        var stripCount = 0
        for m in 1...maxOverlap {
            let prefix = refinedWords.prefix(m).map(normalize)
            let suffix = priorWords.suffix(m).map(normalize)
            // Don't match on tokens that normalize to empty, such as bare punctuation.
            if prefix.contains(where: \.isEmpty) || suffix.contains(where: \.isEmpty) {
                continue
            }
            if prefix == suffix {
                stripCount = m
            }
        }
        if stripCount > 0 {
            let remaining = refinedWords.dropFirst(stripCount)
            return remaining.joined(separator: " ")
        }

        // When the plan absorbed the previous span's last words into the input, `refined` correctly
        // begins with them. Tier 2 would drop the whole first sentence on a semantic match with the
        // prior context, deleting real words when a repetitive list crosses a segment boundary
        // ("database server is up" after "web server is up"). Skip tier 2 then; tier 1's exact
        // anchor check still runs.
        guard mutableWordsAbsorbed == 0 else { return refined }

        // Tier 2, sentence-level overlap: the model sometimes rewrites the prior context instead of
        // echoing it, which tier 1 can't catch. If refined's first sentence shares enough content words
        // with one of the prior context's last 3 sentences, drop that first sentence.
        //
        // Only when refined has at least 2 sentences, its first sentence has at least 6 content words,
        // and the matching prior sentence shares at least 4 unique content words and 40% of the smaller
        // sentence's unique words.
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been",
            "of", "to", "in", "on", "at", "for", "and", "or", "but", "so",
            "i", "we", "you", "they", "he", "she", "it", "this", "that"
        ]
        func contentWords(_ s: String) -> Set<String> {
            Set(s.split(whereSeparator: \.isWhitespace)
                .map { normalize(String($0)) }
                .filter { $0.count >= 3 && !stopWords.contains($0) })
        }

        let refinedSentences = splitSentencesNoTrim(refinedTrimmed)
        guard refinedSentences.count >= 2 else { return refined }
        let firstSentence = refinedSentences[0]
        let firstWords = firstSentence.split(whereSeparator: \.isWhitespace)
        guard firstWords.count >= 6 else { return refined }
        let firstContent = contentWords(firstSentence)
        guard firstContent.count >= 4 else { return refined }

        let priorSentences = splitSentencesNoTrim(priorContext).suffix(3)
        for priorSentence in priorSentences {
            let priorContent = contentWords(priorSentence)
            guard priorContent.count >= 4 else { continue }
            let intersection = firstContent.intersection(priorContent)
            let smaller = min(firstContent.count, priorContent.count)
            if intersection.count >= 4 && Double(intersection.count) / Double(smaller) >= 0.4 {
                // Strip refined's first sentence.
                let kept = refinedSentences.dropFirst().joined()
                let cleaned = kept.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        return refined
    }

    /// Splits text into sentences PRESERVING whitespace + terminator on
    /// each fragment, so concatenating the array reconstructs the input.
    /// Used by the tier-2 semantic overlap detector in stripPriorOverlap.
    nonisolated private static func splitSentencesNoTrim(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if chars[i] == "." || chars[i] == "!" || chars[i] == "?" {
                let next = i + 1
                if next == chars.count {
                    result.append(current); current = ""; i += 1; continue
                }
                if chars[next].isWhitespace {
                    // Consume the trailing whitespace into the same sentence
                    // so concat reconstructs verbatim.
                    while i + 1 < chars.count && chars[i + 1].isWhitespace {
                        i += 1
                        current.append(chars[i])
                    }
                    result.append(current); current = ""
                }
            }
            i += 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Direct mode: commits EOU text since the last commit as a span, from the VAD speech-end
    /// handler. Refine is optional; without it the span keeps EOU's raw text.
    func commitEouSegmentForDirectMode() {
        let words = eouPartialAccumulated.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > lastCommittedEouWordCount else { return }
        let newWords = Array(words.dropFirst(lastCommittedEouWordCount))
        let segmentText = newWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segmentText.isEmpty else { return }

        let spanID = stagedTranscript.ingestEouCommitted(segmentText)
        lastCommittedEouWordCount = words.count
        dictationTraceLog.notice("eou commit (direct mode) span=\(spanID.uuidString, privacy: .public) words=\(newWords.count, privacy: .public) tail=\(transcriptMetrics(segmentText), privacy: .public)")

        if refineRealTimeActive {
            enqueueRefine(spanID: spanID)
        }
    }

    /// Tears down the refine worker. Cancels the Task, drains the queue,
    /// and wakes any pending continuation so the worker exits its await.
    func tearDownRefineWorker() {
        refineQueue.removeAll()
        if let cont = refineQueueContinuation {
            refineQueueContinuation = nil
            cont.resume(returning: nil)
        }
        refineWorkerTask?.cancel()
        refineWorkerTask = nil
        isRefining = false
        refineInFlight = false
    }

    /// Waits until the refine queue drains or `timeout` seconds pass, polling every 50 ms. Called
    /// before paste assembly at stop; otherwise the worker exits when recording stops and cancels
    /// the latest segment's refine. Returns false on timeout. Callers paste either way, since a
    /// partial drain beats a stalled stop.
    @discardableResult
    func awaitPendingRefines(timeout seconds: TimeInterval) async -> Bool {
        guard refineWorkerTask != nil else { return true }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            // Drained means the queue is empty, no span is in flight, and the formatter is idle.
            // `refineInFlight` covers the gap between taking a span and the formatter reporting
            // `.generating`, which can last a whole document status call.
            let queueEmpty = refineQueue.isEmpty
            let formatterIdle: Bool
            if let formatter = dictationFormatter {
                formatterIdle = (formatter.state == .ready)
            } else {
                formatterIdle = true
            }
            if queueEmpty && !refineInFlight && formatterIdle { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Switches which engine drives the live preview overlay during a
    /// dual-engine session. Called from AppState's press-mode-decision Task
    /// once the press resolves. No-op when dual-engine is inactive.
    func setEngineForOverlay(_ engine: DualEngineOverlayChoice) {
        guard dualEngineActive else { return }
        guard currentEngineForOverlay != engine else { return }
        currentEngineForOverlay = engine
        switch engine {
        case .undecided:
            volatileText = ""
            lastVolatileSnapshot = ""
        case .eou:
            // EOU kept updating `eouPartialAccumulated` while the overlay was undecided, so the
            // first words are already there. Show them now.
            volatileText = eouPartialAccumulated
            lastVolatileSnapshot = eouPartialAccumulated
        case .tdt:
            // Expose polling's prior segments. Volatile waits for the next
            // poll cycle; without this, finalized segments from before the
            // mode-resolve would be invisible until the next finalization.
            volatileText = ""
            lastVolatileSnapshot = ""
            confirmedText = cachedFrozenText
        }
    }
}
