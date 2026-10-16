// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

extension DictationOverlayContent {
    /// One word's display data. `text` is the streaming version shown in the gray zone; `tdtText`
    /// is TDT's corrected version, shown once the pointer reaches the word. Confirmed words already
    /// hold the TDT text, so `tdtText` is nil; words beyond TDT's coverage have only streaming text
    /// and stay gray.
    struct DisplayWord {
        let text: String
        let tdtText: String?
        let isRefined: Bool
        let trailingSpace: Bool
        /// When the word's span became `.refined`, for the short fade that crosses the segment. Nil
        /// otherwise.
        let refinedAt: TimeInterval?
        /// Position within the span, used to stagger the refined fade from left to right.
        let wordIndexInSpan: Int
    }

    /// The visible transcript as three runs:
    /// 1. Confirmed spans (TDT final or refined), always behind the pointer's floor, so white.
    /// 2. Streaming TDT for the current segment: each position has streaming text in `text` and TDT
    ///    text in `tdtText`, swapped when the pointer reaches it.
    /// 3. Streaming words beyond TDT's coverage, always gray.
    /// The pointer never drops below `confirmedTdtCount` or passes `whiteEligibleCount`.
    struct DisplayLayout {
        let words: [DisplayWord]
        let confirmedTdtCount: Int
        let whiteEligibleCount: Int
    }

    func computeDisplayWords(
        spans: [StagedTranscript.Span],
        streamingTdt: String,
        tail: String
    ) -> DisplayLayout {
        // Reads the specialty flag from UserDefaults and passes everything else to the pure
        // function below, which tests call directly.
        let templateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
        let template = DictationFormatterService.Template(rawValue: templateRaw) ?? .standard
        return Self.computeDisplayLayout(
            spans: spans,
            streamingTdt: streamingTdt,
            tail: tail,
            isSpecialty: template.isSpecialty
        )
    }

    /// Builds the `DisplayLayout` from confirmed spans, streaming TDT text, and the live tail.
    /// Depends only on its inputs, so tests can check exactly what the user sees.
    static func computeDisplayLayout(
        spans: [StagedTranscript.Span],
        streamingTdt: String,
        tail: String,
        isSpecialty: Bool
    ) -> DisplayLayout {
        let renderable = spans.filter { !$0.text.isEmpty }
        var words: [DisplayWord] = []
        let estimatedCapacity = renderable.reduce(0) { $0 + max(1, $1.precomputedWords.count) } + 32
        words.reserveCapacity(estimatedCapacity)

        // Run 1: confirmed spans, already final, so no `tdtText`. Refined spans carry their
        // timestamp and word index for the left-to-right fade.
        for span in renderable {
            let spanWords = (span.stage == .refined && isSpecialty) ? span.precomputedOriginalWords : span.precomputedWords
            for (idxInSpan, w) in spanWords.enumerated() {
                words.append(DisplayWord(
                    text: w,
                    tdtText: nil,
                    isRefined: span.stage == .refined,
                    trailingSpace: true,
                    refinedAt: !isSpecialty && span.stage == .refined && span.refinementRevealStarts.indices.contains(idxInSpan)
                        ? span.refinementRevealStarts[idxInSpan] : nil,
                    wordIndexInSpan: idxInSpan
                ))
            }
        }
        let confirmedTdtCount = words.count

        // The current segment: streaming EOU usually runs a few words ahead of streaming TDT, so a
        // position can have either version or both.
        let streamingWords: [String]
        if streamingTdt.isEmpty {
            streamingWords = []
        } else {
            streamingWords = streamingTdt.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }
        let eouWords: [String]
        if tail.isEmpty {
            eouWords = []
        } else {
            eouWords = tail.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }

        // Run Levenshtein / edit-distance word alignment to match EOU tail and streaming TDT (P1 #4)
        let alignedPairs = Self.alignWords(eou: eouWords, tdt: streamingWords)

        // Drop the trailing TDT-only run. EOU updates every 160 ms and defines how far speech has
        // gone; streaming TDT polls 2 to 3 times a second and is cleared on every commit. TDT words
        // past the last EOU-backed word are stale and rendered as extra white words that hid the
        // gray tail. TDT-only pairs inside the run (one EOU word split in two, or a word EOU
        // missed) stay. `inProgressTrim` holds the math for tests.
        let trim = Self.inProgressTrim(alignedPairs: alignedPairs)
        let inProgressPairs = alignedPairs.prefix(trim.pairCount)

        for (idx, pair) in inProgressPairs.enumerated() {
            let eouOpt = pair.eou
            let tdtOpt = pair.tdt

            // Default the gray-zone text to EOU. If TDT has this
            // position but EOU doesn't, fall back to TDT for the gray text too.
            guard let baseText = eouOpt ?? tdtOpt, !baseText.isEmpty else { continue }

            // TDT alternative is set when TDT has this word AND it
            // visibly differs from EOU. When they match, no alternative is stored.
            let altTdt: String? = {
                guard let tdt = tdtOpt, !tdt.isEmpty else { return nil }
                return tdt == eouOpt ? nil : tdt
            }()

            words.append(DisplayWord(
                text: baseText,
                tdtText: altTdt,
                isRefined: false,
                trailingSpace: true,
                refinedAt: nil,
                wordIndexInSpan: idx
            ))
        }

        let whiteEligibleCount = confirmedTdtCount + trim.whiteEligibleTail

        // Drop the trailing space from the very last word.
        if !words.isEmpty {
            let last = words[words.count - 1]
            words[words.count - 1] = DisplayWord(
                text: last.text,
                tdtText: last.tdtText,
                isRefined: last.isRefined,
                trailingSpace: false,
                refinedAt: last.refinedAt,
                wordIndexInSpan: last.wordIndexInSpan
            )
        }
        return DisplayLayout(
            words: words,
            confirmedTdtCount: confirmedTdtCount,
            whiteEligibleCount: whiteEligibleCount
        )
    }

    // Internal so tests can cover the empty-side guard in `alignWords`.
    struct AlignedPair {
        let eou: String?
        let tdt: String?
    }

    static func alignWords(eou: [String], tdt: [String]) -> [AlignedPair] {
        let n = eou.count
        let m = tdt.count

        // Handle an empty side before the table fill, since `1...0` traps. Common: EOU has words
        // about 160 ms after speech starts, before the first TDT poll returns, and the reverse
        // right after a commit.
        guard n > 0 else { return tdt.map { AlignedPair(eou: nil, tdt: $0) } }
        guard m > 0 else { return eou.map { AlignedPair(eou: $0, tdt: nil) } }

        // DP table for edit distance.
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        
        for i in 1...n {
            for j in 1...m {
                let w1 = eou[i - 1].lowercased()
                let w2 = tdt[j - 1].lowercased()
                if w1 == w2 {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    let costReplace = dp[i - 1][j - 1] + 1
                    let costDelete = dp[i - 1][j] + 1
                    let costInsert = dp[i][j - 1] + 1
                    dp[i][j] = min(costReplace, min(costDelete, costInsert))
                }
            }
        }
        
        // Backtrack to find the alignment
        var aligned: [AlignedPair] = []
        var i = n
        var j = m
        
        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                let w1 = eou[i - 1].lowercased()
                let w2 = tdt[j - 1].lowercased()
                if w1 == w2 {
                    aligned.append(AlignedPair(eou: eou[i - 1], tdt: tdt[j - 1]))
                    i -= 1
                    j -= 1
                } else {
                    let current = dp[i][j]
                    if current == dp[i - 1][j - 1] + 1 {
                        aligned.append(AlignedPair(eou: eou[i - 1], tdt: tdt[j - 1]))
                        i -= 1
                        j -= 1
                    } else if current == dp[i - 1][j] + 1 {
                        aligned.append(AlignedPair(eou: eou[i - 1], tdt: nil))
                        i -= 1
                    } else {
                        aligned.append(AlignedPair(eou: nil, tdt: tdt[j - 1]))
                        j -= 1
                    }
                }
            } else if i > 0 {
                aligned.append(AlignedPair(eou: eou[i - 1], tdt: nil))
                i -= 1
            } else {
                aligned.append(AlignedPair(eou: nil, tdt: tdt[j - 1]))
                j -= 1
            }
        }
        
        return aligned.reversed()
    }

    /// How much of an EOU and TDT alignment is real in-progress text: `pairCount` leading pairs (up
    /// to the last EOU-backed word), of which `whiteEligibleTail` are TDT-covered.
    struct InProgressTrim {
        let pairCount: Int
        let whiteEligibleTail: Int
    }

    /// Drops the trailing TDT-only run and counts the TDT-covered words left. See
    /// `computeDisplayWords`. Internal for tests.
    static func inProgressTrim(alignedPairs: [AlignedPair]) -> InProgressTrim {
        var lastEouIndex = -1
        for (idx, pair) in alignedPairs.enumerated() where pair.eou != nil {
            lastEouIndex = idx
        }
        let pairCount = max(0, lastEouIndex + 1)
        var lastTdtIndex = -1
        var i = 0
        while i < pairCount {
            if alignedPairs[i].tdt != nil { lastTdtIndex = i }
            i += 1
        }
        return InProgressTrim(pairCount: pairCount, whiteEligibleTail: lastTdtIndex + 1)
    }

    /// Builds the text at a pointer position. Words more than the fade window behind the pointer
    /// are white, words ahead of it are gray, and words in between fade, so several words fade at
    /// once instead of a hard edge. A word switches from its streaming text to TDT's text when the
    /// pointer reaches it; usually they're identical, and where TDT added punctuation, capitals, or
    /// a vocabulary term, that is when the correction appears.
    func composedAnimatedTextLayer(
        words: [DisplayWord],
        pointer: Double,
        now: TimeInterval
    ) -> Text {
        let draftOpacity: Double = {
            if appState.transcriptionService.isRecording {
                return 0.65 + 0.10 * sin((now.truncatingRemainder(dividingBy: 3.0) / 3.0) * 2.0 * .pi)
            } else {
                return 1.0
            }
        }()

        // Pre-resolve endpoints once. See ResolvedColor comment. Uses
        // the per-scheme endpoints so light mode renders with the same
        // tuned gray as the two-stage path.
        let endpoints = Self.overlayColorEndpoints(for: colorScheme)
        let primaryColor = endpoints.primary
        let tailColor = endpoints.gray
        let fadeWindow = Animate.tdtTrailFadeWindow
        
        // Pre-resolve system accent color components once per frame redraw
        let resolvedAccent = accentColorComponents()
        
        var combined = Text("")

        for (i, word) in words.enumerated() {
            let progress = Self.wordProgress(
                wordIndex: i,
                pointer: pointer,
                fadeWindow: fadeWindow
            )
            let suffix = word.trailingSpace ? " " : ""
            let displayText = Self.displayText(word, progress: progress)

            // Base color: gray→primary lerp driven by pointer progress.
            let progressClamped = max(0, min(1, progress))
            let inv = 1 - progressClamped
            var currentR = tailColor.r * inv + primaryColor.r * progressClamped
            var currentG = tailColor.g * inv + primaryColor.g * progressClamped
            var currentB = tailColor.b * inv + primaryColor.b * progressClamped

            var wordOpacity: Double = {
                if progress >= 1.0 { return 1.0 }
                return draftOpacity + (1.0 - draftOpacity) * progress
            }()

            // When a span has just been refined, each word briefly dips in opacity and brightens,
            // staggered by word index so it crosses the segment from left to right.
            var wordBaselineOffset: CGFloat = 0.0
            let weight: Font.Weight = refineAnimationStyle == "Crystalline" ? .semibold : (word.isRefined ? (progress >= 1.0 ? .semibold : .medium) : .medium)

            if word.isRefined, let refAt = word.refinedAt, !reduceMotion {
                let duration = Animate.refinedPulseDuration
                let elapsed = now - refAt
                
                if refineAnimationStyle == "Crystalline" {
                    if elapsed > 0 && elapsed < duration {
                        let t = elapsed / duration
                        let pulseIntensity = sin(t * .pi)
                        let crystalR = 0.92
                        let crystalG = 0.94
                        let crystalB = 1.00
                        currentR = currentR * (1.0 - pulseIntensity) + crystalR * pulseIntensity
                        currentG = currentG * (1.0 - pulseIntensity) + crystalG * pulseIntensity
                        currentB = currentB * (1.0 - pulseIntensity) + crystalB * pulseIntensity
                        wordOpacity = 0.85 + 0.15 * pulseIntensity
                    }
                } else if refineAnimationStyle == "Magical" {
                    if elapsed > 0 && elapsed < duration {
                        let t = elapsed / duration
                        let easeOut = 1.0 - pow(1.0 - t, 3.0)
                        wordBaselineOffset = -2.0 * (1.0 - easeOut)
                        
                        let pulseIntensity = sin(t * .pi)
                        let surgeColors = refineSurgeColorComponents(wordIndex: word.wordIndexInSpan, now: now, resolvedAccent: resolvedAccent)
                        let surgeBlend = pulseIntensity * 0.65
                        currentR = currentR * (1.0 - surgeBlend) + surgeColors.r * surgeBlend
                        currentG = currentG * (1.0 - surgeBlend) + surgeColors.g * surgeBlend
                        currentB = currentB * (1.0 - surgeBlend) + surgeColors.b * surgeBlend
                        
                        wordOpacity *= (0.70 + 0.30 * easeOut)
                    }
                } else if refineAnimationStyle == "Cascade" {
                    if elapsed > 0 && elapsed < duration {
                        let t = elapsed / duration
                        // Continuous sine rebound spring that starts at 0.0 and dampens to 0.0
                        wordBaselineOffset = -3.0 * sin(t * .pi * 1.5) * (1.0 - t)
                        
                        let pulseIntensity = sin(t * .pi)
                        let surgeColors = refineSurgeColorComponents(wordIndex: word.wordIndexInSpan, now: now, resolvedAccent: resolvedAccent)
                        let surgeBlend = pulseIntensity * 0.85
                        currentR = currentR * (1.0 - surgeBlend) + surgeColors.r * surgeBlend
                        currentG = currentG * (1.0 - surgeBlend) + surgeColors.g * surgeBlend
                        currentB = currentB * (1.0 - surgeBlend) + surgeColors.b * surgeBlend
                    }
                } else if refineAnimationStyle == "Glow" {
                    if elapsed > 0 && elapsed < duration {
                        let t = elapsed / duration
                        let pulseIntensity = sin(t * .pi)
                        wordBaselineOffset = (word.wordIndexInSpan % 2 == 0 ? 0.3 : -0.3) * pulseIntensity
                        
                        let surgeColors = refineSurgeColorComponents(wordIndex: word.wordIndexInSpan, now: now, resolvedAccent: resolvedAccent)
                        let surgeBlend = pulseIntensity * 0.95
                        currentR = currentR * (1.0 - surgeBlend) + surgeColors.r * surgeBlend
                        currentG = currentG * (1.0 - surgeBlend) + surgeColors.g * surgeBlend
                        currentB = currentB * (1.0 - surgeBlend) + surgeColors.b * surgeBlend
                    }
                } else if refineAnimationStyle == "Pulse" {
                    if elapsed > 0 && elapsed < duration {
                        let t = elapsed / duration
                        let pulseIntensity = sin(t * .pi)
                        wordOpacity *= (1.0 - 0.45 * pulseIntensity)
                    }
                }
            }

            let foreground = Color(.sRGB, red: currentR, green: currentG, blue: currentB, opacity: wordOpacity)

            let part = Text(displayText + suffix)
                .font(.system(.body, design: .default, weight: weight))
                .foregroundColor(foreground)
                .baselineOffset(wordBaselineOffset)
            combined = Text("\(combined)\(part)")
        }
        return combined
    }

    /// How white a word is, from 0 to 1, for a pointer position. `fadeWindow` sets how many words
    /// fade at once.
    // `internal` (not `private`) so `InProgressTextLock` can compute the
    // same per-word progress the renderer uses when deciding what to freeze.
    static func wordProgress(
        wordIndex: Int,
        pointer: Double,
        fadeWindow: Double
    ) -> Double {
        let distance = pointer - Double(wordIndex)
        if distance <= 0 { return 0 }
        if distance >= fadeWindow { return 1 }
        let raw = distance / fadeWindow
        // Smooth-step easing for a natural fade curve at the edges.
        return raw * raw * (3 - 2 * raw)
    }

    /// Text for a word at a pointer progress: streaming text before the pointer reaches it, then
    /// TDT's text if different. Shared by the renderer and `InProgressTextLock` so both agree.
    static func displayText(_ word: DisplayWord, progress: Double) -> String {
        if progress > 0, let alt = word.tdtText { return alt }
        return word.text
    }

    /// A color resolved to sRGB components once per render, so loops interpolate Doubles instead of
    /// creating an NSColor per word per frame. Per-frame NSColor resolution went through the trait
    /// collection and caused light-mode flicker.
    struct ResolvedColor: Sendable {
        let r: Double
        let g: Double
        let b: Double
        let a: Double

        init(_ color: Color) {
            let ns = NSColor(color)
            if let srgb = ns.usingColorSpace(.sRGB) {
                self.r = Double(srgb.redComponent)
                self.g = Double(srgb.greenComponent)
                self.b = Double(srgb.blueComponent)
                self.a = Double(srgb.alphaComponent)
            } else {
                self.r = 0; self.g = 0; self.b = 0; self.a = 1
            }
        }

        /// Hard-coded sRGB constants. Lets the overlay rendering path
        /// avoid the NSColor-through-trait-collection resolution that
        /// causes light-mode flicker on rapid frame redraws.
        init(r: Double, g: Double, b: Double, a: Double = 1.0) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
    }

    /// Gray and primary text colors per scheme: readable gray on white in light mode, the familiar
    /// softened white in dark mode.
    struct OverlayColorEndpoints {
        let primary: ResolvedColor
        let gray: ResolvedColor
        let grayValue: Color
    }

    static func overlayColorEndpoints(for scheme: ColorScheme) -> OverlayColorEndpoints {
        if scheme == .light {
            // Light mode: black for refined text, mid gray (0.42) for streaming text, readable on
            // any light material.
            let primary = ResolvedColor(r: 0.0, g: 0.0, b: 0.0)
            let gray    = ResolvedColor(r: 0.42, g: 0.42, b: 0.45)
            return OverlayColorEndpoints(
                primary: primary,
                gray: gray,
                grayValue: Color(.sRGB, red: 0.42, green: 0.42, blue: 0.45, opacity: 1.0)
            )
        } else {
            // Dark mode: white for refined text, about 65% white for streaming text, as fixed sRGB
            // values.
            let primary = ResolvedColor(r: 1.0, g: 1.0, b: 1.0)
            let gray    = ResolvedColor(r: 0.65, g: 0.65, b: 0.68)
            return OverlayColorEndpoints(
                primary: primary,
                gray: gray,
                grayValue: Color(.sRGB, red: 0.65, green: 0.65, blue: 0.68, opacity: 1.0)
            )
        }
    }
}
