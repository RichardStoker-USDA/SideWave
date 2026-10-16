// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import TipKit

/// Tips appear one at a time, never in a chain:
///
/// - One dashboard tip per first launch (`FirstLaunchDashboardTip`), shown once the dashboard has
///   settled.
/// - A first-visit tip for History and for Vocabulary, triggered by an event donated on the first
///   visit and limited by the daily display frequency.
/// - Tips for advanced features, each after a related action, also limited daily.
///
/// Every tip shows at most once. Help > Reset Hints shows them again.

// MARK: - Single Dashboard First-Launch Tip

/// First and only tip on the dashboard. Anchored to the Send-To picker
/// because that's where dictated text actually goes. Most important
/// thing for a new user to understand. Replaces the prior 3-tip
/// dashboard tour that fired sequentially on dismiss.
struct FirstLaunchDashboardTip: Tip {
    /// Donated by the dashboard view after it has been visible for a
    /// few seconds without the user starting a recording. Lets the tip
    /// wait for a real "user has had time to look around" moment.
    static let settled = Tips.Event(id: "dashboardSettled")

    var title: Text { Text("Dictated text lands where you started") }
    var message: Text? {
        Text("By default, your text pastes into whatever app was focused when you tapped your hotkey. \"Send to\" lets you change that.")
    }
    var image: Image? { Image(systemName: "arrow.right.doc.on.clipboard") }

    var options: [TipOption] {
        MaxDisplayCount(1)
    }

    var rules: [Rule] {
        #Rule(Self.settled) { $0.donations.count >= 1 }
    }
}

// MARK: - Tab First-Visit Tips

/// Fires the first time the user opens the History tab. The
/// `visited` event is donated by HistoryView's `.task`.
struct HistoryTip: Tip {
    static let visited = Tips.Event(id: "historyTabVisited")

    var title: Text { Text("Find Past Dictations") }
    var message: Text? {
        Text("Everything you've dictated is saved here. Click any entry to copy or delete it.")
    }
    var image: Image? { Image(systemName: "clock.arrow.circlepath") }

    var options: [TipOption] {
        MaxDisplayCount(1)
    }

    var rules: [Rule] {
        #Rule(Self.visited) { $0.donations.count >= 1 }
    }
}

/// Fires the first time the user opens the Vocabulary tab.
struct DictionaryTip: Tip {
    static let visited = Tips.Event(id: "vocabularyTabVisited")

    var title: Text { Text("Add Your Words") }
    var message: Text? {
        Text("Teach SideWave names, abbreviations, or terms it gets wrong. Vocabulary entries are boosted at recognition time and can also feed Refine context.")
    }
    var image: Image? { Image(systemName: "text.book.closed") }

    var options: [TipOption] {
        MaxDisplayCount(1)
    }

    var rules: [Rule] {
        #Rule(Self.visited) { $0.donations.count >= 1 }
    }
}

// MARK: - Event-Triggered Pro Tips

/// Fires the first time the Mini window appears. Bypasses daily
/// frequency because the user just intentionally opened Mini and
/// the tip is contextual to that exact action. Not a generic tour.
struct MiniFirstOpenTip: Tip {
    static let opened = Tips.Event(id: "miniFirstOpen")

    var title: Text { Text("SideWave Mini") }
    var message: Text? {
        Text("Click the mic to dictate. Drag the window edge to park it anywhere on screen. Click the expand icon to return to the full dashboard.")
    }
    var image: Image? { Image(systemName: "rectangle.compress.vertical") }

    var options: [TipOption] {
        MaxDisplayCount(1)
        IgnoresDisplayFrequency(true)
    }

    var rules: [Rule] {
        #Rule(Self.opened) { $0.donations.count >= 1 }
    }
}
