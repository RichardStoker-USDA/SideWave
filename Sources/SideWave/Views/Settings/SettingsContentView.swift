// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Detail column of the Settings window: the selected pane in a scroll view
/// that can jump to a control when Help or Home deep-links to it.
struct SettingsContentView: View {
    let category: SidebarItem
    @Bindable var appState: AppState
    @AppStorage("selectedModelVersion") private var selectedVersion = "v3"
    @AppStorage("experimentalFeatures") private var experimentalFeatures = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    SettingsDetailHeader(category: category)
                    pane
                }
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xl)
                .padding(.horizontal, Spacing.xl)
            }
            .softScrollEdge()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : Animate.standard, value: experimentalFeatures)
            .onChange(of: appState.requestedSettingsSpotlight, initial: true) { _, target in
                guard let target else { return }
                // Give the pane a moment to lay out before scrolling to it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        .buttonBorderShape(.capsule)
        .toggleStyle(.switch)
        .onAppear {
            appState.transcriptionService.checkModelCache(for: ModelVersion(rawValue: selectedVersion) ?? .v3)
        }
        .onChange(of: selectedVersion) { _, newValue in
            let version = ModelVersion(rawValue: newValue) ?? .v3
            appState.transcriptionService.checkModelCache(for: version)
            appState.meetingService.speechModelChanged(version)
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch category {
        case .settingsDictation: SpeechSettingsPane(appState: appState)
        case .settingsRefine: RefineSettingsPane(appState: appState)
        case .settingsMeetings: MeetingSettingsPane(appState: appState)
        case .settingsAudio: MicrophoneSettingsPane(appState: appState)
        case .settingsSound: SoundSettingsPane()
        case .settingsOverlay: OverlaySettingsPane(appState: appState)
        case .settingsPrivacy: PrivacySettingsPane()
        case .settingsAdvanced: AdvancedSettingsPane(appState: appState)
        case .settingsAbout: AboutSettingsPane(appState: appState)
        case .settingsExperimental: ExperimentalSettingsPane(appState: appState)
        default: GeneralSettingsPane(appState: appState)
        }
    }
}
