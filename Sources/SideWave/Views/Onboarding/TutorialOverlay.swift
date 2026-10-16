// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
import AppKit

/// A native sheet with one stable reading area and footer for every step.
struct TutorialOverlay: View {
    @Environment(AppState.self) var appState
    @Binding var tutorialState: TutorialState
    @Binding var isShowing: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        if let step = TutorialSteps.step(at: tutorialState.currentStep) {
            CoachMark(
                step: step,
                currentStepIndex: tutorialState.currentStep,
                totalSteps: TutorialSteps.count,
                hotkeyDisplayString: appState.hotkeyManager.shortcut.displayString,
                onNext: {
                    if tutorialState.isLastStep { close() }
                    else { tutorialState.nextStep() }
                },
                onBack: {
                    guard tutorialState.currentStep > 0 else { return }
                    tutorialState.currentStep -= 1
                    tutorialState.save()
                },
                onSkip: close
            )
            // Text and controls change together, without a moving container.
            .transaction { $0.animation = nil }
            .onChange(of: tutorialState.currentStep, initial: true) { _, index in
                guard voiceOverEnabled, let step = TutorialSteps.step(at: index) else { return }
                NSAccessibility.post(element: NSApp.mainWindow as Any,
                    notification: .announcementRequested,
                    userInfo: [.announcement: "Tutorial step \(index + 1) of \(TutorialSteps.count): \(step.title)",
                               .priority: NSAccessibilityPriorityLevel.high])
            }
        }
    }

    private func close() {
        tutorialState.complete()
        isShowing = false
        appState.requestedPage = .home
    }
}
