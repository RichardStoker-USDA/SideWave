// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
@preconcurrency import AVFAudio
import FluidAudio
import Foundation

// MARK: - Audio tap helpers

/// Owns one recording's HAL, input redirect and disk writer. Setup and teardown
/// run away from the main actor because device negotiation can block.
final class MeetingCapture: @unchecked Sendable {
    private static let halQueue = DispatchQueue(label: "sidewave.meeting.hal", qos: .userInitiated)
    let engine: AVAudioEngine
    let writer: MeetingAudioWriter
    let diagnostics: MeetingAudioDiagnostics
    let sampleRate: Double
    private let originalDefault: AudioDeviceID
    private let redirectedTo: AudioDeviceID
    private let lock = NSLock()
    private var closed = false

    private init(engine: AVAudioEngine, writer: MeetingAudioWriter, diagnostics: MeetingAudioDiagnostics,
                 sampleRate: Double, originalDefault: AudioDeviceID, redirectedTo: AudioDeviceID) {
        self.engine = engine
        self.writer = writer
        self.diagnostics = diagnostics
        self.sampleRate = sampleRate
        self.originalDefault = originalDefault
        self.redirectedTo = redirectedTo
    }

    static func prepare(fileURL: URL, deviceUID: String?, levelStore: MeetingLevelStore,
                      liveContinuation: AsyncStream<MeetingAudioChunk>.Continuation?,
                      operation: AudioSetupOperation<MeetingCapture>) throws -> MeetingCapture {
        try halQueue.sync {
            guard !operation.isAbandoned else { throw CancellationError() }
            return try start(fileURL: fileURL, deviceUID: deviceUID, levelStore: levelStore,
                             liveContinuation: liveContinuation, operation: operation)
        }
    }

    private static func start(fileURL: URL, deviceUID: String?, levelStore: MeetingLevelStore,
                              liveContinuation: AsyncStream<MeetingAudioChunk>.Continuation?,
                              operation: AudioSetupOperation<MeetingCapture>) throws -> MeetingCapture {
        let engine = AVAudioEngine()
        let originalDefault = AudioDeviceManager.defaultInputDeviceID()
        let target = deviceUID.map(AudioDeviceManager.deviceIDForUID) ?? originalDefault
        guard target != 0 else { throw MeetingError.microphoneUnavailable }
        var redirectedTo: AudioDeviceID = 0
        var input: AVAudioInputNode?
        var tapInstalled = false
        var adopted = false
        var writer: MeetingAudioWriter?
        defer {
            if !adopted {
                if tapInstalled { input?.removeTap(onBus: 0) }
                engine.stop()
                writer?.close()
                restoreDefault(originalDefault, ifStill: redirectedTo)
            }
        }
        if target != originalDefault {
            AudioDeviceManager.setSystemDefaultInputDevice(target)
            if AudioDeviceManager.defaultInputDeviceID() == target { redirectedTo = target }
        }
        guard !operation.isAbandoned else { throw CancellationError() }
        let node = engine.inputNode
        input = node
        try AudioDeviceManager.bindInput(node, to: target)
        var format = node.inputFormat(forBus: 0)
        for _ in 0..<30 where format.sampleRate <= 0 || !format.sampleRate.isFinite || format.channelCount == 0 {
            guard !operation.isAbandoned else { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.1)
            format = node.inputFormat(forBus: 0)
        }
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingError.microphoneUnavailable
        }
        guard !operation.isAbandoned else { throw CancellationError() }
        guard let recordingFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            throw MeetingError.microphoneUnavailable
        }
        let file = try AVAudioFile(forWriting: fileURL, settings: recordingFormat.settings)
        let diskWriter = MeetingAudioWriter(file: file)
        writer = diskWriter
        let diagnostics = MeetingAudioDiagnostics(sampleRate: format.sampleRate)
        let resolvedUID = deviceUID ?? AudioDeviceManager.deviceUID(target)
        let selector = ChannelSelector(mode: AudioDeviceManager.channelMode(forUID: resolvedUID),
                                       channelCount: Int(format.channelCount), deviceUID: resolvedUID,
                                       cachedAutoChannel: AudioDeviceManager.autoDetectedChannel(forUID: resolvedUID))
        let capture = MeetingCapture(engine: engine, writer: diskWriter, diagnostics: diagnostics,
                                     sampleRate: format.sampleRate, originalDefault: originalDefault,
                                     redirectedTo: redirectedTo)
        let sampleRate = format.sampleRate
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak capture] buffer, _ in
            guard let capture, !capture.isClosed, !operation.isAbandoned else { return }
            let mono = selector.selectAndDownmix(buffer)
            guard !mono.isEmpty else { return }
            // Preserve the selected physical input for final ASR and recovery too.
            diskWriter.writeMono(mono)
            var meanSquare: Float = 0
            vDSP_measqv(mono, 1, &meanSquare, vDSP_Length(mono.count))
            let rms = Double(sqrtf(meanSquare))
            let safeRMS = rms.isFinite ? rms : 0
            levelStore.setLevel(min(safeRMS, 1))
            mono.withUnsafeBufferPointer { samples in
                if let base = samples.baseAddress {
                    diagnostics.ingest(samples: base, frameCount: samples.count, bufferRMS: safeRMS)
                }
            }
            liveContinuation?.yield(MeetingAudioChunk(samples: mono, sampleRate: sampleRate))
        }
        tapInstalled = true
        guard !operation.isAbandoned else { throw CancellationError() }
        engine.prepare()
        try engine.start()
        adopted = true
        return capture
    }

    private var isClosed: Bool { lock.withLock { closed } }

    func close(waitForHAL: Bool = false) {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        writer.close()
        let ownsRoute = AudioSetupActivity.begin()
        let closeHAL: @Sendable () -> Void = { [self] in
            defer { if ownsRoute { AudioSetupActivity.end() } }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            Self.restoreDefault(originalDefault, ifStill: redirectedTo)
        }
        if waitForHAL {
            Self.halQueue.sync(execute: closeHAL)
        } else {
            Self.halQueue.async(execute: closeHAL)
        }
    }

    private static func restoreDefault(_ original: AudioDeviceID, ifStill target: AudioDeviceID) {
        guard original != 0, target != 0, AudioDeviceManager.defaultInputDeviceID() == target else { return }
        AudioDeviceManager.setSystemDefaultInputDevice(original)
    }
}

/// Serializes writes to the recording file so the tap thread and the stop path can't race;
/// `AVAudioFile.write` isn't thread-safe. `close()` runs after every queued write, so no buffer is
/// lost at stop. Every access to `file` happens on the queue.
final class MeetingAudioWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sidewave.meeting.audiofile", qos: .userInitiated)
    private var file: AVAudioFile?

    private let failureLock = NSLock()
    private var _failedWrites = 0
    private var pendingWrites = 0
    private var acceptingWrites = true
    private var framesWritten: Int64 = 0
    private let sampleRate: Double
    private let fileURL: URL
    private let recordingFormat: AVAudioFormat

    init(file: AVAudioFile) {
        self.file = file
        sampleRate = file.processingFormat.sampleRate
        fileURL = file.url
        recordingFormat = file.processingFormat
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        enqueue { Self.copyBuffer(buffer) }
    }

    func writeMono(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        enqueue {
            guard recordingFormat.channelCount == 1,
                  samples.count <= Int(UInt32.max),
                  let buffer = AVAudioPCMBuffer(pcmFormat: recordingFormat,
                                               frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: source.count) }
            }
            return buffer
        }
    }

    private func enqueue(_ makeBuffer: () -> AVAudioPCMBuffer?) {
        // Enqueue under the admission lock so close cannot overtake an accepted buffer.
        failureLock.withLock {
            guard acceptingWrites else { return }
            guard pendingWrites < 64, let owned = makeBuffer() else {
                _failedWrites += 1
                return
            }
            pendingWrites += 1
            queue.async { [self] in
                defer { failureLock.withLock { pendingWrites -= 1 } }
                guard let file else { return }
                do {
                    try file.write(from: owned)
                    framesWritten += Int64(owned.frameLength)
                } catch { failureLock.withLock { _failedWrites += 1 } }
            }
        }
    }

    /// Flush completed writes to disk without ending the recording.
    func checkpoint() {
        queue.sync {
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.synchronize()
            } catch { failureLock.withLock { _failedWrites += 1 } }
        }
    }

    var recordedDuration: Double {
        queue.sync { sampleRate > 0 ? Double(framesWritten) / sampleRate : 0 }
    }

    static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else { return nil }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return copy
    }

    var failedWriteCount: Int {
        failureLock.lock()
        defer { failureLock.unlock() }
        return _failedWrites
    }

    func close() {
        failureLock.withLock { acceptingWrites = false }
        queue.sync {
            self.file?.close()
            self.file = nil
        }
        checkpoint()
    }
}

/// Audio health counters fed from the recording tap. After the meeting stops, `evaluate()` returns
/// fractions used for a non-blocking warning (quiet mic, clipping, mostly silent). A 100 ms window
/// above -42 dBFS counts as speech: enough for a mic check, not a VAD. Mutations take the lock; the
/// final `evaluate` runs after the writer queue has drained.
final class MeetingAudioDiagnostics: @unchecked Sendable {
    struct Report {
        let clippingFraction: Double
        let quietFraction: Double
        let speechActiveFraction: Double
    }

    private static let quietLinearThreshold: Double = 0.00794328234724281

    private let lock = NSLock()
    private let sampleRate: Double
    private let windowFrames: Int

    private var totalSamples: Int = 0
    private var clippedSamples: Int = 0
    private var quietSamples: Int = 0

    private var windowFilled: Int = 0
    private var windowSumSquares: Double = 0
    private var totalWindows: Int = 0
    private var speechActiveWindows: Int = 0

    init(sampleRate: Double) {
        self.sampleRate = max(sampleRate, 1)
        self.windowFrames = max(Int((sampleRate * 0.1).rounded()), 1)
    }

    func ingest(samples: UnsafePointer<Float>, frameCount: Int, bufferRMS: Double) {
        guard frameCount > 0 else { return }

        var absMax: Float = 0
        vDSP_maxmgv(samples, 1, &absMax, vDSP_Length(frameCount))

        var clipped: Int = 0
        if absMax >= 0.999 {
            for i in 0..<frameCount {
                let v = samples[i]
                if v >= 0.999 || v <= -0.999 { clipped += 1 }
            }
        }

        let isBufferQuiet = bufferRMS < Self.quietLinearThreshold

        lock.lock()
        totalSamples += frameCount
        clippedSamples += clipped
        if isBufferQuiet { quietSamples += frameCount }

        var i = 0
        while i < frameCount {
            let take = min(windowFrames - windowFilled, frameCount - i)
            var partial: Float = 0
            vDSP_measqv(samples.advanced(by: i), 1, &partial, vDSP_Length(take))
            windowSumSquares += Double(partial) * Double(take)
            windowFilled += take
            i += take
            if windowFilled >= windowFrames {
                let meanSquare = windowSumSquares / Double(windowFrames)
                let rms = meanSquare > 0 ? sqrt(meanSquare) : 0
                totalWindows += 1
                if rms > Self.quietLinearThreshold { speechActiveWindows += 1 }
                windowSumSquares = 0
                windowFilled = 0
            }
        }
        lock.unlock()
    }

    func evaluate() -> Report {
        lock.lock()
        defer { lock.unlock() }
        let clipping = totalSamples > 0 ? Double(clippedSamples) / Double(totalSamples) : 0
        let quiet = totalSamples > 0 ? Double(quietSamples) / Double(totalSamples) : 0
        let speech = totalWindows > 0 ? Double(speechActiveWindows) / Double(totalWindows) : 0
        return Report(clippingFraction: clipping, quietFraction: quiet, speechActiveFraction: speech)
    }
}

/// Thread-safe container for the current RMS audio level emitted by the tap.
/// The tap thread writes; the MainActor level-polling task reads at ~20Hz.
final class MeetingLevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: Double = 0

    func setLevel(_ newValue: Double) {
        lock.lock()
        _level = newValue
        lock.unlock()
    }

    var level: Double {
        lock.lock()
        defer { lock.unlock() }
        return _level
    }
}
