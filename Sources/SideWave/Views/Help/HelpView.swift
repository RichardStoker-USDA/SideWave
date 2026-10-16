// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Searchable local help with topic history, like a browser's back and forward.
struct HelpView: View {
    @Environment(AppState.self) var appState
    @State private var selectedSection: HelpSection?
    @State private var searchText: String
    @State private var history: [HelpSection]
    @State private var historyIndex = 0
    /// Set while Back or Forward changes the selection, so that change
    /// isn't recorded as a new visit.
    @State private var isProgrammaticNav = false

    init(section: HelpSection = .gettingStarted, searchText: String = "") {
        _selectedSection = State(initialValue: section)
        _history = State(initialValue: [section])
        _searchText = State(initialValue: searchText)
    }

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    var body: some View {
        NavigationSplitView {
            HelpSidebarView(selectedSection: $selectedSection, searchText: $searchText)
        } detail: {
            detail
        }
        .frame(minWidth: 720, idealWidth: 808, minHeight: 500, idealHeight: 623)
        .buttonBorderShape(.capsule)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward", action: goBack)
                    .disabled(!canGoBack)
                    .help("Previous topic")
                Button("Forward", systemImage: "chevron.forward", action: goForward)
                    .disabled(!canGoForward)
                    .help("Next topic")
            }
        }
        .onChange(of: appState.requestedHelpSection, initial: true) { _, section in
            guard let section else { return }
            searchText = ""
            selectedSection = section
            appState.requestedHelpSection = nil
        }
        .onChange(of: selectedSection) { _, newValue in
            // Back and Forward set the flag synchronously; this observer runs
            // on a later turn, so it's cleared here.
            if isProgrammaticNav {
                isProgrammaticNav = false
                return
            }
            guard let section = newValue else { return }
            history = Array(history.prefix(historyIndex + 1)) + [section]
            if history.count > 20 { history.removeFirst() }
            historyIndex = history.count - 1
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let section = selectedSection {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(section.title).font(.system(size: 25, weight: .semibold))
                        Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    Divider()
                    section.content
                }
                .padding(Spacing.lg)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .id(section)
            .softScrollEdge()
            .environment(\.helpNavigate, HelpNavigationAction { @MainActor target in selectedSection = target })
            .frame(minWidth: 440, minHeight: 400)
        } else {
            ContentUnavailableView("Choose a Topic", systemImage: "questionmark.circle",
                                   description: Text("Pick a topic in the sidebar, or search for what you need."))
        }
    }

    private func goBack() {
        guard canGoBack else { return }
        isProgrammaticNav = true
        historyIndex -= 1
        selectedSection = history[historyIndex]
    }

    private func goForward() {
        guard canGoForward else { return }
        isProgrammaticNav = true
        historyIndex += 1
        selectedSection = history[historyIndex]
    }
}

struct HelpSidebarView: View {
    @Binding var selectedSection: HelpSection?
    @Binding var searchText: String

    private var groups: [(group: HelpSidebarGroup, sections: [HelpSection])] {
        HelpSidebarGroup.allCases
            .map { ($0, $0.sections.filter { $0.matchesSearch(searchText) }) }
            .filter { !$0.sections.isEmpty }
    }

    var body: some View {
        List(selection: $selectedSection) {
            ForEach(groups, id: \.group) { entry in
                Section(entry.group.title) {
                    ForEach(entry.sections) { section in
                        Label(section.title, systemImage: section.icon).tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .disclosureGroupStyle(.automatic)
        .overlay {
            if groups.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Help")
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        .navigationTitle("Help")
    }
}
