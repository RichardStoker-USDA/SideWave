// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import CoreAudio
import XCTest
@testable import SideWave

final class AudioInputRegressionTests: XCTestCase {
    @MainActor
    func testLiveDefaultAndExplicitInputReleaseBetweenSessions() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_AUDIO"] == "1" else {
            throw XCTSkip("Physical input testing requires SIDEWAVE_LIVE_AUDIO=1")
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("The isolated test host needs microphone permission before physical input testing")
        }
        let originalDefault = AudioDeviceManager.defaultInputDeviceID()
        let state = AppState()
        let uid = try XCTUnwrap(AudioDeviceManager.deviceUID(originalDefault))
        var selections: [String?] = [nil, uid]
        if ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_USB_AUDIO"] == "1" {
            let manager = AudioDeviceManager()
            manager.refreshDevices()
            let usb = try XCTUnwrap(manager.availableDevices.first { $0.transportType == kAudioDeviceTransportTypeUSB },
                                    "The requested USB input is not connected")
            selections.append(usb.uid)
        }
        for selection in selections {
            let preview = MicTestController()
            await preview.start(deviceUID: selection)
            XCTAssertTrue(preview.isRunning, preview.lastError ?? "The input did not start")
            XCTAssertTrue(state.audioDeviceManager.isDictationActive?() ?? false,
                          "Default-input overrides must yield to microphone diagnostics")
            let visibleInputs = AudioDeviceManager()
            visibleInputs.refreshDevices()
            XCTAssertFalse(visibleInputs.availableDevices.contains { $0.name.hasPrefix("CADefaultDeviceAggregate-") },
                           "An engine's temporary aggregate must not appear as a microphone choice")
            try await Task.sleep(for: .milliseconds(500))
            preview.stop()
            let deadline = Date().addingTimeInterval(4)
            while MicTestController.isCapturing, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertFalse(MicTestController.isCapturing)
            XCTAssertTrue(preview.testFinished)
            XCTAssertGreaterThan(preview.receivedBufferCount, 0)
            XCTAssertGreaterThan(preview.detectedSampleRate, 0)
            XCTAssertEqual(AudioDeviceManager.defaultInputDeviceID(), originalDefault)
        }
        let service = TranscriptionService()
        service.checkModelCache()
        guard service.modelState.isReady else { throw XCTSkip("The recognition cache is not ready for the live startup check") }
        defer { service.teardownEngineForShutdown() }
        for selection in selections {
            await service.startRecording(deviceUID: selection)
            XCTAssertTrue(service.isRecording, "The selected input must start a session")
            try await Task.sleep(for: .milliseconds(500))
            await service.cancelRecording()
            let deadline = Date().addingTimeInterval(4)
            while AudioSetupActivity.isActive, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertFalse(service.isRecording)
            XCTAssertFalse(AudioSetupActivity.isActive)
            XCTAssertEqual(AudioDeviceManager.defaultInputDeviceID(), originalDefault)
        }
    }

    func testMeetingWriterOwnsAudioAfterRenderBufferIsReused() throws {
        for interleaved in [false, true] {
            let input = try buffer([[0.2, 0.4], [0.6, 0.8]], interleaved: interleaved)
            let owned = try XCTUnwrap(MeetingAudioWriter.copyBuffer(input))
            for entry in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
                memset(entry.mData, 0, Int(entry.mDataByteSize))
            }
            let selector = ChannelSelector(mode: .channel(2), channelCount: 2, deviceUID: nil, cachedAutoChannel: nil, onAutoCalibrated: nil)
            XCTAssertEqual(selector.selectAndDownmix(owned), [0.6, 0.8])
            XCTAssertEqual(selector.selectAndDownmix(input), [0, 0])
        }
    }
    private func buffer(_ channels: [[Float]], interleaved: Bool = false) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: AVAudioChannelCount(channels.count), interleaved: interleaved
        ))
        let frames = channels[0].count
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in channels.indices {
            for frame in 0..<frames {
                if interleaved { data[0][frame * channels.count + channel] = channels[channel][frame] }
                else { data[channel][frame] = channels[channel][frame] }
            }
        }
        return buffer
    }

    func testInterleavedChannelExtractionAndMix() throws {
        let input = try buffer([[0.2, 0.4, 0.6], [0.6, 0.4, 0.2]], interleaved: true)
        let selector = ChannelSelector(mode: .channel(2), channelCount: 2, deviceUID: nil, cachedAutoChannel: nil, onAutoCalibrated: nil)
        XCTAssertEqual(selector.selectAndDownmix(input), [0.6, 0.4, 0.2])
        let mixer = ChannelSelector(mode: .mix, channelCount: 2, deviceUID: nil, cachedAutoChannel: nil, onAutoCalibrated: nil)
        let mixed = mixer.selectAndDownmix(input)
        XCTAssertEqual(mixed.count, 3)
        for sample in mixed { XCTAssertEqual(sample, 0.4, accuracy: 0.0001) }
    }

    func testAutoSelectionPreservesFirstBufferOnSecondChannel() throws {
        for interleaved in [false, true] {
            let selector = ChannelSelector(mode: .auto, channelCount: 2, deviceUID: nil, cachedAutoChannel: nil, onAutoCalibrated: nil)
            let input = try buffer([[0, 0, 0], [0.3, 0.4, 0.2]], interleaved: interleaved)
            XCTAssertEqual(selector.selectAndDownmix(input), [0.3, 0.4, 0.2])
        }
    }

    func testSilenceDoesNotExhaustAutomaticCalibration() throws {
        let selector = ChannelSelector(mode: .auto, channelCount: 2, deviceUID: nil, cachedAutoChannel: nil, onAutoCalibrated: nil)
        let silent = try buffer([[0, 0, 0], [0, 0, 0]])
        for _ in 0..<20 { _ = selector.selectAndDownmix(silent) }
        let speech = try buffer([[0, 0, 0], [0.3, 0.4, 0.2]])
        XCTAssertEqual(selector.selectAndDownmix(speech), [0.3, 0.4, 0.2])
    }

    func testCachedChannelIsRecheckedWhenMicrophoneMoves() throws {
        let selector = ChannelSelector(mode: .auto, channelCount: 2, deviceUID: nil, cachedAutoChannel: 1, onAutoCalibrated: nil)
        let input = try buffer([[0, 0, 0], [0.3, 0.4, 0.2]])
        XCTAssertEqual(selector.selectAndDownmix(input), [0.3, 0.4, 0.2])
    }

    func testInvalidSampleRatesDoNotTrapOrAllocate() {
        for useHQ in [false, true] {
            let resampler = AudioResampler(useHQ: useHQ)
            for rate in [0, -1, Double.nan, Double.infinity, -Double.infinity, Double.leastNonzeroMagnitude] {
                XCTAssertTrue(resampler.resampleTo16k(samples: [0.1, 0.2], sourceSampleRate: rate).isEmpty)
            }
        }
    }

    func testCommonDeviceRatesPreserveDuration() {
        for rate in [8_000, 16_000, 24_000, 44_100, 48_000, 96_000, 192_000] {
            let samples = (0..<(rate / 10)).map { sinf(Float($0) * 0.02) * 0.3 }
            let resampler = AudioResampler(useHQ: false)
            let converted = resampler.resampleTo16k(samples: samples, sourceSampleRate: Double(rate))
            XCTAssertEqual(converted.count, 1_600, accuracy: 1)
            XCTAssertTrue(converted.allSatisfy(\.isFinite))
        }
    }
}
