// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

extension DictationOverlayContent {
    // MARK: Cinematic fade mask

    /// Gradient mask for cinematic mode: only the top ~6% fades to transparent.
    /// The bottom 94% is fully opaque so the user can see text receding far into
    /// the 3D perspective distance before it vanishes.
    var cinematicFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .white, location: 0.06),
                    .init(color: .white, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: Rewrite-and-finish gesture

    private func holdRing(progress: Double) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            Text(progress >= 1 ? "Release to rewrite and finish" : "Hold to rewrite and finish")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: Cleanup mode layout

    /// Shows streaming Gemma 4 inference output while the formatter refines text.
    /// Scrolling pins the latest tokens at the bottom so long inferences stay
    /// visible while older text fades off the top through the gradient mask.
    @ViewBuilder
    var cleanupModeContent: some View {
        let streamText = appState.cleanupStreamingText
        let hasContent = !streamText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let refining = appState.dictationFormatter.state == .generating

        // Header above the streaming text. The Stop button cancels refinement and keeps the raw
        // dictation, like Escape during dictation.
        HStack(spacing: Spacing.xs) {
            Image(systemName: "text.badge.checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(refining ? refineGlyphStyle : AnyShapeStyle(Color(white: colorScheme == .dark ? 0.65 : 0.42)))
                .accessibilityHidden(true)
            Text(appState.cleanupStatus)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
            if refining {
                Text("·").foregroundStyle(Color.secondary)
                Text(cleanupBackendLabel)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button {
                appState.requestCleanupCancel()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color(white: colorScheme == .dark ? 0.65 : 0.42))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop and keep text (Esc)")
            .accessibilityLabel("Stop and keep text")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

        ScrollbackContainer(height: effectiveTextHeight, resetTrigger: streamText,
                            reduceMotion: reduceMotion, expanded: overlayExpanded) {
            if hasContent {
                CleanupStreamingText(streamText: streamText, isGenerating: refining,
                                     colorScheme: colorScheme, reduceMotion: reduceMotion)
            } else {
                ListeningPlaceholder(text: appState.cleanupStatus,
                                     accessibilityText: appState.cleanupStatus, reduceMotion: reduceMotion)
            }
        }
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white.opacity(0.3), .white],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 50)
                Color.white
            }
        )

        // Wave in refine mode: a steady traveling wave in the active backend's colors, not reacting
        // to audio.
        AudioWaveVisualizer(
            audioLevel: 0,
            colorMode: visualizerColorMode,
            sensitivity: audioSensitivity,
            liquidGlass: liquidGlassMode,
            isCleanupMode: refining,
            isRefining: refining,
            refiningBackend: currentRefiningBackendPalette,
            frameRateInterval: waveFrameRateInterval,
            reduceMotion: reduceMotion
        )
        .equatable()

        // Status in place of the hint, with an animated waveform symbol rather than a spinner.
        HStack(spacing: Spacing.xs) {
            Image(systemName: "waveform")
                .symbolEffect(
                    .variableColor.iterative.dimInactiveLayers.reversing,
                    isActive: !reduceMotion
                )
                .accessibilityHidden(true)
            Text(refining ? "Refining" : "Esc to keep text")
            if slowCleanup {
                Text("·")
                    .foregroundStyle(Color.secondary.opacity(0.4))
                Text("taking a moment")
            }
        }
        .font(.system(.caption2, design: .rounded))
        .foregroundStyle(Color.secondary.opacity(0.6))
        .opacity(refiningAppeared ? 1.0 : 0.0)
        .onAppear {
            if reduceMotion {
                refiningAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    refiningAppeared = true
                }
            }
            slowCleanupTask?.cancel()
            slowCleanupTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                if !Task.isCancelled && appState.isCleaningUp {
                    withAnimation(reduceMotion ? .linear(duration: 0) : Animate.fadeQuick) {
                        slowCleanup = true
                    }
                }
            }
        }
    }



    // MARK: Standard mode layout

    /// Combines transcription text, wave visualizer, and hint text.
    @ViewBuilder
    var standardModeContent: some View {
        // Text with a fade mask, inside a scrollback container so the user can scroll to earlier
        // segments; it returns to the live edge after about 2.5 s idle.
        let maskedText = ScrollbackContainer(
            height: effectiveTextHeight,
            resetTrigger: scrollbackResetTrigger,
            reduceMotion: reduceMotion,
            expanded: overlayExpanded
        ) {
            transcriptionContent
        }
        .mask(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .white.opacity(0.3), .white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 50)
                Color.white
            }
        )

        ZStack {
            VStack(spacing: 0) {
                maskedText
                
                if appState.transcriptionService.specialtyLiveStatus != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(refineGlyphStyle)
                            .accessibilityHidden(true)
                        
                        let templateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
                        let template = DictationFormatterService.Template(rawValue: templateRaw) ?? .standard
                        let displayName = template.displayName
                        
                        Text("Formatting \(displayName)\u{2026}")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.secondary)

                        // Working indicator: the same animated waveform symbol as the refine card,
                        // still with Reduce Motion.
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(
                                .variableColor.iterative.dimInactiveLayers.reversing,
                                isActive: !reduceMotion
                            )
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
                    .padding(.bottom, 6)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                }
                
                AudioWaveVisualizer(
                    audioLevel: appState.transcriptionService.audioLevel,
                    colorMode: visualizerColorMode,
                    sensitivity: audioSensitivity,
                    liquidGlass: liquidGlassMode,
                    isRefining: appState.dictationFormatter.state == .generating,
                    isWarmingUp: isWarmingUp,
                    refiningBackend: currentRefiningBackendPalette,
                    frameRateInterval: waveFrameRateInterval,
                    reduceMotion: reduceMotion
                )
                .equatable()

                if appState.hotkeyManager.holdProgress == nil {
                    hintTextView
                } else {
                    hintTextView.opacity(0)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.76), value: appState.transcriptionService.specialtyLiveStatus != nil)

            if let progress = appState.hotkeyManager.holdProgress {
                holdRing(progress: progress)
            }
        }
    }

    // MARK: Standard text content

    /// Startup chip: the breathing wave with one short caption. A cold first start can take a while
    /// on slower Macs, so after 5 s the caption explains that the speech models are being compiled.
    @ViewBuilder
    var preReadyContent: some View {
        VStack(spacing: Spacing.sm) {
            AudioWaveVisualizer(
                audioLevel: 0.0,
                colorMode: "rainbow",
                sensitivity: 0.5,
                liquidGlass: liquidGlassMode,
                isIdleBreathing: true,
                reduceMotion: reduceMotion
            )
            .frame(height: 34)
            .accessibilityHidden(true)

            Text(warmupIsSlow
                 ? "Compiling speech models for Apple Silicon. The first start can take a minute."
                 : "Ready to speak in a moment\u{2026}")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: warmupIsSlow)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SideWave is getting ready")
        .accessibilityValue(warmupIsSlow
            ? "Compiling speech models. The first start can take a minute."
            : "Ready to speak in a moment")
        .task {
            // Attached to the chip itself: cancelled automatically when the
            // engines come up, reset for the next session via onDisappear.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            warmupIsSlow = true
        }
        .onDisappear { warmupIsSlow = false }
    }

    @ViewBuilder
    var transcriptionContent: some View {
        // Follow the running pipeline, including its single-engine fallback.
        Group {
            if appState.transcriptionService.usesStagedPreview {
                multiStageTranscriptionContent
            } else {
                legacyTranscriptionContent
            }
        }
    }

    @ViewBuilder
    private var legacyTranscriptionContent: some View {
        let service = appState.transcriptionService
        if service.confirmedText.isEmpty && service.volatileText.isEmpty {
            ListeningPlaceholder(reduceMotion: reduceMotion)
        } else {
            RecognitionPreview(confirmed: service.confirmedText, draft: service.volatileText,
                               reduceMotion: reduceMotion)
        }
    }

    // MARK: Cinematic text mode

    /// Cinematic crawl: text scrolls upward at a constant speed driven by TimelineView. New text
    /// joins at the bottom, below the visible area, and drifts into view.
    @ViewBuilder
    private func cinematicCrawlBody(crawlYellow: Color) -> some View {
        let crawlYellowDim = Color(red: 0.85, green: 0.68, blue: 0.0)
        // The visible height, so text can start below the viewport.
        GeometryReader { geo in
            let viewportHeight = geo.size.height

            TimelineView(.animation(minimumInterval: Animate.waveFrameRate30)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(crawlStartDate) - crawlDelay)
                let maxScroll = max(viewportHeight, crawlContentHeight)
                let scrollOffset = min(CGFloat(elapsed) * crawlSpeed, maxScroll)

                VStack(alignment: .center, spacing: Spacing.xs) {
                    // Confirmed (or pseudo-confirmed) lines -- full opacity,
                    // no progressive fade since the 3D perspective + gradient
                    // mask already create the depth illusion.
                    ForEach(rollingWindow.confirmedLines, id: \.id) { line in
                        Text(line.text)
                            .font(.system(.title2, design: .default, weight: .bold))
                            .foregroundStyle(crawlYellow)
                            .shadow(color: crawlYellowDim.opacity(0.4), radius: 8, y: 2)
                            .shadow(color: Color.black.opacity(0.7), radius: 4, y: 1)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Volatile (in-progress) text -- slightly dimmer
                    if !rollingWindow.volatileText.isEmpty {
                        Text(rollingWindow.volatileText)
                            .font(.system(.title2, design: .default, weight: .bold))
                            .foregroundStyle(crawlYellow.opacity(0.65))
                            .shadow(color: crawlYellowDim.opacity(0.3), radius: 6, y: 1)
                            .shadow(color: Color.black.opacity(0.5), radius: 3, y: 1)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
                    }
                )
                .onPreferenceChange(HeightPreferenceKey.self) { height in
                    crawlContentHeight = height
                }
                // Start the text VStack with its top edge at the bottom of
                // the viewport. As scrollOffset grows, text drifts upward.
                .offset(y: viewportHeight - scrollOffset)
            }
        }
    }

    @ViewBuilder
    var cinematicTranscriptionContent: some View {
        let hasContent = !rollingWindow.confirmedLines.isEmpty || !rollingWindow.volatileText.isEmpty
        let crawlYellow = Color(red: 1.0, green: 0.82, blue: 0.0)

        Group {
            if reduceMotion {
                if !hasContent {
                    ListeningPlaceholder(
                        font: .system(.title2, design: .default, weight: .bold),
                        color: crawlYellow,
                        alignment: .center,
                        restOpacity: 0.35,
                        reduceMotion: reduceMotion
                    )
                } else {
                    cinematicCrawlBody(crawlYellow: crawlYellow)
                }
            } else {
                ZStack(alignment: .center) {
                    ListeningPlaceholder(
                        font: .system(.title2, design: .default, weight: .bold),
                        color: crawlYellow,
                        alignment: .center,
                        restOpacity: 0.35,
                        reduceMotion: reduceMotion
                    )
                    .opacity(hasContent ? 0.0 : 1.0)
                    .allowsHitTesting(!hasContent)

                    cinematicCrawlBody(crawlYellow: crawlYellow)
                        .opacity(hasContent ? 1.0 : 0.0)
                        .allowsHitTesting(hasContent)
                }
                .animation(.easeInOut(duration: 0.25), value: hasContent)
            }
        }
    }
}
