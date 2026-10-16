// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import Foundation

/// CTC vocabulary boosting shared by dictation and meetings. Holds FluidAudio's 110M keyword encoder,
/// the tokenized vocabulary, and the rescorer: `make` builds them from vocabulary terms, and
/// `rescore` runs the encoder on audio and replaces a word when the audio favors a vocabulary term.
/// Every stored value is a Sendable FluidAudio value type, so any actor can hold one and call
/// `rescore` without hopping to the main actor.
struct CtcVocabBooster: Sendable {

    let models: CtcModels
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let vocabulary: CustomVocabularyContext
    /// Number of terms that survived CTC tokenization (what the caller reports
    /// as "ready with N terms").
    let termCount: Int

    /// Builds the booster from vocabulary terms. Returns nil when there's nothing to boost (no
    /// terms, or none survive tokenization). Throws only when setup fails (model download or load,
    /// tokenizer, or rescorer). Downloads the 200 MB encoder on first use.
    static func make(vocabularyTerms vocabTerms: [CustomVocabularyTerm]) async throws -> CtcVocabBooster? {
        guard !vocabTerms.isEmpty else { return nil }

        // Load CTC models (downloads ~200MB on first run)
        let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)

        // Tokenize vocabulary terms with CTC tokenizer
        let ctcModelDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        let ctcTokenizer = try await CtcTokenizer.load(from: ctcModelDir)
        let tokenizedTerms = vocabTerms.compactMap { term -> CustomVocabularyTerm? in
            let tokenIds = ctcTokenizer.encode(term.text)
            guard !tokenIds.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                weight: term.weight,
                aliases: term.aliases,
                tokenIds: nil,
                ctcTokenIds: tokenIds
            )
        }
        guard !tokenizedTerms.isEmpty else { return nil }
        let vocabulary = CustomVocabularyContext(terms: tokenizedTerms)

        // Build CTC spotter and rescorer
        let blankId = ctcModels.vocabulary.count
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: vocabulary,
            config: .default,
            ctcModelDirectory: ctcModelDir
        )

        return CtcVocabBooster(
            models: ctcModels,
            spotter: spotter,
            rescorer: rescorer,
            vocabulary: vocabulary,
            termCount: tokenizedTerms.count
        )
    }

    /// Builds the booster only if the encoder is already downloaded, never downloading it. Used for
    /// meetings, so background processing doesn't download 200 MB outside the normal model download
    /// flow. Without it the meeting is processed unboosted; text substitutions still apply.
    static func makeIfCached(vocabularyTerms vocabTerms: [CustomVocabularyTerm]) async throws -> CtcVocabBooster? {
        guard !vocabTerms.isEmpty else { return nil }
        let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard CtcModels.modelsExist(at: cacheDir) else { return nil }
        return try await make(vocabularyTerms: vocabTerms)
    }

    /// Outcome of a single rescore pass.
    struct RescoreOutcome: Sendable {
        /// Corrected transcript when a replacement was made, otherwise the
        /// original transcript unchanged.
        let text: String
        /// Number of applied replacements (the caller's ctcBoostsApplied delta).
        let replacementCount: Int
        /// True when the rescorer changed the text.
        let wasModified: Bool
    }

    /// Runs CTC on `audioSamples` and rescores `transcript` against the vocabulary. `tokenTimings`
    /// must be relative to `audioSamples` (shift file-relative timings for a slice first). Throws
    /// if the encoder pass fails.
    func rescore(
        transcript: String,
        tokenTimings: [TokenTiming],
        audioSamples: [Float]
    ) async throws -> RescoreOutcome {
        guard !tokenTimings.isEmpty else {
            return RescoreOutcome(text: transcript, replacementCount: 0, wasModified: false)
        }

        // Run CTC inference on the segment audio to get log-probabilities
        let spotResult = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: audioSamples,
            customVocabulary: vocabulary,
            minScore: nil
        )

        let logProbs = spotResult.logProbs
        guard !logProbs.isEmpty else {
            return RescoreOutcome(text: transcript, replacementCount: 0, wasModified: false)
        }

        // Rescoring parameters scaled to vocabulary size, with a 0.75 similarity floor.
        // FluidAudio's default of 0.50 to 0.60 replaced ordinary words that share a prefix with a
        // term ("anthropology" and "Anthropic" are 0.67 similar). Exact matches score 1.0, so real
        // terms still pass.
        let vocabConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
        let falsePositiveFloor: Float = 0.75
        let minSimilarity = max(vocabConfig.minSimilarity, vocabulary.minSimilarity, falsePositiveFloor)
        let cbw = vocabConfig.cbw

        let rescoreOutput = rescorer.ctcTokenRescore(
            transcript: transcript,
            tokenTimings: tokenTimings,
            logProbs: logProbs,
            frameDuration: spotResult.frameDuration,
            cbw: cbw,
            marginSeconds: 0.5,
            minSimilarity: minSimilarity
        )

        // FluidAudio 0.15.4's acoustic rescue can propose replacements that sound plausible but
        // look nothing like the term ("the team" to "Rust"). `minSimilarity` doesn't gate that
        // path, and raising it didn't stop them. So check the output: keep a replacement only when
        // a word in the replaced span is at least `falsePositiveFloor` similar to the term, then
        // rebuild from the original transcript with just those. In testing, false positives went
        // from 11 to 0 while exact matches were kept.
        let accepted = rescoreOutput.replacements.filter { r in
            guard r.shouldReplace, let rep = r.replacementWord, !rep.isEmpty else { return false }
            return Self.spanMatchesTerm(span: r.originalWord, term: rep, floor: falsePositiveFloor)
        }
        guard !accepted.isEmpty else {
            return RescoreOutcome(text: transcript, replacementCount: 0, wasModified: false)
        }
        // Apply the accepted replacements as whole-word, first-occurrence edits that don't overlap.
        // Replacing across the whole transcript changed unrelated text ("rust" inside "trust"); the
        // count comes from what was actually replaced.
        let applied = Self.applyAcceptedReplacements(
            to: transcript,
            replacements: accepted.map { (originalWord: $0.originalWord, replacementWord: $0.replacementWord ?? "") }
        )
        guard applied.count > 0 else {
            return RescoreOutcome(text: transcript, replacementCount: 0, wasModified: false)
        }
        return RescoreOutcome(text: applied.text, replacementCount: applied.count, wasModified: true)
    }

    /// Applies accepted replacements to `transcript` as whole-word, first-occurrence edits that
    /// don't overlap. FluidAudio reports only the replaced text, not its position, so each span is
    /// matched as an exact sequence of whole words: "rust" to "Rust" never touches "trust", and
    /// each span is replaced once. Punctuation around matched words is kept. Returns the new text
    /// and the number of edits made.
    static func applyAcceptedReplacements(
        to transcript: String,
        replacements: [(originalWord: String, replacementWord: String)]
    ) -> (text: String, count: Int) {
        guard !replacements.isEmpty else { return (transcript, 0) }

        func isAlnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        // Whole-word tokens: each run of non-whitespace, with the range of its letters and digits
        // (so surrounding punctuation survives) and a lowercased copy for matching. A
        // punctuation-only run has an empty core, so it can't be inside a matched span.
        struct Token {
            let coreLower: String
            let coreRange: Range<String.Index>
        }
        var tokens: [Token] = []
        var idx = transcript.startIndex
        while idx < transcript.endIndex {
            if transcript[idx].isWhitespace {
                idx = transcript.index(after: idx)
                continue
            }
            let runStart = idx
            var runEnd = idx
            while runEnd < transcript.endIndex, !transcript[runEnd].isWhitespace {
                runEnd = transcript.index(after: runEnd)
            }
            var coreStart = runStart
            while coreStart < runEnd, !isAlnum(transcript[coreStart]) {
                coreStart = transcript.index(after: coreStart)
            }
            if coreStart < runEnd {
                var coreEnd = runEnd
                while coreEnd > coreStart {
                    let before = transcript.index(before: coreEnd)
                    if isAlnum(transcript[before]) { break }
                    coreEnd = before
                }
                tokens.append(Token(
                    coreLower: transcript[coreStart..<coreEnd].lowercased(),
                    coreRange: coreStart..<coreEnd
                ))
            } else {
                tokens.append(Token(coreLower: "", coreRange: runStart..<runEnd))
            }
            idx = runEnd
        }

        var consumed = [Bool](repeating: false, count: tokens.count)
        var edits: [(range: Range<String.Index>, text: String)] = []

        for rep in replacements {
            guard !rep.replacementWord.isEmpty else { continue }
            let targetWords = rep.originalWord
                .split(whereSeparator: { $0.isWhitespace })
                .map { normalizeForSim(String($0)) }
                .filter { !$0.isEmpty }
            let width = targetWords.count
            guard width > 0, tokens.count >= width else { continue }

            var start = 0
            var matchAt: Int? = nil
            while start + width <= tokens.count {
                var ok = true
                for k in 0..<width {
                    let t = tokens[start + k]
                    if consumed[start + k] || t.coreLower.isEmpty || t.coreLower != targetWords[k] {
                        ok = false
                        break
                    }
                }
                if ok { matchAt = start; break }
                start += 1
            }
            guard let s = matchAt else { continue }
            let lower = tokens[s].coreRange.lowerBound
            let upper = tokens[s + width - 1].coreRange.upperBound
            edits.append((lower..<upper, rep.replacementWord))
            for j in s..<(s + width) { consumed[j] = true }
        }

        guard !edits.isEmpty else { return (transcript, 0) }
        // Apply right-to-left so each edit's range stays valid against the
        // original string.
        var result = transcript
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.text)
        }
        return (result, edits.count)
    }

    // MARK: - String-similarity guard

    /// True when `span` is at least `floor` similar to `term`, checked word by word ("talking with
    /// Claude" passes on "Claude"; "the team" fails for "Rust"), as a window of the term's word
    /// count, and collapsed, for a one-word term split by recognition ("coober netties" for
    /// "Kubernetes"). Uses FluidAudio's own similarity, 1 - editDistance / maxLength.
    static func spanMatchesTerm(span: String, term: String, floor: Float) -> Bool {
        let cleanTerm = normalizeForSim(term)
        guard !cleanTerm.isEmpty else { return false }
        let spanWords = span.split(whereSeparator: { $0 == " " }).map(String.init)
        let normalizedSpanWords = spanWords.compactMap { word -> String? in
            let normalized = normalizeForSim(word)
            return normalized.isEmpty ? nil : normalized
        }

        // Terms of five letters or fewer must match exactly: one edit still clears 0.75 ("help"
        // against "Helm" is exactly 0.75), and every spoken "help" became "Helm". The floor was
        // tuned for longer words.
        let effectiveFloor: Float = cleanTerm.count <= 5 ? 1.0 : floor

        // Per-word: handles single-word vocab and multi-word spans that carry
        // the term as one of their words.
        for word in normalizedSpanWords {
            if stringSimilarity(word, cleanTerm) >= effectiveFloor { return true }
        }

        // Whole-span, word-count-aware: slide a window of the term's word count
        // across the span and compare the joined window to the whole term.
        let termWordCount = cleanTerm.split(separator: " ").count
        if termWordCount >= 2 {
            if normalizedSpanWords.count >= termWordCount {
                for startIdx in 0...(normalizedSpanWords.count - termWordCount) {
                    let window = normalizedSpanWords[startIdx..<(startIdx + termWordCount)].joined(separator: " ")
                    if stringSimilarity(window, cleanTerm) >= floor { return true }
                }
            }
        } else if cleanTerm.count >= 6, normalizedSpanWords.count >= 2 {
            // Recognizers sometimes split a longer unfamiliar word into two
            // or three phonetic pieces. Compare only short adjacent windows so
            // unrelated surrounding prose cannot qualify as the term.
            let maxWidth = min(3, normalizedSpanWords.count)
            for width in 2...maxWidth {
                for startIdx in 0...(normalizedSpanWords.count - width) {
                    let collapsed = normalizedSpanWords[startIdx..<(startIdx + width)].joined()
                    if stringSimilarity(collapsed, cleanTerm) >= effectiveFloor { return true }
                }
            }
        }
        return false
    }

    /// Lowercase and strip surrounding non-alphanumerics ("issue." -> "issue").
    private static func normalizeForSim(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Normalized Levenshtein similarity in [0, 1]: 1 - editDistance/maxLength.
    static func stringSimilarity(_ a: String, _ b: String) -> Float {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let d = levenshtein(Array(a), Array(b))
        return 1.0 - Float(d) / Float(max(a.count, b.count))
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
