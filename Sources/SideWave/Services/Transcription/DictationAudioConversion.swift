// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
import AppKit
@preconcurrency import AVFAudio
import CoreAudio
import FluidAudio
import Foundation
import os

/// Resamples mono Float32 audio from the device rate to 16 kHz.
///
/// - High quality (default) uses `AVAudioConverter`, which filters before downsampling so 88.2,
///   96, and 192 kHz interfaces don't alias noise into the speech band.
/// - Linear interpolation is the fallback when the converter can't be built, and the setting's
///   Off state.
///
/// One instance per session. The converter keeps its filter state between tap callbacks so phase
/// stays continuous; a new session gets a new converter.
final class AudioResampler: @unchecked Sendable {
    private let useHQ: Bool
    private var converter: AVAudioConverter?
    private var converterInputRate: Double = 0
    private let lock = NSLock()
    private static let targetRate: Double = 16_000

    // Cached formats and buffers for zero-allocation reuse in the real-time path
    private var cachedInFormat: AVAudioFormat?
    private var cachedOutFormat: AVAudioFormat?
    private var cachedInBuffer: AVAudioPCMBuffer?
    private var cachedOutBuffer: AVAudioPCMBuffer?
    private var cachedSourceRate: Double = 0

    init(useHQ: Bool) {
        self.useHQ = useHQ
    }

    /// Returns 16 kHz audio, or the input unchanged when it is already 16 kHz. Falls back to linear
    /// interpolation if the converter fails, so the caller never loses a buffer.
    func resampleTo16k(samples: [Float], sourceSampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceSampleRate.isFinite, sourceSampleRate > 0 else { return [] }
        let outputFrames = ceil(Double(samples.count) * Self.targetRate / sourceSampleRate)
        guard outputFrames.isFinite, outputFrames <= Double(UInt32.max - 16),
              samples.count <= Int(UInt32.max) else { return [] }
        if sourceSampleRate == Self.targetRate { return samples }
        if useHQ {
            if let hq = resampleHQ(samples: samples, sourceSampleRate: sourceSampleRate) {
                return hq
            }
            // HQ path failed (rare; bad format, allocation failure).
            // Quiet fall-through to linear so the session still works.
        }
        return Self.resampleLinear(samples: samples, sourceSampleRate: sourceSampleRate)
    }

    private func resampleHQ(samples: [Float], sourceSampleRate: Double) -> [Float]? {
        guard !samples.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        // 1. Resolve / cache formats and converter
        if cachedSourceRate != sourceSampleRate || cachedInFormat == nil || cachedOutFormat == nil {
            guard let inFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false),
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetRate,
                channels: 1,
                interleaved: false)
            else { return nil }

            self.cachedInFormat = inFormat
            self.cachedOutFormat = outFormat
            self.cachedSourceRate = sourceSampleRate
            
            // Re-create converter when rate changes
            self.converter = AVAudioConverter(from: inFormat, to: outFormat)
            self.converterInputRate = sourceSampleRate
            self.cachedInBuffer = nil
            self.cachedOutBuffer = nil
        }

        guard let inFormat = cachedInFormat,
              let outFormat = cachedOutFormat,
              let conv = converter
        else { return nil }

        // 2. Resolve / cache input buffer
        let neededInCapacity = AVAudioFrameCount(samples.count)
        if cachedInBuffer == nil || cachedInBuffer!.frameCapacity < neededInCapacity {
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: neededInCapacity) else {
                return nil
            }
            self.cachedInBuffer = inBuffer
        }
        guard let inBuffer = cachedInBuffer else { return nil }
        inBuffer.frameLength = neededInCapacity

        if let inPtr = inBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    inPtr.update(from: base, count: samples.count)
                }
            }
        }

        // 3. Resolve / cache output buffer
        let neededOutCapacity = AVAudioFrameCount(
            ceil(Double(samples.count) * Self.targetRate / sourceSampleRate)
        ) + 16
        if cachedOutBuffer == nil || cachedOutBuffer!.frameCapacity < neededOutCapacity {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: neededOutCapacity) else {
                return nil
            }
            self.cachedOutBuffer = outBuffer
        }
        guard let outBuffer = cachedOutBuffer else { return nil }
        outBuffer.frameLength = 0 // Clean downstream writes

        var error: NSError?
        final class InputProvidedBox: @unchecked Sendable {
            var value = false
        }
        let inputProvided = InputProvidedBox()
        let status = conv.convert(to: outBuffer, error: &error) { _, outStatus in
            if inputProvided.value {
                // No more input for this call. `.noDataNow`, unlike `.endOfStream`, keeps the
                // filter state for the next callback.
                outStatus.pointee = .noDataNow
                return nil
            }
            inputProvided.value = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        if status == .error || error != nil {
            return nil
        }

        guard let outPtr = outBuffer.floatChannelData?[0] else { return nil }
        let outCount = Int(outBuffer.frameLength)
        guard outCount > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: outPtr, count: outCount))
    }

    private static func resampleLinear(samples: [Float], sourceSampleRate: Double) -> [Float] {
        let ratio = targetRate / sourceSampleRate
        let outCount = Int(Double(samples.count) * ratio)
        guard outCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            if idx + 1 < samples.count {
                output[i] = samples[idx] + (samples[idx + 1] - samples[idx]) * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }
}

/// Picks the input channel that feeds the recognizer on multi-channel devices. On first use per
/// device it measures each channel briefly, keeps the loudest, and saves the choice through
/// AudioDeviceManager.
///
/// On a two-input interface with one mic connected, averaging both channels mixes in the silent
/// input and halves the level (-6 dB); selecting one channel keeps it.
///
/// The tap callback runs serially on one CoreAudio thread, so state isn't locked.
final class ChannelSelector: @unchecked Sendable {
    private let channelCount: Int
    private let deviceUID: String?
    private let onAutoCalibrated: (@Sendable (String?, Int) -> Void)?

    // Calibration state; only mutated by the audio tap thread.
    private var calibrationCallbacksRemaining: Int
    private var perChannelSumSquares: [Float]
    private var perChannelFrameCount: [Int]
    /// Resolved channel choice. 1-based index when extracting a single
    /// channel; 0 means "downmix all channels" (legacy mix mode).
    private var lockedInChannel: Int
    /// Read on the tap thread after selecting a buffer. Nil represents the all-channel mix.
    var selectedChannel: Int? { lockedInChannel == 0 ? nil : lockedInChannel }
    private var didFinalize: Bool = false

    /// Callbacks used to measure channels: about 700 ms at 4096 frames and 48 kHz. If every channel
    /// stays below the silence floor, channel 1 is used without saving, so the next session
    /// measures again.
    private static let calibrationCallbacks = 8

    /// About -66 dBFS. Below this on every channel, nobody was speaking and nothing is saved.
    private static let silenceFloor: Float = 0.0005

    init(
        mode: ChannelMode,
        channelCount: Int,
        deviceUID: String?,
        cachedAutoChannel: Int?,
        onAutoCalibrated: (@Sendable (String?, Int) -> Void)? = { uid, channel in
            AudioDeviceManager.setAutoDetectedChannel(channel, forUID: uid)
        }
    ) {
        self.channelCount = max(1, channelCount)
        self.deviceUID = deviceUID
        self.onAutoCalibrated = onAutoCalibrated
        self.perChannelSumSquares = [Float](repeating: 0, count: self.channelCount)
        self.perChannelFrameCount = [Int](repeating: 0, count: self.channelCount)

        switch mode {
        case .channel(let n):
            self.lockedInChannel = max(1, min(n, self.channelCount))
            self.calibrationCallbacksRemaining = 0
            self.didFinalize = true
        case .mix:
            self.lockedInChannel = 0  // 0 = downmix all
            self.calibrationCallbacksRemaining = 0
            self.didFinalize = true
        case .auto:
            if self.channelCount == 1 {
                self.lockedInChannel = 1
                self.calibrationCallbacksRemaining = 0
                self.didFinalize = true
            } else if let cached = cachedAutoChannel,
                      cached >= 1, cached <= self.channelCount {
                self.lockedInChannel = cached
                self.calibrationCallbacksRemaining = Self.calibrationCallbacks
                self.didFinalize = false
            } else {
                // The first non-silent buffer selects the draft channel.
                self.lockedInChannel = 1
                self.calibrationCallbacksRemaining = Self.calibrationCallbacks
                self.didFinalize = false
            }
        }
    }

    /// Extract mono samples at the device's native rate. Always returns
    /// data (never nil) so the caller doesn't need a drop-buffer path.
    /// Updates calibration state if calibration is still in progress.
    func selectAndDownmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }
        let bufferChannels = Int(buffer.format.channelCount)
        let effectiveChannels = min(bufferChannels, channelCount)
        guard effectiveChannels > 0 else { return [] }
        let stride = buffer.format.isInterleaved ? bufferChannels : 1
        func channel(_ index: Int) -> UnsafeMutablePointer<Float> {
            buffer.format.isInterleaved ? channelData[0].advanced(by: index) : channelData[index]
        }

        if !didFinalize, calibrationCallbacksRemaining > 0 {
            var energies = [Float](repeating: 0, count: effectiveChannels)
            for c in 0..<effectiveChannels {
                vDSP_measqv(channel(c), vDSP_Stride(stride), &energies[c], vDSP_Length(frameCount))
            }
            if let strongest = energies.indices.max(by: { energies[$0] < energies[$1] }),
               energies[strongest] >= Self.silenceFloor * Self.silenceFloor {
                // Use the active channel immediately, including the first word.
                // Silence does not spend the calibration window.
                lockedInChannel = strongest + 1
                for c in 0..<effectiveChannels {
                    perChannelSumSquares[c] += energies[c] * Float(frameCount)
                    perChannelFrameCount[c] += frameCount
                }
                calibrationCallbacksRemaining -= 1
                if calibrationCallbacksRemaining == 0 { finalizeCalibration() }
            }
        }

        if lockedInChannel == 0 {
            var mixed = [Float](repeating: 0, count: frameCount)
            for c in 0..<effectiveChannels {
                vDSP_vadd(channel(c), vDSP_Stride(stride), mixed, 1, &mixed, 1, vDSP_Length(frameCount))
            }
            var divisor = Float(effectiveChannels)
            vDSP_vsdiv(mixed, 1, &divisor, &mixed, 1, vDSP_Length(frameCount))
            return mixed
        }

        let index = max(0, min(lockedInChannel - 1, effectiveChannels - 1))
        let selected = channel(index)
        if stride == 1 { return Array(UnsafeBufferPointer(start: selected, count: frameCount)) }
        return (0..<frameCount).map { selected[$0 * stride] }
    }

    private func finalizeCalibration() {
        var bestChannel = 1
        var bestRMS: Float = 0
        for c in 0..<channelCount {
            let frames = perChannelFrameCount[c]
            guard frames > 0 else { continue }
            let meanSquare = perChannelSumSquares[c] / Float(frames)
            let rms = sqrtf(meanSquare)
            if rms > bestRMS {
                bestRMS = rms
                bestChannel = c + 1
            }
        }

        didFinalize = true

        let capturedUID = deviceUID
        let finalBestChannel = bestChannel
        let finalBestRMS = bestRMS

        if finalBestRMS < Self.silenceFloor {
            // All channels essentially silent during calibration. Don't
            // persist; let the next recording re-run calibration when
            // the user is actually speaking.
            lockedInChannel = 1
            DispatchQueue.global(qos: .utility).async {
                SWLog.note("[ChannelSelector] Calibration found only silence (best RMS=\(finalBestRMS)); using channel 1 without caching")
            }
            return
        }

        lockedInChannel = finalBestChannel
        if let onAutoCalibrated {
            DispatchQueue.global(qos: .utility).async {
                onAutoCalibrated(capturedUID, finalBestChannel)
            }
        }
    }


}
