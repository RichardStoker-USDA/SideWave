// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import XCTest
@testable import SideWave

final class DictationRecordingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String, bytes: Int, ageSeconds: TimeInterval) throws {
        let url = directory.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
    }

    func testPruneKeepsTheNewestWithinCountAndSize() throws {
        try makeFile("a.wav", bytes: 400, ageSeconds: 30)
        try makeFile("b.wav", bytes: 400, ageSeconds: 20)
        try makeFile("c.wav", bytes: 400, ageSeconds: 10)
        try makeFile("notes.txt", bytes: 10, ageSeconds: 40)

        DictationRecordings.prune(in: directory, maxCount: 2, maxBytes: 10_000)
        XCTAssertEqual(DictationRecordings.files(in: directory).map(\.url.lastPathComponent), ["c.wav", "b.wav"])

        DictationRecordings.prune(in: directory, maxCount: 10, maxBytes: 500)
        XCTAssertEqual(DictationRecordings.files(in: directory).map(\.url.lastPathComponent), ["c.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.txt").path))
    }

    func testPruneNeverDeletesTheNewestRecording() throws {
        try makeFile("long.wav", bytes: 2_000, ageSeconds: 5)
        DictationRecordings.prune(in: directory, maxCount: 1, maxBytes: 100)
        XCTAssertEqual(DictationRecordings.files(in: directory).count, 1)
    }

    func testRecordingIsMonoSixteenKilohertzAndOwnerOnly() throws {
        let url = directory.appendingPathComponent("session_test.wav")
        let capture = try XCTUnwrap(SessionAudioCapture(url: url))
        capture.append([Float](repeating: 0.25, count: 1_600))
        capture.append([Float](repeating: -0.25, count: 1_600))
        let done = expectation(description: "closed")
        capture.close { done.fulfill() }
        wait(for: [done], timeout: 5)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 3_200)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}
