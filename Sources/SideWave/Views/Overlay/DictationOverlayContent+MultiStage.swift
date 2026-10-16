// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

extension DictationOverlayContent {
    // MARK: Multi-stage transcription content

    @ViewBuilder
    private func multiStageContentBody(spans: [StagedTranscript.Span], tail: String) -> some View {
        if skipRefine {
            RecognitionPreview(confirmed: spans.map(\.originalText).joined(separator: " "),
                               draft: tail, reduceMotion: reduceMotion)
        } else if tdtHiddenRefineSweep && !skipRefine && !reduceMotion {
            tdtHiddenRefineSweepContent(spans: spans, tail: tail)
        } else if perWordTransitionAnimation && !reduceMotion {
            animatedMultiStageZStack(spans: spans, tail: tail)
        } else {
            staticMultiStageZStack(spans: spans, tail: tail)
        }
    }

    @ViewBuilder
    var multiStageTranscriptionContent: some View {
        let staged = appState.transcriptionService.stagedTranscript
        let allSpans = staged.confirmedSpans
        // Limit displayed spans so layout work stays bounded in long sessions; older spans are
        // hidden by the mask anyway. Expanded mode keeps more so earlier text can be scrolled back
        // to.
        let spanCap = overlayExpanded || embeddedTranscript ? 100 : 30
        let spans = allSpans.count > spanCap ? Array(allSpans.suffix(spanCap)) : allSpans
        let tail = staged.liveEouTail
        let hasContent = !spans.isEmpty || !tail.isEmpty

        Group {
            if reduceMotion {
                if !hasContent {
                    ListeningPlaceholder(reduceMotion: reduceMotion)
                } else {
                    multiStageContentBody(spans: spans, tail: tail)
                }
            } else {
                ZStack(alignment: .leading) {
                    ListeningPlaceholder(reduceMotion: reduceMotion)
                        .opacity(hasContent ? 0.0 : 1.0)
                        .allowsHitTesting(!hasContent)

                    multiStageContentBody(spans: spans, tail: tail)
                        .opacity(hasContent ? 1.0 : 0.0)
                        .allowsHitTesting(hasContent)
                }
                .animation(.easeInOut(duration: 0.25), value: hasContent)
            }
        }
    }

    /// Two-stage rendering:
    /// 1. Speech appears as gray streaming text at the leading edge.
    /// 2. When a segment's refine finishes, its gray text changes to refined text in a left-to-right
    ///    sweep.
    ///
    /// TDT runs in the background (it gives Refine vocabulary-boosted, punctuated input) but is never
    /// shown. Confirmed spans not yet refined show the `originalEouText` saved at finalize, so the gray
    /// text never gains punctuation or capitals mid-sentence.
    ///
    /// `TimelineView` runs only while a span is inside its sweep window; otherwise rendering is static.
    @ViewBuilder
    private func tdtHiddenRefineSweepContent(
        spans: [StagedTranscript.Span],
        tail: String
    ) -> some View {
        let now = CFAbsoluteTimeGetCurrent()
        let active = !reduceMotion && refineAnimationStyle != "Instant"
            && Self.hasActiveRefineSweep(spans: spans, now: now)
        if active {
            TimelineView(.animation(minimumInterval: Animate.waveFrameRate30)) { context in
                let frameNow = context.date.timeIntervalSinceReferenceDate
                composedTdtHiddenText(spans: spans, tail: tail, now: frameNow)
                    .font(.system(.body, design: .default, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: colorScheme == .dark
                        ? Color.black.opacity(0.5)
                        : Color.black.opacity(0.15),
                        radius: 2, y: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Transcription: \(spans.map(\.text).joined(separator: " ")) \(tail)")
        } else {
            // No active sweep. Static render, no per-frame redraw.
            // Cheap CPU during long sessions when nothing's animating.
            composedTdtHiddenText(spans: spans, tail: tail, now: now)
                .font(.system(.body, design: .default, weight: .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shadow(color: colorScheme == .dark
                    ? Color.black.opacity(0.5)
                    : Color.black.opacity(0.15),
                    radius: 2, y: 1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Transcription: \(spans.map(\.text).joined(separator: " ")) \(tail)")
        }
    }

    private static func hasActiveRefineSweep(spans: [StagedTranscript.Span], now: TimeInterval) -> Bool {
        spans.contains { span in
            span.stage == .refined && span.refinementRevealStarts.contains { start in
                guard let start else { return false }
                return now < start + max(Animate.refinedSweepWordDuration, Animate.refinedPulseDuration)
            }
        }
    }

    func accentColorComponents() -> (r: Double, g: Double, b: Double) {
        let nsAccent = NSColor.controlAccentColor
        let resolvedAccent = nsAccent.usingColorSpace(.sRGB) ?? nsAccent.usingColorSpace(.deviceRGB) ?? nsAccent
        let r = resolvedAccent.numberOfComponents >= 3 ? Double(resolvedAccent.redComponent) : 0.0
        let g = resolvedAccent.numberOfComponents >= 3 ? Double(resolvedAccent.greenComponent) : 0.5
        let b = resolvedAccent.numberOfComponents >= 3 ? Double(resolvedAccent.blueComponent) : 1.0
        return (r, g, b)
    }

    private func interpolatePalette(
        colors: [(Double, Double, Double)],
        wordIndex: Int,
        now: Double
    ) -> (r: Double, g: Double, b: Double) {
        guard !colors.isEmpty else { return (0.0, 0.5, 1.0) }
        var phase = (now * 0.4 - Double(wordIndex) * 0.15).truncatingRemainder(dividingBy: 1.0)
        if phase < 0 { phase += 1.0 }
        
        let idx = phase * Double(colors.count)
        let stopIndex = Int(floor(idx)) % colors.count
        let nextIndex = (stopIndex + 1) % colors.count
        let fraction = idx - floor(idx)
        
        let c1 = colors[stopIndex]
        let c2 = colors[nextIndex]
        
        let r = c1.0 * (1.0 - fraction) + c2.0 * fraction
        let g = c1.1 * (1.0 - fraction) + c2.1 * fraction
        let b = c1.2 * (1.0 - fraction) + c2.2 * fraction
        return (r, g, b)
    }

    func refineSurgeColorComponents(wordIndex: Int, now: Double, resolvedAccent: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        if visualizerColorMode == "accent" {
            return resolvedAccent
        }
        
        // Scheme-aware: dark backgrounds get the luminous stops, the light
        // overlay gets the deeper legible variants so surging words never
        // wash out to invisible on white.
        let backend = appState.dictationFormatter.activeBackend
        switch backend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            return interpolatePalette(colors: GemmaPalette.stops(for: colorScheme), wordIndex: wordIndex, now: now)
        case .appleIntelligence, .appleIntelligenceLegacy:
            return interpolatePalette(colors: Color.appleIntelligenceStops(for: colorScheme), wordIndex: wordIndex, now: now)
        }
    }

    /// Peak strength of the Apple Intelligence tint during a word's reveal (0 none, 1 full). 0.55
    /// is visible without hurting legibility.
    private static let afmRevealBloomStrength: Double = 0.55

    /// Builds the text for the two-stage mode at a given time: refined spans sweep from gray to the
    /// primary color word by word; unrefined spans and the live tail show gray streaming text.
    func composedTdtHiddenText(
        spans: [StagedTranscript.Span],
        tail: String,
        now: TimeInterval
    ) -> Text {
        let draftOpacity: Double = {
            if appState.transcriptionService.isRecording {
                return 0.65
            } else {
                return 1.0
            }
        }()

        // Fixed sRGB colors per scheme instead of resolving Color.primary through NSColor each
        // render, which could change mid-frame and caused flicker in light mode. It also lets light
        // mode use a darker gray for contrast.
        let endpoints = Self.overlayColorEndpoints(for: colorScheme)
        let primaryColor = endpoints.primary
        let grayColor = endpoints.gray
        let grayColorValue = endpoints.grayValue
        let refinedWeight: Font.Weight = .medium
        
        // Pre-resolve system accent color components once per frame redraw
        let resolvedAccent = accentColorComponents()

        // Match the active model's palette while changed words settle.
        let styleCarriesOwnColor = refineAnimationStyle == "Crystalline"
            || refineAnimationStyle == "Magical"
            || refineAnimationStyle == "Cascade"
            || refineAnimationStyle == "Glow"
        let afmRevealBloom = !styleCarriesOwnColor
            && !reduceMotion && visualizerColorMode != "accent"

        let renderable = spans.filter { span in
            // Refined spans render their text; others render `originalEouText` when present. Empty
            // spans are skipped.
            if span.stage == .refined {
                return !span.text.isEmpty
            } else {
                return !span.originalEouText.isEmpty || !span.text.isEmpty
            }
        }
        var combined = Text("")

        let templateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
        let template = DictationFormatterService.Template(rawValue: templateRaw) ?? .standard
        let isSpecialty = template.isSpecialty

        for (idx, span) in renderable.enumerated() {
            let isLastSpan = idx == renderable.count - 1
            let needsSpaceAfterSpan = !isLastSpan || !tail.isEmpty

            if span.stage == .refined {
                let words = isSpecialty ? span.precomputedOriginalWords : span.precomputedWords
                guard !words.isEmpty else { continue }
                let perWordDuration = Animate.refinedSweepWordDuration

                for (wIdx, word) in words.enumerated() {
                    let isLastWord = wIdx == words.count - 1
                    let suffix = (isLastWord && !needsSpaceAfterSpan) ? "" : " "
                    let revealStart = !isSpecialty && span.refinementRevealStarts.indices.contains(wIdx)
                        ? span.refinementRevealStarts[wIdx] : nil
                    let progress: Double = {
                        guard let revealStart, !reduceMotion, refineAnimationStyle != "Instant" else { return 1.0 }
                        let elapsed = now - revealStart
                        if elapsed <= 0 { return 0 }
                        if refineAnimationStyle == "Instant" || refineAnimationStyle == "Pulse" { return 1.0 }
                        if elapsed >= perWordDuration { return 1 }
                        let raw = elapsed / perWordDuration
                        // Smooth-step easing for natural curve.
                        return raw * raw * (3 - 2 * raw)
                    }()
                    let wordOpacity: Double = {
                        if progress >= 1.0 { return 1.0 }
                        return draftOpacity + (1.0 - draftOpacity) * progress
                    }()
                    let clampedT = max(0, min(1, progress))
                    let inv = 1 - clampedT
                    var currentR = grayColor.r * inv + primaryColor.r * clampedT
                    var currentG = grayColor.g * inv + primaryColor.g * clampedT
                    var currentB = grayColor.b * inv + primaryColor.b * clampedT

                    // Apple Intelligence tint during reveal: strongest at the midpoint of the
                    // transition and zero at both ends, so settled words keep their normal color.
                    if afmRevealBloom, clampedT > 0, clampedT < 1 {
                        let bloom = sin(clampedT * .pi) * Self.afmRevealBloomStrength
                        let afm = refineSurgeColorComponents(wordIndex: wIdx, now: now, resolvedAccent: resolvedAccent)
                        currentR = currentR * (1 - bloom) + afm.r * bloom
                        currentG = currentG * (1 - bloom) + afm.g * bloom
                        currentB = currentB * (1 - bloom) + afm.b * bloom
                    }

                    var finalOpacity = wordOpacity
                    var wordBaselineOffset: CGFloat = 0.0
                    let weight: Font.Weight = refineAnimationStyle == "Crystalline" ? .semibold : (progress >= 1.0 ? refinedWeight : .medium)
                    
                    if let revealStart, !reduceMotion {
                        let elapsed = now - revealStart
                        let duration = Animate.refinedPulseDuration
                        
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
                                finalOpacity = 0.85 + 0.15 * pulseIntensity
                            }
                        } else if refineAnimationStyle == "Magical" {
                            if elapsed > 0 && elapsed < duration {
                                let t = elapsed / duration
                                let easeOut = 1.0 - pow(1.0 - t, 3.0)
                                wordBaselineOffset = -2.0 * (1.0 - easeOut)
                                
                                let pulseIntensity = sin(t * .pi)
                                let surgeColors = refineSurgeColorComponents(wordIndex: wIdx, now: now, resolvedAccent: resolvedAccent)
                                let surgeBlend = pulseIntensity * 0.65
                                currentR = currentR * (1.0 - surgeBlend) + surgeColors.r * surgeBlend
                                currentG = currentG * (1.0 - surgeBlend) + surgeColors.g * surgeBlend
                                currentB = currentB * (1.0 - surgeBlend) + surgeColors.b * surgeBlend
                                
                                finalOpacity *= (0.70 + 0.30 * easeOut)
                            }
                        } else if refineAnimationStyle == "Cascade" {
                            if elapsed > 0 && elapsed < duration {
                                let t = elapsed / duration
                                // Continuous sine rebound spring that starts at 0.0 and dampens to 0.0
                                wordBaselineOffset = -3.0 * sin(t * .pi * 1.5) * (1.0 - t)
                                
                                let pulseIntensity = sin(t * .pi)
                                let surgeColors = refineSurgeColorComponents(wordIndex: wIdx, now: now, resolvedAccent: resolvedAccent)
                                let surgeBlend = pulseIntensity * 0.85
                                currentR = currentR * (1.0 - surgeBlend) + surgeColors.r * surgeBlend
                                currentG = currentG * (1.0 - surgeBlend) + surgeColors.g * surgeBlend
                                currentB = currentB * (1.0 - surgeBlend) + surgeColors.b * surgeBlend
                            }
                        } else if refineAnimationStyle == "Glow" {
                            if elapsed > 0 && elapsed < duration {
                                let t = elapsed / duration
                                let pulseIntensity = sin(t * .pi)
                                wordBaselineOffset = (wIdx % 2 == 0 ? 0.3 : -0.3) * pulseIntensity
                                
                                let surgeColors = refineSurgeColorComponents(wordIndex: wIdx, now: now, resolvedAccent: resolvedAccent)
                                let surgeBlend = pulseIntensity * 0.95
                                currentR = currentR * (1.0 - surgeBlend) + surgeColors.r * surgeBlend
                                currentG = currentG * (1.0 - surgeBlend) + surgeColors.g * surgeBlend
                                currentB = currentB * (1.0 - surgeBlend) + surgeColors.b * surgeBlend
                            }
                        } else if refineAnimationStyle == "Pulse" {
                            if elapsed > 0 && elapsed < duration {
                                let t = elapsed / duration
                                let pulseIntensity = sin(t * .pi)
                                finalOpacity *= (1.0 - 0.45 * pulseIntensity)
                            }
                        }
                    }
                    
                    let surgedColor = Color(.sRGB, red: currentR, green: currentG, blue: currentB, opacity: finalOpacity)
                    let part = Text(word + suffix)
                        .font(.system(.body, design: .default, weight: weight))
                        .foregroundColor(surgedColor)
                        .baselineOffset(wordBaselineOffset)
                    combined = Text("\(combined)\(part)")
                }
            } else {
                // Not refined yet: show the gray streaming text. When no snapshot exists (streaming
                // lagged TDT at finalize, or direct mode), use a lowercased, unpunctuated version,
                // so the gray zone never shows corrected text.
                let display: String
                if !span.originalEouText.isEmpty {
                    display = span.originalEouText
                } else {
                    display = Self.eouLikeFallback(span.text)
                }
                let suffix = needsSpaceAfterSpan ? " " : ""
                let part = Text(display + suffix)
                    .font(.system(.body, design: .default, weight: refineAnimationStyle == "Crystalline" ? .semibold : .regular))
                    .foregroundColor(grayColorValue.opacity(draftOpacity))
                combined = Text("\(combined)\(part)")
            }
        }

        if !tail.isEmpty {
            let tailPart = Text(tail)
                .font(.system(.body, design: .default, weight: refineAnimationStyle == "Crystalline" ? .semibold : .regular))
                .foregroundColor(grayColorValue.opacity(draftOpacity))
            combined = Text("\(combined)\(tailPart)")
        }

        return combined
    }

    /// Lowercased, unpunctuated version of corrected text, for unrefined spans without a streaming
    /// snapshot.
    nonisolated private static func eouLikeFallback(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // Strip sentence-terminator punctuation + commas + semicolons +
        // colons, lowercase the result. Keep apostrophes (they're part
        // of contractions EOU emits) and hyphens (compound words).
        let stripped = text.filter { !".,!?;:".contains($0) }
        return stripped.lowercased()
    }

    /// Static rendering with instant stage changes. Content transitions crossfaded the whole
    /// composed text on every update and left nearly invisible frames; the animated path below
    /// changes per-word colors instead.
    @ViewBuilder
    private func staticMultiStageZStack(
        spans: [StagedTranscript.Span],
        tail: String
    ) -> some View {
        // One crisp text layer, no blur.
        composedStagedText(spans: spans, tail: tail)
            .font(.system(.body, design: .default, weight: .medium))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Shadow for legibility on the translucent overlay: stronger in dark mode, lighter in
            // light mode.
            .shadow(color: colorScheme == .dark
                ? Color.black.opacity(0.5)
                : Color.black.opacity(0.15),
                radius: 2, y: 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Transcription: \(spans.map(\.text).joined(separator: " ")) \(tail)")
    }

    /// Animated rendering driven by `TimelineView(.animation)`. Each tick advances the displayed
    /// pointer by `dt / TdtTrailAnimator.wordDuration` words toward the confirmed edge and rebuilds
    /// the text with per-word colors. The pointer keeps a constant pace: fast speech leaves a few
    /// gray words at the edge, and a pause lets everything settle. Only colors change between
    /// rebuilds, never layout, which is why this works where content transitions didn't.
    @ViewBuilder
    private func animatedMultiStageZStack(
        spans: [StagedTranscript.Span],
        tail: String
    ) -> some View {
        let staged = appState.transcriptionService.stagedTranscript
        let layout = computeDisplayWords(
            spans: spans,
            streamingTdt: staged.streamingTdtText,
            tail: tail
        )
        // 30 fps: at about 3 words a second that's 10 frames per word.
        TimelineView(.animation(minimumInterval: Animate.waveFrameRate30)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            // Stop the pointer at the edge TDT has confirmed; words beyond it are streaming-only
            // and stay gray.
            let pointer = tdtTrailAnimator.advance(
                targetWords: layout.whiteEligibleCount,
                floorWords: layout.confirmedTdtCount,
                at: now
            )
            // Words behind the pointer keep the text they had when they turned white; words ahead
            // of it keep updating. Stops the leading edge from jumping.
            let displayWords = inProgressLock.apply(
                words: layout.words,
                confirmedTdtCount: layout.confirmedTdtCount,
                pointer: pointer,
                fadeWindow: Animate.tdtTrailFadeWindow
            )
            // One layer: refined text is bold, with a short left-to-right fade when it arrives.
            composedAnimatedTextLayer(
                words: displayWords,
                pointer: pointer,
                now: now
            )
            .font(.system(.body, design: .default, weight: .medium))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: colorScheme == .dark
                ? Color.black.opacity(0.5)
                : Color.black.opacity(0.15),
                radius: 2, y: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcription: \(spans.map(\.text).joined(separator: " ")) \(tail)")
    }

    /// One `Text` from confirmed spans and the live tail. Refined spans are bold, others medium,
    /// all in the primary color.
    private func composedStagedText(
        spans: [StagedTranscript.Span],
        tail: String
    ) -> Text {
        // Same per-scheme palette as the TDT-hidden path so light-mode
        // gray reads consistently across both modes and refined text
        // lands on a deterministic primary colour.
        let endpoints = Self.overlayColorEndpoints(for: colorScheme)
        let primaryValue = Color(.sRGB, red: endpoints.primary.r, green: endpoints.primary.g, blue: endpoints.primary.b, opacity: endpoints.primary.a)
        let grayValue = endpoints.grayValue
        let templateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
        let template = DictationFormatterService.Template(rawValue: templateRaw) ?? .standard
        let isSpecialty = template.isSpecialty
        
        let renderable = spans.filter { !$0.text.isEmpty }
        var combined = Text("")
        for (idx, span) in renderable.enumerated() {
            let needsSpace = idx < renderable.count - 1 || !tail.isEmpty
            let suffix = needsSpace ? " " : ""
            let isRefined = span.stage == .refined
            let spanText = (isRefined && isSpecialty) ? span.originalText : span.text
            let part = Text(spanText + suffix)
                .font(.system(
                    .body,
                    design: .default,
                    weight: isRefined ? .bold : .medium
                ))
                .foregroundColor(primaryValue)
            combined = Text("\(combined)\(part)")
        }
        if !tail.isEmpty {
            let tailText = Text(tail)
                .font(.system(.body, design: .default, weight: .regular))
                .foregroundColor(grayValue)
            combined = Text("\(combined)\(tailText)")
        }
        return combined
    }
}
