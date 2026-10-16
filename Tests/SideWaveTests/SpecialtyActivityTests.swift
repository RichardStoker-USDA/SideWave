// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class SpecialtyActivityTests: XCTestCase {
    @MainActor
    func testChangingTemplateDismissesOnlyThePreviousDeliveryFailure() {
        let defaults = UserDefaults.standard
        let savedTemplate = defaults.object(forKey: "dictationCleanupTemplate")
        defer {
            if let savedTemplate { defaults.set(savedTemplate, forKey: "dictationCleanupTemplate") }
            else { defaults.removeObject(forKey: "dictationCleanupTemplate") }
        }
        let state = AppState()
        state.dictationCleanupTemplate = "standard"
        state.recordDictationFailure(.delivery("The output is in History."))
        XCTAssertEqual(state.dictationSessionPhase, .failed)
        state.dictationCleanupTemplate = "emailReady"
        XCTAssertNil(state.lastDictationError)
        XCTAssertEqual(state.dictationSessionPhase, .idle)
        state.recordDictationFailure(.persistence("Copy the recovered text before quitting."))
        state.dictationCleanupTemplate = "instructions"
        XCTAssertEqual(state.lastDictationError, "Copy the recovered text before quitting.")
        state.recordDictationFailure(.capture("The microphone disconnected."))
        state.dictationCleanupTemplate = "standard"
        XCTAssertEqual(state.lastDictationError, "The microphone disconnected.")
    }

    func testStoppedMicrophoneStillShowsWorkUntilFinalFormattingCompletes() {
        XCTAssertEqual(SpecialtyActivity(session: .listening, command: false, editing: false, generating: false), .listening)
        let draining = SpecialtyActivity(session: .finishing, command: false, editing: false, generating: false)
        XCTAssertEqual(draining, .finishing)
        XCTAssertTrue(draining.isWorking)
        let formatting = SpecialtyActivity(session: .finishing, command: false, editing: false, generating: true)
        XCTAssertEqual(formatting, .formatting)
        XCTAssertTrue(formatting.isWorking)
        XCTAssertEqual(SpecialtyActivity(session: .delivered, command: false, editing: false, generating: false), .ready)
    }

    func testSpokenFollowUpRemainsBusyWhileEditRuns() {
        XCTAssertEqual(SpecialtyActivity(session: .listening, command: true, editing: false, generating: false), .listeningForInstruction)
        let editing = SpecialtyActivity(session: .finishing, command: true, editing: true, generating: true)
        XCTAssertEqual(editing, .editing)
        XCTAssertTrue(editing.isWorking)
    }
}
