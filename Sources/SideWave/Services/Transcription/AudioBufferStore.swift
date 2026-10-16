// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
import AppKit
@preconcurrency import AVFAudio
import CoreAudio
import FluidAudio
import Foundation
import os

// Sendable container for audio buffers shared between MainActor and audio tap callback.
// Uses NSLock (not Mutex) because Mutex let-properties can't be captured across
// actor isolation boundaries in Swift 5 language mode.
final class AudioBufferStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [Float] = []
    private var _audioLevel: Double = 0
    private var _audioPeak: Double = 0
    private var _lastBufferTime: Double = 0
    // Cap at ~10 minutes of 16kHz audio to prevent unbounded growth in long sessions
    private let maxSamples = 16_000 * 60 * 10

    // MARK: - Adaptive speech-energy tracking (EOU ghost-word gate)

    /// Upper bound for the silence floor (-45 dBFS, the input meter's `.silent` level). Once the
    /// background level is known, the effective floor adapts down to it: a quiet mic chain can
    /// carry real speech at 0.002 to 0.005 RMS, below this fixed value.
    static let silenceFloorRMS: Double = 0.0056
    /// Hard lower bound on the adaptive floor (-58 dBFS): true digital silence
    /// stays classified as silence no matter how low the background drifts, so
    /// hallucination protection is never fully disarmed.
    private static let minFloorRMS: Double = 0.0012
    /// Adaptive floor = background * this margin (clamped to [minFloorRMS,
    /// silenceFloorRMS]). Slightly above speechMargin so the floor never
    /// undercuts the margin-based threshold on quiet chains.
    private static let floorMarginOverBackground: Double = 3.0
    /// Speech must exceed the adaptive background estimate by this factor. Keeps
    /// steady room tone (fan, HVAC, mains hum) from reading as speech without
    /// clipping genuinely quiet talkers, who sit well above the background.
    private static let speechMargin: Double = 2.2
    /// Cap on the adaptive background estimate so a long stretch of continuous
    /// speech can't slowly pull the "background" up into the talker's own level
    /// and start gating real words.
    private static let backgroundCeilingRMS: Double = 0.02
    /// Buffers (~85ms each) before the background estimate is trusted enough
    /// to adapt the floor below the fixed cap. ~1s of audio.
    private static let establishedBufferCount = 12

    private var _backgroundRMS: Double = 0.001
    private var _lastSpeechAt: Double = 0
    private var _levelBufferCount = 0
    /// Set when the ghost gate's text-growth release fired: the chain proved
    /// quieter than the fixed floor, so keep the floor pinned to the adaptive
    /// path for the session remainder.
    private var _quietChainMode = false

    /// Records a buffer's RMS/peak AND advances the adaptive speech detector.
    /// Called from the audio-tap thread. `now` is a monotonic-enough wall clock
    /// (timeIntervalSince1970); the gate only compares deltas so drift is moot.
    func noteAudioLevel(_ rms: Double, peak: Double, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        _audioLevel = min(rms, 1.0)
        _audioPeak = peak
        _levelBufferCount += 1
        // Background estimate tracks quiet fast (drops toward true silence) and
        // rises slowly, clamped, so it represents room tone, not speech.
        if rms < _backgroundRMS {
            _backgroundRMS = _backgroundRMS * 0.90 + rms * 0.10
        } else {
            _backgroundRMS = min(Self.backgroundCeilingRMS, _backgroundRMS * 0.997 + rms * 0.003)
        }
        // Once background is established, scale the floor to the measured ambient level. After the
        // text-growth release fires, the session stays on the adaptive floor.
        let established = _levelBufferCount >= Self.establishedBufferCount
        let effectiveFloor: Double
        if established || _quietChainMode {
            effectiveFloor = min(Self.silenceFloorRMS,
                                 max(Self.minFloorRMS, _backgroundRMS * Self.floorMarginOverBackground))
        } else {
            effectiveFloor = Self.silenceFloorRMS
        }
        let speechThreshold = max(effectiveFloor, _backgroundRMS * Self.speechMargin)
        if rms > speechThreshold { _lastSpeechAt = now }
    }

    /// Time of the latest buffer classified as speech. The EOU ghost gate holds the gray tail while
    /// `now - lastSpeechAt` exceeds its hangover window, so tokens produced during silence never reach
    /// the preview or the paste.
    var lastSpeechAt: Double { lock.lock(); defer { lock.unlock() }; return _lastSpeechAt }

    /// The ghost gate's text-growth release proved the chain is quieter than
    /// the fixed floor: commit to the adaptive floor and treat this instant as
    /// speech so the gate opens immediately.
    func relaxFloorForQuietChain(at now: Double) {
        lock.lock(); defer { lock.unlock() }
        _quietChainMode = true
        _lastSpeechAt = now
    }

    /// Clears the detector between sessions. `_lastSpeechAt` starts at now, not zero, so the
    /// hangover window acts as a trust period for the first words.
    func resetSpeechDetector() {
        lock.lock(); defer { lock.unlock() }
        _backgroundRMS = 0.001
        _lastSpeechAt = Date().timeIntervalSince1970
        _levelBufferCount = 0
        _quietChainMode = false
    }

    func appendSamples(_ new: [Float]) {
        lock.lock()
        _samples.append(contentsOf: new)
        if _samples.count > maxSamples {
            // Use replaceSubrange + suffix instead of removeFirst to avoid O(n) shift.
            // Array.suffix returns a slice sharing the same backing storage, then
            // Array.init copies only the kept portion into a new contiguous buffer.
            let keep = maxSamples
            _samples = Array(_samples.suffix(keep))
        }
        lock.unlock()
    }
    func clearSamples() { lock.lock(); _samples.removeAll(); lock.unlock() }
    func clearSamplesKeepCapacity() { lock.lock(); _samples.removeAll(keepingCapacity: true); lock.unlock() }
    func reserveSamples(_ n: Int) { lock.lock(); _samples.reserveCapacity(n); lock.unlock() }
    func sampleCount() -> Int { lock.lock(); defer { lock.unlock() }; return _samples.count }
    func allSamples() -> [Float] { lock.lock(); defer { lock.unlock() }; return _samples }
    func sampleRange(from offset: Int, count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let start = max(0, min(offset, _samples.count))
        let end = min(start + count, _samples.count)
        return Array(_samples[start..<end])
    }
    @discardableResult
    func dropFirstSamples(_ n: Int) -> Int { lock.lock(); let c = min(n, _samples.count); _samples.removeFirst(c); lock.unlock(); return c }

    var audioLevel: Double {
        get { lock.lock(); defer { lock.unlock() }; return _audioLevel }
        set { lock.lock(); _audioLevel = newValue; lock.unlock() }
    }
    /// Largest sample magnitude in the latest buffer (linear, 0...1+). The level meter uses it to
    /// detect clipping independently of RMS.
    var audioPeak: Double {
        get { lock.lock(); defer { lock.unlock() }; return _audioPeak }
        set { lock.lock(); _audioPeak = newValue; lock.unlock() }
    }
    var lastBufferTime: Double {
        get { lock.lock(); defer { lock.unlock() }; return _lastBufferTime }
        set { lock.lock(); _lastBufferTime = newValue; lock.unlock() }
    }
}

/// Lock-protected FIFO from the audio tap thread to the EOU feeder task. A task per buffer would
/// race the actor's executor and reorder audio.
final class StreamingAudioQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<AVAudioPCMBuffer?, Never>?
    private var finished = false
    /// ~85s of 16k mono audio. Backstop against a wedged feeder leaking memory;
    /// in practice the feeder drains within ~70ms of arrival so depth stays at 0-1.
    private static let maxBuffered = 1024

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: buffer)
            return
        }
        if buffers.count >= Self.maxBuffered {
            buffers.removeFirst(buffers.count - Self.maxBuffered + 1)
        }
        buffers.append(buffer)
        lock.unlock()
    }

    func dequeue() async -> AVAudioPCMBuffer? {
        // Cancelling the feeder resumes the continuation with nil, so teardown doesn't depend on a
        // matching finish() call. The lock makes sure exactly one resume happens even when
        // cancellation races enqueue() or finish().
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<AVAudioPCMBuffer?, Never>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(returning: nil)
                    return
                }
                if !buffers.isEmpty {
                    let next = buffers.removeFirst()
                    lock.unlock()
                    cont.resume(returning: next)
                    return
                }
                if finished {
                    lock.unlock()
                    cont.resume(returning: nil)
                    return
                }
                continuation = cont
                if Task.isCancelled {
                    continuation = nil
                    lock.unlock()
                    cont.resume(returning: nil)
                    return
                }
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: nil)
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: nil)
    }
}

/// Thread-safe increasing counter. Stamps EOU partials in delivery order so the main actor can drop
/// any that arrive out of order.
final class MonotonicSeq: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    /// Returns a value strictly greater than every prior `next()`.
    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }

    /// Current value without advancing. Taken at session start so stragglers from the previous
    /// session fall below it and are dropped.
    func peek() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Setup owns this resource until it is adopted or closed after cancellation.
final class PreparedDictationInput: @unchecked Sendable {
    let engine: AVAudioEngine
    var tappedInput: AVAudioInputNode?
    var originalDefault: AudioDeviceID = 0
    var redirectedTo: AudioDeviceID = 0
    var channelSelector: ChannelSelector?
    var resampler: AudioResampler?
    private let closeLock = NSLock()
    private var closed = false

    init(engine: AVAudioEngine) { self.engine = engine }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        tappedInput?.removeTap(onBus: 0)
        engine.stop()
        if originalDefault != 0, redirectedTo != 0,
           AudioDeviceManager.defaultInputDeviceID() == redirectedTo {
            AudioDeviceManager.setSystemDefaultInputDevice(originalDefault)
        }
    }
}
