// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import XCTest
import WebKit
@testable import SideWave

@MainActor
final class DictationHomeRenderingTests: XCTestCase {
    func testRenderCheckRejectsBlankImages() throws {
        for background in [CGFloat(0.12), 0.97] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: background, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            XCTAssertFalse(try containsRenderedContent(XCTUnwrap(context.makeImage())))
            context.setFillColor(CGColor(gray: 1 - background, alpha: 1))
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 4))
            XCTAssertTrue(try containsRenderedContent(XCTUnwrap(context.makeImage())))
        }
    }

    func testSetupRecoveryKeepsSelectedModels() {
        let defaults = UserDefaults.standard
        let keys = ["selectedModelVersion", "dictationCleanupBackend", "dictationCleanupEnabled", "skipRefine", "skipRefineAutoForced"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let state = AppState()
        state.dictationCleanupEnabled = true
        for (progress, expected) in [(Double.nan, 0.0), (Double.infinity, 0.0), (-0.5, 0.0), (1.5, 1.0), (0.45, 0.45)] {
            XCTAssertEqual(DownloadProgressBlock(title: "Model", progress: progress).boundedProgress, expected)
        }
        for speech in ModelVersion.allCases {
            defaults.set(speech.rawValue, forKey: "selectedModelVersion")
            for backend in DictationFormatterService.Backend.allCases {
                state.dictationCleanupBackend = backend.rawValue
                state.dictationFormatter.state = .error("Model preparation was interrupted.")
                let card = ActiveModelsCard(appState: state)
                XCTAssertEqual(card.selectedSpeechVersion, speech)
                XCTAssertTrue(card.refineDownloadTitle.contains(backend.displayName))
                card.retryRefine()
                XCTAssertEqual(state.dictationCleanupBackend, backend.rawValue)
                XCTAssertEqual(defaults.string(forKey: "selectedModelVersion"), speech.rawValue)
                XCTAssertTrue(state.dictationCleanupEnabled)
            }
        }
        state.transcriptionService.modelState = .notDownloaded
        state.dictationFormatter.state = .unavailable("Enable Apple Intelligence in System Settings.")
        XCTAssertTrue(ActiveModelsCard(appState: state).canPrepareModels,
                      "Unavailable refinement must not block speech preparation")
        state.dictationCleanupEnabled = false
        XCTAssertTrue(ActiveModelsCard(appState: state).canPrepareModels)
        state.transcriptionService.modelState = .compiling
        XCTAssertFalse(ActiveModelsCard(appState: state).canPrepareModels)
        state.transcriptionService.modelState = .error("Retry speech preparation.")
        XCTAssertFalse(ActiveModelsCard(appState: state).canPrepareModels,
                       "An interrupted speech download uses its dedicated retry action")
    }

    func testIncompleteSetupAndPermissionStatesFit() async throws {
        let defaults = UserDefaults.standard
        let keys = ["dictationCleanupBackend", "dictationCleanupEnabled", "skipRefine", "skipRefineAutoForced"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let state = AppState()
        let originalInput = state.audioDeviceManager.selectedDeviceUID
        defer { state.audioDeviceManager.selectedDeviceUID = originalInput }
        state.audioDeviceManager.selectedDeviceUID = nil
        state.isAccessibilityGranted = false
        state.dictationCleanupBackend = DictationFormatterService.Backend.gemma4_12B.rawValue
        state.dictationCleanupEnabled = true
        state.dictationFormatter.state = .error("A model file is missing. Valid downloaded files are kept.")
        state.transcriptionService.modelState = .error("The connection was interrupted. Retry to continue preparation.")
        state.audioDeviceManager.availableDevices = [
            AudioInputDevice(id: 1, uid: "setup-usb-input", name: "USB recording interface with a long device name and multiple input channels", isDefault: true, transportType: 0, channelCount: 8),
            AudioInputDevice(id: 2, uid: "setup-built-in", name: "Built-in microphone", isDefault: false, transportType: 0, channelCount: 1)
        ]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for height in [CGFloat(560), 670] {
                try await render(WelcomeView(appState: state), scheme: scheme,
                    name: "onboarding_incomplete_\(Int(height))_\(suffix)", width: 675, height: height)
            }
            for (undetermined, requesting, name) in [(true, false, "request"), (true, true, "waiting"), (false, false, "denied")] {
                try await render(MicrophonePermissionSetupCard(isUndetermined: undetermined, isRequesting: requesting, requestAccess: {}),
                    scheme: scheme, name: "onboarding_microphone_\(name)_\(suffix)", width: 550, height: 130)
            }
            try await render(DownloadProgressBlock(title: "Refine model", progress: .nan), scheme: scheme,
                name: "onboarding_unknown_progress_\(suffix)", width: 420, height: 40)
            state.dictationCleanupBackend = DictationFormatterService.Backend.appleIntelligence.rawValue
            state.dictationFormatter.state = .unavailable("Enable Apple Intelligence in System Settings, then return here.")
            state.transcriptionService.modelState = .notDownloaded
            try await render(ActiveModelsCard(appState: state), scheme: scheme,
                name: "onboarding_model_unavailable_\(suffix)", width: 590, height: 300)
            state.transcriptionService.modelState = .error("The connection was interrupted. Retry to continue preparation.")
            state.dictationCleanupBackend = DictationFormatterService.Backend.gemma4_12B.rawValue
            state.dictationFormatter.state = .error("A model file is missing. Valid downloaded files are kept.")
        }
    }

    func testDisconnectedMicrophoneNamesFitThePriorityList() async throws {
        let defaults = UserDefaults.standard
        let keys = [AudioDeviceManager.audioInputPriorityKey, AudioDeviceManager.autoOverrideBluetoothInputKey,
                    "audioInputDeviceNames"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        AudioDeviceManager.setAudioInputPriorityUIDs(["known-disconnected-input", "legacy-disconnected-input"])
        defaults.set(["known-disconnected-input": "Studio microphone"], forKey: "audioInputDeviceNames")
        AudioDeviceManager.setAutoOverrideBluetoothInput(true)
        let state = AppState()
        XCTAssertEqual(state.audioDeviceManager.knownInputName(forUID: "known-disconnected-input"), "Studio microphone")
        XCTAssertNil(state.audioDeviceManager.knownInputName(forUID: "legacy-disconnected-input"))
        for scheme in [ColorScheme.light, .dark] {
            try await render(SettingsContentView(category: .settingsAudio, appState: state).environment(state),
                scheme: scheme, name: "microphone_priorities_\(scheme == .dark ? "dark" : "light")",
                width: 540, height: 620)
        }
    }

    func testPopulatedDownloadHistoryFitsAndKeepsSourcesReadable() async throws {
        let url = AppPaths.applicationSupportDirectory().appendingPathComponent("render_network_history.json")
        let log = NetworkActivityLog(storageURL: url)
        defer { log.flush(); try? FileManager.default.removeItem(at: url) }
        let earlierURL = AppPaths.applicationSupportDirectory().appendingPathComponent("render_earlier_downloads.json")
        let earlierLog = NetworkActivityLog(storageURL: earlierURL)
        defer { earlierLog.flush(); try? FileManager.default.removeItem(at: earlierURL) }
        earlierLog.record(.init(timestamp: Calendar.current.date(byAdding: .day, value: -90, to: .now)!,
            kind: .modelDownload, direction: .incoming, host: "example.org", path: "/models/encoder.safetensors",
            bytes: 1_048_576, detail: "Downloaded a model file."))
        for day in 0..<35 {
            log.record(.init(timestamp: Calendar.current.date(byAdding: .day, value: -day, to: .now)!,
                kind: day.isMultiple(of: 3) ? .modelManifest : .modelDownload, direction: .incoming,
                host: "example.org", path: "/models/speech/resolve/main/encoder-part-\(day).safetensors",
                bytes: Int64(day + 1) * 1_048_576,
                detail: "Downloaded a model file. Existing verified files were reused; this entry records only the transferred bytes."))
        }
        for scheme in [ColorScheme.light, .dark] {
            try await render(DataTransparencyView(log: log), scheme: scheme,
                name: "transparency_populated_\(scheme == .dark ? "dark" : "light")", width: 580, height: 680)
            try await render(DataTransparencyView(log: earlierLog), scheme: scheme,
                name: "transparency_earlier_\(scheme == .dark ? "dark" : "light")", width: 580, height: 680)
        }
    }

    func testHelpAndSettingsSearchMatchWordsAcrossTheirDescriptions() {
        XCTAssertTrue(HelpSection.models.matchesSearch("download gemma"))
        XCTAssertTrue(HelpSection.refine.matchesSearch("  DOCUMENT\nundo  "))
        XCTAssertTrue(HelpSection.vocabulary.matchesSearch("pronunciation glossary"))
        XCTAssertTrue(HelpSection.audioDevices.matchesSearch("default microphone"))
        XCTAssertTrue(HelpSection.audioDevices.matchesSearch("mixer channel"))
        XCTAssertTrue(HelpSection.gettingStarted.matchesSearch(" \n "))
        XCTAssertFalse(HelpSection.privacy.matchesSearch("unmatchedzz"))
        XCTAssertTrue(AppSettingsView.matchesSearch("bluetooth input", label: "Microphone", item: .settingsAudio))
        XCTAssertTrue(AppSettingsView.matchesSearch("reduce motion", label: "General", item: .settingsGeneral))
        XCTAssertTrue(AppSettingsView.matchesSearch("input channel", label: "Microphone", item: .settingsAudio))
        XCTAssertFalse(AppSettingsView.matchesSearch("input channel", label: "About", item: .settingsAbout))
    }

    func testSearchEmptyStatesAndIncompleteSetupNavigationRender() async throws {
        let state = AppState()
        state.isAccessibilityGranted = false
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(HelpView(searchText: "unmatchedzz").environment(state), scheme: scheme,
                             name: "help_search_empty_\(suffix)", width: 720, height: 500)
            try await render(AppSettingsView(searchText: "bluetooth input").environment(state), scheme: scheme,
                             name: "settings_search_input_\(suffix)", width: 780, height: 560)
            try await render(AppSettingsView(searchText: "unmatchedzz").environment(state), scheme: scheme,
                             name: "settings_search_empty_\(suffix)", width: 780, height: 560)
        }
    }

    func testContextualHelpOpensTheRequestedTopic() async throws {
        let state = AppState()
        state.requestedHelpSection = .meetingTranscription
        try await render(HelpView().environment(state), scheme: .light,
                         name: "help_meeting_deep_link", width: 808, height: 623)
        XCTAssertNil(state.requestedHelpSection)
    }

    func testNativeSidebarContentsRenderIndependentlyOfWindowCompositor() async throws {
        let state = AppState()
        let defaults = UserDefaults.standard
        let keys = ["showAdvancedControls", "experimentalFeatures"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "experimentalFeatures")
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for query in ["", "unmatchedzz"] {
                let kind = query.isEmpty ? "topics" : "empty"
                try await render(HelpSidebarView(selectedSection: .constant(.gettingStarted), searchText: .constant(query)).environment(state), scheme: scheme,
                                 name: "help_sidebar_\(kind)_\(suffix)", width: 220, height: 623)
                for advanced in [false, true] {
                    defaults.set(advanced, forKey: "showAdvancedControls")
                    let mode = advanced ? "advanced" : "simple"
                    try await render(SettingsSidebarView(selectedTab: .constant(.settingsGeneral), searchText: .constant(query)).environment(state), scheme: scheme,
                                     name: "settings_sidebar_\(kind)_\(mode)_\(suffix)", width: 228, height: 650)
                }
            }
        }
    }

    func testMiniSharesPreparingFinishingAndDocumentFeedback() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for phase in DictationSessionPhase.allCases {
                let view = MiniDashboardSurface(phase: phase, hotkey: "Right Option", elapsed: 65,
                    outputSummary: "Professional · Gemma E4B", reduceMotion: true, onPrimary: {}, onExpand: {})
                if phase == .preparing { XCTAssertEqual(view.statusTitle, "Preparing") }
                if phase == .finishing { XCTAssertEqual(view.statusTitle, "Finishing dictation") }
                try await render(view, scheme: scheme, name: "mini_\(phase.rawValue)_\(suffix)", width: 380, height: 64)
            }
            let view = MiniDashboardSurface(phase: .idle, isEditingDocument: true, hotkey: "Right Option",
                outputSummary: "Instructions · Gemma E2B", reduceMotion: true, onPrimary: {}, onExpand: {})
            XCTAssertEqual(view.statusTitle, "Applying changes")
            try await render(view, scheme: scheme, name: "mini_document_edit_\(suffix)", width: 380, height: 64)
        }
    }

    func testShortcutHelpAndInitialSettingsDeepLinkFit() async throws {
        let state = AppState()
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let settings = SettingsContentView(category: .settingsGeneral, appState: state)
            try await render(InfoSheet(topic: .refine), scheme: scheme,
                             name: "dictation_refine_info_\(suffix)", width: 520, height: 670)
            try await render(InfoSheet(topic: .holdToRewrite), scheme: scheme,
                             name: "shortcut_hold_refine_\(suffix)", width: 520, height: 560)
            try await render(InfoSheet(topic: .smartPushToTalk), scheme: scheme,
                             name: "shortcut_push_to_talk_\(suffix)", width: 520, height: 560)
            try await render(InfoSheet(topic: .doubleTapRepaste), scheme: scheme,
                             name: "shortcut_repeat_\(suffix)", width: 520, height: 480)
            state.requestedSettingsSpotlight = "hotkey"
            try await render(settings.environment(state), scheme: scheme,
                             name: "settings_initial_hotkey_\(suffix)", width: 540, height: 500,
                             settleTime: 0.8, minimumVerticalOffset: 100)
            state.requestedSettingsSpotlight = nil
        }
    }

    func testGlossaryCreationImportAssistanceAndMeetingSetupFit() async throws {
        let state = AppState()
        let store = VocabularyStore(storageURL: AppPaths.applicationSupportDirectory().appendingPathComponent("sheet_vocabulary.json"))
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(NewCollectionSheet(onCreate: { _ in }), scheme: scheme,
                             name: "glossary_new_\(suffix)", width: 420, height: 250)
            try await render(NewCollectionSheet(initialName: "Laboratory names and technical terms", onCreate: { _ in }), scheme: scheme,
                             name: "glossary_rename_\(suffix)", width: 420, height: 250)
            try await render(BulkImportSheet(onImport: { _ in }), scheme: scheme,
                             name: "glossary_csv_\(suffix)", width: 560, height: 540)
            try await render(DescribeVocabularySheet(appState: state, onSave: { _, _ in }), scheme: scheme,
                             name: "glossary_describe_\(suffix)", width: 600, height: 540)
            try await render(SpeechProfileSheet(appState: state), scheme: scheme,
                             name: "speech_profile_\(suffix)", width: 600, height: 560)
            try await render(GlossaryCatalogView(store: store, onImport: { _ in }, loadCatalog: {
                GlossaryCatalog(format: "sidewave.glossary.catalog", version: 1, glossaries: [])
            }), scheme: scheme, name: "glossary_catalog_empty_\(suffix)", width: 620, height: 540, settleTime: 0.2)
            try await render(GlossaryCatalogView(store: store, onImport: { _ in }, loadCatalog: {
                throw GlossaryCatalog.CatalogError.unavailable
            }), scheme: scheme, name: "glossary_catalog_unavailable_\(suffix)", width: 620, height: 540, settleTime: 0.2)
            try await render(MeetingSetupSheet(appState: state, onStart: { _ in }), scheme: scheme,
                             name: "meeting_setup_\(suffix)", width: 500, height: 390)
            try await render(MeetingSetupSheet(appState: state, onStart: { _ in }, helpExpanded: true), scheme: scheme,
                             name: "meeting_setup_details_\(suffix)", width: 500, height: 590)
        }
        XCTAssertFalse(state.isDictationBusy)
    }

    func testSubscribedGlossaryControlsAndChangeHistoryFit() async throws {
        let store = VocabularyStore(storageURL: AppPaths.applicationSupportDirectory().appendingPathComponent("bundle_render.json"))
        let subscription = GlossarySubscription(catalogID: "research", version: "2026.10.1", digest: String(repeating: "a", count: 64),
            lastChecked: Date(), changes: [.init(date: Date(), version: "2026.10.1", added: ["phenotype"], edited: ["genotype"], removed: ["legacy term"], notes: "Narrowed ambiguous aliases and updated pronunciation.")])
        let pack = VocabPack(name: "Research terminology", description: "Curated research words and acronyms.", isEnabled: true,
            terms: [VocabTerm(canonical: "phenotype", aliases: ["feno type"], definition: "Observable characteristics.", pronunciation: "fee no type", category: "Biology", scope: .both)], subscription: subscription)
        store.packs = [pack, VocabPack(name: "My words", description: "Personal corrections")]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(GlossaryCatalogView(store: store, onImport: { _ in }, loadCatalog: {
                throw GlossaryCatalog.CatalogError.unavailable
            }, initiallyInstalled: true), scheme: scheme, name: "glossary_installed_\(suffix)", width: 620, height: 540, settleTime: 0.2)
            try await render(GlossaryBundleHistoryView(pack: pack), scheme: scheme,
                name: "glossary_change_history_\(suffix)", width: 560, height: 500)
            try await render(WordEditSheet(packID: pack.id, term: pack.terms.first, store: store), scheme: scheme,
                name: "glossary_subscribed_word_\(suffix)", width: 520, height: 640)
        }
    }

    func testSharedWorkspaceAndDocumentCaptureFitInBothModes() async throws {
        let defaults = UserDefaults.standard
        let keys = ["showAdvancedControls", "dictationCleanupTemplate", "dictationCleanupEnabled", "dictationCleanupBackend", "skipRefine", "useDualEngineSmartPTT", "useMultiStageRendering", "useRealTimeRefine", "performFinalRefinePass"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let state = AppState()
        state.dictationCleanupTemplate = "standard"
        state.transcriptionService.modelState = .ready
        state.dictationCleanupEnabled = true
        state.dictationFormatter.state = .ready
        defaults.set(false, forKey: "skipRefine")
        defaults.set(true, forKey: "useDualEngineSmartPTT")
        defaults.set(true, forKey: "useMultiStageRendering")
        let pipelineKeys = ["useDualEngineSmartPTT", "useMultiStageRendering", "useRealTimeRefine", "performFinalRefinePass", "skipRefine"]
        let pipeline = pipelineKeys.map { defaults.bool(forKey: $0) }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for advanced in [false, true] {
                defaults.set(advanced, forKey: "showAdvancedControls")
                try await render(DictationHomeView(appState: state).environment(state), scheme: scheme,
                           name: "workspace_\(advanced ? "advanced" : "simple")_\(suffix)", width: 640, height: 560)
                if advanced {
                    try await render(DictationHomeView(appState: state).environment(state), scheme: scheme,
                               name: "workspace_advanced_tall_\(suffix)", width: 760, height: 960)
                }
                XCTAssertEqual(pipelineKeys.map { defaults.bool(forKey: $0) }, pipeline)
            }
            defaults.set(false, forKey: "showAdvancedControls")
            state.dictationCleanupTemplate = "instructions"
            state.specialtyEditedText = "1. Label the samples.\n2. Keep the control group separate."
            try await render(DictationHomeView(appState: state).environment(state), scheme: scheme,
                       name: "workspace_document_\(suffix)", width: 640, height: 560)
            state.transcriptionService.stagedTranscript.reset()
            _ = state.transcriptionService.stagedTranscript.ingestTdtCommitted("Review the samples before Friday.")
            state.transcriptionService.stagedTranscript.ingestEouPartial("Review the samples before Friday and keep each label with its sample")
            state.transcriptionService.isRecording = true
            try await render(SpecialtyPreviewView().environment(state), scheme: scheme,
                       name: "document_listening_\(suffix)", width: 640, height: 520, settleTime: 0.3)
            state.transcriptionService.isRecording = false
            state.isProcessingAgenticEdit = true
            state.dictationFormatter.state = .generating
            try await render(SpecialtyPreviewView().environment(state), scheme: scheme,
                       name: "document_editing_compact_\(suffix)", width: 640, height: 520, settleTime: 0.3)
            state.isProcessingAgenticEdit = false
            state.dictationFormatter.state = .ready
            state.dictationCleanupTemplate = "standard"
        }
    }

    func testSessionStatesRenderInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for phase in DictationSessionPhase.allCases {
                let view = DictationHomeSurface(
                    phase: phase,
                    statusDetail: phase == .failed ? "Microphone disconnected. Text saved to history." : nil,
                    hotkey: "Right Option",
                    transcript: phase == .idle || phase == .preparing ? "" : "The trial results are ready for review. We should check the figures before Friday.",
                    transcriptLabel: "Last dictation",
                    metadata: phase.isBusy ? "" : "2 minutes ago",
                    audioLevel: 0.18,
                    reduceMotion: true,
                    onPrimaryAction: {}, onCopy: {}, onDiscard: {}
                ) {
                    VStack {
                        LabeledContent("Microphone", value: "System Default")
                        LabeledContent("Refine", value: "Standard")
                    }
                }
                try await render(view, scheme: scheme, name: "home_\(phase.rawValue)_\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func testUnfinishedRefinementRecoveryFitsHome() async throws {
        let state = AppState()
        state.transcriptionService.modelState = .ready
        state.preserveUnfinishedRefinement("Keep the samples frozen until Friday. Send the report after lunch.")
        for scheme in [ColorScheme.light, .dark] {
            try await render(DictationHomeView(appState: state).environment(state), scheme: scheme,
                name: "home_unfinished_refinement_\(scheme == .dark ? "dark" : "light")", width: 675, height: 640)
        }
    }

    func testRecentDocumentsAndPausedCaptureFitTheWorkspace() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "dictationCleanupTemplate")
        defer {
            if let saved { defaults.set(saved, forKey: "dictationCleanupTemplate") }
            else { defaults.removeObject(forKey: "dictationCleanupTemplate") }
        }
        let state = AppState()
        state.dictationCleanupTemplate = "emailReady"
        state.specialtyEditedText = "Subject: Sample review\n\nHello team,\n\nPlease review the samples by Friday.\n\nThank you."
        XCTAssertTrue(state.newSpecialtyDocument())
        state.dictationCleanupTemplate = "instructions"
        state.specialtyEditedText = "1. Label the samples.\n2. Store them in the freezer."
        state.pendingSessionText = "Check the inventory before lunch."
        state.dictationFormatter.state = .ready
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(RecentDocumentsView(appState: state), scheme: scheme,
                             name: "documents_recent_\(suffix)", width: 540, height: 460)
            try await render(SpecialtyPreviewView().environment(state), scheme: scheme,
                             name: "document_paused_\(suffix)", width: 640, height: 520, settleTime: 0.4)
        }
    }

    func testWorkspaceMaterialPreservesReadableContent() async throws {
        let state = AppState()
        state.transcriptionService.modelState = .ready
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(DictationHomeView(appState: state).environment(state)
                .background(WindowBackgroundView(opacity: 0.84, blurRadius: 0)),
                scheme: scheme, name: "workspace_material_\(suffix)", width: 675, height: 624)
        }
    }

    func testMultilingualAndLongRecentOutputFitsCollapsedShelf() async throws {
        let view = DictationHomeSurface(
            phase: .delivered, hotkey: "⌥ Space",
            transcript: String(repeating: "日本語、한국어、العربية, café, and 🌿. A long transcript stays selectable and scrollable. ", count: 20),
            transcriptLabel: "Paused dictation", hasPendingSession: true,
            reduceMotion: true,
            onPrimaryAction: {}, onCopy: {}, onDiscard: {}
        ) { EmptyView() }
        try await render(view, scheme: .light, name: "home_multilingual")
    }

    func testHelpVocabularyHistoryAndOverlayRenderOffscreen() async throws {
        XCTAssertTrue(AppPaths.isTestHost)
        let motionPreference = UserDefaults.standard.object(forKey: "reduceAppMotion") as? Bool
        defer { XCTAssertEqual(UserDefaults.standard.object(forKey: "reduceAppMotion") as? Bool, motionPreference) }
        let appState = AppState()
        let historyURL = AppPaths.applicationSupportDirectory().appendingPathComponent("render_history.json")
        let history = HistoryStore(storageURL: historyURL)
        defer { _ = history.flush(); try? FileManager.default.removeItem(at: historyURL) }
        history.addEntry(text: "The observations are ready. Review the figures before the next meeting.", appName: "Notes")
        history.addEntry(text: "Please review the control group before Friday.", appName: "Notes", rawText: "Please, um, review the control group before Friday.", eouText: "please um review the control group before friday", refineBackend: "gemma4-12b")
        let defaults = UserDefaults.standard
        let keys = ["useDualEngineSmartPTT", "useMultiStageRendering", "showLiveGhostText", "appearance", "tdtHiddenRefineSweep", "perWordTransitionAnimation"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "useDualEngineSmartPTT")
        defaults.set(true, forKey: "useMultiStageRendering")
        defaults.set(true, forKey: "showLiveGhostText")
        defaults.set(false, forKey: "tdtHiddenRefineSweep")
        defaults.set(false, forKey: "perWordTransitionAnimation")
        defaults.set("system", forKey: "appearance")
        let staged = appState.transcriptionService.stagedTranscript
        staged.ingestEouPartial("the observations are ready for review")
        staged.ingestTdtCommitted("The observations are ready for review.")
        staged.ingestEouPartial("the observations are ready for review next we should compare the figures")
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(HelpView().environment(appState), scheme: scheme, name: "help_\(suffix)", width: 808, height: 623)
            try await render(VocabularyView().environment(appState), scheme: scheme, name: "vocabulary_\(suffix)")
            try await render(HistoryView(historyStore: history, shortcutDisplay: "Right Option").environment(appState),
                       scheme: scheme, name: "history_\(suffix)")
            try await render(DictationOverlayContent(appState: appState),
                       scheme: scheme, name: "overlay_\(suffix)", width: 740, height: 350)
        }
        history.addEntry(text: "Keep the samples cold. Send the report on Friday.", appName: "Recovered",
                         entryType: .recovered, recoverySourceID: "render_partial", recoveryIncomplete: true)
        for scheme in [ColorScheme.light, .dark] {
            try await render(HistoryView(historyStore: history, shortcutDisplay: "Right Option").environment(appState),
                       scheme: scheme, name: "history_partial_\(scheme == .dark ? "dark" : "light")", width: 640, height: 520)
        }
    }

    func testAdvancedSettingsMeetingAndWordDetailsRenderOffscreen() async throws {
        let motionPreference = UserDefaults.standard.object(forKey: "reduceAppMotion") as? Bool
        defer { XCTAssertEqual(UserDefaults.standard.object(forKey: "reduceAppMotion") as? Bool, motionPreference) }
        let appState = AppState()
        appState.meetingService.meetingModelsState = .ready
        appState.transcriptionService.modelState = .ready
        let inputSelection = appState.audioDeviceManager.selectedDeviceUID
        appState.audioDeviceManager.selectedDeviceUID = nil
        defer { appState.audioDeviceManager.selectedDeviceUID = inputSelection }
        let defaults = UserDefaults.standard
        let keys = ["showAdvancedControls", "lastSelectedSettingsTab", "appearance", "audioInputPriorityList"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "showAdvancedControls")
        defaults.set("settingsGeneral", forKey: "lastSelectedSettingsTab")
        defaults.set([String](), forKey: "audioInputPriorityList")
        defaults.set("system", forKey: "appearance")
        let vocabularyURL = AppPaths.applicationSupportDirectory().appendingPathComponent("render_vocabulary.json")
        let store = VocabularyStore(storageURL: vocabularyURL)
        defer { try? FileManager.default.removeItem(at: vocabularyURL) }
        let pack = VocabPack(name: "My research", description: "Words for this project", isEnabled: true,
            terms: [VocabTerm(canonical: "phenotype", aliases: ["feno type"], definition: "An observed trait", scope: .both)])
        store.packs = [pack]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            defaults.set(false, forKey: "showAdvancedControls")
            try await render(DictationHomeView(appState: appState).environment(appState), scheme: scheme, name: "home_controls_\(suffix)")
            try await render(VocabularyView(store: store).environment(appState), scheme: scheme, name: "vocabulary_populated_\(suffix)")
            defaults.set(true, forKey: "showAdvancedControls")
            try await render(DictationHomeView(appState: appState).environment(appState), scheme: scheme, name: "advanced_\(suffix)")
            defaults.set(false, forKey: "showAdvancedControls")
            try await render(AppSettingsView().environment(appState), scheme: scheme, name: "settings_\(suffix)", width: 780, height: 650)
            try await render(MeetingDashboardView(appState: appState).environment(appState), scheme: scheme, name: "meeting_\(suffix)")
            for (phase, name) in [(MeetingState.recording(duration: 3661), "recording"),
                                  (.processing(stage: .transcribing), "processing"),
                                  (.error("The microphone was disconnected. Reconnect it or choose another microphone in Settings."), "error")] {
                appState.meetingService.state = phase
                try await render(MeetingDashboardView(appState: appState).environment(appState), scheme: scheme,
                                 name: "meeting_\(name)_\(suffix)", width: 675, height: 560)
            }
            appState.meetingService.state = .idle
            try await render(WordEditSheet(packID: pack.id, term: pack.terms.first, store: store),
                       scheme: scheme, name: "word_details_\(suffix)", width: 520, height: 640)
            let partial = MeetingTranscript(segments: [MeetingSegment(speakerId: "one", speakerLabel: "Speaker 1",
                text: "Review the greenhouse results before Friday. The observations need another check.", startTime: 0, endTime: 12)],
                speakerNames: [:], duration: 12, timestamp: Date(), isPartial: true)
            appState.meetingService.transcript = partial
            appState.meetingService.state = .complete
            appState.meetingService.postRecordingWarning = "A partial transcript was recovered. The recording is kept on disk for another processing attempt."
            try await render(MeetingDashboardView(appState: appState).environment(appState), scheme: scheme, name: "meeting_partial_\(suffix)")
            try await render(MeetingResultsView(transcript: partial, isLiveMeeting: true, onDismiss: {}, onPurgeAudio: {}),
                       scheme: scheme, name: "meeting_results_\(suffix)", width: 760, height: 650)
            try await render(MeetingFormatView(appState: appState, transcript: partial),
                       scheme: scheme, name: "meeting_format_\(suffix)", width: 640, height: 560)
            appState.formatterService.state = .generating(output: "", note: "Preparing meeting notes")
            try await render(MeetingFormatView(appState: appState, transcript: partial),
                       scheme: scheme, name: "meeting_format_busy_\(suffix)", width: 640, height: 560)
            appState.meetingService.state = .idle
        }
    }

    func testEmptyMeetingRecoveryAndFormattingFit() async throws {
        let appState = AppState()
        let empty = MeetingTranscript(segments: [], speakerNames: [:], duration: 6, timestamp: Date())
        appState.meetingService.transcript = empty
        appState.meetingService.postRecordingWarning = "The recording is kept for another processing attempt, including after you close SideWave."
        appState.meetingService.state = .complete
        appState.meetingService.meetingModelsState = .ready
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(MeetingDashboardView(appState: appState).environment(appState),
                scheme: scheme, name: "meeting_no_speech_\(suffix)")
            try await render(MeetingResultsView(transcript: empty, isLiveMeeting: true, onDismiss: {}, onPurgeAudio: {}, onRediarize: { _ in }),
                scheme: scheme, name: "meeting_no_speech_results_\(suffix)", width: 640, height: 360)
            try await render(MeetingFormatView(appState: appState, transcript: empty),
                scheme: scheme, name: "meeting_no_speech_format_\(suffix)", width: 640, height: 560)
        }
    }

    func testDocumentWorkspaceAndAllSettingsAndHelpTopicsFit() async throws {
        let appState = AppState()
        let defaults = UserDefaults.standard
        let keys = ["showAdvancedControls", "dictationCleanupTemplate", "audioInputPriorityList", "dictationCleanupEnabled", "dictationCleanupBackend", "skipRefine", "skipRefineAutoForced", "dictationRefineAdvancedOpen", "gemmaThinkingMode", "dictationOpenSection"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set([String](), forKey: "audioInputPriorityList")
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            appState.dictationCleanupTemplate = "instructions"
            appState.dictationFormatter.state = .ready
            try await render(SpecialtyPreviewView().environment(appState), scheme: scheme,
                       name: "document_empty_\(suffix)", width: 720, height: 540)
            appState.specialtyEditedText = "1. Label the samples.\n2. Keep the control group separate.\n3. Review the results on Friday."
            appState.isProcessingAgenticEdit = true
            appState.dictationFormatter.state = .generating
            try await render(SpecialtyPreviewView().environment(appState), scheme: scheme,
                       name: "document_working_\(suffix)", width: 720, height: 540, settleTime: 1.5)
            appState.isProcessingAgenticEdit = false
            appState.dictationFormatter.state = .ready
            appState.specialtyEditedText = ""
            for topic in HelpSection.allCases {
                try await render(HelpView(section: topic).environment(appState), scheme: scheme,
                           name: "help_\(topic.rawValue)_\(suffix)", width: 808, height: 650)
            }
            defaults.set(true, forKey: "showAdvancedControls")
            for category in SidebarItem.settingsSidebarGroups.flatMap(\.items).map(\.item) {
                try await render(SettingsContentView(category: category, appState: appState).environment(appState),
                           scheme: scheme, name: "settings_\(category.persistedRawValue)_\(suffix)", width: 540, height: 650)
            }
            appState.dictationCleanupBackend = DictationFormatterService.Backend.gemma4_12B.rawValue
            appState.dictationCleanupEnabled = true
            defaults.set(false, forKey: "skipRefine")
            appState.dictationFormatter.state = .ready
            try await render(SettingsContentView(category: .settingsRefine, appState: appState).environment(appState),
                       scheme: scheme, name: "settings_refine_enabled_\(suffix)", width: 540, height: 650)
            defaults.set(true, forKey: "dictationRefineAdvancedOpen")
            defaults.set("Refine", forKey: "dictationOpenSection")
            try await render(DictationView(appState: appState).environment(appState), scheme: scheme,
                       name: "dictation_refine_advanced_\(suffix)", width: 675, height: 624)
            for section in ["Filters", "Formatting"] {
                defaults.set(section, forKey: "dictationOpenSection")
                try await render(DictationView(appState: appState).environment(appState), scheme: scheme,
                           name: "dictation_\(section.lowercased())_\(suffix)", width: 675, height: 624)
            }
            appState.dictationCleanupEnabled = false
        }
    }

    func testDocumentTemplatesAndRecoveryFitTheMinimumViewport() async throws {
        let state = AppState()
        state.transcriptionService.modelState = .ready
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "dictationCleanupTemplate")
        defer {
            if let saved { defaults.set(saved, forKey: "dictationCleanupTemplate") }
            else { defaults.removeObject(forKey: "dictationCleanupTemplate") }
        }
        let documents: [(DictationFormatterService.Template, String)] = [
            (.instructions, "# Sample review\n\n1. Label the samples.\n   - Keep the control group separate.\n2. Review the results on Friday.\n\nDo not change the measurements."),
            (.emailReady, "Subject: Sample review\n\nHello team,\n\nPlease review the samples by Friday. Keep the control group separate.\n\nThank you."),
            (.aiPrompt, "<task>Review the results.</task>\n<constraints>Keep all units. Do not invent measurements.</constraints>"),
            (.custom, "## Review\n\n- Compare the control group.\n- Keep the original measurements.\n\n日本語、한국어、العربية, café.")
        ]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for (template, document) in documents {
                state.dictationCleanupTemplate = template.rawValue
                state.specialtyEditedText = document
                state.dictationFormatter.state = .ready
                state.agenticEditInstruction = "Make the wording more concise without changing any measurements."
                state.documentEditNotice = nil
                try await render(SpecialtyPreviewView().environment(state), scheme: scheme,
                           name: "document_\(template.rawValue)_\(suffix)", width: 640, height: 520, settleTime: 0.4)
            }
            try await render(DocumentInstructionsView(appState: state), scheme: scheme,
                       name: "document_rules_\(suffix)", width: 500, height: 345)
            state.documentEditNotice = "The model could not apply the change. Your document and instruction are kept."
            state.dictationFormatter.state = .error("Connection interrupted")
            try await render(SpecialtyPreviewView().environment(state), scheme: scheme,
                       name: "document_recovery_\(suffix)", width: 640, height: 520, settleTime: 0.4)
            state.isProcessingAgenticEdit = true
            state.dictationFormatter.state = .generating
            state.documentEditNotice = nil
            try await render(DictationHomeView(appState: state).environment(state), scheme: scheme,
                       name: "home_document_working_\(suffix)", width: 640, height: 560)
            state.isProcessingAgenticEdit = false
            let activity = ModelDownloadActivity()
            let id = activity.begin(displayName: "Gemma 4 E4B", repoID: "mlx-community/gemma-4-e4b-it-4bit", baselineBytes: 2_000_000_000)
            activity.setStage(.verifying, detail: "Checking tokenizer, template, and weight files", sessionID: id)
            activity.update(files: [], overall: 1, signalsRealDownload: false, sessionID: id,
                            downloadedBytes: 5_200_000_000, totalBytes: 5_200_000_000)
            try await render(ModelRecoveryView(activity: activity), scheme: scheme,
                       name: "downloads_verifying_\(suffix)", width: 460, height: 270)
            activity.markComplete(sessionID: id)
            try await render(ModelRecoveryView(activity: activity), scheme: scheme,
                       name: "downloads_complete_\(suffix)", width: 460, height: 270)
        }
    }

    func testDownloadStagesFitTheSmallWindow() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let activity = ModelDownloadActivity()
            let id = activity.begin(displayName: "Gemma 4 E2B", repoID: "mlx-community/gemma-4-E2B-it-4bit", baselineBytes: 0)
            activity.update(files: (1...8).map {
                .init(id: "model-part-\($0).safetensors", totalBytes: 400_000_000, downloadedBytes: 120_000_000, finishedAt: nil)
            }, overall: 0.3, signalsRealDownload: true, sessionID: id)
            _ = activity.begin(displayName: "Speech recognition", repoID: "FluidInference/parakeet-ultra-coreml", baselineBytes: 0)
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(ModelRecoveryView(activity: activity), scheme: scheme,
                       name: "downloads_active_\(suffix)", width: 500, height: 360)
            try await render(ModelRecoveryView(activity: activity, showsFiles: true), scheme: scheme,
                       name: "downloads_files_\(suffix)", width: 500, height: 430)
            activity.markError("The connection was interrupted. Valid files are kept; retry preparation to continue.", sessionID: id)
            try await render(ModelRecoveryView(activity: activity, retryModel: { _ in }, canRetry: { _ in true }), scheme: scheme,
                       name: "downloads_error_\(suffix)", width: 500, height: 430)
        }
    }

    func testOnboardingExperimentalRecoveryAndPrivacySurfaces() async throws {
        let appState = AppState()
        let defaults = UserDefaults.standard
        let keys = ["showAdvancedControls", "experimentalFeatures", "appearance", "lastSelectedSettingsTab"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "showAdvancedControls")
        defaults.set(true, forKey: "experimentalFeatures")
        defaults.set("system", forKey: "appearance")
        let orphan = OrphanedMeeting(id: UUID(), directory: AppPaths.applicationSupportDirectory(),
            startedAt: Date(timeIntervalSince1970: 1_780_000_000), recordedDuration: 3_605,
            diskBytes: 348_000_000, hasLiveSegments: true, status: .recording)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(WelcomeView(appState: appState), scheme: scheme, name: "onboarding_\(suffix)", width: 675, height: 550, settleTime: 1)
            try await render(MenuBarView(appState: appState), scheme: scheme, name: "menu_bar_\(suffix)", width: 280, height: 390)
            try await render(DataTransparencyView(), scheme: scheme, name: "transparency_\(suffix)", width: 620, height: 720)
            try await render(SettingsContentView(category: .settingsExperimental, appState: appState).environment(appState),
                       scheme: scheme, name: "experimental_\(suffix)", width: 540, height: 1_000)
            appState.isProcessingAgenticEdit = true
            try await render(ModelStorageSection(appState: appState), scheme: scheme,
                       name: "model_storage_busy_\(suffix)", width: 500, height: 560)
            appState.isProcessingAgenticEdit = false
            for enabled in [false, true] {
                try await render(MeetingRecoverySheet(orphan: orphan, canResume: enabled, onResume: {}, onTranscribe: {}, onDiscard: {}, onLater: {}),
                           scheme: scheme, name: "meeting_recovery_\(enabled)_\(suffix)", width: 560, height: 430)
            }
        }
    }

    func testTourAndBlockedMicrophoneFitTheSmallWindow() async throws {
        let appState = AppState()
        // A busy session prevents this offscreen microphone sheet from opening input.
        appState.transcriptionService.isRecording = true
        defer { appState.transcriptionService.isRecording = false }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for step in TutorialSteps.all.indices {
                try await render(TutorialOverlay(tutorialState: .constant(TutorialState(currentStep: step)),
                           isShowing: .constant(true)).environment(appState),
                           scheme: scheme, name: "tour_\(step)_\(suffix)", width: 640, height: 560, settleTime: 0.5)
            }
            try await render(MicrophoneTestSheet(appState: appState), scheme: scheme,
                       name: "microphone_busy_\(suffix)", width: 480, height: 460)
        }
        XCTAssertFalse(MicTestController.isCapturing)
    }

    func testHomeShowsSpeechPreparationBeforeEnablingDictation() async throws {
        let state = AppState()
        let editing = DictationHomeSurface(phase: .idle, speechModelState: .loading,
            hotkey: "Right Option", transcript: "", transcriptLabel: "Recent dictation", metadata: "",
            isEditingDocument: true, onPrimaryAction: {}, onCopy: {}, onDiscard: {}) { EmptyView() }
        XCTAssertFalse(editing.speechNeedsPreparation, "An active document edit takes priority over idle speech preparation")
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for (name, modelState) in [("loading", ModelState.loading),
                                       ("error", ModelState.error("Speech preparation failed. Open Model settings to retry."))] {
                state.transcriptionService.modelState = modelState
                try await render(DictationHomeView(appState: state).environment(state), scheme: scheme,
                    name: "home_speech_\(name)_\(suffix)", width: 675, height: 670)
            }
            state.transcriptionService.modelState = .loading
            state.isProcessingAgenticEdit = true
            try await render(DictationHomeView(appState: state).environment(state), scheme: scheme,
                name: "home_document_during_speech_preparation_\(suffix)", width: 675, height: 670)
            state.isProcessingAgenticEdit = false
        }
    }

    func testTutorialUsesReadablePanelsAcrossDesktopSizes() async throws {
        let appState = AppState()
        for size in [CGSize(width: 675, height: 720), CGSize(width: 1_920, height: 1_080)] {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = "\(Int(size.width))_\(scheme == .dark ? "dark" : "light")"
                appState.reduceAppMotion = scheme == .light
                for step in TutorialSteps.all.indices {
                    try await render(TutorialOverlay(tutorialState: .constant(TutorialState(currentStep: step)),
                        isShowing: .constant(true)).environment(appState), scheme: scheme,
                        name: "tutorial_readable_\(step)_\(suffix)", width: size.width, height: size.height, settleTime: 0.3,
                        requiresContentFit: true)
                }
            }
        }
        XCTAssertLessThan(CoachMarkSize.width, 640)
        XCTAssertLessThan(CoachMarkSize.height, 560)
    }

    func testRecognitionModesShareAReadablePreviewAtEverySize() async throws {
        let defaults = UserDefaults.standard
        let keys = ["sideWaveExperience", "useDualEngineSmartPTT", "useMultiStageRendering", "useRealTimeRefine",
                    "skipRefine", "skipRefineAutoForced", "tdtHiddenRefineSweep", "useEouToRefineDirect",
                    "showLiveGhostText", "performFinalRefinePass", "dictationCleanupEnabled", "dictationCleanupTemplate",
                    "overlayExpanded", "overlaySize", "customOverlayWidth", "appearance", "reduceAppMotion", "liquidGlassMode"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("system", forKey: "appearance")
        defaults.set(true, forKey: "reduceAppMotion")
        let state = AppState()
        state.transcriptionService.modelState = .ready
        for mode in ["standard", "speedy"] {
            ExperiencePreset.apply(mode, appState: state)
            let service = state.transcriptionService
            service.stagedTranscript.reset()
            service.confirmedText = "Review the sample results before Friday. Keep the controls and observations together."
            service.volatileText = "the final paragraph is still being dictated and can change"
            if mode == "standard" {
                service.stagedTranscript.ingestEouPartial(service.confirmedText.lowercased())
                service.stagedTranscript.ingestTdtCommitted(service.confirmedText)
                service.stagedTranscript.ingestEouPartial(service.confirmedText.lowercased() + " " + service.volatileText)
            }
            for scheme in [ColorScheme.light, .dark] {
                for size in ["compact", "standard", "expanded"] {
                    defaults.set(size == "expanded", forKey: "overlayExpanded")
                    defaults.set(size == "compact" ? OverlaySize.compact.rawValue : OverlaySize.standard.rawValue, forKey: "overlaySize")
                    defaults.set(size == "compact" ? OverlaySize.compact.width : OverlaySize.standard.width, forKey: "customOverlayWidth")
                    try await render(DictationOverlayContent(appState: state), scheme: scheme,
                        name: "recognition_\(mode)_\(size)_\(scheme == .dark ? "dark" : "light")",
                        width: size == "expanded" ? 1_100 : 740, height: size == "expanded" ? 980 : 350)
                }
                state.isCleaningUp = true
                state.cleanupStatus = "Sending text"
                state.cleanupStreamingText = service.confirmedText + " " + service.volatileText
                defaults.set(false, forKey: "overlayExpanded")
                defaults.set(OverlaySize.standard.rawValue, forKey: "overlaySize")
                try await render(DictationOverlayContent(appState: state), scheme: scheme,
                    name: "recognition_delivery_\(mode)_\(scheme == .dark ? "dark" : "light")", width: 740, height: 350)
                state.isCleaningUp = false
                try await render(DictationView(appState: state), scheme: scheme,
                    name: "mode_controls_\(mode)_\(scheme == .dark ? "dark" : "light")")
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try await render(RecognitionPreview(confirmed: "", draft: String(repeating: "The ongoing sentence remains provisional and wraps naturally. ", count: 4), reduceMotion: true),
                             scheme: scheme, name: "recognition_draft_\(suffix)", width: 310, height: 250)
            try await render(RecognitionPreview(confirmed: "日本語 한국어 العربية café.", draft: "A_long_word_without_spaces_that_must_wrap_without_disappearing_from_the_preview.", reduceMotion: true),
                             scheme: scheme, name: "recognition_multilingual_\(suffix)", width: 310, height: 250)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func containsRenderedContent(_ image: CGImage) throws -> Bool {
        // PNG compression and display scale do not measure whether a view is blank.
        let width = min(256, image.width)
        let height = min(256, image.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var contrastingPixels = 0
        for pixel in 0..<(width * height) {
            if (0..<3).contains(where: { abs(Int(pixels[pixel * 4 + $0]) - Int(pixels[$0])) > 24 }) {
                contrastingPixels += 1
            }
        }
        return contrastingPixels >= max(8, width * height / 1000)
    }

    private func render<V: View>(_ view: V, scheme: ColorScheme, name: String, width: CGFloat = 675, height: CGFloat = 624, settleTime: TimeInterval = 0.05, minimumVerticalOffset: CGFloat? = nil, requiresContentFit: Bool = false) async throws {
        let reviewSurface = ProcessInfo.processInfo.environment["SIDEWAVE_REVIEW_SURFACE"]
        if let reviewSurface, reviewSurface != name { return }
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previousAppearance }
        let content = view
            .frame(width: width, height: height)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame,
            styleMask: reviewSurface == nil ? [.borderless] : [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "SideWave review: \(name)"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let presentWindow = reviewSurface != nil || ProcessInfo.processInfo.environment["SIDEWAVE_PRESENT_RENDER_WINDOWS"] == "1"
        if presentWindow {
            window.center()
            window.orderFrontRegardless()
            window.displayIfNeeded()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(presentWindow ? max(0.3, settleTime) : settleTime))
        defer {
            if presentWindow { window.orderOut(nil) }
            window.contentView = nil
        }
        if let minimumVerticalOffset {
            let offsets = descendants(of: host).compactMap { $0 as? NSScrollView }
                .filter { $0.bounds.width > 300 }.map { $0.contentView.bounds.origin.y }
            XCTAssertGreaterThanOrEqual(offsets.max() ?? 0, minimumVerticalOffset,
                                        "A deep link set before opening Settings must scroll to its control")
        }
        if requiresContentFit {
            let scrollViews = descendants(of: host).compactMap { $0 as? NSScrollView }
                .filter { $0.bounds.width > 300 }
            XCTAssertFalse(scrollViews.isEmpty, "Check the actual reading viewport")
            for scrollView in scrollViews {
                let document = try XCTUnwrap(scrollView.documentView)
                XCTAssertLessThanOrEqual(document.bounds.height, scrollView.contentSize.height + 1,
                    "Tutorial instructions and shortcuts must fit without scrolling")
            }
        }
        try await capture(host: host, window: window, scheme: scheme, name: name)
        if reviewSurface != nil {
            let seconds = Double(ProcessInfo.processInfo.environment["SIDEWAVE_REVIEW_SECONDS"] ?? "120") ?? 120
            let deadline = Date().addingTimeInterval(min(600, max(10, seconds)))
            while window.isVisible, Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        guard ProcessInfo.processInfo.environment["SIDEWAVE_RENDER_SCROLL_PAGES"] == "1",
              name.hasPrefix("help_") || name.hasPrefix("settings_") || name.hasPrefix("dictation_") else { return }
        let minimumScrollWidth: CGFloat = name.contains("_sidebar_") ? 100 : 300
        let scrollViews = descendants(of: host).compactMap { $0 as? NSScrollView }
            .filter { $0.bounds.width > minimumScrollWidth && ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 1 }
        if name.hasPrefix("dictation_refine_advanced_") {
            XCTAssertFalse(scrollViews.isEmpty, "Expanded refinement must scroll in the default viewport")
        }
        for (index, scrollView) in scrollViews.enumerated() {
            if name.hasPrefix("dictation_") {
                XCTAssertTrue(scrollView.hasVerticalScroller, "Overflowing dictation controls need a native scroll affordance")
            }
            let document = try XCTUnwrap(scrollView.documentView)
            let bottom = max(0, document.bounds.height - scrollView.contentSize.height)
            let stride = max(100, scrollView.contentSize.height - 60)
            var offset: CGFloat = 0
            var page = 0
            while offset < bottom && page < 40 {
                offset = min(bottom, offset + stride)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                page += 1
                try await capture(host: host, window: window, scheme: scheme,
                                  name: "\(name)_scroll\(index)_page\(page)")
            }
            XCTAssertEqual(scrollView.contentView.bounds.origin.y, bottom, accuracy: 1,
                           "All controls and help content must be reachable by scrolling")
        }
    }

    private func capture(host: NSView, window: NSWindow, scheme: ColorScheme, name: String) async throws {
        let width = host.bounds.width
        let height = host.bounds.height
        if ProcessInfo.processInfo.environment["SIDEWAVE_PRESENT_RENDER_WINDOWS"] == "1",
           let directory = ProcessInfo.processInfo.environment["SIDEWAVE_RENDER_OUTPUT"] {
            print("RENDER_WINDOW \(name) \(window.windowNumber) screen_access=\(CGPreflightScreenCaptureAccess())")
            if CGPreflightScreenCaptureAccess() {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-l", String(window.windowNumber), directory + "/" + name + "_window.png"]
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            }
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        let webViews = descendants(of: host).compactMap { $0 as? WKWebView }.filter { !$0.isHidden && !$0.bounds.isEmpty }
        var webSnapshots: [(NSRect, NSImage)] = []
        for webView in webViews {
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            var ready = false
            while ContinuousClock.now < deadline {
                let state = try? await webView.callAsyncJavaScript(
                    "return {text:document.querySelector('main')?.innerText ?? '', appearance:document.documentElement.dataset.appearance, width:document.documentElement.scrollWidth};",
                    arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
                if let text = state?["text"] as? String, !text.isEmpty,
                   state?["appearance"] as? String == (scheme == .dark ? "dark" : "light") {
                    XCTAssertLessThanOrEqual((state?["width"] as? Double) ?? 0, webView.bounds.width + 1,
                                             "Document text must fit horizontally in its viewport")
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(ready, "The document must render before its screenshot is accepted")
            let image = try await webView.takeSnapshot(configuration: nil)
            var frame = host.convert(webView.bounds, from: webView)
            if host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
            webSnapshots.append((frame, image))
        }
        let data: Data
        if webSnapshots.isEmpty {
            data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        } else {
            let result = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: result))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let scale = NSAffineTransform()
            scale.scaleX(by: CGFloat(bitmap.pixelsWide) / width, yBy: CGFloat(bitmap.pixelsHigh) / height)
            scale.concat()
            NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size).draw(in: host.bounds)
            for (frame, image) in webSnapshots { image.draw(in: frame) }
            NSGraphicsContext.restoreGraphicsState()
            data = try XCTUnwrap(result.representation(using: .png, properties: [:]))
        }
        let capturedImage = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
        XCTAssertTrue(try containsRenderedContent(capturedImage),
                      "The view must contain rendered content, not a blank canvas")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SIDEWAVE_RENDER_OUTPUT"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent(name + ".png"))
        }
    }
}
