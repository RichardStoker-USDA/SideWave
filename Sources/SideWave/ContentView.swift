// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import TipKit

// MARK: - SidebarItem (used by Settings window)

enum SidebarItem: Hashable, Identifiable {
    case home
    case history
    case dictionary
    case settingsGeneral
    case settingsDictation        // Speech Recognition (model + EOU + CTC status)
    case settingsMeetings
    case settingsRefine           // Refine settings (template, backend, custom instructions)
    case settingsAudio            // Microphone (picker, standby, behavior)
    case settingsSound            // Sound Effects (per-event toggles)
    case settingsOverlay
    case settingsAdvanced
    case settingsPrivacy
    case settingsAbout
    case settingsExperimental

    var id: Self { self }

    var isSettingsItem: Bool {
        switch self {
        case .home, .history, .dictionary: return false
        default: return true
        }
    }

    /// Hidden tab for in-development features. Only shown in the sidebar
    /// when Experimental Features is on (in Settings → Advanced).
    static let experimentalCategory: (item: SidebarItem, label: String, icon: String) =
        (.settingsExperimental, "Experimental", "flask")

    /// Settings sidebar sections, grouped like the Help sidebar.
    static let settingsSidebarGroups: [(header: String, items: [(item: SidebarItem, label: String, icon: String)])] = [
        ("Dictation", [
            (.settingsGeneral, "General", "gearshape"),
            (.settingsDictation, "Speech Recognition", "waveform.badge.mic"),
            (.settingsRefine, "Refine", "text.badge.checkmark"),
            (.settingsMeetings, "Meetings", "person.3"),
        ]),
        ("Audio", [
            (.settingsAudio, "Microphone", "mic"),
            (.settingsSound, "Sound Effects", "speaker.wave.2"),
        ]),
        ("Interface", [
            (.settingsOverlay, "Overlay", "inset.filled.bottomthird.rectangle"),
        ]),
        ("System", [
            (.settingsPrivacy, "Privacy", "hand.raised"),
            (.settingsAdvanced, "Advanced", "slider.horizontal.3"),
            (.settingsAbout, "About", "info.circle"),
        ]),
    ]

    /// Simple view leaves out the Advanced category.
    static func settingsSidebarGroups(showingAdvanced: Bool) -> [(header: String, items: [(item: SidebarItem, label: String, icon: String)])] {
        guard !showingAdvanced else { return settingsSidebarGroups }
        return settingsSidebarGroups.map { group in
            (header: group.header, items: group.items.filter { $0.item != .settingsAdvanced })
        }
    }

    /// Stable string for UserDefaults persistence. Distinct from
    /// `Hashable.hashValue` because that's not stable across runs.
    var persistedRawValue: String {
        switch self {
        case .home: return "home"
        case .history: return "history"
        case .dictionary: return "dictionary"
        case .settingsGeneral: return "settingsGeneral"
        case .settingsDictation: return "settingsDictation"
        case .settingsRefine: return "settingsRefine"
        case .settingsMeetings: return "settingsMeetings"
        case .settingsAudio: return "settingsAudio"
        case .settingsSound: return "settingsSound"
        case .settingsOverlay: return "settingsOverlay"
        case .settingsAdvanced: return "settingsAdvanced"
        case .settingsPrivacy: return "settingsPrivacy"
        case .settingsAbout: return "settingsAbout"
        case .settingsExperimental: return "settingsExperimental"
        }
    }

    static func fromPersistedRawValue(_ raw: String) -> SidebarItem? {
        switch raw {
        case "settingsGeneral": return .settingsGeneral
        case "settingsDictation": return .settingsDictation
        case "settingsRefine": return .settingsRefine
        case "settingsMeetings": return .settingsMeetings
        case "settingsAudio": return .settingsAudio
        case "settingsSound": return .settingsSound
        case "settingsOverlay": return .settingsOverlay
        case "settingsLocalPolish": return .settingsRefine
        case "settingsOutput": return .settingsGeneral
        case "settingsText": return .settingsGeneral
        case "settingsAdvanced": return .settingsAdvanced
        case "settingsPrivacy": return .settingsPrivacy
        case "settingsAbout": return .settingsAbout
        case "settingsExperimental": return .settingsExperimental
        default: return nil
        }
    }
}

// MARK: - Main Content View (toolbar-based navigation)

struct ContentView: View {
    enum Tab: String { case dashboard, dictation, history, dictionary, meeting }

    @Environment(AppState.self) var appState
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: Tab = .dashboard
    @AppStorage("meetingTranscriptionEnabled") private var meetingTabEnabled = false
    @AppStorage(WindowAppearance.opacityKey) private var windowOpacity = WindowAppearance.defaultOpacity
    @AppStorage(ExperiencePreset.experienceKey) private var sideWaveExperience = "full"
    @AppStorage("perfRecommendationShown") private var perfRecommendationShown = false
    @State private var showLighterExperiencePrompt = false

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .dashboard:
            if shouldShowWelcome {
                WelcomeView(appState: appState)
            } else {
                DictationHomeView(appState: appState)
            }
        case .dictation:
            DictationView(appState: appState)
        case .history:
            HistoryView(
                historyStore: appState.historyStore,
                shortcutDisplay: appState.hotkeyManager.shortcut.displayString
            )
        case .dictionary:
            VocabularyView()
        case .meeting:
            MeetingDashboardView(appState: appState)
        }
    }

    /// Turning off Meetings while one is recording stops the capture right away, since the Stop
    /// button is about to disappear, and queues what was recorded for transcription.
    private func stopMeetingCaptureOnDisable() {
        if case .recording = appState.meetingService.state {
            appState.meetingService.stopRecording()
            appState.meetingService.processRecording()
            appState.showToast("Meeting mode off. Recording stopped and transcribing", icon: "waveform.slash")
        }
    }

    var body: some View {
        @Bindable var appState = appState
        tabContent
        .frame(minWidth: 640, minHeight: 560)
        .background {
            WindowBackgroundView(opacity: windowOpacity)
            .ignoresSafeArea()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                meetingToolbarPicker
            }
            // The section picker draws its own glass track.
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(.bar, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshMicrophonePermission()
            appState.isAccessibilityGranted = AXIsProcessTrusted()
        }
        .onChange(of: meetingTabEnabled) {
            // If meeting mode gets disabled, stop any live recording first (no
            // hot mic), then switch back to dashboard if the tab was showing.
            if !meetingTabEnabled {
                stopMeetingCaptureOnDisable()
                if selectedTab == .meeting { selectedTab = .dashboard }
            }
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            switch newTab {
            case .history: appState.currentPage = .history
            case .dictionary: appState.currentPage = .dictionary
            default: appState.currentPage = .home
            }
            // Unload LLM when leaving Meeting tab to free 3-6 GB of RAM
            if oldTab == .meeting && newTab != .meeting {
                appState.formatterService.unloadModel()
            }
        }
        .onChange(of: appState.requestedPage) {
            if let page = appState.requestedPage {
                switch page {
                case .history: selectedTab = .history
                case .dictionary: selectedTab = .dictionary
                default: selectedTab = .dashboard
                }
                appState.requestedPage = nil
            }
        }
        // Start the tour after setup completes and Home has settled.
        .onChange(of: shouldShowWelcome) { wasShowing, isShowing in
            guard wasShowing, !isShowing,
                  appState.tutorialState.showTutorialOnLaunch,
                  !appState.tutorialState.hasCompletedTutorial else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard selectedTab == .dashboard, !appState.showTutorial else { return }
                appState.showTutorial = true
            }
        }
        // Recovery for meetings interrupted by a crash or quit: one sheet per meeting, in order.
        // Held while a meeting is active, so acting on one can't disturb a live recording.
        .sheet(isPresented: Binding(
            get: {
                guard case .idle = appState.meetingService.state else { return false }
                return !appState.pendingMeetingRecovery.isEmpty
            },
            set: { if !$0 { } }
        )) {
            if let orphan = appState.pendingMeetingRecovery.first {
                MeetingRecoverySheet(
                    orphan: orphan,
                    canResume: meetingTabEnabled,
                    onResume: {
                        // Same engine-collision guard as every meeting start.
                        if appState.isDictationBusy {
                            appState.showToast("Finish the dictation first", icon: "waveform.badge.exclamationmark")
                            return
                        }
                        selectedTab = .meeting
                        Task {
                            do {
                                try await appState.meetingService.resumeRecording(orphan: orphan)
                                // Pop only on success so a failed resume keeps
                                // the orphan recoverable in this session.
                                if appState.pendingMeetingRecovery.first?.id == orphan.id {
                                    appState.pendingMeetingRecovery.removeFirst()
                                }
                            } catch {
                                appState.meetingService.state = .error(error.localizedDescription)
                                appState.showToast("Couldn't resume the meeting", icon: "waveform.badge.exclamationmark")
                            }
                        }
                    },
                    onTranscribe: {
                        if appState.pendingMeetingRecovery.first?.id == orphan.id {
                            appState.pendingMeetingRecovery.removeFirst()
                        }
                        selectedTab = .meeting
                        appState.meetingService.processOrphan(orphan: orphan)
                    },
                    onDiscard: {
                        if appState.pendingMeetingRecovery.first?.id == orphan.id {
                            appState.pendingMeetingRecovery.removeFirst()
                        }
                        appState.meetingService.discardOrphan(orphan: orphan)
                    },
                    onLater: {
                        // Keep the audio; the next launch re-offers it.
                        if appState.pendingMeetingRecovery.first?.id == orphan.id {
                            appState.pendingMeetingRecovery.removeFirst()
                        }
                    }
                )
                .interactiveDismissDisabled()
            }
        }
        .task {
            // On low-tier Macs (Intel, 8 GB, or no on-device AI with little memory), suggest a
            // lighter mode once. Complete stays available.
            guard !perfRecommendationShown,
                  sideWaveExperience == "full",
                  UserDefaults.standard.string(forKey: HardwareDetector.tierKey) == HardwareDetector.Tier.low.rawValue
            else { return }
            showLighterExperiencePrompt = true
        }
        .alert("Lighter Dictation Experience Available", isPresented: $showLighterExperiencePrompt) {
            Button("Use Basic Experience") {
                ExperiencePreset.apply("standard", appState: appState)
                perfRecommendationShown = true
            }
            Button("Keep Complete Experience", role: .cancel) {
                perfRecommendationShown = true
            }
        } message: {
            Text("Basic keeps the live transcript with Refine off to reduce memory and processing. Complete remains available in Advanced View > Dictation. Changing this preset is separate from switching Simple or Advanced View.")
        }

        .sheet(isPresented: $appState.showTutorial) {
            TutorialOverlay(tutorialState: $appState.tutorialState,
                            isShowing: $appState.showTutorial)
                .environment(appState)
        }
        .onChange(of: appState.showSpecialtyPreview) {
            if appState.showSpecialtyPreview {
                DispatchQueue.main.async {
                    openWindow(id: "specialty-preview")
                    appState.showSpecialtyPreview = false
                }
            }
        }
        .onAppear {
            // A captured OpenWindowAction the app can use to open the editor even when no window
            // observing the request is open. It stays valid after this window closes. Also clears a
            // stuck request.
            appState.openSpecialtyWindowAction = { openWindow(id: "specialty-preview") }
            if appState.showSpecialtyPreview {
                DispatchQueue.main.async {
                    openWindow(id: "specialty-preview")
                    appState.showSpecialtyPreview = false
                }
            }
        }
    }

    private var shouldShowWelcome: Bool {
        !appState.transcriptionService.hasInstalledSpeechModels || !appState.isAccessibilityGranted
            || appState.microphonePermission != .granted
    }
}

extension ContentView {
    /// The main window's sections, drawn as a glass track with a raised selection so the current
    /// section reads clearly on a white toolbar.
    @ViewBuilder
    var meetingToolbarPicker: some View {
        if shouldShowWelcome {
            Text("Set up SideWave")
                .font(.headline)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isHeader)
        } else {
            GlassSegmentedPicker(selection: $selectedTab, segments: sectionSegments,
                                 selectionStyle: .raised, accessibilityLabel: "Sections")
                .fixedSize()
        }
    }

    private var sectionSegments: [GlassSegmentedPicker<Tab>.Segment] {
        var segments: [GlassSegmentedPicker<Tab>.Segment] = [
            .init("Home", tag: .dashboard), .init("Dictation", tag: .dictation),
            .init("Vocabulary", tag: .dictionary), .init("History", tag: .history),
        ]
        if meetingTabEnabled { segments.append(.init("Meeting", tag: .meeting)) }
        return segments
    }
}
