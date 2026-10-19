// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Persistent state for the interactive tutorial
struct TutorialState: Codable, Equatable {
    var hasCompletedTutorial: Bool = false
    var currentStep: Int = 0
    var showTutorialOnLaunch: Bool = true

    /// Total number of tutorial steps (computed from TutorialSteps content)
    static var totalSteps: Int { TutorialSteps.count }

    /// Storage key for UserDefaults
    private static let storageKey = "tutorialState"

    /// Load tutorial state from UserDefaults.
    /// Completion and launch-preference flags persist across app launches.
    /// Step progress resets to 0 every launch if the tutorial wasn't completed,
    /// because the tutorial workflow can't resume mid-stream after a relaunch.
    static func load() -> TutorialState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var state = try? JSONDecoder().decode(TutorialState.self, from: data) else {
            return TutorialState()
        }

        if !state.hasCompletedTutorial {
            state.currentStep = 0
        }

        return state
    }

    /// Save tutorial state to UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Reset tutorial to beginning (for replay)
    mutating func reset() {
        currentStep = 0
        hasCompletedTutorial = false
        showTutorialOnLaunch = true
        save()
    }

    /// Mark tutorial as completed
    mutating func complete() {
        hasCompletedTutorial = true
        save()
    }

    /// Skip tutorial without marking as completed (allows relaunch next time)
    mutating func skipForNow() {
        currentStep = 0
        save()
    }

    mutating func nextStep() {
        if currentStep < Self.totalSteps - 1 {
            currentStep += 1
            save()
        }
    }

    /// Check if this is the last step
    var isLastStep: Bool {
        currentStep >= Self.totalSteps - 1
    }
}
