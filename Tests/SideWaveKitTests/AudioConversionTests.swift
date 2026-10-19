// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFoundation
import XCTest

@testable import SideWaveKit

/// Pins the carried capture math: channel selection (the Scarlett
/// silent-channel scenario) and 16 kHz resampling.
final class AudioConversionTests: XCTestCase {

    // MARK: Buffer builder

    private func makeBuffer(
        channels: [[Float]],
        sampleRate: Double = 48_000
    ) -> AVAudioPCMBuffer {
        let channelCount = AVAudioChannelCount(channels.count)
        let frames = AVAudioFrameCount(channels.first?.count ?? 0)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { source in
                buffer.floatChannelData![index].update(
                    from: source.baseAddress!, count: channel.count)
            }
        }
        return buffer
    }

    private func tone(_ amplitude: Float, count: Int = 4096) -> [Float] {
        (0..<count).map { amplitude * sinf(Float($0) * 0.05) }
    }

    // MARK: ChannelSelector

    func testAutoCalibrationPicksTheLoudChannel() {
        let cached = LockedBox<Int?>(nil)
        let selector = ChannelSelector(
            mode: .auto, channelCount: 2, deviceUID: "scarlett",
            cachedAutoChannel: nil,
            onAutoCalibrated: { _, channel in cached.set(channel) })

        // Mic on input 2, input 1 silent; the field scenario mirrored.
        let quiet = tone(0.0001)
        let loud = tone(0.4)
        for _ in 0..<8 {
            _ = selector.selectAndDownmix(makeBuffer(channels: [quiet, loud]))
        }

        // Post-calibration output must be the loud channel's data.
        let after = selector.selectAndDownmix(makeBuffer(channels: [quiet, loud]))
        XCTAssertEqual(after.count, 4096)
        let peak = after.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.3, "selector must extract the loud channel, not a diluted mix")

        let deadline = Date().addingTimeInterval(2)
        while cached.get() == nil && Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(cached.get(), 2, "calibration must report channel 2 for caching")
    }

    func testAutoCalibrationOnSilenceDoesNotCache() {
        let cached = LockedBox<Int?>(nil)
        let selector = ChannelSelector(
            mode: .auto, channelCount: 2, deviceUID: "dev",
            cachedAutoChannel: nil,
            onAutoCalibrated: { _, channel in cached.set(channel) })

        let silent = [Float](repeating: 0.0001, count: 4096)
        for _ in 0..<9 {
            _ = selector.selectAndDownmix(makeBuffer(channels: [silent, silent]))
        }
        usleep(50_000)
        XCTAssertNil(cached.get(), "an all-silent calibration must not persist a choice")
    }

    func testCachedChannelSkipsCalibration() {
        let selector = ChannelSelector(
            mode: .auto, channelCount: 2, deviceUID: "dev",
            cachedAutoChannel: 2, onAutoCalibrated: nil)
        let quiet = tone(0.0001)
        let loud = tone(0.4)
        // First buffer already extracts the cached channel.
        let first = selector.selectAndDownmix(makeBuffer(channels: [quiet, loud]))
        let peak = first.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.3)
    }

    func testMixModeAveragesChannels() {
        let selector = ChannelSelector(
            mode: .mix, channelCount: 2, deviceUID: nil,
            cachedAutoChannel: nil, onAutoCalibrated: nil)
        let ones = [Float](repeating: 1.0, count: 128)
        let zeros = [Float](repeating: 0.0, count: 128)
        let mixed = selector.selectAndDownmix(makeBuffer(channels: [ones, zeros]))
        XCTAssertEqual(mixed.count, 128)
        XCTAssertEqual(mixed.first ?? 0, 0.5, accuracy: 0.001)
    }

    func testExplicitChannelClampsToAvailable() {
        let selector = ChannelSelector(
            mode: .channel(7), channelCount: 2, deviceUID: nil,
            cachedAutoChannel: nil, onAutoCalibrated: nil)
        let a = [Float](repeating: 0.1, count: 64)
        let b = [Float](repeating: 0.9, count: 64)
        let out = selector.selectAndDownmix(makeBuffer(channels: [a, b]))
        XCTAssertEqual(out.first ?? 0, 0.9, accuracy: 0.001, "channel 7 of 2 must clamp to the last real channel")
    }

    func testMonoDeviceNeedsNoCalibration() {
        let selector = ChannelSelector(
            mode: .auto, channelCount: 1, deviceUID: nil,
            cachedAutoChannel: nil, onAutoCalibrated: nil)
        let samples = tone(0.5, count: 512)
        let out = selector.selectAndDownmix(makeBuffer(channels: [samples]))
        XCTAssertEqual(out, samples)
    }

    // MARK: AudioResampler

    func testResamplerPassesThrough16k() {
        let resampler = AudioResampler(useHQ: true)
        let samples = tone(0.3, count: 1600)
        let out = resampler.resampleTo16k(samples: samples, sourceSampleRate: 16_000)
        XCTAssertEqual(out, samples)
    }

    func testResamplerDownsamples48kToRoughlyAThird() {
        let resampler = AudioResampler(useHQ: true)
        let samples = tone(0.3, count: 4800)
        // The sinc kernel holds back priming samples on the first call
        // (phase continuity returns them on later calls), so the first
        // buffer runs short of the ideal 1600.
        let first = resampler.resampleTo16k(samples: samples, sourceSampleRate: 48_000)
        XCTAssertGreaterThan(first.count, 1200)
        XCTAssertLessThan(first.count, 1700)
        XCTAssertGreaterThan(first.map(abs).max() ?? 0, 0.1, "signal must survive the resample")

        // Steady state: later calls return the full ratio's worth; the
        // constant kernel latency (~220 samples) never grows.
        let second = resampler.resampleTo16k(samples: samples, sourceSampleRate: 48_000)
        XCTAssertGreaterThanOrEqual(second.count, 1600)
        let cumulative = first.count + second.count
        XCTAssertGreaterThan(cumulative, 2900)
        XCTAssertLessThanOrEqual(cumulative, 3300)
    }

    func testLinearFallbackAlsoDownsamples() {
        let resampler = AudioResampler(useHQ: false)
        let samples = tone(0.3, count: 4800)
        let out = resampler.resampleTo16k(samples: samples, sourceSampleRate: 48_000)
        XCTAssertEqual(out.count, 1600)
    }

    func testResamplerSurvivesRateChangeMidSession() {
        let resampler = AudioResampler(useHQ: true)
        _ = resampler.resampleTo16k(samples: tone(0.3, count: 4800), sourceSampleRate: 48_000)
        let out = resampler.resampleTo16k(samples: tone(0.3, count: 4410), sourceSampleRate: 44_100)
        XCTAssertGreaterThan(out.count, 1400)
        XCTAssertLessThan(out.count, 1700)
    }

    // MARK: Device resolution (tolerant of hardware differences)

    func testResolveFallsBackWhenPreferredMissing() throws {
        guard !AudioDevices.listInputDevices().isEmpty else {
            throw XCTSkip("no input devices on this machine")
        }
        let (info, usedFallback) = AudioDevices.resolveForCapture(
            preferredUID: "definitely-not-a-real-device-uid")
        XCTAssertNotNil(info, "a live default must resolve when the preferred device is gone")
        XCTAssertTrue(usedFallback)
        XCTAssertFalse(info?.name.isEmpty ?? true, "fallback must carry a human name for the toast")
    }

    func testResolveHonorsPresentPreferredDevice() throws {
        let devices = AudioDevices.listInputDevices()
        guard let first = devices.first else {
            throw XCTSkip("no input devices on this machine")
        }
        let (info, usedFallback) = AudioDevices.resolveForCapture(preferredUID: first.uid)
        XCTAssertEqual(info?.uid, first.uid)
        XCTAssertFalse(usedFallback)
    }
}

/// Tiny thread-safe box for cross-thread test assertions.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ new: T) {
        lock.lock()
        value = new
        lock.unlock()
    }
}
