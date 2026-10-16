// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Pins the crash-safety persistence layer: the manifest must round-trip and
/// tolerate older/partial writes, the journal reader must survive a truncated
/// last line (a crash mid-append), and the orphan scan must classify + reap
/// directories correctly. These are the invariants that make "a crash 30 min in
/// loses almost nothing" hold.
final class MeetingSessionStoreTests: XCTestCase {

    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        createdDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-store-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdDirs.append(dir)
        return dir
    }

    // MARK: - Manifest round-trip

    func testManifestRoundTrips() throws {
        let manifest = MeetingManifest(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            parts: [MeetingPart(file: "audio-001.caf", duration: 42.5, sampleRate: 48000)],
            expectedSpeakers: 3,
            deviceUID: "mic-uid",
            status: .stopped,
            heartbeat: Date(timeIntervalSince1970: 1_700_000_100),
            appVersion: "1.2.3")

        let data = try JSONEncoder.meeting.encode(manifest)
        let decoded = try JSONDecoder.meeting.decode(MeetingManifest.self, from: data)

        XCTAssertEqual(decoded.id, manifest.id)
        XCTAssertEqual(decoded.status, .stopped)
        XCTAssertEqual(decoded.parts.count, 1)
        XCTAssertEqual(decoded.parts.first?.duration, 42.5)
        XCTAssertEqual(decoded.expectedSpeakers, 3)
        XCTAssertEqual(decoded.deviceUID, "mic-uid")
        XCTAssertEqual(decoded.appVersion, "1.2.3")
    }

    // MARK: - Tolerant decode

    func testManifestTolerantDecodeMissingOptionalsAndUnknownKeys() throws {
        // A manifest written by a different build: no expectedSpeakers/deviceUID,
        // an unknown extra key, and an unrecognized status string.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "startedAt": "2026-01-01T00:00:00Z",
          "parts": [],
          "status": "some-future-status",
          "heartbeat": "2026-01-01T00:00:10Z",
          "appVersion": "9.9",
          "futureField": {"nested": true}
        }
        """
        let decoded = try JSONDecoder.meeting.decode(MeetingManifest.self, from: Data(json.utf8))
        XCTAssertNil(decoded.expectedSpeakers)
        XCTAssertNil(decoded.deviceUID)
        // Unknown status must fall back to .recording so the dir stays a resumable orphan.
        XCTAssertEqual(decoded.status, .recording)
        XCTAssertEqual(decoded.appVersion, "9.9")
    }

    func testStatusUnknownDecodesToRecording() throws {
        let data = Data("\"garbage\"".utf8)
        let status = try JSONDecoder.meeting.decode(MeetingSessionStatus.self, from: data)
        XCTAssertEqual(status, .recording)
    }

    // MARK: - Journal recovery

    func testJournalReadDropsTruncatedLastLine() throws {
        let dir = makeTempDir()
        let journal = dir.appendingPathComponent("segments.jsonl")

        let seg1 = MeetingSegment(speakerId: "Speaker 0", speakerLabel: "Speaker 0",
                                  text: "first line", startTime: 0, endTime: 1)
        let seg2 = MeetingSegment(speakerId: "Speaker 1", speakerLabel: "Speaker 1",
                                  text: "second line", startTime: 1, endTime: 2)

        var data = Data()
        data.append(try JSONEncoder.meeting.encode(seg1)); data.append(0x0A)
        data.append(try JSONEncoder.meeting.encode(seg2)); data.append(0x0A)
        // A crash mid-write leaves a partial, unterminated third line.
        data.append(Data("{\"speakerId\":\"Speaker 2\",\"text\":\"cut o".utf8))
        try data.write(to: journal)

        let read = MeetingSession.readJournal(at: journal)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.map(\.text), ["first line", "second line"])
    }

    func testAppendAndReadLiveSegmentsRoundTrip() {
        let dir = makeTempDir()
        let manifest = MeetingManifest(id: UUID(), startedAt: Date(), heartbeat: Date(), appVersion: "t")
        let session = MeetingSession(directory: dir, manifest: manifest)

        let seg1 = MeetingSegment(speakerId: "Speaker 0", speakerLabel: "Speaker 0",
                                  text: "hello", startTime: 0, endTime: 1)
        let seg2 = MeetingSegment(speakerId: "Speaker 0", speakerLabel: "Speaker 0",
                                  text: "world", startTime: 1, endTime: 2)
        session.appendLiveSegment(seg1)
        session.appendLiveSegment(seg2)
        session.closeJournal()

        let read = session.readLiveSegments()
        XCTAssertEqual(read.map(\.text), ["hello", "world"])
    }

    func testJournalKeepsCompleteLinesBeforeTruncatedUTF8() throws {
        let dir = makeTempDir()
        let journal = dir.appendingPathComponent("segments.jsonl")
        let segment = MeetingSegment(speakerId: "0", speakerLabel: "Speaker 1",
                                     text: "Keep the temperature at 4 degrees.", startTime: 0, endTime: 2)
        var data = try JSONEncoder.meeting.encode(segment)
        data.append(0x0A)
        data.append(Data("{\"text\":\"The next symbol is ".utf8))
        data.append(contentsOf: [0xE2, 0x82])
        try data.write(to: journal)
        XCTAssertEqual(MeetingSession.readJournal(at: journal).map(\.text), [segment.text])
    }

    func testReopenReconcilesPartNamesWithoutDroppingMissingAudio() throws {
        let dir = makeTempDir()
        let manifest = MeetingManifest(id: UUID(), startedAt: Date(), parts: [
            MeetingPart(file: "audio-001.caf", duration: 1, sampleRate: 16000),
            MeetingPart(file: "audio-002.caf", duration: 2, sampleRate: 16000)
        ], heartbeat: Date(), appVersion: "t")
        try JSONEncoder.meeting.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try Data([2]).write(to: dir.appendingPathComponent("audio-002.caf"))
        try Data([3]).write(to: dir.appendingPathComponent("audio-003.caf"))
        let orphan = OrphanedMeeting(id: manifest.id, directory: dir, startedAt: manifest.startedAt,
                                     recordedDuration: 3, diskBytes: 2, hasLiveSegments: false, status: .stopped)
        let reopened = try MeetingSessionStore.openSession(orphan)
        XCTAssertEqual(reopened.partURLs().map(\.lastPathComponent), ["audio-001.caf", "audio-002.caf", "audio-003.caf"])
        try reopened.persistManifest()
        XCTAssertEqual(try MeetingSessionStore.readManifest(in: dir)?.parts[1].duration, 2)
    }

    func testResumingAGappedRecordingNeverOverwritesAnExistingPart() throws {
        let dir = makeTempDir()
        let manifest = MeetingManifest(id: UUID(), startedAt: Date(), parts: [
            MeetingPart(file: "audio-001.caf", duration: 1, sampleRate: 16000),
            MeetingPart(file: "audio-003.caf", duration: 3, sampleRate: 16000)
        ], heartbeat: Date(), appVersion: "t")
        let prior = dir.appendingPathComponent("audio-003.caf")
        let unlisted = dir.appendingPathComponent("audio-005.caf")
        let data = Data([1, 2, 3, 4])
        try data.write(to: prior)
        try data.write(to: unlisted)
        let session = MeetingSession(directory: dir, manifest: manifest)
        let next = try session.beginPart()
        XCTAssertEqual(next.lastPathComponent, "audio-006.caf")
        XCTAssertEqual(try Data(contentsOf: prior), data)
        XCTAssertEqual(try Data(contentsOf: unlisted), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: next.path)[.posixPermissions] as? Int, 0o600)
    }

    func testFailedPartRegistrationLeavesNoPhantomPart() throws {
        let dir = makeTempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("manifest.json"), withIntermediateDirectories: false)
        let manifest = MeetingManifest(id: UUID(), startedAt: Date(), heartbeat: Date(), appVersion: "t")
        let session = MeetingSession(directory: dir, manifest: manifest)
        XCTAssertThrowsError(try session.beginPart())
        XCTAssertTrue(session.partURLs().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio-001.caf").path))
    }

    func testReleaseKeepsUnprocessedAudioUntilExplicitDiscard() throws {
        for status in [MeetingSessionStatus.recording, .processing, .stopped] {
            let dir = makeTempDir()
            let manifest = MeetingManifest(id: UUID(), startedAt: Date(), status: status, heartbeat: Date(), appVersion: "t")
            let session = MeetingSession(directory: dir, manifest: manifest)
            let part = try session.beginPart()
            try Data([1, 2, 3]).write(to: part)
            session.release()
            XCTAssertEqual(try Data(contentsOf: part), Data([1, 2, 3]))
            XCTAssertEqual(try MeetingSessionStore.readManifest(in: dir)?.status, .stopped)
            session.release(discardUnprocessed: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        }
    }

    func testReleaseRemovesAudioAfterDurableCompletion() throws {
        let dir = makeTempDir()
        let manifest = MeetingManifest(id: UUID(), startedAt: Date(), status: .completed, heartbeat: Date(), appVersion: "t")
        MeetingSession(directory: dir, manifest: manifest).release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testPartialTranscriptLabelSurvivesHistoryRoundTrip() throws {
        let transcript = MeetingTranscript(
            segments: [MeetingSegment(speakerId: "0", speakerLabel: "Speaker 1", text: "The report is ready.", startTime: 0, endTime: 1)],
            speakerNames: [:], duration: 1, timestamp: Date(), isPartial: true)
        let data = try JSONEncoder.meeting.encode(transcript)
        let decoded = try JSONDecoder.meeting.decode(MeetingTranscript.self, from: data)
        XCTAssertTrue(decoded.isPartial)
        XCTAssertTrue(decoded.plainText.hasPrefix("Partial transcript"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "isPartial")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertFalse(try JSONDecoder.meeting.decode(MeetingTranscript.self, from: oldData).isPartial)
    }

    // MARK: - Orphan scan

    func testScanClassifiesRecordingSessionAsOrphan() throws {
        let session = try MeetingSessionStore.createSession(deviceUID: "dev", expectedSpeakers: 2)
        createdDirs.append(session.directory)
        _ = try session.beginPart()

        let orphans = MeetingSessionStore.scanForOrphans()
        let mine = orphans.first { $0.id == session.id }
        XCTAssertNotNil(mine, "A live recording directory must be surfaced as an orphan at launch")
        XCTAssertEqual(mine?.status, .recording)
    }

    func testScanReapsCompletedDirectory() throws {
        let session = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
        let dir = session.directory
        createdDirs.append(dir)
        session.setStatus(.completed)

        let orphans = MeetingSessionStore.scanForOrphans()
        XCTAssertFalse(orphans.contains { $0.id == session.id },
                       "A completed directory is durable in history and must not be an orphan")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "The scan must reap leftover completed directories")
    }

    func testCafDurationOfMissingFileIsZero() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).caf")
        XCTAssertEqual(MeetingSessionStore.cafDuration(missing), 0)
    }

    // MARK: - Retention

    private func withRetentionDays(_ days: Int, _ body: () throws -> Void) rethrows {
        let key = "historyRetentionDays"
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defaults.set(days, forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        try body()
    }

    func testScanKeepsUnfinishedAudioBeyondHistoryRetention() throws {
        try withRetentionDays(7) {
            let session = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
            let dir = session.directory
            createdDirs.append(dir)

            // Backdate the manifest well beyond the 7-day window.
            let old = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            let backdated = MeetingManifest(
                id: session.id, startedAt: old, status: .recording, heartbeat: old, appVersion: "t")
            let data = try JSONEncoder.meeting.encode(backdated)
            try data.write(to: dir.appendingPathComponent("manifest.json"))

            let orphans = MeetingSessionStore.scanForOrphans()
            XCTAssertTrue(orphans.contains { $0.id == session.id },
                          "Completed-history cleanup must keep unfinished recordings recoverable")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                          "The only recoverable recording must not be deleted by age")
        }
    }

    func testScanKeepsFreshOrphanUnderRetention() throws {
        try withRetentionDays(7) {
            let session = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
            createdDirs.append(session.directory)
            _ = try session.beginPart()

            let orphans = MeetingSessionStore.scanForOrphans()
            XCTAssertTrue(orphans.contains { $0.id == session.id },
                          "A recording started today must survive a 7-day retention window")
        }
    }

    func testScanKeepsFreshRecordingWithAMissingStartDate() throws {
        try withRetentionDays(7) {
            let session = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
            createdDirs.append(session.directory)
            _ = try session.beginPart()
            let url = session.directory.appendingPathComponent("manifest.json")
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            manifest.removeValue(forKey: "startedAt")
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            let orphan = MeetingSessionStore.scanForOrphans().first { $0.id == session.id }
            XCTAssertNotNil(orphan)
            XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
            XCTAssertGreaterThan(orphan?.startedAt ?? .distantPast, Date().addingTimeInterval(-60))
        }
    }

    func testRetentionZeroKeepsEverything() throws {
        try withRetentionDays(0) {
            let session = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
            let dir = session.directory
            createdDirs.append(dir)

            // Even a very old recording is kept when retention is disabled (0).
            let old = Calendar.current.date(byAdding: .day, value: -3650, to: Date())!
            let backdated = MeetingManifest(
                id: session.id, startedAt: old, status: .recording, heartbeat: old, appVersion: "t")
            try JSONEncoder.meeting.encode(backdated).write(to: dir.appendingPathComponent("manifest.json"))

            let orphans = MeetingSessionStore.scanForOrphans()
            XCTAssertTrue(orphans.contains { $0.id == session.id },
                          "Retention 0 means keep forever; nothing is auto-discarded by age")
        }
    }
}
