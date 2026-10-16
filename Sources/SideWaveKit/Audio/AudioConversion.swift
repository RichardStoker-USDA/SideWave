// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFoundation
import Accelerate
import Foundation

// From the original app's capture path, unchanged except that ChannelSelector reports its choice
// through a callback, so this package doesn't depend on UserDefaults. Both types run on the tap
// thread.

/// How the tap turns a multi-channel device buffer into the mono stream
/// the recognizer eats.
public enum InputChannelMode: Equatable, Sendable {
    /// Calibrate on first use per device: measure a short window, lock in
    /// the loudest channel, report it for caching.
    case auto
    /// Average all channels (historical downmix).
    case mix
    /// Extract one specific channel (1-based).
    case channel(Int)
}

/// Converts to the recognizer's 16 kHz.
/// - High quality (default) uses `AVAudioConverter`, which filters before downsampling so 88.2, 96,
///   and 192 kHz interfaces don't alias noise into the speech band.
/// - Linear interpolation is the fallback if the converter fails, so no buffer is lost.
/// One instance per session; the converter keeps filter state between callbacks.
final class AudioResampler: @unchecked Sendable {
    private let useHQ: Bool
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private static let targetRate: Double = 16_000

    // Cached formats and buffers for zero-allocation reuse on the tap.
    private var cachedInFormat: AVAudioFormat?
    private var cachedOutFormat: AVAudioFormat?
    private var cachedInBuffer: AVAudioPCMBuffer?
    private var cachedOutBuffer: AVAudioPCMBuffer?
    private var cachedSourceRate: Double = 0

    init(useHQ: Bool) {
        self.useHQ = useHQ
    }

    /// Resample a mono Float32 buffer to 16 kHz. Returns the input array
    /// unmodified when the source rate is already 16 kHz.
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
        }
        return Self.resampleLinear(samples: samples, sourceSampleRate: sourceSampleRate)
    }

    private func resampleHQ(samples: [Float], sourceSampleRate: Double) -> [Float]? {
        guard !samples.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if cachedSourceRate != sourceSampleRate || cachedInFormat == nil || cachedOutFormat == nil {
            guard
                let inFormat = AVAudioFormat(
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

            cachedInFormat = inFormat
            cachedOutFormat = outFormat
            cachedSourceRate = sourceSampleRate
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            cachedInBuffer = nil
            cachedOutBuffer = nil
        }

        guard let inFormat = cachedInFormat,
            let outFormat = cachedOutFormat,
            let conv = converter
        else { return nil }

        let neededInCapacity = AVAudioFrameCount(samples.count)
        if cachedInBuffer == nil || cachedInBuffer!.frameCapacity < neededInCapacity {
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: neededInCapacity)
            else { return nil }
            cachedInBuffer = inBuffer
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

        let neededOutCapacity =
            AVAudioFrameCount(ceil(Double(samples.count) * Self.targetRate / sourceSampleRate)) + 16
        if cachedOutBuffer == nil || cachedOutBuffer!.frameCapacity < neededOutCapacity {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: neededOutCapacity)
            else { return nil }
            cachedOutBuffer = outBuffer
        }
        guard let outBuffer = cachedOutBuffer else { return nil }
        outBuffer.frameLength = 0

        var error: NSError?
        final class InputProvidedBox: @unchecked Sendable {
            var value = false
        }
        let inputProvided = InputProvidedBox()
        let status = conv.convert(to: outBuffer, error: &error) { _, outStatus in
            if inputProvided.value {
                // `.noDataNow`, unlike `.endOfStream`, keeps the filter state for the next callback.
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

/// Picks the input channel on devices with more than one: measures briefly on first use, keeps the
/// loudest, and reports it through `onAutoCalibrated`. On a two-input interface with one mic,
/// mixing would halve the level (-6 dB). The tap runs serially on one thread, so no locks.
final class ChannelSelector: @unchecked Sendable {
    private let channelCount: Int
    private let deviceUID: String?
    private let onAutoCalibrated: (@Sendable (String?, Int) -> Void)?

    private var calibrationCallbacksRemaining: Int
    private var perChannelSumSquares: [Float]
    private var perChannelFrameCount: [Int]
    /// 1-based channel when extracting; 0 means downmix all.
    private var lockedInChannel: Int
    private var didFinalize = false

    /// ~700ms of audio at typical 4096-frame buffers and 48 kHz: enough
    /// for a meaningful per-channel RMS reading.
    private static let calibrationCallbacks = 8

    /// Below this (~-66 dBFS) the user wasn't speaking during calibration;
    /// fall back to channel 1 without caching so next session re-measures.
    private static let silenceFloor: Float = 0.0005

    init(
        mode: InputChannelMode,
        channelCount: Int,
        deviceUID: String?,
        cachedAutoChannel: Int?,
        onAutoCalibrated: (@Sendable (String?, Int) -> Void)? = nil
    ) {
        self.channelCount = max(1, channelCount)
        self.deviceUID = deviceUID
        self.onAutoCalibrated = onAutoCalibrated
        self.perChannelSumSquares = [Float](repeating: 0, count: self.channelCount)
        self.perChannelFrameCount = [Int](repeating: 0, count: self.channelCount)

        switch mode {
        case .channel(let n):
            lockedInChannel = max(1, min(n, self.channelCount))
            calibrationCallbacksRemaining = 0
            didFinalize = true
        case .mix:
            lockedInChannel = 0
            calibrationCallbacksRemaining = 0
            didFinalize = true
        case .auto:
            if self.channelCount == 1 {
                lockedInChannel = 1
                calibrationCallbacksRemaining = 0
                didFinalize = true
            } else if let cached = cachedAutoChannel, cached >= 1, cached <= self.channelCount {
                lockedInChannel = cached
                calibrationCallbacksRemaining = Self.calibrationCallbacks
                didFinalize = false
            } else {
                // The first non-silent buffer selects the draft channel.
                lockedInChannel = 1
                calibrationCallbacksRemaining = Self.calibrationCallbacks
                didFinalize = false
            }
        }
    }

    /// Extract mono samples at the device's native rate. Always returns
    /// data, never nil, so the caller has no drop-buffer path.
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

        guard bestRMS >= Self.silenceFloor else {
            lockedInChannel = 1
            return
        }

        lockedInChannel = bestChannel
        if let onAutoCalibrated {
            let uid = deviceUID
            let channel = bestChannel
            DispatchQueue.global(qos: .utility).async {
                onAutoCalibrated(uid, channel)
            }
        }
    }


}
