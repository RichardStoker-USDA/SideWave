// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

@MainActor
final class DictationModeTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = ["sideWaveExperience", "useDualEngineSmartPTT", "useMultiStageRendering",
        "useRealTimeRefine", "skipRefine", "skipRefineAutoForced", "tdtHiddenRefineSweep",
        "useEouToRefineDirect", "showLiveGhostText", "performFinalRefinePass",
        "dictationCleanupEnabled", "dictationCleanupTemplate", "holdToRewriteEnabled"]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testRecognitionModesDisableAllRefinementAndReleaseFormatter() {
        let state = AppState()
        let defaults = UserDefaults.standard
        for mode in ["standard", "speedy"] {
            ExperiencePreset.apply("full", appState: state)
            state.hotkeyManager.holdToRewriteEnabled = true
            defaults.set(true, forKey: "skipRefineAutoForced")
            ExperiencePreset.apply(mode, appState: state)
            XCTAssertEqual(defaults.bool(forKey: "useDualEngineSmartPTT"), mode == "standard")
            XCTAssertEqual(defaults.bool(forKey: "useMultiStageRendering"), mode == "standard")
            XCTAssertFalse(defaults.bool(forKey: "useRealTimeRefine"))
            XCTAssertFalse(defaults.bool(forKey: "performFinalRefinePass"))
            XCTAssertTrue(defaults.bool(forKey: "skipRefine"))
            XCTAssertFalse(defaults.bool(forKey: "skipRefineAutoForced"))
            XCTAssertFalse(state.dictationCleanupEnabled)
            XCTAssertEqual(state.dictationFormatter.state, .disabled)
            XCTAssertFalse(state.hotkeyManager.refinementAvailable)
            XCTAssertTrue(state.hotkeyManager.holdToRewriteEnabled, "Keep the preference for Complete mode")
            XCTAssertTrue(ExperiencePreset.isRecognitionOnly(), "Relaunch must not auto-load the refiner")
            XCTAssertEqual(DictationTemplateMenu(appState: state).selectionTitle, "As spoken")
        }
    }

    func testCompleteRestoresBothEnginesAndRefinement() {
        let state = AppState()
        ExperiencePreset.apply("speedy", appState: state)
        ExperiencePreset.apply("full", appState: state)
        let defaults = UserDefaults.standard
        for key in ["useDualEngineSmartPTT", "useMultiStageRendering", "useRealTimeRefine", "performFinalRefinePass"] {
            XCTAssertTrue(defaults.bool(forKey: key), key)
        }
        XCTAssertFalse(defaults.bool(forKey: "skipRefine"))
        XCTAssertTrue(state.dictationCleanupEnabled)
        XCTAssertTrue(state.hotkeyManager.refinementAvailable)
        XCTAssertFalse(ExperiencePreset.isRecognitionOnly())
    }

    func testSelectingTemplateAfterEitherModeEnablesARealFinalPass() {
        let state = AppState()
        for mode in ["standard", "speedy"] {
            ExperiencePreset.apply(mode, appState: state)
            state.selectDictationOutput(.professional, openDocument: false)
            XCTAssertTrue(state.dictationCleanupEnabled)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "skipRefine"))
            XCTAssertTrue(UserDefaults.standard.bool(forKey: "performFinalRefinePass"))
            XCTAssertFalse(ExperiencePreset.isRecognitionOnly())
            XCTAssertFalse(ExperiencePreset.description(for: mode, refinementEnabled: true).contains("No AI"))
        }
    }

    func testRecognitionModeLeavesDocumentSafelyAndRestoresOrdinaryOutput() {
        let state = AppState()
        state.selectDictationOutput(.instructions, openDocument: false)
        state.specialtyEditedText = "1. Review the report."
        state.isSpecialtyActive = true
        ExperiencePreset.apply("speedy", appState: state)
        XCTAssertFalse(state.isSpecialtyActive)
        XCTAssertFalse(state.selectedDictationTemplate.isSpecialty)
        state.selectDictationOutput(.instructions, openDocument: false)
        XCTAssertEqual(state.specialtyEditedText, "1. Review the report.")
    }

    func testModeCannotChangeDuringRecordingEditingOrPendingRecovery() {
        let state = AppState()
        ExperiencePreset.apply("full", appState: state)
        state.transcriptionService.isRecording = true
        ExperiencePreset.apply("speedy", appState: state)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sideWaveExperience"), "full")
        state.transcriptionService.isRecording = false
        state.isProcessingAgenticEdit = true
        ExperiencePreset.apply("standard", appState: state)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sideWaveExperience"), "full")
        state.isProcessingAgenticEdit = false
        state.pendingSessionText = "Keep the pending dictation."
        ExperiencePreset.apply("speedy", appState: state)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sideWaveExperience"), "full")
    }

    func testFailedStreamingStartUsesTheAvailablePollingPreview() {
        let service = TranscriptionService()
        UserDefaults.standard.set(true, forKey: "useDualEngineSmartPTT")
        UserDefaults.standard.set(true, forKey: "useMultiStageRendering")
        service.isRecording = true
        service.volatileText = "Polling recognition remains visible."
        XCTAssertFalse(service.usesStagedPreview, "Preferences cannot override the actual engine fallback")
    }
}
