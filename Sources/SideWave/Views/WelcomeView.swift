// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// SideWave's quiet signature waveform.
struct AnimatedBrandStrip: View {
    var reduceMotion = false
    var body: some View {
        AudioWaveVisualizer(
            audioLevel: 0.0,
            colorMode: "rainbow",
            sensitivity: 0.5,
            liquidGlass: false,
            isIdleBreathing: true,
            reduceMotion: reduceMotion
        )
        .accessibilityHidden(true)
        .frame(height: 32)
    }
}

/// First-run setup. The spectrum colors appear only in the wave at the bottom of the main card;
/// everything else uses system colors. Layouts are compact, with scrolling as a fallback so the
/// permission buttons stay reachable with long download details or larger text.
struct WelcomeView: View {
    @Bindable var appState: AppState

    @State private var appIconDark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "sidewave_icon_dark", withExtension: "png", subdirectory: "AppIcon.icon/Assets") else { return nil }
        let img = NSImage(contentsOf: url)
        img?.size = NSSize(width: 256, height: 256)
        return img
    }()

    @State private var appIconLight: NSImage? = {
        guard let url = Bundle.main.url(forResource: "sidewave_icon_light", withExtension: "png", subdirectory: "AppIcon.icon/Assets") else { return nil }
        let img = NSImage(contentsOf: url)
        img?.size = NSSize(width: 256, height: 256)
        return img
    }()

    private var currentAppIcon: NSImage {
        let isDark = colorScheme == .dark
        if isDark {
            return appIconDark ?? fallbackIcon
        } else {
            return appIconLight ?? fallbackIcon
        }
    }

    private var fallbackIcon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        img.size = NSSize(width: 256, height: 256)
        return img
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }

    // MARK: - Derived state

    private var isAccessibilityGranted: Bool { appState.isAccessibilityGranted }
    private var areSpeechModelsReady: Bool { appState.transcriptionService.modelState.isReady }

    private var isRefineReady: Bool {
        switch appState.dictationFormatter.state {
        case .ready, .generating: return true
        case .error, .unavailable, .downloading, .loading: return false
        case .disabled, .unloaded:
            let backend = DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend) ?? .gemma4E2B
            return DictationFormatterService.isGemmaBackendCached(backend)
        }
    }

    private var allComplete: Bool {
        isAccessibilityGranted && areSpeechModelsReady && appState.microphonePermission == .granted
    }

    private var stepsRemaining: Int {
        var count = 0
        if !isAccessibilityGranted { count += 1 }
        if !areSpeechModelsReady { count += 1 }
        if appState.microphonePermission != .granted { count += 1 }
        return count
    }

    private var statusText: String {
        if allComplete { return "Setup complete" }
        if stepsRemaining == 1 { return "1 step remaining" }
        return "\(stepsRemaining) steps remaining"
    }

    // MARK: - Body

    var body: some View {
        ViewThatFits(in: .vertical) {
            // Full layout at the default window size.
            layout(
                heroSize: 76,
                titleFont: .system(size: 32, weight: .bold, design: .rounded),
                preheaderFont: .system(.body, design: .rounded, weight: .semibold),
                taglineFont: .subheadline,
                showWelcomePreheader: true,
                showHeroTagline: true,
                showBrandStrip: true,
                spacing: Spacing.md,
                paddingTop: Spacing.md,
                paddingBottom: Spacing.lg
            )

            // Tier 2: Standard Layout
            layout(
                heroSize: 64,
                titleFont: .system(size: 26, weight: .bold, design: .rounded),
                preheaderFont: .system(.caption, design: .rounded, weight: .semibold),
                taglineFont: .caption,
                showWelcomePreheader: true,
                showHeroTagline: true,
                showBrandStrip: true,
                spacing: Spacing.sm,
                paddingTop: Spacing.sm,
                paddingBottom: Spacing.md
            )

            // Tier 3: Compact Layout (Tagline Hidden)
            layout(
                heroSize: 52,
                titleFont: .system(size: 22, weight: .bold, design: .rounded),
                preheaderFont: .system(.caption, design: .rounded, weight: .semibold),
                taglineFont: nil,
                showWelcomePreheader: false,
                showHeroTagline: false,
                showBrandStrip: true,
                spacing: Spacing.sm,
                paddingTop: Spacing.xs,
                paddingBottom: Spacing.sm
            )

            // Tier 4: Ultra-Compact Layout (No tagline or brand strip)
            layout(
                heroSize: 40,
                titleFont: .system(size: 18, weight: .bold, design: .rounded),
                preheaderFont: nil,
                taglineFont: nil,
                showWelcomePreheader: false,
                showHeroTagline: false,
                showBrandStrip: false,
                spacing: Spacing.xs,
                paddingTop: Spacing.xxs,
                paddingBottom: Spacing.xs
            )
            ScrollView {
                layout(
                    heroSize: 40,
                    titleFont: .system(size: 22, weight: .bold, design: .rounded),
                    preheaderFont: nil,
                    taglineFont: nil,
                    showWelcomePreheader: false,
                    showHeroTagline: false,
                    showBrandStrip: false,
                    spacing: Spacing.sm,
                    paddingTop: Spacing.sm,
                    paddingBottom: Spacing.md
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .softScrollEdge()
        .onAppear {
            guard !AppPaths.isTestHost else { return }
            appState.refreshMicrophonePermission()
            appState.transcriptionService.checkModelCache()
        }
    }

    /// Layout variant. Variations differ in spacing, hero icon size,
    /// typography visibility, and spacing; the cards in the middle
    /// are identical so progress bars / step indicators read the same.
    private func layout(
        heroSize: CGFloat,
        titleFont: Font,
        preheaderFont: Font?,
        taglineFont: Font?,
        showWelcomePreheader: Bool,
        showHeroTagline: Bool,
        showBrandStrip: Bool,
        spacing: CGFloat,
        paddingTop: CGFloat,
        paddingBottom: CGFloat
    ) -> some View {
        VStack(spacing: spacing) {
            heroSection(
                iconSize: heroSize,
                titleFont: titleFont,
                preheaderFont: preheaderFont,
                taglineFont: taglineFont,
                showPreheader: showWelcomePreheader,
                showTagline: showHeroTagline,
                showBrandStrip: showBrandStrip
            )
            statusLine
            accessibilityCard
            modelsCard
            microphoneAccessCard
            microphonePreferenceCard
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, paddingTop)
        .padding(.bottom, paddingBottom)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Hero

    private func heroSection(
        iconSize: CGFloat,
        titleFont: Font,
        preheaderFont: Font?,
        taglineFont: Font?,
        showPreheader: Bool,
        showTagline: Bool,
        showBrandStrip: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(nsImage: currentAppIcon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.08),
                        radius: 4, y: 2
                    )
                    .animation(reduceMotion ? nil : Animate.standard, value: iconSize)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text("SideWave")
                            .font(titleFont)
                            .tracking(-0.3)

                        if showPreheader, let preFont = preheaderFont {
                            Text("Setup")
                                .font(preFont)
                                .foregroundStyle(.tertiary)
                                .tracking(1.0)
                                .textCase(.uppercase)
                        }
                    }

                    if showTagline, let tagFont = taglineFont {
                        Text("On-device, privacy-first dictation for macOS.")
                            .font(tagFont)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            if showBrandStrip {
                AnimatedBrandStrip(reduceMotion: reduceMotion)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack {
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .id(statusText)
            Spacer()
        }
        .padding(.horizontal, Spacing.xxs)
    }

    // MARK: - Accessibility step

    private var accessibilityCard: some View {
        Group {
            if isAccessibilityGranted {
                CompletedStepRow(stepNumber: 1, title: "Accessibility access granted", state: .complete)
                    .transition(.opacity)
            } else {
                ActiveAccessibilityCard()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Animate.standard, value: isAccessibilityGranted)
    }

    // MARK: - Models step

    private var modelsCard: some View {
        Group {
            if areSpeechModelsReady && (!appState.dictationCleanupEnabled || isRefineReady)
                && appState.transcriptionService.auxiliaryModelErrors.isEmpty {
                CompletedStepRow(stepNumber: 2, title: "Dictation models ready", state: .complete)
                    .transition(.opacity)
            } else {
                ActiveModelsCard(appState: appState)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Animate.standard, value: areSpeechModelsReady)
        .animation(reduceMotion ? nil : Animate.standard, value: isRefineReady)
       }

    private var microphoneAccessCard: some View {
        Group {
            if appState.microphonePermission == .granted {
                CompletedStepRow(stepNumber: 3, title: "Microphone access granted", state: .complete)
            } else {
                MicrophonePermissionSetupCard(
                    isUndetermined: appState.microphonePermission == .undetermined,
                    isRequesting: appState.isRequestingMicrophoneAccess,
                    requestAccess: { Task { await appState.requestMicrophoneAccess() } }
                )
            }
        }
    }

    // MARK: - Microphone preference

    /// Microphone picker for first launch, shown only with more than one input. Choosing a
    /// non-Bluetooth device puts it first in the priority list, so it stays selected when AirPods
    /// reconnect. Choosing Bluetooth shows a short warning without blocking the choice.
    @ViewBuilder
    private var microphonePreferenceCard: some View {
        if appState.audioDeviceManager.availableDevices.count > 1 {
            let resolvedIsBluetooth: Bool = {
                let mgr = appState.audioDeviceManager
                if let uid = mgr.selectedDeviceUID,
                   let device = mgr.availableDevices.first(where: { $0.uid == uid }) {
                    return device.isBluetooth
                }
                return mgr.resolvedDefaultDevice?.isBluetooth ?? false
            }()
            let resolvedName = appState.audioDeviceManager.selectedDevice?.name
                ?? appState.audioDeviceManager.resolvedDefaultDevice?.name ?? "No microphone connected"

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.md) {
                    SetupBadge(style: .icon("mic.fill"), state: .active)

                    Text("Microphone")
                        .font(.callout.weight(.medium))

                    Spacer()

                    WorkspaceMenu(value: appState.audioDeviceManager.selectedDeviceUID == nil ? "System Default" : resolvedName) {
                        Picker("Microphone", selection: Binding(
                            get: { appState.audioDeviceManager.selectedDeviceUID ?? "__system_default__" },
                            set: { newValue in
                                let uid = (newValue == "__system_default__") ? nil : newValue
                                appState.audioDeviceManager.userDidSelectDevice(uid)
                                // Promote a non-BT pick to priority #1 so the
                                // auto-switch override knows what to favor.
                                if let uid,
                                   let device = appState.audioDeviceManager.availableDevices.first(where: { $0.uid == uid }),
                                   !device.isBluetooth
                                {
                                    var prio = AudioDeviceManager.audioInputPriorityUIDs()
                                    prio.removeAll(where: { $0 == uid })
                                    prio.insert(uid, at: 0)
                                    AudioDeviceManager.setAudioInputPriorityUIDs(prio)
                                }
                            }
                        )) {
                            Text("System Default").tag("__system_default__")
                            ForEach(appState.audioDeviceManager.availableDevices) { device in
                                Text(device.pickerLabel(includeDefault: false)).tag(device.uid)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    .frame(maxWidth: 260, alignment: .trailing)
                    .accessibilityLabel("Microphone input device")
                }

                Text(resolvedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if resolvedIsBluetooth {
                    HStack(alignment: .top, spacing: Spacing.xs) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text("Using a Bluetooth microphone can change playback quality. If sound becomes muffled, choose a built-in or wired microphone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Spacing.xxs)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCardStyle()
        }
    }

}
struct MicrophonePermissionSetupCard: View {
    let isUndetermined: Bool
    let isRequesting: Bool
    let requestAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                SetupBadge(style: .icon("mic.fill"), state: .active)
                Text("Microphone access").font(.callout.weight(.medium))
                Spacer()
                if isRequesting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for macOS").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(isUndetermined ? "Enable Microphone" : "Open Settings", action: requestAccess)
                        .actionButton()
                }
            }
            Text(isRequesting
                 ? "Choose Allow in the macOS permission dialog to continue. This step does not start recording."
                 : isUndetermined
                    ? "Allow SideWave to turn your speech into text. macOS will ask for access next. This step does not start recording."
                    : "Microphone access is off. Enable SideWave in System Settings > Privacy & Security > Microphone, then return here.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardStyle()
    }
}

// MARK: - Setup Badge View

private struct SetupBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reduceAppMotion") private var reduceAppMotion = false
    enum BadgeStyle {
        case number(Int)
        case icon(String)
        case checkmark
    }
    
    enum BadgeState {
        case upcoming
        case active
        case complete
    }
    
    let style: BadgeStyle
    let state: BadgeState
    
    private var accessibilityLabelText: String {
        let stateStr: String
        switch state {
        case .upcoming:
            stateStr = "upcoming"
        case .active:
            stateStr = "active"
        case .complete:
            stateStr = "complete"
        }
        
        switch style {
        case .number(let num):
            return "Step \(num), \(stateStr)"
        case .icon(let name):
            let cleanName = name.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ")
            return "\(cleanName.capitalized), \(stateStr)"
        case .checkmark:
            return "Checkmark, \(stateStr)"
        }
    }
    
    var body: some View {
        ZStack {
            switch state {
            case .upcoming:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
            case .active:
                Circle()
                    .fill(Color.accentColor)
            case .complete:
                Circle()
                    .fill(Color.green)
            }
            
            switch style {
            case .number(let num):
                if state == .complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                } else {
                    Text("\(num)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(state == .active ? .white : .secondary)
                }
            case .icon(let name):
                if state == .complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                } else {
                    Image(systemName: name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(state == .active ? .white : .secondary)
                }
            case .checkmark:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .animation(reduceMotion || reduceAppMotion ? nil : .easeInOut(duration: 0.2), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
    }
}

// MARK: - Completed step row

private struct CompletedStepRow: View {
    let stepNumber: Int
    let title: String
    var state: SetupBadge.BadgeState = .complete

    var body: some View {
        HStack(spacing: Spacing.md) {
            SetupBadge(style: .number(stepNumber), state: state)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(state == .complete ? .primary : .secondary)
                .contentTransition(.opacity)
                .id(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardStyle()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Active accessibility card

private struct ActiveAccessibilityCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            SetupBadge(style: .number(1), state: .active)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Allow accessibility access")
                        .font(.body.weight(.semibold))
                    Text("SideWave needs accessibility to detect your hotkey and paste text into other apps. macOS may ask for your administrator password when you flip the toggle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                Button("Open System Settings") {
                    AppDelegate.openAccessibilitySettings()
                }
                .prominentActionButton()
                .padding(.top, Spacing.xs)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardStyle()
    }
}

// MARK: - Active models card

struct ActiveModelsCard: View {
    @Bindable var appState: AppState
    @State private var isStartingSetup = false
    @State private var downloadActivity = ModelDownloadActivity.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            SetupBadge(style: .number(2), state: indicatorState).padding(.top, 2)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(isDownloadingOrProcessing ? "Preparing on-device models" : "On-device models")
                    .font(.body.weight(.semibold))
                Text(downloadPlanDescription)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if canPrepareModels {
                    Button("Prepare Models") {
                        isStartingSetup = true
                        if refineNeedsPreparation { retryRefine() }
                        Task {
                            if appState.transcriptionService.modelState == .notDownloaded {
                                await appState.transcriptionService.downloadModel(version: selectedSpeechVersion)
                            }
                            isStartingSetup = false
                        }
                    }
                    .prominentActionButton()
                }
                speechProgressBlock
                if appState.dictationCleanupEnabled { refineProgressBlock }
                if !appState.transcriptionService.auxiliaryModelErrors.isEmpty { auxiliaryErrorBanner }
                if isDownloadingOrProcessing {
                    Button("Open Setup Help") { openWindow(id: "help") }
                        .actionButton()
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardStyle()
    }

    var selectedSpeechVersion: ModelVersion { appState.transcriptionService.storedModelVersion() }
    var selectedRefineBackend: DictationFormatterService.Backend {
        DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend) ?? .gemma4E2B
    }

    func retryRefine() { appState.dictationFormatter.enable() }

    var canPrepareModels: Bool {
        !isDownloadingOrProcessing &&
            (appState.transcriptionService.modelState == .notDownloaded || refineNeedsPreparation)
    }

    private var refineNeedsPreparation: Bool {
        guard appState.dictationCleanupEnabled else { return false }
        switch appState.dictationFormatter.state {
        case .disabled, .unloaded: return !isRefineReady
        default: return false
        }
    }

    private var indicatorState: SetupBadge.BadgeState {
        let speechReady = appState.transcriptionService.modelState.isReady
        let refineReady = isRefineReady
        return (speechReady && refineReady) ? .complete : .active
    }

    private var isRefineReady: Bool {
        switch appState.dictationFormatter.state {
        case .ready, .generating: return true
        case .error, .unavailable, .downloading, .loading: return false
        case .disabled, .unloaded:
            let backend = DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend) ?? .gemma4E2B
            return DictationFormatterService.isGemmaBackendCached(backend)
        }
    }

    private var downloadPlanDescription: String {
        var parts: [String] = []
        if !appState.transcriptionService.modelState.isReady {
            parts.append("\(selectedSpeechVersion.displayName): \(selectedSpeechVersion.downloadSizeLabel).")
        }
        if appState.dictationCleanupEnabled {
            switch selectedRefineBackend {
            case .appleIntelligence, .appleIntelligenceLegacy:
                parts.append("Apple Intelligence uses assets managed by macOS and needs to be enabled and ready.")
            default:
                if !isRefineReady {
                    parts.append("\(selectedRefineBackend.displayName): \(selectedRefineBackend.diskSize).")
                }
            }
        }
        parts.append("Speech helpers may download separately. Processing stays on this Mac; downloads appear in Download History.")
        return parts.joined(separator: " ")
    }

    var refineDownloadTitle: String {
        let size: String
        if let session = downloadActivity.session,
           session.displayName == selectedRefineBackend.displayName,
           session.hasRealDownload, session.totalBytes > 0 {
            size = Self.formatBytes(session.totalBytes)
        } else {
            size = selectedRefineBackend.diskSize
        }
        return "Refine · \(selectedRefineBackend.displayName) (\(size))"
    }

    /// Title for the speech model download row: the exact total from ModelDownloadActivity once
    /// known, otherwise an estimate, also when another model owns the download session. The repoID
    /// check keeps a Gemma download from being labeled as the speech model.
    private var speechDownloadTitle: String {
        if let s = downloadActivity.session,
           s.hasRealDownload,
           s.totalBytes > 0,
           (s.repoID.localizedCaseInsensitiveContains("parakeet") || s.repoID.localizedCaseInsensitiveContains("phonon")) {
            return "Speech model (\(Self.formatBytes(s.totalBytes)))"
        }
        return "Speech model (\(selectedSpeechVersion.downloadSizeLabel))"
    }

    private static func formatBytes(_ bytes: Int64) -> String { bytes.byteCountText }

    private var isDownloadingOrProcessing: Bool {
        let speechActive: Bool = {
            switch appState.transcriptionService.modelState {
            case .notDownloaded, .ready, .error: return false
            default: return true
            }
        }()
        
        let refineActive: Bool = {
            guard appState.dictationCleanupEnabled else { return false }
            switch appState.dictationFormatter.state {
            case .disabled, .unloaded, .ready, .error, .unavailable: return false
            default: return true
            }
        }()
        
        return speechActive || refineActive || isStartingSetup
    }

    @ViewBuilder
    private var speechProgressBlock: some View {
        switch appState.transcriptionService.modelState {
        case .downloading(let progress):
            DownloadProgressBlock(
                title: speechDownloadTitle,
                progress: progress
            )
        case .downloadingAuxiliary(let model):
            IndeterminateProgressBlock(title: "Setting up \(model.lowercased())…")
        case .verifying:
            IndeterminateProgressBlock(title: "Checking speech model files…")
        case .compiling:
            IndeterminateProgressBlock(title: "Preparing the speech engine for this Mac…")
        case .loading:
            IndeterminateProgressBlock(title: "Loading the speech engine…")
        case .ready:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Speech recognition ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(Color.warningAmber)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Speech") {
                    Task { await appState.transcriptionService.downloadModel(version: selectedSpeechVersion) }
                }
                .actionButton()
                .controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var refineProgressBlock: some View {
        switch appState.dictationFormatter.state {
        case .downloading(let progress):
            DownloadProgressBlock(
                title: refineDownloadTitle,
                progress: progress
            )
        case .loading:
            IndeterminateProgressBlock(title: "Loading the refine model…")
        case .ready:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("\(selectedRefineBackend.displayName) is ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(Color.warningAmber)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Refine") {
                    retryRefine()
                }
                .actionButton()
                .controlSize(.small)
            }
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refine Settings") {
                    appState.requestedSettingsTab = .settingsRefine
                    openWindow(id: "settings")
                }
                .actionButton().controlSize(.small)
            }
        default:
            EmptyView()
        }
    }
    
    private var auxiliaryErrorBanner: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(appState.transcriptionService.auxiliaryModelErrors, id: \.self) { msg in
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.warningAmber)
                        .accessibilityHidden(true)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Retry Auxiliary Models") {
                Task { await appState.transcriptionService.retryAuxiliaryDownloads() }
            }
            .actionButton()
        }
        .padding(.top, Spacing.xxs)
    }
}

// MARK: - Progress blocks

struct DownloadProgressBlock: View {
    let title: String
    let progress: Double
    var boundedProgress: Double { progress.isFinite ? max(0, min(1, progress)) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .id(title)
                Spacer()
                Text("\(Int(boundedProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: boundedProgress * 100))
            }
            ProgressView(value: boundedProgress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct IndeterminateProgressBlock: View {
    let title: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .id(title)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Welcome - Light") {
    WelcomeView(appState: AppState())
        .frame(width: 640, height: 500)
        .preferredColorScheme(.light)
}

#Preview("Welcome - Dark") {
    WelcomeView(appState: AppState())
        .frame(width: 640, height: 500)
        .preferredColorScheme(.dark)
}
#endif
