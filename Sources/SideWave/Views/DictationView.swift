// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// The Dictation tab: settings that shape dictated text, in three collapsible sections (Refine,
/// Filters, Formatting), one open at a time. Uses the same stored values as Settings, so changes
/// show everywhere.
struct DictationView: View {
    @Bindable var appState: AppState

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }
    /// Advanced view (Settings > General). Off by default; expert sections aren't shown at all.
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    @AppStorage("skipRefine") private var skipRefine = false
    @AppStorage("performFinalRefinePass") private var performFinalRefinePass = true
    @AppStorage("gemmaThinkingMode") private var gemmaThinkingMode = false
    @AppStorage("sideWaveExperience") private var sideWaveExperience = "full"
    @AppStorage("removeFillerWords") private var removeFillerWords = true
    @AppStorage("removeProfanity") private var removeProfanity = false
    @AppStorage("replaceProfanity") private var replaceProfanity = false
    /// Which section is currently expanded. Empty string means all collapsed.
    /// Accordion behavior: opening one auto-closes the others. Persisted so
    /// the tab reopens to the section the user last had open.
    @AppStorage("dictationOpenSection") private var openSection: String = "Refine"

    /// Output languages for the active backend, refreshed when the backend changes. Cached because
    /// Apple Intelligence reads `supportedLanguages` from a new model handle each time.
    @State private var offeredOutputLanguages: [DictationFormatterService.OutputLanguage] =
        DictationFormatterService.OutputLanguage.allCases

    /// Keeps detailed explanations out of the main controls.
    @State private var showRefineInfo: Bool = false
    @State private var showPromptPreview = false
    /// Folds the expert refine knobs (bypass-on-short, final-pass strategy)
    /// under an Advanced disclosure. Collapsed by default; persisted so the
    /// common case stays uncluttered and the tab fits without scrolling.
    @AppStorage("dictationRefineAdvancedOpen") private var refineAdvancedOpen = false

    /// Apple Intelligence availability for the status row, refreshed when the backend changes and
    /// when the app becomes active, since the user may turn Apple Intelligence on in System
    /// Settings. Cached because each check creates a `SystemLanguageModel` handle. Stored as `Any?`
    /// so the property doesn't reference a FoundationModels type; `afmAvailabilityRow` casts it
    /// back.
    @State private var cachedAFMAvailability: Any? = nil

    /// Whether each Gemma backend is downloaded. Checking walks the model folder, so it runs off
    /// the main thread when the backend changes, keyed by backend so switching between E2B and E4B
    /// doesn't check both again.
    @State private var cachedGemmaCacheStatus: [String: Bool] = [:]

    var body: some View {
        // Expanded controls remain scrollable at the default window size.
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Experience preset; the primary control. Most people pick a
                // mode here and never open the sections below. Always visible,
                // never inside the accordion.
                experiencePresetCard

                accordionCard(
                    title: "Refine",
                    icon: "text.badge.checkmark"
                ) {
                    refineContent
                }

                accordionCard(
                    title: "Filters",
                    icon: "line.3.horizontal.decrease"
                ) {
                    filtersContent
                }

                accordionCard(
                    title: "Formatting",
                    icon: "text.alignleft"
                ) {
                    formattingContent
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.sm)
        }
        .scrollIndicators(.automatic)
        .softScrollEdge()
        .sheet(isPresented: $showRefineInfo) {
            InfoSheet(topic: .refine)
        }
        .sheet(isPresented: $showPromptPreview) {
            PromptPreviewSheet(
                previewBuilder: {
                    DictationFormatterService.makePromptPreview(
                        customInstructions: appState.dictationCleanupInstructions,
                        backend: DictationFormatterService.Backend(
                            rawValue: appState.dictationCleanupBackend
                        ) ?? .gemma4E2B
                    )
                },
                onClose: { showPromptPreview = false }
            )
        }
        // Refresh the status caches when the backend changes, so rendering never creates a model
        // handle or walks the model folder on the main thread.
        .task(id: appState.dictationFormatter.activeBackend) {
            await refreshBackendStatusCaches(for: appState.dictationFormatter.activeBackend)
        }
        // Re-evaluate when the app comes back to the foreground. The
        // user may have flipped Apple Intelligence on/off in System
        // Settings while SideWave was inactive.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await refreshBackendStatusCaches(for: appState.dictationFormatter.activeBackend)
                }
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    /// Refreshes the status caches for the selected backend: Apple Intelligence availability on the
    /// main actor, and the Gemma folder check in a detached task so a large download doesn't stall
    /// the view.
    private func refreshBackendStatusCaches(for backend: DictationFormatterService.Backend) async {
        // AFM availability. Lightweight Foundation Models query.
        // Runs on MainActor; takes a handful of microseconds.
        let availability = DictationFormatterService.currentAFMAvailability()
        cachedAFMAvailability = availability

        // Gemma on-disk walk. Off-main, then merge back to MainActor.
        let backendRawValue = backend.rawValue
        switch backend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            let cached = await Task.detached(priority: .userInitiated) {
                DictationFormatterService.isGemmaBackendCached(backend)
            }.value
            cachedGemmaCacheStatus[backendRawValue] = cached
        case .appleIntelligence, .appleIntelligenceLegacy:
            break  // No on-disk weights to check.
        }
    }

    private var customInstructionsPlaceholder: String {
        let tmpl = DictationFormatterService.Template(rawValue: appState.dictationCleanupTemplate)
        switch tmpl {
        case .standard:
            return "e.g. keep a formal tone, prefer British spelling"
        case .professional:
            return "e.g. use active voice, avoid corporate jargon"
        case .concise:
            return "e.g. cut greetings and sign-offs, bullet points only"
        case .emailReady:
            return "e.g. add a greeting to John, sign off as Rich"
        case .instructions:
            return "e.g. write for new users, keep each step short, group safety notes with their step"
        case .aiPrompt:
            return "e.g. keep technical constraints together, preserve examples verbatim, use short XML sections"
        case .custom:
            return "Write your rules here. The model follows these as its primary directive."
        case .none:
            return "e.g. keep a formal tone, prefer British spelling"
        }
    }

    // MARK: - Experience preset (primary control)

    /// Complete, Basic, or Minimalistic: how much of the pipeline runs. Writes `sideWaveExperience`
    /// through ExperiencePreset.apply, like Home, so the two can't drift.
    private var experiencePresetCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Dictation Mode")
                    .font(.callout.weight(.semibold))
                Spacer()
                GlassSegmentedPicker(
                    selection: Binding(
                        get: { sideWaveExperience },
                        set: { newValue in
                            ExperiencePreset.apply(newValue, appState: appState)
                        }
                    ),
                    segments: [
                        .init("Complete", tag: "full"),
                        .init("Basic", tag: "standard"),
                        .init("Minimalistic", tag: "speedy"),
                    ],
                    equalWidths: true,
                    accessibilityLabel: "Dictation mode"
                )
                .disabled(isSessionActive || appState.pendingSessionText != nil)
                .help(appState.pendingSessionText != nil
                      ? "Finish or discard the paused dictation before changing modes"
                      : isSessionActive ? "Locked while dictating" : "Choose which speech and refinement engines run")
            }
            Text(experienceDescription(for: sideWaveExperience))
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .settingsCardStyle()
    }

    /// One-line description of the selected mode. Says what happens.
    private func experienceDescription(for experience: String) -> String {
        ExperiencePreset.description(for: experience,
                                     refinementEnabled: appState.dictationCleanupEnabled && !skipRefine)
    }

    // MARK: - Refine section body

    /// True while a dictation is running or finishing. Refine model, template, language, and
    /// instruction changes are locked then, since switching would unload the model mid-session.
    private var isSessionActive: Bool {
        appState.isDictationBusy || appState.isProcessingAgenticEdit
    }

    /// Locks the Refine model picker while a model loads or generates, or during a session.
    /// Switching mid-download cancels and reloads; switching mid-generation unloads the model under
    /// an active segment, which then falls back to raw text. Same rule as the Settings > Refine
    /// picker.
    private var isBackendSwitchLocked: Bool {
        if isSessionActive { return true }
        switch appState.dictationFormatter.state {
        case .downloading, .loading, .generating: return true
        default: return false
        }
    }

    private var refineContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.xxs) {
                Text("Cleans up dictation with a local model. Your dictated words stay on this Mac.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showRefineInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("How Refine works")
                .accessibilityLabel("How Refine works")
                Spacer(minLength: 0)
            }

            SettingsDivider()

            HStack {
                Text("Enable Refine")
                    .font(.callout.weight(.medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { !skipRefine },
                    set: { isOn in
                        // Refine needs the local model loaded. Under 8 GB it
                        // can't run, so keep the toggle pinned off there.
                        if appState.lowMemoryMode {
                            skipRefine = true
                            return
                        }
                        appState.selectDictationOutput(isOn ? appState.selectedDictationTemplate : nil,
                                                       openDocument: false)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(appState.lowMemoryMode || isSessionActive)
                .help(appState.lowMemoryMode
                      ? "Refine is unavailable on Macs with less than 8 GB of RAM."
                      : "Refine dictated text with the on-device model before it pastes.")
                .accessibilityLabel("Enable Refine")
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                SettingsDivider()

                // Model picker with status text on the same row, shown only when there's something
                // to do (Apple Intelligence off, Gemma not downloaded, model not ready). Nothing is
                // shown when everything is fine.
                refineRow(label: "Model") {
                    HStack(spacing: Spacing.sm) {
                        ChoiceMenu(title: "Refine model", value: DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend)?.displayName ?? "Choose model", selection: Binding(
                            get: { appState.dictationCleanupBackend },
                            set: { appState.dictationCleanupBackend = $0 }
                        )) {
                            ForEach(DictationFormatterService.Backend.availableBackends, id: \.rawValue) { backend in
                                Text(backend.displayName).tag(backend.rawValue)
                            }
                        }

                        .labelsHidden()
                        .fixedSize()
                        .disabled(isBackendSwitchLocked)
                        .help(isSessionActive
                              ? "Locked while dictating"
                              : isBackendSwitchLocked
                                ? "Wait for the current backend to finish loading or refining before switching."
                                : "Pick which local model runs Refine")

                        backendStatusInline
                    }
                }

                // Template
                refineRow(label: "Template") {
                    HStack(spacing: Spacing.xs) {
                        ChoiceMenu(title: "Template", value: selectedTemplate.workspaceTitle, selection: $appState.dictationCleanupTemplate) {
                            Section("Paste into an app") {
                                ForEach(DictationFormatterService.Template.allCases.filter { !$0.isSpecialty }) {
                                    Text($0.workspaceTitle).tag($0.rawValue)
                                }
                            }
                            Section("Review as a document") {
                                ForEach(DictationFormatterService.Template.allCases.filter(\.isSpecialty)) {
                                    Text($0.workspaceTitle).tag($0.rawValue)
                                }
                            }
                        }

                        .labelsHidden()
                        .fixedSize()
                        .disabled(isSessionActive || appState.pendingSessionText != nil)
                        .help(appState.pendingSessionText != nil ? "Resume or discard the paused dictation before changing templates" : isSessionActive ? "Locked while dictating" : "")

                        Image(systemName: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help(templateHelpText)
                            // Hover-only hint; Help > Refine covers the same ground for VoiceOver.
                            .accessibilityHidden(true)

                        if selectedTemplate.isSpecialty {
                            Button("Open Editor", systemImage: "macwindow.on.rectangle") {
                                appState.openSpecialtyEditor()
                            }
                            .actionButton()
                            .help("Open the document editor for this template")
                        }
                    }
                }

                refineRow(label: "Output language") {
                    // Keep the current choice visible even if the active backend
                    // wouldn't offer it (picked under Gemma, then switched to an
                    // AFM build that lacks it) so the menu never renders blank.
                    let current = DictationFormatterService.OutputLanguage.from(code: appState.dictationOutputLanguage)
                    let shown = offeredOutputLanguages.contains(current) ? offeredOutputLanguages : offeredOutputLanguages + [current]
                    ChoiceMenu(title: "Output language", value: current.displayName, selection: $appState.dictationOutputLanguage) {
                        ForEach(shown) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }

                    .labelsHidden()
                    .fixedSize()
                    .disabled(isSessionActive)
                    .help(isSessionActive
                          ? "Locked while dictating"
                          : "Keep the language you speak, or translate while Refine cleans up")
                    .task(id: appState.dictationCleanupBackend) {
                        let backend = DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend) ?? .gemma4E2B
                        offeredOutputLanguages = DictationFormatterService.offeredOutputLanguages(for: backend)
                    }
                }
                Text("As spoken keeps the language you speak. Choose a language and Refine translates while it cleans up, keeping your meaning and tone.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)

                // Simple view hides the whole disclosure, not just its contents.
                if showAdvancedControls {
                    SettingsDivider()

                    DisclosureGroup("Advanced", isExpanded: $refineAdvancedOpen) {
                        advancedRefineControls
                            .padding(.top, Spacing.sm)
                    }
                    .font(.callout)
                    .disclosureGroupStyle(.row)
                }
            }
            .disabled(skipRefine)
            .opacity(skipRefine ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: skipRefine)
            .animation(reduceMotion ? nil : Animate.standard, value: showAdvancedControls)
        }
    }

    /// Expert refine controls inside the Advanced disclosure, one row per setting with a caption,
    /// spaced so the Filters and Formatting headers stay visible at the default window size.
    @ViewBuilder
    private var advancedRefineControls: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            customInstructionsSection

            SettingsDivider()

            refineRow(label: "Prompt preview") {
                Button("Preview") { showPromptPreview = true }
                    .actionButton()
                    .help("Show what Refine receives with your current template and settings")
            }

            SettingsDivider()

            refineRow(label: "Bypass Refine on short sessions") {
                Toggle("Bypass Refine on short sessions", isOn: $appState.bypassRefineOnShortSessions)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            Text("Skip the final cleanup for brief ordinary dictation. Document templates always apply their chosen format.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)

            if appState.bypassRefineOnShortSessions {
                refineRow(label: "Minimum words") {
                    ChoiceMenu(title: "Minimum words", value: "\(appState.dictationCleanupMinWords) words", selection: $appState.dictationCleanupMinWords) {
                        Text("5 words").tag(5)
                        Text("10 words").tag(10)
                        Text("20 words").tag(20)
                        Text("50 words").tag(50)
                    }

                    .labelsHidden()
                    .fixedSize()
                }
                Text("Ordinary dictation under this word count skips the final Refine pass.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            refineRow(label: "Final refinement pass") {
                Toggle("Final refinement pass", isOn: $performFinalRefinePass)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(skipRefine || !appState.dictationCleanupEnabled)
            }
            Text("Finish refining before sending ordinary dictation. Turn this off to send the current text immediately, including any words that have not been refined. Document templates still apply their format.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)

            if performFinalRefinePass {
                refineRow(label: "Final pass strategy") {
                    ChoiceMenu(title: "Final pass strategy", value: ["incremental": "Incremental (Fast)", "smart": "Smart Window (Balanced)", "full": "Full Session (Thorough)"][appState.finalPassStrategy] ?? "Incremental (Fast)", selection: Binding(
                        get: { appState.finalPassStrategy },
                        set: { appState.finalPassStrategy = $0 }
                    )) {
                        Text("Incremental (Fast)").tag("incremental")
                        Text("Smart Window (Balanced)").tag("smart")
                        Text("Full Session (Thorough)").tag("full")
                    }

                    .labelsHidden()
                    .fixedSize()
                    .disabled(skipRefine || !appState.dictationCleanupEnabled)
                }
                Text("Incremental checks the ending and all unfinished text, using recent context. Smart Window checks the last sentences. Full Session rewrites the entire dictation.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }

            if DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend)?.huggingFaceRepoID != nil {
                SettingsDivider()
                refineRow(label: "Think before a full rewrite") {
                    Toggle("Think before a full rewrite", isOn: $gemmaThinkingMode)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(isSessionActive)
                }
                Text("Optional Gemma reasoning for document formatting and Rewrite and finish. It can take substantially longer. Live cleanup stays fast.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Custom instructions field, inside the Refine Advanced disclosure, with its in-use cue,
    /// character count, and template-aware caption.
    @ViewBuilder
    private var customInstructionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                Text("Custom instructions")
                    .font(.callout)
                if appState.dictationCleanupTemplate == DictationFormatterService.Template.custom.rawValue {
                    Image(systemName: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("On the Custom template, your instructions have maximum weight. The model follows them as its primary directive. Write exactly how you want your text processed.")
                        .accessibilityHidden(true)
                }
                Spacer()
                // Active-status cue: visible when the user has typed anything.
                // Plain text + small symbol, no tinted background.
                if !appState.dictationCleanupInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        Text("In use")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.dictationCleanupInstructions.isEmpty)

            TextField(
                customInstructionsPlaceholder,
                text: $appState.dictationCleanupInstructions,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...5)
            .disabled(isSessionActive)
            .help(isSessionActive ? "Locked while dictating" : "")

            HStack(spacing: 4) {
                Text(appState.dictationCleanupTemplate == DictationFormatterService.Template.custom.rawValue
                     ? "Your rules take priority. The model follows these as its main directive."
                     : "Optional. Added alongside the template rules above.")
                    .settingsCaption()
                Spacer(minLength: 8)
                // Live char count when content exists. Cap is 1000 (enforced in
                // AppState.didSet); color shifts near the limit.
                if !appState.dictationCleanupInstructions.isEmpty {
                    let count = appState.dictationCleanupInstructions.count
                    let isNearLimit = count > 950
                    Text("\(count) / 1000")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isNearLimit ? Color.accentColor : Color.secondary)
                }
            }
        }
    }

    /// Selected template's raw value coerced to the Template enum.
    /// Falls back to .standard if the persisted value doesn't match
    /// (legacy data, mistyped key, etc.).
    private var selectedTemplate: DictationFormatterService.Template {
        DictationFormatterService.Template(rawValue: appState.dictationCleanupTemplate) ?? .standard
    }

    private var templateHelpText: String {
        selectedTemplate.subtitle + (selectedTemplate.isSpecialty
            ? " Opens a document to review, edit, and copy." : "")
    }

    // MARK: - Filters section body

    @ViewBuilder
    private var filtersContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            PreferenceToggle("Remove filler words (um, uh, like)", isOn: $removeFillerWords)
                .font(.callout)

            PreferenceToggle("Redact profanity", isOn: $removeProfanity)
                .font(.callout)
                .disabled(replaceProfanity)
            PreferenceToggle("Replace profanity with alternatives", isOn: $replaceProfanity)
                .font(.callout)
                .disabled(removeProfanity)
            Text("Redact replaces profane words with asterisks. Replace swaps them for mild alternatives. Pick one or neither.")
                .settingsCaption()
                .fixedSize(horizontal: false, vertical: true)


        }
    }

    // MARK: - Formatting section body

    @ViewBuilder
    private var formattingContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            PreferenceToggle("Add trailing space after pasted text", isOn: $appState.appendTrailingSpace)
                .font(.callout)
            Text("Inserts a single space after each dictation so the next word starts cleanly.")
                .settingsCaption()

            PreferenceToggle("Also copy text to clipboard", isOn: $appState.copyToClipboard)
                .font(.callout)
            Text("Keeps a copy on your clipboard in case the paste fails or you want to paste elsewhere.")
                .settingsCaption()
        }
    }

    // MARK: - Accordion helper

    /// Accordion card: clicking the header toggles this section; opening a
    /// section auto-collapses the others. Animated via withAnimation so
    /// collapse + open feels continuous rather than two discrete changes.
    @ViewBuilder
    private func accordionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isOpen = (openSection == title)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Animate.standard) {
                    openSection = isOpen ? "" : title
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                SettingsDivider()
                content()
                    .padding(Spacing.lg)
                    .transition(.opacity)
            }
        }
        .clipped()
        .settingsCardStyle()
    }

    private func refineRow<Control: View>(
        label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        PreferenceRow(label: label, content: control)
    }

    /// Status text after the model picker, empty when the backend is ready. Shown only when the
    /// user needs to act: turn Apple Intelligence on, wait for its model or Gemma to download, or
    /// see that the Mac isn't eligible. Includes a link to System Settings when Apple Intelligence
    /// is off.
    @ViewBuilder
    private var backendStatusInline: some View {
        let backendRaw = appState.dictationCleanupBackend
        if backendRaw == DictationFormatterService.Backend.appleIntelligence.rawValue ||
           backendRaw == DictationFormatterService.Backend.appleIntelligenceLegacy.rawValue {
            let availability = (cachedAFMAvailability as? DictationFormatterService.AFMAvailability)
                ?? DictationFormatterService.currentAFMAvailability()
            switch availability {
            case .available:
                // Ready: show nothing. The picker already names the generation.
                EmptyView()
            case .unavailable(let reason, let kind):
                HStack(spacing: Spacing.xs) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if kind == .appleIntelligenceNotEnabled {
                        Button {
                            Self.openAppleIntelligenceSettings()
                        } label: {
                            Text("Open")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        } else if DictationFormatterService.Backend(rawValue: backendRaw)?.huggingFaceRepoID != nil {
            let backend = appState.dictationFormatter.activeBackend
            // Show "Downloads on first refine" only when the model isn't downloaded. Assume
            // downloaded while the check runs, so the message doesn't flash.
            let cached = cachedGemmaCacheStatus[backend.rawValue] ?? true
            if !cached {
                Text("Downloads on first refine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Opens the Apple Intelligence pane in System Settings, falling back to the Apple Intelligence
    /// & Siri pane and then Settings itself, since pane IDs change between releases.
    private static func openAppleIntelligenceSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.applemodelintelligence",
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

#if DEBUG
#Preview("Dictation - Light") {
    DictationView(appState: AppState())
        .frame(width: 720, height: 720)
        .preferredColorScheme(.light)
}

#Preview("Dictation - Dark") {
    DictationView(appState: AppState())
        .frame(width: 720, height: 720)
        .preferredColorScheme(.dark)
}
#endif
