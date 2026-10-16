// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Pane title and one-line summary, matching the Help window's hierarchy.
struct SettingsDetailHeader: View {
    let category: SidebarItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(category.settingsTitle).font(.system(size: 25, weight: .semibold))
            Text(category.settingsSummary)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, Spacing.sm)
        }
        .padding(.bottom, Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SidebarItem {
    var settingsTitle: String {
        SidebarItem.settingsSidebarGroups.flatMap(\.items).first { $0.item == self }?.label
            ?? (self == .settingsExperimental ? "Experimental" : "Settings")
    }

    var settingsSummary: String {
        switch self {
        case .settingsGeneral: "Appearance, the dictation shortcut, and shortcut gestures."
        case .settingsDictation: "Speech models and glossary bundles."
        case .settingsRefine: "Writing models, prompts, and model storage."
        case .settingsMeetings: "Meeting recording and local meeting notes."
        case .settingsAudio: "Input device, channels, and other audio while dictating."
        case .settingsSound: "Sounds for starting, stopping, sending, and errors."
        case .settingsOverlay: "Size, position, and motion of the dictation preview."
        case .settingsPrivacy: "What SideWave keeps on this Mac and what it downloads."
        case .settingsAdvanced: "Shortcut timing, diagnostics, experimental features, and reset."
        case .settingsAbout: "Version, license, and updates."
        case .settingsExperimental: "Features still in development. They may change or be removed."
        default: ""
        }
    }
}

/// A group of related settings on a quiet rounded surface.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let title {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(Spacing.lg)
        .settingsCardStyle()
    }
}

/// Label on the leading edge, control on the trailing edge.
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        PreferenceRow(label: label, content: content)
    }
}

/// Switch row with a title and an explanation under it. The switch stays
/// level with the title however long the explanation runs.
struct SettingsToggleRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var info: (() -> Void)?

    init(_ title: String, caption: String, isOn: Binding<Bool>, info: (() -> Void)? = nil) {
        self.title = title
        self.caption = caption
        _isOn = isOn
        self.info = info
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                HStack(spacing: Spacing.xxs) {
                    Text(title).font(.callout)
                    if let info {
                        Button(action: info) { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("About \(title.lowercased())")
                            .accessibilityLabel("About \(title)")
                    }
                }
                Text(caption)
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .accessibilityElement(children: .contain)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.vertical, Spacing.xs)
    }
}

extension View {
    /// Explanatory text under a setting.
    func settingsCaption() -> some View {
        font(.subheadline).foregroundStyle(.secondary)
    }

    /// Lets Help and Home deep-link to a control and briefly outline it.
    func settingsSpotlight(key: String, appState: AppState) -> some View {
        modifier(SettingsSpotlightModifier(key: key, appState: appState))
    }
}

struct SettingsSpotlightModifier: ViewModifier {
    let key: String
    @Bindable var appState: AppState
    @State private var pulseCount = 0
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content
            .id(key)
            .overlay {
                if appState.requestedSettingsSpotlight == key {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .opacity(pulseCount % 2 == 1 ? 0.8 : 0)
                        .animation(.easeInOut(duration: 0.35), value: pulseCount)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: appState.requestedSettingsSpotlight, initial: true) { _, newValue in
                guard newValue == key else { return }
                pulseCount = 1
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                    // Scheduled from the main actor, so it fires on the main run loop.
                    MainActor.assumeIsolated {
                        pulseCount += 1
                        if pulseCount > 5 {
                            timer?.invalidate()
                            timer = nil
                            appState.requestedSettingsSpotlight = nil
                            pulseCount = 0
                        }
                    }
                }
            }
    }
}
