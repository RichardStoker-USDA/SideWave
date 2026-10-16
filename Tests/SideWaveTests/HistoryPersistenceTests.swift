// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

@MainActor
final class HistoryPersistenceTests: XCTestCase {
    func testUnrefinedHistoryDoesNotAcquireAModelFromRawStages() throws {
        let raw = TranscriptionEntry(text: "The samples are ready.", appName: "Test",
            rawText: "The samples are ready.", eouText: "the samples are ready")
        XCTAssertNil(raw.displayRefineBackend)
        let refined = TranscriptionEntry(text: "The samples are ready.", appName: "Test",
            rawText: "The samples are ready.", refineBackend: "gemma4-e2b")
        XCTAssertEqual(refined.displayRefineBackend, "gemma4-e2b", "A successful no-change pass still used the model")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(refined)) as? [String: Any])
        legacy.removeValue(forKey: "refinementUsed")
        let decoded = try JSONDecoder().decode(TranscriptionEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.displayRefineBackend, "Legacy identical raw/output stages are not evidence of refinement")
    }

    func testHardwareDefaultsPreserveExplicitPipelinePreferences() throws {
        let domain = "sidewave_tests.hardware_\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("high", forKey: "hardwareTier")
        defaults.set(Date().timeIntervalSince1970, forKey: "hardwareTierDetectedAt")
        defaults.set("standard", forKey: "refineCadence")
        defaults.set(false, forKey: "refineFixedIntervalEnabled")
        XCTAssertEqual(HardwareDetector.detectIfNeeded(afmAvailable: true, defaults: defaults), .high)
        XCTAssertEqual(defaults.string(forKey: "refineCadence"), "standard")
        XCTAssertFalse(defaults.bool(forKey: "refineFixedIntervalEnabled"))
        defaults.removeObject(forKey: "refineCadence")
        XCTAssertEqual(defaults.string(forKey: "refineCadence"), "faster", "Hardware defaults still apply when no choice was saved")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFailedSaveKeepsTextForRetry() throws {
        let root = try directory().appendingPathComponent("unavailable")
        let file = root.appendingPathComponent("history.json")
        let store = HistoryStore(storageURL: file)
        store.addEntry(text: "Keep the final three words", appName: "Test")
        XCTAssertFalse(store.flush())
        XCTAssertNotNil(store.persistenceError)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(store.flush())
        XCTAssertEqual(HistoryStore(storageURL: file).entries.first?.text, "Keep the final three words")
    }

    func testUnreadableHistoryCannotBeOverwritten() throws {
        let file = try directory().appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let sentinel = file.appendingPathComponent("original")
        try Data("preserved".utf8).write(to: sentinel)
        let store = HistoryStore(storageURL: file)
        store.addEntry(text: "Unsaved", appName: "Test")
        XCTAssertFalse(store.flush())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserved".utf8))
    }

    func testLegacyTemporarySnapshotIsRecoveredBeforeDeletion() throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let source = sessions.appendingPathComponent("session_example.volatile.tmp")
        try Data("The previously unsaved ending".utf8).write(to: source)
        let history = root.appendingPathComponent("history.json")
        let store = HistoryStore(storageURL: history, sessionsDirectory: sessions)
        XCTAssertEqual(store.entries.first?.text, "The previously unsaved ending")
        XCTAssertEqual(HistoryStore(storageURL: history).entries.first?.entryType, .recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testMalformedRecoveryAndFailedFlushKeepTheirSourceFiles() throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let corrupt = sessions.appendingPathComponent("session_partial.jsonl")
        let valid = sessions.appendingPathComponent("session_valid.volatile")
        try Data("{\"text\":\"keep this\"}\n{partial".utf8).write(to: corrupt)
        try Data("Recover this when storage returns".utf8).write(to: valid)
        let file = root.appendingPathComponent("missing/history.json")
        let store = HistoryStore(storageURL: file, sessionsDirectory: sessions)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
        XCTAssertFalse(store.flush())
    }

    func testPartialJournalRecoversReadableTextWithoutDuplicateHistory() throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let journal = sessions.appendingPathComponent("session_interrupted.jsonl")
        let snapshot = sessions.appendingPathComponent("session_interrupted.volatile")
        var data = Data("{\"text\":\"Keep the samples cold.\"}\n{\"text\":\"".utf8)
        data.append(contentsOf: [0xE2, 0x82])
        try data.write(to: journal)
        try Data("Send the report on Friday.".utf8).write(to: snapshot)
        let file = root.appendingPathComponent("history.json")
        let first = HistoryStore(storageURL: file, sessionsDirectory: sessions)
        XCTAssertEqual(first.entries.first?.text, "Keep the samples cold. Send the report on Friday.")
        XCTAssertEqual(first.entries.first?.recoveryIncomplete, true)
        XCTAssertNotNil(first.persistenceError)
        XCTAssertEqual(try Data(contentsOf: journal), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        let second = HistoryStore(storageURL: file, sessionsDirectory: sessions)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.id, first.entries.first?.id)

        try Data("{\"text\":\"Keep the samples cold.\"}\n{\"text\":\"Check the labels.\"}\n".utf8).write(to: journal)
        let complete = HistoryStore(storageURL: file, sessionsDirectory: sessions)
        XCTAssertEqual(complete.entries.count, 1)
        XCTAssertEqual(complete.entries.first?.id, first.entries.first?.id)
        XCTAssertEqual(complete.entries.first?.text, "Keep the samples cold. Check the labels. Send the report on Friday.")
        XCTAssertEqual(complete.entries.first?.recoveryIncomplete, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }

    func testMeetingHistoryFailureKeepsTranscriptAndCanRetry() throws {
        let root = try directory().appendingPathComponent("missing")
        let file = root.appendingPathComponent("meeting-history.json")
        let store = MeetingHistoryStore(storageURL: file)
        let transcript = MeetingTranscript(segments: [], speakerNames: [:], duration: 1, timestamp: Date())
        XCTAssertFalse(store.addMeeting(transcript))
        XCTAssertEqual(store.meetings.first?.id, transcript.id)
        XCTAssertNotNil(store.persistenceError)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(store.retrySaving())
        XCTAssertEqual(MeetingHistoryStore(storageURL: file).meetings.first?.id, transcript.id)
    }

    func testUnreadableMeetingHistoryCannotBeOverwritten() throws {
        let file = try directory().appendingPathComponent("meeting-history.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let sentinel = file.appendingPathComponent("original")
        try Data("preserved".utf8).write(to: sentinel)
        let store = MeetingHistoryStore(storageURL: file)
        store.clearAll()
        XCTAssertFalse(store.retrySaving())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserved".utf8))
    }

    func testMeetingHistoryDoesNotSilentlyDropOlderSavedMeetings() throws {
        let file = try directory().appendingPathComponent("meeting-history.json")
        let store = MeetingHistoryStore(storageURL: file)
        var identifiers: Set<UUID> = []
        for _ in 0..<60 {
            let transcript = MeetingTranscript(segments: [], speakerNames: [:], duration: 1, timestamp: Date())
            identifiers.insert(transcript.id)
            XCTAssertTrue(store.addMeeting(transcript))
        }
        let reopened = MeetingHistoryStore(storageURL: file)
        XCTAssertEqual(Set(reopened.meetings.map(\.id)), identifiers)
    }

    func testMeetingExpiryPreservesUnfinishedTranscripts() throws {
        let domain = "sidewave_tests.retention_\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(7, forKey: "historyRetentionDays")
        let file = try directory().appendingPathComponent("meeting-history.json")
        let store = MeetingHistoryStore(storageURL: file)
        let oldDate = Date().addingTimeInterval(-30 * 86_400)
        let segment = MeetingSegment(speakerId: "one", speakerLabel: "Speaker 1", text: "Review the results.", startTime: 0, endTime: 2)
        let complete = MeetingTranscript(segments: [segment], speakerNames: [:], duration: 2, timestamp: oldDate)
        let partial = MeetingTranscript(segments: [segment], speakerNames: [:], duration: 2, timestamp: oldDate, isPartial: true)
        let empty = MeetingTranscript(segments: [], speakerNames: [:], duration: 2, timestamp: oldDate)
        for meeting in [complete, partial, empty] { XCTAssertTrue(store.addMeeting(meeting)) }
        store.pruneExpiredMeetings(defaults: defaults)
        XCTAssertEqual(Set(MeetingHistoryStore(storageURL: file).meetings.map(\.id)), [partial.id, empty.id])
    }
}
