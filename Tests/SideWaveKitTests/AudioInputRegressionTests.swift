// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import XCTest
@testable import SideWaveKit

final class AudioInputRegressionTests: XCTestCase {
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
