// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Help Sections

enum HelpSection: String, CaseIterable, Identifiable {
    case gettingStarted
    case howDictationWorks
    case audioWaveShowcase
    case hotkeySetup
    case models
    case vocabulary
    case refine
    case textNormalization
    case meetingTranscription
    case voiceActivityDetection
    case overlay
    case audioDevices
    case history
    case settingsOverview
    case keyboardShortcuts
    case troubleshooting
    case privacy
    case technologyAndCredits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .howDictationWorks: return "How Dictation Works"
        case .audioWaveShowcase: return "Audio Wave"
        case .hotkeySetup: return "Hotkey Setup"
        case .models: return "Models"
        case .vocabulary: return "Vocabulary"
        case .refine: return "Refine"
        case .textNormalization: return "Text Normalization"
        case .meetingTranscription: return "Meeting Transcription"
        case .voiceActivityDetection: return "Speech Detection"
        case .overlay: return "Overlay"
        case .audioDevices: return "Audio Devices"
        case .history: return "History"
        case .settingsOverview: return "Settings Overview"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .troubleshooting: return "Troubleshooting"
        case .privacy: return "Privacy"
        case .technologyAndCredits: return "Technology & Credits"
        }
    }

    var icon: String {
        switch self {
        case .gettingStarted: return "play.circle"
        case .howDictationWorks: return "waveform"
        case .audioWaveShowcase: return "waveform.path"
        case .hotkeySetup: return "keyboard"
        case .models: return "arrow.down.circle"
        case .vocabulary: return "character.book.closed"
        case .refine: return "text.badge.checkmark"
        case .textNormalization: return "textformat.123"
        case .meetingTranscription: return "person.3"
        case .voiceActivityDetection: return "mic.badge.plus"
        case .overlay: return "rectangle.on.rectangle"
        case .audioDevices: return "speaker.wave.2"
        case .history: return "clock.arrow.circlepath"
        case .settingsOverview: return "slider.horizontal.3"
        case .keyboardShortcuts: return "command"
        case .troubleshooting: return "wrench.and.screwdriver"
        case .privacy: return "lock.shield"
        case .technologyAndCredits: return "building.columns"
        }
    }

    var subtitle: String {
        switch self {
        case .gettingStarted: return "Learn the basics of dictation, vocabulary, and navigation."
        case .howDictationWorks: return "How speech becomes text on this Mac."
        case .audioWaveShowcase: return "What the wave shows while you dictate and while Refine works."
        case .hotkeySetup: return "Configure hotkey triggers and shortcuts."
        case .models: return "Choose, prepare, and manage local models."
        case .vocabulary: return "Glossaries, word corrections, and bundles."
        case .refine: return "Models, templates, and the document editor."
        case .textNormalization: return "How spoken numbers, dates, and amounts become digits."
        case .meetingTranscription: return "Recording meetings, speaker labels, and notes."
        case .voiceActivityDetection: return "How SideWave finds pauses in your speech."
        case .overlay: return "The floating preview you see while dictating."
        case .audioDevices: return "Microphones, interfaces, Bluetooth, and input channels."
        case .history: return "Find, copy, and compare past dictations."
        case .settingsOverview: return "What each settings panel controls."
        case .keyboardShortcuts: return "Global shortcuts and view controls."
        case .troubleshooting: return "Fix mic access, model download, and paste problems."
        case .privacy: return "Local processing, saved data, and optional connections."
        case .technologyAndCredits: return "Open-source software and models SideWave uses."
        }
    }

    var searchTerms: String {
        switch self {
        case .gettingStarted: "simple advanced home ready record permission"
        case .howDictationWorks: "stages live gray refined white pipeline"
        case .audioWaveShowcase: "rainbow animation motion apple gemma colors"
        case .hotkeySetup: "option fn keyboard press hold push talk toggle"
        case .models: "gemma 12b e2b e4b apple intelligence fluid audio download repair partial offline cache"
        case .vocabulary: "glossary glossaries pronunciation alias replace acronym category import export catalog github bundles sync updates copy"
        case .refine: "document editor instructions email prompt template formatting ask follow up undo"
        case .textNormalization: "numbers dates currency nemo itn"
        case .meetingTranscription: "meeting record recovery crash eight speakers diarization nemotron notes long audio"
        case .voiceActivityDetection: "voice activity detection vad pause silence threshold"
        case .overlay: "window text animation wave font size position motion"
        case .audioDevices: "microphone bluetooth usb airpods input channel test system default selection priority mixer interface standby"
        case .history: "search copy delete stages raw refined retention"
        case .settingsOverview: "preferences categories advanced simple"
        case .keyboardShortcuts: "command key menu hotkey"
        case .troubleshooting: "error failed crash recovery permission slow missing download microphone"
        case .privacy: "network telemetry download history local offline internet"
        case .technologyAndCredits: "license libraries dependencies fluid audio mlx"
        }
    }

    func matchesSearch(_ query: String) -> Bool {
        let text = title + " " + subtitle + " " + searchTerms
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.localizedStandardContains(String($0))
        }
    }

    var group: HelpSidebarGroup {
        switch self {
        case .gettingStarted, .howDictationWorks, .audioWaveShowcase: return .basics
        case .hotkeySetup, .models, .vocabulary, .refine, .textNormalization, .meetingTranscription, .voiceActivityDetection: return .features
        case .overlay, .audioDevices, .history: return .interface
        case .settingsOverview, .keyboardShortcuts, .troubleshooting, .privacy, .technologyAndCredits: return .reference
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .gettingStarted: HelpGettingStartedContent()
        case .howDictationWorks: HelpHowDictationWorksContent()
        case .audioWaveShowcase: HelpAudioWaveShowcaseContent()
        case .hotkeySetup: HelpHotkeySetupContent()
        case .models: HelpModelsContent()
        case .vocabulary: HelpVocabularyContent()
        case .refine: HelpRefineContent()
        case .textNormalization: HelpTextNormalizationContent()
        case .meetingTranscription: HelpMeetingTranscriptionContent()
        case .voiceActivityDetection: HelpVADContent()
        case .overlay: HelpOverlayContent()
        case .audioDevices: HelpAudioDevicesContent()
        case .history: HelpHistoryContent()
        case .settingsOverview: HelpSettingsOverviewContent()
        case .keyboardShortcuts: HelpKeyboardShortcutsContent()
        case .troubleshooting: HelpTroubleshootingContent()
        case .privacy: HelpPrivacyContent()
        case .technologyAndCredits: HelpTechnologyAndCreditsContent()
        }
    }
}

/// Sidebar groupings
enum HelpSidebarGroup: String, CaseIterable {
    case basics
    case features
    case interface
    case reference

    var title: String {
        switch self {
        case .basics: return "Basics"
        case .features: return "Features"
        case .interface: return "Interface"
        case .reference: return "Reference"
        }
    }

    var sections: [HelpSection] {
        HelpSection.allCases.filter { $0.group == self }
    }
}


// MARK: - Navigation between topics and windows

struct HelpNavigationAction: Sendable {
    var selectSection: @MainActor @Sendable (HelpSection) -> Void
}

struct HelpNavigationActionKey: EnvironmentKey {
    static let defaultValue = HelpNavigationAction { @MainActor _ in }
}

extension EnvironmentValues {
    var helpNavigate: HelpNavigationAction {
        get { self[HelpNavigationActionKey.self] }
        set { self[HelpNavigationActionKey.self] = newValue }
    }
}

/// Opens the destination even when initial setup is incomplete.
struct HelpDeepLinkButton: View {
    let label: String
    let systemImage: String?
    let targetPage: SidebarItem?
    let targetSettingsTab: SidebarItem?
    let spotlightKey: String?
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            if let page = targetPage {
                appState.requestedPage = page
                appState.showMainWindow = true
            }
            if let settingsTab = targetSettingsTab {
                appState.requestedSettingsSpotlight = spotlightKey
                appState.requestedSettingsTab = settingsTab
                openWindow(id: "settings")
            }
        } label: {
            Label(label, systemImage: systemImage ?? "arrow.up.forward")
                .font(.callout)
        }
        .actionButton()
    }
}

/// An internal navigation button within the Help section that jumps to another Help topic.
struct HelpInternalButton: View {
    let label: String
    let systemImage: String?
    let targetSection: HelpSection
    @Environment(\.helpNavigate) private var helpNavigate
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }
    @State private var isHovered = false
    
    var body: some View {
        Button {
            helpNavigate.selectSection(targetSection)
        } label: {
            HStack(spacing: 6) {
                if let sysImg = systemImage {
                    Image(systemName: sysImg)
                        .font(.callout)
                }
                Text(label)
                    .font(.callout)
                
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.12), lineWidth: 1)
            )
            .foregroundStyle(isHovered ? Color.accentColor : .primary)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
