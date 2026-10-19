// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

// MARK: - Overlay SwiftUI Content

struct DictationOverlayContent: View {
    struct TextRenderSample {
        let spans: [StagedTranscript.Span]
        let tail: String
        let time: TimeInterval
    }
    var textRenderSample: TextRenderSample? = nil
    var appState: AppState
    var embeddedTranscript = false
    @State private var embeddedWidth: CGFloat = 600
    @State private var overlayViewportSize = DictationOverlayController.collapsedSize
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openWindow) var openWindow
    @AppStorage("overlaySize") private var overlaySizeRaw: String = OverlaySize.standard.rawValue
    @AppStorage("customOverlayWidth") private var customOverlayWidth: Double = 500
    /// Expanded overlay: about 1.45 times wider and 1.6 times taller, within the panel's 740 by 350
    /// frame, anchored at the bottom. Saved across launches; toggled with the corner button or the
    /// context menu.
    @AppStorage("overlayExpanded") var overlayExpanded: Bool = false
    @AppStorage("visualizerColorMode") var visualizerColorMode: String = "rainbow"
    @AppStorage("liquidGlassMode") var liquidGlassMode: Bool = true
    @AppStorage("audioSensitivity") var audioSensitivity: Double = 0.7
    @AppStorage("dictationTargetMode") private var dictationTargetMode: String = DictationTargetMode.focusedWindow.rawValue
    @AppStorage("textDisplayMode") private var textDisplayMode: String = "standard"
    @AppStorage("appearance") private var appearance: String = "system"
    @AppStorage("waveFrameRate") private var waveFrameRate: String = "30"
    /// Fades each word from gray to the primary color left to right as TDT confirms it. Off by
    /// default; Reduce Motion uses the static path.
    @AppStorage("perWordTransitionAnimation") var perWordTransitionAnimation: Bool = false
    /// Two-stage rendering: the gray streaming text stays visible while TDT runs only in the
    /// background (still feeding vocabulary, capitalization, and punctuation to Refine), and
    /// refined spans replace the gray with a left-to-right sweep. Avoids the per-word gray-to-TDT
    /// swap, which made text jump. Takes precedence over `perWordTransitionAnimation`.
    @AppStorage("tdtHiddenRefineSweep") var tdtHiddenRefineSweep: Bool = false
    /// ASR-only sessions share the neutral draft-to-confirmed preview.
    @AppStorage("skipRefine") var skipRefine: Bool = false
    @AppStorage("refineAnimationStyle") var refineAnimationStyle: String = "Sweep"
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }

    var waveFrameRateInterval: TimeInterval {
        waveFrameRate == "60" ? Animate.waveFrameRate60 : Animate.waveFrameRate30
    }

    @State var rollingWindow = RollingWindowState()
    @State var cachedRunningApps: [RunningAppInfo] = []

    /// Moves a displayed pointer toward the live edge at a fixed pace (about 280 ms per word),
    /// independent of segment timing. A reference type, so pointer updates don't trigger SwiftUI
    /// updates; `TimelineView` drives the redraw.
    @State var tdtTrailAnimator = TdtTrailAnimator()

    /// Freezes in-progress words the pointer has already swept white so the
    /// leading edge stops jumping when EOU/TDT churn behind the pointer.
    /// Same `@State` reference-type pattern as `tdtTrailAnimator`.
    @State var inProgressLock = InProgressTextLock()

    /// Static prompt length, recomputed only when the settings fingerprint changes.
    @State var cachedStaticPromptChars: Int = 0
    @State var cachedStaticPromptFingerprint: Int = 0

    /// Apple Intelligence context size, cached per backend because
    /// `SystemLanguageModel.contextSize` queries the system model each call and the overlay redraws
    /// often during dictation. Refreshed on backend change and when the app becomes active. Gemma
    /// uses the fixed `Backend.contextCap`.
    @State var cachedAFMContextCap: Int = 4096

    // Cleanup mode transient state
    @State var refiningAppeared: Bool = false
    @State private var isRefiningPulsing: Bool = false
    @State private var holdPulse: Bool = false
    /// Flips after 5s of continuous warm-up so the subtitle can explain the
    /// cold-start model compile instead of promising "in a moment" forever.
    @State var warmupIsSlow: Bool = false
    @State var slowCleanup: Bool = false
    @State var slowCleanupTask: Task<Void, Never>? = nil

    // Cinematic crawl scroll state
    @State var crawlStartDate: Date = .now
    /// Points per second the crawl text drifts upward (slow, majestic pace)
    let crawlSpeed: CGFloat = 6
    /// Seconds to wait before the crawl scroll begins (text queues off-screen)
    let crawlDelay: TimeInterval = 4.0
    @State var crawlContentHeight: CGFloat = 0

    private var overlaySize: OverlaySize {
        OverlaySize.from(rawValue: overlaySizeRaw)
    }

    var isCinematic: Bool {
        !embeddedTranscript && textDisplayMode == "cinematic" && !reduceMotion
    }

    /// True while the audio engine is initializing or the EOU actor is loading.
    /// Buffering captures words immediately in the background, but the UI shows
    /// a premium "Initializing..." state until all models are warm.
    var isWarmingUp: Bool {
        appState.dictationSessionPhase == .preparing
    }

    /// True from the hotkey press until every engine is ready. The full overlay waits for the
    /// engines, so its appearance is the signal to start talking. Uses hotkeyManager.isRecording so
    /// the stop drain can't bring the chip back.
    private var isPreReady: Bool {
        isWarmingUp && appState.hotkeyManager.isRecording
    }

    /// The active backend as a wave palette. Apple Intelligence is the default.
    var currentRefiningBackendPalette: RefiningBackendForPalette {
        switch appState.dictationFormatter.activeBackend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B: return .gemma
        case .appleIntelligence, .appleIntelligenceLegacy: return .appleIntelligence
        }
    }

    /// Expanded content dimensions, further limited by the actual panel size.
    private static let expandedWidth: CGFloat = 740
    private static let expandedTextHeight: CGFloat = 980

    /// Width of the compact pre-ready chip while the engines warm. Small on
    /// purpose: the chip reads as its own little window, and the card
    /// blooming out to the full overlay width is the ready transition.
    private static let preReadyWidth: CGFloat = 330

    /// Width during dictation: the custom width, the expanded width, or the cinematic minimum.
    /// Separate from `effectiveWidth` so wrapping is sized for the real overlay, not the startup
    /// chip.
    private var fullOverlayWidth: CGFloat {
        if embeddedTranscript { return embeddedWidth }
        let baseWidth = CGFloat(customOverlayWidth)
        let requested = isCinematic ? max(baseWidth, 560) : overlayExpanded ? Self.expandedWidth : baseWidth
        return min(requested, max(1, overlayViewportSize.width - 40))
    }

    /// Effective width: the compact chip while pre-ready, the real overlay
    /// width once the engines are live. The width change animates via the
    /// existing appleSnappy animation keyed on this value.
    private var effectiveWidth: CGFloat {
        isPreReady ? Self.preReadyWidth : fullOverlayWidth
    }

    /// Text height: taller for cinematic mode, and filling the panel when expanded.
    var effectiveTextHeight: CGFloat {
        if isCinematic { return overlaySize.cinematicMaxTextHeight }
        if overlayExpanded {
            return min(Self.expandedTextHeight, max(80, overlayViewportSize.height - 120))
        }
        return overlaySize.maxTextHeight
    }

    /// Effective max lines: cinematic shows more history.
    private var effectiveMaxLines: Int {
        if embeddedTranscript { return 24 }
        return isCinematic ? overlaySize.cinematicMaxLines : overlaySize.maxLines
    }

    /// Subtitle shown in the cleanup-mode header. U+00B7 middle dot matches
    /// the spacing pattern used by the standard hintTextView.
    var cleanupBackendLabel: String {
        "On-device · \(appState.cleanupBackendDisplayName)"
    }

    /// Changes whenever the transcript changes, so ScrollbackContainer knows to return to the live
    /// edge. Covers both rendering paths.
    var scrollbackResetTrigger: AnyHashable {
        let staged = appState.transcriptionService.stagedTranscript
        var hasher = Hasher()
        hasher.combine(staged.confirmedSpans.count)
        hasher.combine(staged.confirmedSpans.last?.text ?? "")
        hasher.combine(staged.liveEouTail)
        hasher.combine(rollingWindow.confirmedLines.count)
        hasher.combine(rollingWindow.confirmedLines.last?.text ?? "")
        hasher.combine(rollingWindow.volatileText)
        return hasher.finalize()
    }

    /// Characters per line for the dictation-time width (body text averages about 8.5 pt per
    /// character, minus 40 pt of padding). Uses fullOverlayWidth so the startup chip doesn't set
    /// it.
    private var effectiveWrapCharLimit: Int {
        let availableWidth = fullOverlayWidth - 40
        return max(30, Int(availableWidth / 8.5))
    }

    var body: some View {
        if let sample = textRenderSample {
            composedTdtHiddenText(spans: sample.spans, tail: sample.tail, now: sample.time)
        } else if embeddedTranscript {
            documentTranscript
        } else {
            overlayBody
        }
    }

    /// Reuse the live overlay's staged text and motion without a second window or its controls.
    private var documentTranscript: some View {
        GeometryReader { geometry in
            ScrollbackContainer(height: geometry.size.height, resetTrigger: scrollbackResetTrigger,
                                reduceMotion: reduceMotion, expanded: true, growsFromTop: true) {
                transcriptionContent
            }
            .onAppear {
                embeddedWidth = geometry.size.width
                rollingWindow.maxLines = effectiveMaxLines
                rollingWindow.wrapCharLimit = max(30, Int((geometry.size.width - 40) / 8.5))
                updateEmbeddedTranscript()
            }
            .onChange(of: geometry.size.width) { _, width in
                embeddedWidth = width
                rollingWindow.wrapCharLimit = max(30, Int((width - 40) / 8.5))
                updateEmbeddedTranscript()
            }
            .onChange(of: appState.transcriptionService.confirmedText) { updateEmbeddedTranscript() }
            .onChange(of: appState.transcriptionService.volatileText) { updateEmbeddedTranscript() }
            .onDisappear { rollingWindow.reset() }
        }
        .accessibilityIdentifier("document-live-transcript")
    }

    private func updateEmbeddedTranscript() {
        rollingWindow.update(confirmed: appState.transcriptionService.confirmedText,
                             volatile: appState.transcriptionService.volatileText)
    }

    private var overlayBody: some View {
        ZStack {
            if !appState.overlayMessage.isEmpty {
                // Status message (model not ready, etc.)
                Text(appState.overlayMessage)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(isCinematic ? .white.opacity(0.6) : .secondary)
                    .multilineTextAlignment(.center)
                    .transition(reduceMotion ? .identity : .opacity)
            } else if appState.isCleaningUp {
                // AI cleanup mode: stream Gemma 4 inference output with refining status
                VStack(spacing: Spacing.md) {
                    cleanupModeContent
                }
                .transition(reduceMotion ? .identity : .opacity)
            } else if isPreReady {
                // While engines warm up, a small chip with the breathing wave holds the space. When
                // they're ready the card expands to full width, which is the ready signal.
                preReadyContent
                    .transition(reduceMotion ? .identity : .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94)),
                        removal: .opacity.combined(with: .scale(scale: 1.06))
                    ))
            } else {
                VStack(spacing: Spacing.xs) {
                    // Target app indicator (assigned mode only)
                    if dictationTargetMode == DictationTargetMode.assignedWindow.rawValue {
                        targetPickerRow
                    }

                    if isCinematic {
                        // Cinematic perspective crawl: strong 3D perspective, center-aligned,
                        // bottom-anchored scroll, dramatic gradient fade at top
                        cinematicTranscriptionContent
                            .frame(height: effectiveTextHeight, alignment: .bottom)
                            .clipped()
                            .mask(cinematicFadeMask)
                            .rotation3DEffect(
                                .degrees(45),
                                axis: (x: 1, y: 0, z: 0),
                                anchor: .bottom,
                                perspective: 0.6
                            )

                        // Wave visualizer: muted in cinematic mode
                        AudioWaveVisualizer(
                            audioLevel: appState.transcriptionService.audioLevel,
                            colorMode: "cinematic",
                            sensitivity: audioSensitivity,
                            liquidGlass: liquidGlassMode,
                            isWarmingUp: isWarmingUp,
                            frameRateInterval: waveFrameRateInterval,
                            reduceMotion: reduceMotion
                        )
                        .equatable()
                        .opacity(0.5)

                        hintTextView
                    } else {
                        // Standard mode: text + wave + hint (with glass container when applicable)
                        standardModeContent
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.lg)
        .frame(width: effectiveWidth)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : Animate.appleSnappy, value: isPreReady)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: appState.isCleaningUp)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: appState.overlayMessage)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { value in
            DictationOverlayController.shared.drag(start: value.startLocation, location: value.location)
        }.onEnded { _ in
            DictationOverlayController.shared.rememberUserPosition()
        }, isEnabled: !appState.overlayPositionLocked)
        .allowsWindowActivationEvents(true)
        .contextMenu {
            Section("Size") {
                ForEach(OverlaySize.allCases) { size in
                    Button {
                        overlaySizeRaw = size.rawValue
                        customOverlayWidth = Double(size.width)
                    } label: {
                        HStack {
                            Text(size.rawValue)
                            if overlaySize == size {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
            Button(overlayExpanded ? "Restore Size" : "Expand Overlay") {
                if reduceMotion {
                    overlayExpanded.toggle()
                } else {
                    withAnimation(Animate.appleSnappy) {
                        overlayExpanded.toggle()
                    }
                }
            }
            Button(appState.overlayPositionLocked ? "Unlock Position" : "Lock Position") {
                appState.overlayPositionLocked.toggle()
                DictationOverlayController.shared.setMovable(!appState.overlayPositionLocked)
            }
            Button("Reset Position") {
                DictationOverlayController.shared.resetPosition()
            }
        }
        .overlayBackground(isCinematic: isCinematic, colorScheme: colorScheme, liquidGlassEnabled: liquidGlassMode, reduceMotion: reduceMotion)
        // Expand and collapse button in the top-trailing corner: faint until hovered. Hidden in
        // cinematic mode. The panel frame change animates the growth.
        .overlay(alignment: .topTrailing) {
            // Hidden on the pre-ready chip; there is nothing to expand yet,
            // and the chip should carry zero chrome.
            if !isCinematic && !isPreReady {
                ExpandToggleButton(
                    isExpanded: $overlayExpanded,
                    reduceMotion: reduceMotion
                )
                .padding(.top, 6)
                .padding(.trailing, 6)
                .accessibilityIdentifier("overlayExpandToggle")
            }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            // Debug-only build tag in the top-leading corner, to tell which build drives the
            // overlay.
            if AppPaths.showsDebugLabels {
                Text(SideWaveApp.appVersion)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(isCinematic ? Color.white.opacity(0.35) : Color.secondary.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .accessibilityHidden(true)
            }
        }
        #endif
        // Keep the visible card at the panel's bottom in every session phase.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { overlayViewportSize = $0 }
        .animation(reduceMotion ? nil : Animate.appleSnappy, value: overlayExpanded)
        .animation(reduceMotion ? nil : Animate.appleSnappy, value: effectiveWidth)
        .animation(reduceMotion ? nil : Animate.appleSnappy, value: effectiveTextHeight)
        .onChange(of: overlayExpanded) { _, newValue in
            // Resize the panel itself, not only the card inside it. Cinematic mode manages its own
            // size.
            guard !isCinematic else { return }
            DictationOverlayController.shared.setExpanded(newValue, animated: !reduceMotion)
        }
        .onAppear {
            rollingWindow.maxLines = effectiveMaxLines
            rollingWindow.wrapCharLimit = effectiveWrapCharLimit
            cachedRunningApps = AppState.runningApps()
            crawlStartDate = .now
            refreshStaticPromptCache()
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isRefiningPulsing = true
                }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    holdPulse = true
                }
            } else {
                holdPulse = true
            }
        }
        .task(id: staticPromptFingerprint) {
            refreshStaticPromptCache()
        }
        // Refresh the Apple Intelligence context size when the backend changes, never per render.
        .task(id: appState.dictationFormatter.activeBackend) {
            if appState.dictationFormatter.activeBackend == .appleIntelligence ||
               appState.dictationFormatter.activeBackend == .appleIntelligenceLegacy {
                cachedAFMContextCap = DictationFormatterService.afmContextSize()
            }
        }
        .onDisappear {
            rollingWindow.reset()
        }
        .onChange(of: overlaySizeRaw) {
            rollingWindow.maxLines = effectiveMaxLines
            rollingWindow.wrapCharLimit = effectiveWrapCharLimit
        }
        .onChange(of: customOverlayWidth) {
            rollingWindow.wrapCharLimit = effectiveWrapCharLimit
        }
        .onChange(of: textDisplayMode) {
            rollingWindow.maxLines = effectiveMaxLines
            rollingWindow.wrapCharLimit = effectiveWrapCharLimit
            crawlStartDate = .now
        }
        // Reset rolling window when overlay visibility toggles.
        // onAppear/onDisappear are unreliable for a reused NSPanel,
        // so also watch the overlay visibility flag directly.
        .onChange(of: appState.isOverlayVisible) {
            if appState.isOverlayVisible {
                rollingWindow.reset()
                rollingWindow.maxLines = effectiveMaxLines
                rollingWindow.wrapCharLimit = effectiveWrapCharLimit
                cachedRunningApps = AppState.runningApps()
                crawlStartDate = .now // reset cinematic crawl for each dictation
            } else {
                // Clean up accumulated text state when overlay hides
                rollingWindow.reset()
            }
        }
        .onChange(of: appState.transcriptionService.confirmedText) {
            rollingWindow.update(
                confirmed: appState.transcriptionService.confirmedText,
                volatile: appState.transcriptionService.volatileText
            )
        }
        .onChange(of: appState.transcriptionService.volatileText) {
            rollingWindow.update(
                confirmed: appState.transcriptionService.confirmedText,
                volatile: appState.transcriptionService.volatileText
            )
        }
        .onChange(of: appState.isCleaningUp) { _, nowCleaning in
            // Reset cleanup-mode transient state on every entry/exit so the
            // pop-out fires again next cleanup and the slow indicator starts
            // counting from zero.
            if !nowCleaning {
                slowCleanupTask?.cancel()
                slowCleanupTask = nil
                refiningAppeared = false
                slowCleanup = false
            }
        }
        // Apply user's appearance preference so the SwiftUI overlay content
        // matches the main window. The NSPanel's AppKit appearance is synced
        // separately by the DictationOverlayController's appearance observer.
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .onChange(of: appState.showSpecialtyPreview) {
            if appState.showSpecialtyPreview {
                DispatchQueue.main.async {
                    openWindow(id: "specialty-preview")
                    appState.showSpecialtyPreview = false
                }
            }
        }
    }

}

struct HeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// "Listening…" placeholder with a soft opacity pulse, so waiting for the first word doesn't look
/// stalled next to the animated warm-up state. Keeps its own state so it animates whenever it
/// appears. Static with Reduce Motion.
struct ListeningPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    /// The wait-state label. Defaults to the "Listening…" recording placeholder;
    /// the cleanup wait-state passes "Refining…" so every empty/wait state in
    /// the overlay shares the same breath instead of one being a dead label.
    var text: String = "Listening\u{2026}"
    var accessibilityText: String = "Waiting for speech input"
    var font: Font = .system(.body, design: .default, weight: .medium)
    var color: Color? = nil
    var alignment: Alignment = .leading
    /// Resting tone the breath oscillates around (matches each mode's prior
    /// static opacity). The breath spans roughly ±20% of this value.
    var restOpacity: Double = 0.85
    let reduceMotion: Bool
    @State private var breathe = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color ?? Color(white: colorScheme == .dark ? 0.75 : 0.32))
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .opacity(reduceMotion
                ? restOpacity
                : (breathe ? restOpacity * 0.8 : min(1.0, restOpacity * 1.24)))
            .frame(maxWidth: .infinity, alignment: alignment)
            .transition(.opacity)
            .accessibilityLabel(accessibilityText)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}

