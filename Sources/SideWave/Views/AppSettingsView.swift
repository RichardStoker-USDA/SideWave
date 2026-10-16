// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Settings Window View

/// Settings keep the same navigation and control language as Help.
struct AppSettingsView: View {
    @Environment(AppState.self) var appState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("experimentalFeatures") private var experimentalFeatures = false
    /// Simple-by-default switch (Settings > General). When off, the Advanced
    /// category is dropped from the sidebar — its pane is expert-only tuning.
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false
    /// Persist across opens so reopening Settings returns to where the
    /// user was. Stored as the SidebarItem's case name; falls back to
    /// General when the persisted value can't be decoded.
    @AppStorage("lastSelectedSettingsTab") private var lastSelectedTabRaw: String = "settingsGeneral"
    @State private var selectedTab: SidebarItem = .settingsGeneral
    @State private var searchText = ""

    init(searchText: String = "") {
        _searchText = State(initialValue: searchText)
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebarView(selectedTab: $selectedTab, searchText: $searchText)
                .navigationSplitViewColumnWidth(min: 220, ideal: 228, max: 260)
                .navigationTitle("Settings")
        } detail: {
            SettingsContentView(category: selectedTab, appState: appState)
                .id(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbarBackground(.bar, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .frame(minWidth: 780, idealWidth: 860, maxWidth: .infinity,
               minHeight: 560, idealHeight: 620, maxHeight: .infinity)
        .buttonBorderShape(.capsule)
        .onAppear {
            // Restore the last pane. A deep link from the dashboard still wins, because the
            // onChange below runs after onAppear. Skip a pane that's hidden now, since Advanced
            // view can change from the menu bar while Settings is closed.
            if let restored = SidebarItem.fromPersistedRawValue(lastSelectedTabRaw) {
                let visible: Bool = switch restored {
                case .settingsAdvanced: showAdvancedControls
                case .settingsExperimental: experimentalFeatures && showAdvancedControls
                default: true
                }
                selectedTab = visible ? restored : .settingsGeneral
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            lastSelectedTabRaw = newTab.persistedRawValue
        }
        .onChange(of: experimentalFeatures) {
            if !experimentalFeatures && selectedTab == .settingsExperimental {
                // Go to Advanced, where the switch lives, when it's visible; otherwise General.
                selectedTab = showAdvancedControls ? .settingsAdvanced : .settingsGeneral
            }
        }
        .onChange(of: showAdvancedControls) {
            // Turning Advanced view off hides the Advanced and Experimental panes, so leave them if
            // selected.
            if !showAdvancedControls,
               selectedTab == .settingsAdvanced || selectedTab == .settingsExperimental {
                selectedTab = .settingsGeneral
            }
        }
        .onChange(of: appState.requestedSettingsTab, initial: true) { _, newTab in
            // `initial: true` handles a deep link set before the Settings window exists.
            if let tab = newTab {
                if tab == .settingsAdvanced || tab == .settingsExperimental {
                    showAdvancedControls = true
                }
                selectedTab = tab == .settingsExperimental && !experimentalFeatures ? .settingsAdvanced : tab
                appState.requestedSettingsTab = nil
            }
        }
        .onChange(of: appState.showSpecialtyPreview) {
            if appState.showSpecialtyPreview {
                DispatchQueue.main.async {
                    openWindow(id: "specialty-preview")
                    appState.showSpecialtyPreview = false
                }
            }
        }
    }

    static func matchesExperimental(_ query: String) -> Bool {
        matchesSearch(query, label: "Experimental", item: .settingsExperimental)
    }

    static func matchesSearch(_ query: String, label: String, item: SidebarItem) -> Bool {
        let text = label + " " + keywords(for: item)
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.localizedStandardContains(String($0))
        }
    }

    private static func keywords(for item: SidebarItem) -> String {
        switch item {
        case .settingsGeneral: "hotkey shortcut keyboard theme appearance light dark window opacity reduce motion simple advanced"
        case .settingsDictation: "speech model download recognition parakeet nemotron silence voice vocabulary glossary bundles catalog sync updates"
        case .settingsMeetings: "meeting speakers diarization notes minutes recovery audio recording nemotron"
        case .settingsRefine: "apple intelligence gemma template prompt polish thinking language translate filler words document cache storage download repair models"
        case .settingsAudio: "microphone input bluetooth airpods usb priority test standby device gain audio duck volume channel resampling"
        case .settingsSound: "sound effects chime start stop tone"
        case .settingsOverlay: "overlay live text waveform animation motion opacity size font"
        case .settingsPrivacy: "privacy history retention network downloads telemetry clipboard local"
        case .settingsAdvanced: "pipeline runtime performance refine timing expert hold threshold push talk diagnostics reset experimental relay"
        case .settingsExperimental: "experimental developer relay press return submit fixed interval"
        case .settingsAbout: "about version update license"
        default: ""
        }
    }
}

struct SettingsSidebarView: View {
    @Binding var selectedTab: SidebarItem
    @Binding var searchText: String
    @AppStorage("experimentalFeatures") private var experimentalFeatures = false
    @AppStorage("showAdvancedControls") private var showAdvancedControls = false

    private typealias Entry = (item: SidebarItem, label: String, icon: String)

    /// Matching categories by group. Search reaches Advanced and Experimental
    /// even while Advanced view is off; choosing one turns Advanced view on.
    private var groups: [(header: String, items: [Entry])] {
        let searching = !searchText.isEmpty
        let showsExperimental = experimentalFeatures && (showAdvancedControls || searching)
            && AppSettingsView.matchesExperimental(searchText)
        return SidebarItem.settingsSidebarGroups(showingAdvanced: showAdvancedControls || searching).map { group in
            var items = group.items.filter { AppSettingsView.matchesSearch(searchText, label: $0.label, item: $0.item) }
            if group.header == "System", showsExperimental { items.append(SidebarItem.experimentalCategory) }
            return (header: group.header, items: items)
        }
        .filter { !$0.items.isEmpty }
    }

    var body: some View {
        List(selection: Binding<SidebarItem?>(get: { selectedTab }, set: { item in
            guard let item else { return }
            if item == .settingsAdvanced || item == .settingsExperimental { showAdvancedControls = true }
            selectedTab = item
        })) {
            ForEach(groups, id: \.header) { group in
                Section(group.header) {
                    ForEach(group.items, id: \.item) { entry in
                        Label(entry.label, systemImage: entry.icon).tag(entry.item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .disclosureGroupStyle(.automatic)
        .overlay {
            if groups.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Find a Setting")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Toggle("Advanced view", isOn: $showAdvancedControls)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.callout)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .help("Show expert controls without changing how dictation runs")
            }
        }
    }
}
