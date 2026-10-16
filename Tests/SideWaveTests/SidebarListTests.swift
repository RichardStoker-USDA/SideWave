// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import XCTest
@testable import SideWave

/// Sidebar sections are disclosure groups. A disclosure style inherited from
/// the window must not merge each section into a single row.
@MainActor
final class SidebarListTests: XCTestCase {
    func testSettingsSidebarKeepsOneRowPerCategory() async throws {
        let defaults = UserDefaults.standard
        let showsAdvanced = defaults.bool(forKey: "showAdvancedControls")
        let groups = SidebarItem.settingsSidebarGroups(showingAdvanced: showsAdvanced)
        var expected = groups.count + groups.reduce(0) { $0 + $1.items.count }
        if showsAdvanced && defaults.bool(forKey: "experimentalFeatures") { expected += 1 }

        let rows = try await outlineRows {
            SettingsSidebarView(selectedTab: .constant(.settingsGeneral), searchText: .constant(""))
        }
        XCTAssertEqual(rows, expected)
    }

    func testHelpSidebarKeepsOneRowPerTopic() async throws {
        let expected = HelpSidebarGroup.allCases.reduce(0) { $0 + 1 + $1.sections.count }
        let rows = try await outlineRows {
            HelpSidebarView(selectedSection: .constant(nil), searchText: .constant(""))
        }
        XCTAssertEqual(rows, expected)
    }

    private func outlineRows<Sidebar: View>(@ViewBuilder _ sidebar: () -> Sidebar) async throws -> Int {
        let content = NavigationSplitView { sidebar() } detail: { Color.clear }
            .disclosureGroupStyle(.row)
            .frame(width: 720, height: 1_200)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 1_200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(Self.outlineView(in: host), "The sidebar should be backed by an outline view")
        return outline.numberOfRows
    }

    private static func outlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let outline = outlineView(in: subview) { return outline }
        }
        return nil
    }
}
