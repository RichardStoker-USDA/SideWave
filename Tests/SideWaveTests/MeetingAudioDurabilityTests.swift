// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import Darwin
import XCTest
@testable import SideWave

final class MeetingAudioDurabilityTests: XCTestCase {
    func testSavedMeetingPreservesSelectedInterfaceChannel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 48_000))
        input.frameLength = 48_000
        for frame in 0..<48_000 {
            input.floatChannelData![0][frame] = 0
            input.floatChannelData![1][frame] = sinf(Float(frame) * 0.02) * 0.3
            input.floatChannelData![2][frame] = 0.8
            input.floatChannelData![3][frame] = -0.8
        }
        let selector = ChannelSelector(mode: .channel(2), channelCount: 4, deviceUID: nil,
                                       cachedAutoChannel: nil, onAutoCalibrated: nil)
        let selected = selector.selectAndDownmix(input)
        let outputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
        let writer = MeetingAudioWriter(file: file)
        writer.writeMono(selected)
        writer.checkpoint()
        XCTAssertEqual(writer.failedWriteCount, 0)
        XCTAssertEqual(writer.recordedDuration, 1, accuracy: 0.001)
        writer.close()
        XCTAssertFalse(file.isOpen)

        let saved = try AVAudioFile(forReading: url)
        XCTAssertEqual(saved.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: 48_000))
        var recovered: [Float] = []
        while saved.framePosition < saved.length {
            try saved.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            recovered.append(contentsOf: UnsafeBufferPointer(
                start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(recovered.count, selected.count)
        for frame in stride(from: 0, to: recovered.count, by: 97) {
            XCTAssertEqual(recovered[frame], selected[frame], accuracy: 0.00001)
        }
    }

    func testAbruptProcessExitKeepsHourOfAudio() throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LONG_MEETING_TESTS"] == "1" else {
            throw XCTSkip("Process-kill recovery requires explicit long-meeting opt-in")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = try XCTUnwrap(Bundle.main.executableURL)
        child.arguments = ["-XCTest", "SideWaveTests.MeetingAudioDurabilityTests/testCrashWriterProcess",
                           "-sideWaveDataDirOverride", root.appendingPathComponent("data").path,
                           "-keepMicOnStandby", "NO"]
        var environment = ProcessInfo.processInfo.environment
        environment["SIDEWAVE_CRASH_WRITER_ROOT"] = root.path
        // XCTest removes its injection variables after launch; restore them for this fixture child.
        let platform = Bundle(for: XCTestCase.self).bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        environment["DYLD_INSERT_LIBRARIES"] = platform.appendingPathComponent("usr/lib/libXCTestBundleInject.dylib").path
        environment["DYLD_FRAMEWORK_PATH"] = Bundle.main.bundleURL.deletingLastPathComponent().path
            + ":" + platform.appendingPathComponent("Library/Frameworks").path
        environment["DYLD_LIBRARY_PATH"] = platform.appendingPathComponent("usr/lib").path
        environment["XCInjectBundle"] = Bundle(for: Self.self).bundleURL.path
        environment["XCInjectBundleInto"] = Bundle.main.executableURL?.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        let ready = root.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(90)
        while child.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            return XCTFail("Writer did not reach its on-disk checkpoint")
        }
        guard child.isRunning else { return XCTFail("Writer exited before recovery could be tested") }
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(MeetingSessionStore.cafDuration(root.appendingPathComponent("recording.caf")), 3600, accuracy: 0.001)
    }

    func testCrashWriterProcess() throws {
        guard let path = ProcessInfo.processInfo.environment["SIDEWAVE_CRASH_WRITER_ROOT"] else {
            throw XCTSkip("Invoked only by the abrupt-exit recovery test")
        }
        let root = URL(fileURLWithPath: path)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let writer = MeetingAudioWriter(file: try AVAudioFile(forWriting: root.appendingPathComponent("recording.caf"), settings: format.settings))
        let buffer = try oneSecond(format: format)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        for second in 1...3600 {
            writer.writeMono(samples)
            if second % 16 == 0 { writer.checkpoint() }
        }
        writer.checkpoint()
        XCTAssertEqual(writer.failedWriteCount, 0)
        try Data("ready".utf8).write(to: root.appendingPathComponent("ready"))
        withExtendedLifetime(writer) { Thread.sleep(forTimeInterval: 90) }
    }

    func testOpenRecordingIsReadableBeforeClose() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let writer = MeetingAudioWriter(file: try AVAudioFile(forWriting: url, settings: format.settings))
        defer { writer.close() }
        let buffer = try oneSecond(format: format)
        for _ in 0..<16 { writer.write(buffer) }
        writer.checkpoint()
        XCTAssertEqual(writer.failedWriteCount, 0)
        XCTAssertEqual(writer.recordedDuration, 16)
        XCTAssertEqual(MeetingSessionStore.cafDuration(url), 16, accuracy: 0.001)
        let saved = try AVAudioFile(forReading: url)
        let read = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: 16_000))
        try saved.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][100], buffer.floatChannelData![0][100], accuracy: 0.00001)
    }

    func testHourRecordingRemainsRecoverable() throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LONG_MEETING_TESTS"] == "1" else {
            throw XCTSkip("Hour-long disk fixture requires SIDEWAVE_LONG_MEETING_TESTS=1")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let writer = MeetingAudioWriter(file: try AVAudioFile(forWriting: url, settings: format.settings))
        defer { writer.close() }
        let buffer = try oneSecond(format: format)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        for second in 1...3600 {
            writer.writeMono(samples)
            if second % 16 == 0 { writer.checkpoint() }
        }
        writer.checkpoint()
        XCTAssertEqual(writer.failedWriteCount, 0)
        XCTAssertEqual(MeetingSessionStore.cafDuration(url), 3600, accuracy: 0.001)
        let reader = try AVAudioFile(forReading: url)
        reader.framePosition = reader.length - 16_000
        let tail = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 16_000))
        try reader.read(into: tail)
        XCTAssertEqual(tail.frameLength, 16_000)
        XCTAssertEqual(tail.floatChannelData![0][100], buffer.floatChannelData![0][100], accuracy: 0.00001)
    }

    private func oneSecond(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for frame in 0..<16_000 { buffer.floatChannelData![0][frame] = sinf(Float(frame) * 0.02) * 0.2 }
        return buffer
    }
}
