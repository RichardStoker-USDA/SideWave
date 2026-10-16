// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

@MainActor
final class DocumentDraftStoreTests: XCTestCase {
    private func restorePreferences() -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = ["dictationCleanupTemplate", "dictationCleanupBackend", "dictationCleanupEnabled", "skipRefine", "skipRefineAutoForced", "useRealTimeRefine", "performFinalRefinePass"]
        let values = keys.map { ($0, defaults.object(forKey: $0)) }
        return {
            for (key, value) in values {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }

    func testChoosingADocumentOnHomeKeepsFocusAndPreservesItsDraft() {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        var windowsOpened = 0
        state.openSpecialtyWindowAction = { windowsOpened += 1 }
        state.dictationCleanupTemplate = "instructions"
        state.specialtyEditedText = "1. Keep every sample labeled."
        state.selectDictationOutput(.standard, openDocument: false)
        state.selectDictationOutput(.instructions, openDocument: false)
        XCTAssertEqual(windowsOpened, 0)
        XCTAssertEqual(state.specialtyEditedText, "1. Keep every sample labeled.")
        XCTAssertEqual(state.selectedDictationTemplate, .instructions)
        state.openSpecialtyEditor()
        XCTAssertEqual(windowsOpened, 1)
    }

    func testChoosingARefiningTemplateRestoresAWorkingPassAfterBasicMode() {
        let restore = restorePreferences()
        defer { restore() }
        let defaults = UserDefaults.standard
        let state = AppState()
        defaults.set(false, forKey: "useRealTimeRefine")
        defaults.set(false, forKey: "performFinalRefinePass")
        defaults.set(true, forKey: "skipRefine")
        state.selectDictationOutput(.professional, openDocument: false)
        XCTAssertFalse(defaults.bool(forKey: "skipRefine"))
        XCTAssertTrue(defaults.bool(forKey: "performFinalRefinePass"))
        XCTAssertFalse(defaults.bool(forKey: "useRealTimeRefine"))
        XCTAssertTrue(state.dictationCleanupEnabled)
    }

    func testHomeTemplateLabelTracksRefineDisabledFromAnotherControl() {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.selectDictationOutput(.professional, openDocument: false)
        XCTAssertEqual(DictationTemplateMenu(appState: state).selectionTitle, "Professional")

        state.dictationCleanupEnabled = false
        XCTAssertEqual(DictationTemplateMenu(appState: state).selectionTitle, "As spoken")
        state.dictationCleanupEnabled = true
        UserDefaults.standard.set(true, forKey: "skipRefine")
        XCTAssertEqual(DictationTemplateMenu(appState: state).selectionTitle, "As spoken")

        state.selectDictationOutput(.instructions, openDocument: false)
        state.dictationCleanupEnabled = false
        XCTAssertEqual(DictationTemplateMenu(appState: state).selectionTitle, "Instructions",
                       "An unrefined document still uses its document route")
    }

    func testLegacyDraftsMigrateAndPendingWorkSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("drafts.json")
        try JSONEncoder().encode(["instructions": "1. Keep the samples cold."]).write(to: url)
        let store = DocumentDraftStore(storageURL: url)
        XCTAssertEqual(store.text(for: "instructions"), "1. Keep the samples cold.")
        store.save(store.text(for: "instructions"), for: "instructions", additions: ["Review the report on Friday."], instruction: "Keep each step short.")
        store.flush()
        let restored = DocumentDraftStore(storageURL: url).draft(for: "instructions")
        XCTAssertEqual(restored.additions, ["Review the report on Friday."])
        XCTAssertEqual(restored.instruction, "Keep each step short.")
        XCTAssertEqual(restored.text, "1. Keep the samples cold.")
    }

    func testAsSpokenClearsDocumentRoutingAndPreservesPendingWork() {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "instructions"
        state.isSpecialtyActive = true
        state.specialtyEditedText = "1. Review the samples."
        state.specialtyQueuedSegments = [.init(text: "Send the report.")]
        state.agenticEditInstruction = "Make the first step shorter."
        state.selectDictationOutput(nil)
        XCTAssertEqual(state.dictationCleanupTemplate, "standard")
        XCTAssertFalse(state.isSpecialtyActive)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "skipRefine"))
        state.dictationCleanupTemplate = "instructions"
        XCTAssertEqual(state.specialtyEditedText, "1. Review the samples.")
        XCTAssertEqual(state.specialtyQueuedSegments.map(\.text), ["Send the report."])
        XCTAssertEqual(state.agenticEditInstruction, "Make the first step shorter.")
    }

    func testBusyDocumentCannotChangeTemplateBackendOrAppendOverAnEdit() {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "instructions"
        state.specialtyEditedText = "1. Review the samples."
        let addition = AppState.SpecialtyQueuedSegment(text: "Send the report.")
        state.specialtyQueuedSegments = [addition]
        let backend = state.dictationCleanupBackend
        state.isProcessingAgenticEdit = true
        state.dictationCleanupTemplate = "emailReady"
        state.dictationCleanupBackend = "gemma4-12b"
        state.appendSpecialtyAddition(id: addition.id)
        XCTAssertEqual(state.dictationCleanupTemplate, "instructions")
        XCTAssertEqual(state.dictationCleanupBackend, backend)
        XCTAssertEqual(state.specialtyEditedText, "1. Review the samples.")
        XCTAssertEqual(state.specialtyQueuedSegments.count, 1)
        state.isProcessingAgenticEdit = false
        state.appendSpecialtyAddition(id: addition.id)
        XCTAssertEqual(state.specialtyEditedText, "1. Review the samples.\n\nSend the report.")
        XCTAssertTrue(state.specialtyQueuedSegments.isEmpty)
    }

    func testUnavailableModelKeepsInstructionAndReportsItInDocument() async {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "instructions"
        state.specialtyEditedText = "1. Review the samples."
        state.agenticEditInstruction = "Add a short heading."
        state.dictationFormatter.state = .disabled
        await state.applyAgenticEdit()
        XCTAssertEqual(state.specialtyEditedText, "1. Review the samples.")
        XCTAssertEqual(state.agenticEditInstruction, "Add a short heading.")
        XCTAssertNotNil(state.documentEditNotice)
        XCTAssertFalse(state.isProcessingAgenticEdit)
    }

    func testRecordingStartKeepsAnActiveDocumentEditIntact() {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "instructions"
        state.isSpecialtyActive = true
        state.specialtyEditedText = "1. Review the samples."
        state.agenticEditInstruction = "Add a short heading."
        state.isProcessingAgenticEdit = true

        state.handleStartRecording()

        XCTAssertTrue(state.isProcessingAgenticEdit)
        XCTAssertFalse(state.isDictationBusy)
        XCTAssertFalse(state.hotkeyManager.isRecording)
        XCTAssertFalse(state.isOverlayVisible)
        XCTAssertEqual(state.specialtyEditedText, "1. Review the samples.")
        XCTAssertEqual(state.agenticEditInstruction, "Add a short heading.")
        XCTAssertEqual(state.documentDrafts.text(for: "instructions"), state.specialtyEditedText)
    }

    func testFormattingFallbackStaysVisibleInTheDocument() {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "instructions"
        state.dictationFormatter.onSilentFallback?("Formatting timed out. Your original words are kept.")
        XCTAssertEqual(state.documentEditNotice, "Formatting timed out. Your original words are kept.")
        state.dictationCleanupTemplate = "standard"
        XCTAssertNil(state.documentEditNotice)
    }

    func testUnreadableDraftIsPreservedBeforeSavingNewWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("drafts.json")
        let damaged = Data("{\"instructions\":\"Recover this unfinished file".utf8)
        try damaged.write(to: url)
        let store = DocumentDraftStore(storageURL: url)
        store.save("New document", for: "instructions")
        store.flush()
        let preserved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".corrupt-") })
        XCTAssertEqual(try Data(contentsOf: preserved), damaged)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(DocumentDraftStore(storageURL: url).text(for: "instructions"), "New document")
    }

    func testTemplatesRestoreIndependentlyAndClearStaysCleared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("drafts.json")
        let store = DocumentDraftStore(storageURL: url)
        store.save("Hello team,\n\nReview the samples.", for: "emailReady")
        store.save("1. Label the samples.\n2. Store them safely.", for: "instructions")
        store.flush()
        XCTAssertNil(store.persistenceError)
        let restored = DocumentDraftStore(storageURL: url)
        XCTAssertEqual(restored.text(for: "emailReady"), store.text(for: "emailReady"))
        XCTAssertEqual(restored.text(for: "instructions"), store.text(for: "instructions"))
        restored.save("", for: "emailReady")
        restored.flush()
        let afterClear = DocumentDraftStore(storageURL: url)
        XCTAssertEqual(afterClear.text(for: "emailReady"), "")
        XCTAssertFalse(afterClear.text(for: "instructions").isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testSwitchingTemplatesAndStreamingCannotReplaceAnotherDraft() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "dictationCleanupTemplate")
        defer {
            if let saved { defaults.set(saved, forKey: "dictationCleanupTemplate") }
            else { defaults.removeObject(forKey: "dictationCleanupTemplate") }
        }
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "instructions"
        state.specialtyEditedText = "1. Label the samples."
        state.dictationCleanupTemplate = "emailReady"
        XCTAssertEqual(state.specialtyEditedText, "")
        state.specialtyEditedText = "Hello team, review the samples."
        state.dictationCleanupTemplate = "instructions"
        XCTAssertEqual(state.specialtyEditedText, "1. Label the samples.")
        state.isProcessingAgenticEdit = true
        state.specialtyEditedText = "1. Incomplete streamed edit"
        XCTAssertEqual(state.documentDrafts.text(for: "instructions"), "1. Label the samples.")
    }

    func testUnsavedDocumentShowsAnActionableError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentDraftStore(storageURL: root.appendingPathComponent("draft.json"))
        store.save("Keep this document", for: "custom")
        store.flush()
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(store.text(for: "custom"), "Keep this document")
    }

    func testNewAndRestorePreserveManualEditsAndPendingAdditionsAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.json")
        let store = DocumentDraftStore(storageURL: url)
        store.save("First document, manually edited.", for: "emailReady", additions: ["A final spoken sentence."], instruction: "Shorten the closing.")
        let firstID = store.draft(for: "emailReady").id
        XCTAssertTrue(store.startNewDocument(for: "emailReady"))
        XCTAssertEqual(store.text(for: "emailReady"), "")
        store.save("Second document", for: "emailReady")
        store.flush()
        let restored = DocumentDraftStore(storageURL: url)
        XCTAssertEqual(restored.recentDocuments.count, 1)
        XCTAssertEqual(restored.restoreDocument(id: firstID)?.draft.additions, ["A final spoken sentence."])
        XCTAssertEqual(restored.draft(for: "emailReady").instruction, "Shorten the closing.")
        XCTAssertEqual(restored.recentDocuments.map(\.draft.text), ["Second document"])
        XCTAssertEqual(DocumentDraftStore(storageURL: url).text(for: "emailReady"), "First document, manually edited.")
    }

    func testFailedNewDocumentKeepsCurrentWorkVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentDraftStore(storageURL: root.appendingPathComponent("draft.json"))
        store.save("Unsaved manual changes", for: "emailReady")
        XCTAssertFalse(store.startNewDocument(for: "emailReady"))
        XCTAssertEqual(store.text(for: "emailReady"), "Unsaved manual changes")
        XCTAssertTrue(store.recentDocuments.isEmpty)
        XCTAssertNotNil(store.persistenceError)
    }

    func testShortcutStartsNewDocumentRegardlessOfWindowVisibilityAndAddIsExplicit() {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "emailReady"
        for windowOpen in [false, true] {
            state.isSpecialtyActive = windowOpen
            state.specialtyEditedText = "Previous email"
            XCTAssertTrue(state.prepareDocumentCapture(target: .auto, resuming: false))
            XCTAssertEqual(state.specialtyEditedText, "")
            state.specialtyEditedText = "Current email"
            XCTAssertTrue(state.prepareDocumentCapture(target: .document, resuming: false))
            XCTAssertEqual(state.specialtyEditedText, "Current email")
        }
        XCTAssertEqual(state.documentDrafts.recentDocuments.count, 2)
        XCTAssertTrue(state.prepareDocumentCapture(target: .auto, resuming: true))
        XCTAssertEqual(state.specialtyEditedText, "Current email")
    }

    func testCompleteCaptureKeepsFinalWordsWithoutConfirmedSpans() async {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "emailReady"
        state.specialtyEditedText = "Hello team."
        XCTAssertTrue(state.transcriptionService.stagedTranscript.confirmedSpans.isEmpty)
        let result = await state.formatCapturedDocument("Send the final report on Friday.", refine: false)
        XCTAssertEqual(result, "Hello team.\n\nSend the final report on Friday.")
        XCTAssertEqual(state.documentDrafts.text(for: "emailReady"), result)
        XCTAssertTrue(state.specialtyQueuedSegments.isEmpty)
        let silent = await state.formatCapturedDocument(" \n ", refine: false)
        XCTAssertEqual(silent, "")
        XCTAssertEqual(state.specialtyEditedText, result, "A silent capture cannot duplicate a previous document")
    }

    func testPausedDocumentKeepsItsTemplateAndDraftUntilResumedOrDiscarded() {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "emailReady"
        state.specialtyEditedText = "Earlier email"
        XCTAssertTrue(state.newSpecialtyDocument())
        let earlierID = state.documentDrafts.recentDocuments[0].id
        state.specialtyEditedText = "Current email"
        state.pendingSessionText = "New words awaiting resume."
        state.dictationCleanupTemplate = "instructions"
        state.selectDictationOutput(.standard, openDocument: false)
        XCTAssertEqual(state.dictationCleanupTemplate, "emailReady")
        XCTAssertFalse(state.newSpecialtyDocument())
        state.restoreSpecialtyDocument(id: earlierID)
        XCTAssertEqual(state.specialtyEditedText, "Current email")
        XCTAssertTrue(state.prepareDocumentCapture(target: .document, resuming: true))
        XCTAssertEqual(state.pendingSessionText, "New words awaiting resume.")
        state.agenticEditInstruction = "Shorten the greeting."
        XCTAssertFalse(state.prepareDocumentCapture(target: .askBar, resuming: true))
        XCTAssertFalse(state.isCommandDictation)
        XCTAssertEqual(state.agenticEditInstruction, "Shorten the greeting.")
        state.discardPendingSession()
        state.selectDictationOutput(.instructions, openDocument: false)
        XCTAssertEqual(state.dictationCleanupTemplate, "instructions")
    }

    func testManualAppendKeepsCaptureSeparateAndDoesNotRecordOldDocumentAgain() async {
        let restore = restorePreferences()
        defer { restore() }
        let state = AppState()
        state.dictationCleanupTemplate = "instructions"
        state.specialtyEditedText = "1. Label the samples."
        state.autoAppendSpecialtyAdditions = false
        let capture = "Store them in the cold room."
        let result = await state.formatCapturedDocument(capture, refine: true)
        XCTAssertEqual(result, capture)
        XCTAssertEqual(state.specialtyEditedText, "1. Label the samples.")
        XCTAssertEqual(state.specialtyQueuedSegments.map(\.text), [capture])
        XCTAssertEqual(state.documentDrafts.draft(for: "instructions").additions, [capture])
    }
}
