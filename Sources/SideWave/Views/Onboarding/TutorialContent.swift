// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

enum TutorialSteps {
    static let all: [TutorialStep] = [
        TutorialStep(
            id: 0, title: "Home",
            body: "Home has your template, microphone, model, and text destination. These controls stay in the same place in Simple and Advanced view.",
            icon: "house"
        ),
        TutorialStep(
            id: 1, title: "Start and stop dictation",
            body: "Place your cursor where you want to type. Press your shortcut and speak when the preview says Listening. Press it again to finish the remaining text and send it to your app.",
            icon: "mic",
            keyboardHints: [KeyboardHint(label: "Start or finish", keys: "{hotkey}"),
                            KeyboardHint(label: "Pause dictation", keys: "Escape")]
        ),
        TutorialStep(
            id: 2, title: "Select a template",
            body: "Standard, Professional, and Concise send text to your chosen app. Email, Instructions, AI Prompt, and Custom open a document you can review, edit, and copy.",
            icon: "text.badge.checkmark"
        ),
        TutorialStep(
            id: 3, title: "Add vocabulary",
            body: "Create a glossary for names and terms you use. Add the correct spelling and any words SideWave mistakes it for. Browse bundles lets you add optional shared glossaries.",
            icon: "character.book.closed"
        ),
        TutorialStep(
            id: 4, title: "Review history",
            body: "Search, copy, and delete dictations in History. Open an entry to compare recognized and refined text. Set how long to keep entries in Settings > Privacy.",
            icon: "clock"
        ),
        TutorialStep(
            id: 5, title: "Advanced controls",
            body: "Advanced view adds recording and refinement controls without changing your current choices. Enable Meetings in Settings to record conversations with speaker labels.",
            icon: "slider.horizontal.3",
            keyboardHints: [KeyboardHint(label: "Open Settings", keys: "⌘,")]
        ),
        TutorialStep(
            id: 6, title: "Help and downloads",
            body: "Help has instructions and troubleshooting. Help > Data Transparency lists downloads and network requests. To reopen this tutorial, choose Help > Take a Tour.",
            icon: "questionmark.circle",
            keyboardHints: [KeyboardHint(label: "Open Help", keys: "⌘?")]
        )
    ]

    static func step(at index: Int) -> TutorialStep? {
        guard all.indices.contains(index) else { return nil }
        return all[index]
    }

    static var count: Int { all.count }
}
