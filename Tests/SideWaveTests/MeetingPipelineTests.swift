// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import XCTest
@testable import SideWave

final class MeetingPipelineTests: XCTestCase {
    private enum FixtureError: Error { case processingFailed }

    @MainActor
    func testEmptyRecognitionKeepsRecordingRecoverableAfterCompletionAndRelease() throws {
        let session = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
        defer { try? FileManager.default.removeItem(at: session.directory) }
        defer { MeetingHistoryStore.shared.deleteMeeting(id: session.id) }
        let audio = try session.beginPart()
        try writeCAF(Array(repeating: 0, count: 16_000), to: audio)
        let service = MeetingTranscriptionService()
        try service.commit(.init(rawSegments: [], speakerCount: 0, duration: 1, words: [], tokenTimings: []), session: session)
        XCTAssertEqual(service.state, .complete)
        XCTAssertEqual(service.transcript?.hasSpeech, false)
        XCTAssertTrue(service.postRecordingWarning?.contains("kept") == true)
        session.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let recovered = try XCTUnwrap(MeetingSessionStore.scanForOrphans().first { $0.id == session.id })
        XCTAssertEqual(recovered.status, .stopped)
    }

    @MainActor
    func testReprocessingRecoveredRecordingReplacesItsHistoryEntry() throws {
        let session = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
        let other = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
        defer {
            for item in [session, other] {
                MeetingHistoryStore.shared.deleteMeeting(id: item.id)
                try? FileManager.default.removeItem(at: item.directory)
            }
        }
        let audio = try session.beginPart()
        try writeCAF(Array(repeating: 0, count: 16_000), to: audio)
        let empty = MeetingBatchResult(rawSegments: [], speakerCount: 0, duration: 1, words: [], tokenTimings: [])
        try MeetingTranscriptionService().commit(empty, session: session)
        session.release()
        let orphan = try XCTUnwrap(MeetingSessionStore.scanForOrphans().first { $0.id == session.id })
        let recovered = try MeetingSessionStore.openSession(orphan)
        try MeetingTranscriptionService().commit(empty, session: recovered)
        try MeetingTranscriptionService().commit(empty, session: other)

        let history = MeetingHistoryStore.shared
        XCTAssertEqual(history.meetings.filter { $0.id == session.id }.count, 1)
        XCTAssertEqual(history.meetings.filter { $0.id == other.id }.count, 1)
        let loaded = MeetingHistoryStore(storageURL: history.storageDirectory.appendingPathComponent("meeting-history.json"))
        XCTAssertEqual(loaded.meetings.filter { $0.id == session.id }.count, 1)
        XCTAssertEqual(loaded.meetings.filter { $0.id == other.id }.count, 1)
        XCTAssertEqual(try MeetingSessionStore.readManifest(in: session.directory)?.status, .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    @MainActor
    func testReprocessingPreservesNotesAndEmptyRetryCannotErasePriorSpeech() throws {
        let session = try MeetingSessionStore.createSession(deviceUID: nil, expectedSpeakers: nil)
        defer {
            MeetingHistoryStore.shared.deleteMeeting(id: session.id)
            try? FileManager.default.removeItem(at: session.directory)
        }
        let audio = try session.beginPart()
        try writeCAF(Array(repeating: 0, count: 16_000), to: audio)
        let partial = MeetingTranscript(id: session.id,
            segments: [.init(speakerId: "0", speakerLabel: "Speaker 1", text: "The report", startTime: 0, endTime: 1)],
            speakerNames: [:], duration: 1, timestamp: session.startedAt, isPartial: true)
        XCTAssertTrue(MeetingHistoryStore.shared.addMeeting(partial))
        MeetingHistoryStore.shared.saveFormattedOutput(meetingID: session.id, format: "Notes", output: "Keep these reviewed notes.")
        let service = MeetingTranscriptionService()
        try service.commit(.init(rawSegments: [.init(speakerId: "0", start: 0, end: 1, rawText: "The report is ready.")],
            speakerCount: 1, duration: 1, words: [], tokenTimings: []), session: session)
        let completed = try XCTUnwrap(service.transcript)
        XCTAssertEqual(completed.id, session.id)
        XCTAssertFalse(completed.isPartial)
        XCTAssertEqual(completed.savedFormats["Notes"], "Keep these reviewed notes.")
        XCTAssertTrue(completed.staleFormats.contains("Notes"))
        XCTAssertEqual(MeetingHistoryStore.shared.meetings.filter { $0.id == session.id }.count, 1)

        try service.commit(.init(rawSegments: [], speakerCount: 0, duration: 1, words: [], tokenTimings: []), session: session)
        XCTAssertEqual(service.transcript?.plainText, completed.plainText)
        XCTAssertEqual(service.transcript?.savedFormats, completed.savedFormats)
        XCTAssertTrue(service.postRecordingWarning?.contains("previous transcript") == true)
        XCTAssertEqual(try MeetingSessionStore.readManifest(in: session.directory)?.status, .stopped)
        session.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testHourOfMeetingPartsUsesCompleteDiskBackedTimeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SIDEWAVE_LIVE_MODELS"] == "1", env["SIDEWAVE_LONG_MEETING_TESTS"] == "1",
              let path = env["SIDEWAVE_MEETING_FIXTURE"] else {
            throw XCTSkip("Long meeting processing requires an explicit audio fixture and opt-in")
        }
        let url = URL(fileURLWithPath: path)
        let duration = MeetingSessionStore.cafDuration(url)
        XCTAssertGreaterThan(duration, 60)
        guard duration > 60 else { return }
        let count = Int(ceil(3600 / duration))
        let engine = MeetingEngine(asrVersion: .v3)
        try await engine.prepare(includeLive: false, progress: { _ in })
        let start = Date()
        let result = try await engine.batchProcess(partURLs: Array(repeating: url, count: count), progress: { _, _ in })
        XCTAssertEqual(result.duration, duration * Double(count), accuracy: 0.1)
        XCTAssertGreaterThan(result.words.count, 1_000)
        XCTAssertTrue(result.tokenTimings.contains { $0.startTime > result.duration - 120 })
        XCTAssertTrue(result.rawSegments.contains { $0.end > result.duration - 120 })
        XCTAssertTrue(result.rawSegments.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= result.duration + 1 })
        XCTAssertLessThanOrEqual(result.speakerCount, 8)
        print("LONG_MEETING audio_seconds=\(result.duration) processing_seconds=\(Date().timeIntervalSince(start)) words=\(result.words.count) speakers=\(result.speakerCount)")
    }

    func testAudioReaderPropagatesProcessingErrors() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeCAF([Float](repeating: 0.1, count: 16_000), to: url)
        let engine = MeetingEngine(asrVersion: .v3)
        do {
            try await engine.streamCAF(url) { _ in throw FixtureError.processingFailed }
            XCTFail("A diarization failure must reach the recovery path")
        } catch FixtureError.processingFailed { }
    }

    func testMissingOrCorruptPartCannotBeReportedAsComplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("audio.caf")
        try writeCAF([Float](repeating: 0.1, count: 320), to: valid)
        let empty = root.appendingPathComponent("empty.caf")
        try Data().write(to: empty)
        XCTAssertEqual(try MeetingEngine.validatedAudioParts([valid, empty]).first?.duration, 0.02)
        XCTAssertThrowsError(try MeetingEngine.validatedAudioParts([valid, root.appendingPathComponent("missing.caf")]))
        let corrupt = root.appendingPathComponent("corrupt.caf")
        try Data("broken audio".utf8).write(to: corrupt)
        XCTAssertThrowsError(try MeetingEngine.validatedAudioParts([valid, corrupt]))
    }

    func testLiveMultiPartMeetingPreservesBothRecordings() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Meeting models require SIDEWAVE_LIVE_MODELS=1")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = [
            ("Samantha", "We reviewed the greenhouse samples this morning. The first group is ready for analysis, and we should send the report before Friday."),
            ("Fred", "I will check the irrigation records after lunch. Please keep the control plants in the second chamber until the temperature is stable.")
        ]
        var parts: [URL] = []
        for (index, fixture) in fixtures.enumerated() {
            let source = directory.appendingPathComponent("speech_\(index).aiff")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", fixture.0, "-o", source.path, fixture.1]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let file = try AVAudioFile(forReading: source)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let selector = ChannelSelector(mode: .mix, channelCount: Int(buffer.format.channelCount), deviceUID: nil, cachedAutoChannel: nil, onAutoCalibrated: nil)
            let samples = AudioResampler(useHQ: true).resampleTo16k(samples: selector.selectAndDownmix(buffer), sourceSampleRate: buffer.format.sampleRate)
            let part = directory.appendingPathComponent("part_\(index).caf")
            try writeCAF([Float](repeating: 0, count: 4_000) + samples + [Float](repeating: 0, count: 8_000), to: part)
            parts.append(part)
        }
        let engine = MeetingEngine(asrVersion: .v3)
        try await engine.prepare(includeLive: false, progress: { _ in })
        let result = try await engine.batchProcess(partURLs: parts, progress: { _, _ in })
        let text = result.rawSegments.map(\.rawText).joined(separator: " ").lowercased()
        for word in ["greenhouse", "friday", "irrigation", "temperature"] {
            XCTAssertTrue(text.contains(word), "Both recording parts must survive: \(text)")
        }
        XCTAssertGreaterThan(result.duration, 10)
        XCTAssertGreaterThan(result.speakerCount, 0)
        XCTAssertLessThanOrEqual(result.speakerCount, 8)
        XCTAssertFalse(result.tokenTimings.isEmpty)
        XCTAssertTrue(result.rawSegments.allSatisfy { $0.start.isFinite && $0.end >= $0.start })
        let firstDuration = MeetingSessionStore.cafDuration(parts[0])
        XCTAssertTrue(result.tokenTimings.contains { $0.startTime >= firstDuration }, "Second-part timestamps must be offset")
    }

    private func writeCAF(_ samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
