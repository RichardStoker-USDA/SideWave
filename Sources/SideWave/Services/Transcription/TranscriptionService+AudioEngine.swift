// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
import AppKit
@preconcurrency import AVFAudio
import CoreAudio
import FluidAudio
import Foundation
import os

@MainActor
extension TranscriptionService {
    // MARK: - Audio Engine

    func setupAudioEngine(deviceUID: String? = nil) async throws {
        try Task.checkCancellation()
        let engineSetupBegan = CFAbsoluteTimeGetCurrent()
        dictationTraceLog.notice("engine setup begin")
        let engineRef = engine
        // A timed-out caller must not tear down an engine still owned by HAL setup.
        engineStorage = nil
        let capturedDeviceUID = deviceUID
        let setupGeneration = sessionGeneration
        let bufs = audioBuffers
        let tapQueue = streamingAudioQueue
        let audioCapture = sessionAudioCapture
        let prepared = try await AudioSetupOperation<PreparedDictationInput>.run(timeout: 8) { operation in
            let prepared = PreparedDictationInput(engine: engineRef)
            var completed = false
            defer { if !completed { prepared.close() } }
            // 1. Resolve target device, save original default for later restore.
            let originalDefault = AudioDeviceManager.defaultInputDeviceID()
            var targetDeviceID: AudioDeviceID = 0

            if let uid = capturedDeviceUID {
                targetDeviceID = AudioDeviceManager.deviceIDForUID(uid)
                if targetDeviceID == 0 {
                    throw NSError(domain: "SideWave.AudioInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected microphone is disconnected. Choose another input in SideWave, then try again."])
                } else if targetDeviceID != originalDefault {
                    // Redirect system default to the target so the AUHAL
                    // initializes against the right device.
                    var defaultAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioHardwarePropertyDefaultInputDevice,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var targetID = targetDeviceID
                    let status = AudioObjectSetPropertyData(
                        AudioObjectID(kAudioObjectSystemObject),
                        &defaultAddr, 0, nil,
                        UInt32(MemoryLayout<AudioDeviceID>.size),
                        &targetID
                    )
                    if status != noErr {
                        print("[TranscriptionService] System default input redirect failed (\(status))")
                    } else {
                        prepared.originalDefault = originalDefault
                        prepared.redirectedTo = targetDeviceID
                    }
                }
            }

            // Bind the input unit to the target device. `inputNode` binds to the system default on
            // first access, so uninitialize the unit, set its device, and initialize it again.
            // Without an explicit target, a reused engine is moved back to the current default; a
            // new engine already uses it.
            let input = engineRef.inputNode
            let desiredDeviceID = targetDeviceID != 0 ? targetDeviceID : originalDefault
            try AudioDeviceManager.bindInput(input, to: desiredDeviceID)

            // Read the input format, retrying while the unit settles (a Bluetooth headset switching
            // profiles, or a USB interface reinitializing after sleep): 1.2 s normally, 3 s when
            // the target itself is Bluetooth, where profile negotiation takes longer.
            var inFormat = input.inputFormat(forBus: 0)
            var retryCount = 0
            let isBluetoothTarget = AudioDeviceManager.isBluetoothInput(desiredDeviceID)
            let maxRetries = isBluetoothTarget ? 30 : 12
            while !inFormat.sampleRate.isFinite || inFormat.sampleRate <= 0 || inFormat.channelCount == 0 {
                retryCount += 1
                if retryCount > maxRetries {
                    throw NSError(
                        domain: "TranscriptionService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio input format invalid after \(maxRetries) retries. Microphone may still be initializing."]
                    )
                }
                print("[TranscriptionService] Input format not ready (attempt \(retryCount)/\(maxRetries)), waiting 100ms")
                Thread.sleep(forTimeInterval: 0.1)
                inFormat = input.inputFormat(forBus: 0)
            }
            if retryCount > 0 {
                print("[TranscriptionService] Input format ready after \(retryCount) retries: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch")
            }

            // Build the channel selector from the device's saved channel mode. It either takes one
            // channel, so a silent second input doesn't halve the level, or mixes all channels.
            let resolvedChannelUID = AudioDeviceManager.deviceUID(desiredDeviceID)
            let channelMode = AudioDeviceManager.channelMode(forUID: resolvedChannelUID)
            let cachedAutoChannel = AudioDeviceManager.autoDetectedChannel(forUID: resolvedChannelUID)
            let selector = ChannelSelector(
                mode: channelMode,
                channelCount: Int(inFormat.channelCount),
                deviceUID: resolvedChannelUID,
                cachedAutoChannel: cachedAutoChannel
            )
            prepared.channelSelector = selector

            // Build the resampler. Default high-quality on; user
            // can flip via Settings > Microphone > Audio conversion if a
            // device misbehaves with AVAudioConverter.
            let useHQ = UserDefaults.standard.object(forKey: "useHighQualityResampling") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "useHighQualityResampling")
            let sessionResampler = AudioResampler(useHQ: useHQ)
            prepared.resampler = sessionResampler

            guard !operation.isAbandoned else { throw CancellationError() }

            // 5. Install tap and start the engine.
            let sourceSampleRate = inFormat.sampleRate
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
                guard !operation.isAbandoned else { return }
                bufs.lastBufferTime = Date().timeIntervalSince1970
                let mono16k = Self.convertToMono16k(
                    buffer: buffer,
                    sourceSampleRate: sourceSampleRate,
                    selector: selector,
                    resampler: sessionResampler
                )
                if !mono16k.isEmpty {
                    bufs.appendSamples(mono16k)
                    audioCapture?.append(mono16k)
                    var meanSquare: Float = 0
                    vDSP_measqv(mono16k, 1, &meanSquare, vDSP_Length(mono16k.count))
                    let rms = Double(sqrtf(meanSquare))
                    // Track the loudest single sample in this buffer for
                    // peak / clipping detection. abs is fine; vDSP_maxmgv
                    // ignores sign.
                    var peak: Float = 0
                    vDSP_maxmgv(mono16k, 1, &peak, vDSP_Length(mono16k.count))
                    // Records level + peak AND advances the adaptive
                    // speech detector that gates EOU ghost words.
                    bufs.noteAudioLevel(rms, peak: Double(peak), at: Date().timeIntervalSince1970)

                    if let q = tapQueue,
                       let pcm = Self.makePCMBuffer16k(samples: mono16k) {
                        q.enqueue(pcm)
                    }
                }
            }
            prepared.tappedInput = input
            engineRef.prepare()
            try engineRef.start()
            guard !operation.isAbandoned else { throw CancellationError() }
            completed = true
            return prepared
        } dispose: { $0.close() }
        guard !Task.isCancelled, sessionGeneration == setupGeneration else {
            let ownsRoute = AudioSetupActivity.begin()
            DispatchQueue.global(qos: .userInitiated).async {
                prepared.close()
                if ownsRoute { AudioSetupActivity.end() }
            }
            throw CancellationError()
        }
        engineStorage = prepared.engine
        redirectedSystemDefaultFromID = prepared.originalDefault
        redirectedSystemDefaultToID = prepared.redirectedTo
        didRedirectSystemDefault = prepared.redirectedTo != 0
        channelSelector = prepared.channelSelector
        resampler = prepared.resampler
        dictationTraceLog.notice("engine setup done elapsedMs=\((CFAbsoluteTimeGetCurrent() - engineSetupBegan) * 1000, format: .fixed(precision: 0), privacy: .public)")
    }

    /// Forwards to AudioDeviceManager.setSystemDefaultInputDevice for this file's callers.
    nonisolated static func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) {
        AudioDeviceManager.setSystemDefaultInputDevice(deviceID)
    }

    func teardownEngine(synchronous: Bool = false, destroyEngine: Bool = false) {
        // Copy the engine and redirect state into locals and release them on the main thread right away,
        // so stop, removeTap, and the default-input restore run in the background.
        //
        // `destroyEngine` false (normal stop or cancel) keeps the engine after removing the tap. Its input
        // unit stays bound to the session's device, so the next press skips binding, which takes several
        // hundred ms on pro USB and Thunderbolt interfaces. True (setup failure, recovery, wake, quit)
        // destroys it, because its state is suspect. The keep path records its work in
        // engineQuiesceTask, and startRecording waits for it before reusing the engine.
        //
        // Background, because a wedged audio system (for example mid Bluetooth renegotiation) can block
        // these calls indefinitely, which froze the main thread when they ran there.
        //
        // `synchronous` is for quit (`teardownEngineForShutdown`): restore the default input before exit,
        // with a short timeout so a wedged audio system can't hold termination past macOS's grace
        // period.
        let engineRef = engineStorage as? AVAudioEngine
        let didRedirect = didRedirectSystemDefault
        let restoreID = redirectedSystemDefaultFromID
        let redirectedTo = redirectedSystemDefaultToID
        didRedirectSystemDefault = false
        redirectedSystemDefaultFromID = 0
        redirectedSystemDefaultToID = 0
        if destroyEngine {
            engineStorage = nil
        }

        guard let engineRef else { return }
        let ownsRoute = AudioSetupActivity.begin()
        let work: @Sendable () -> Void = {
            defer { if ownsRoute { AudioSetupActivity.end() } }
            engineRef.inputNode.removeTap(onBus: 0)
            engineRef.stop()
            // Restore the default input after `engine.stop()`, once the unit has detached, so the
            // change can't rebind a running unit.
            if didRedirect, restoreID != 0,
               AudioDeviceManager.defaultInputDeviceID() == redirectedTo {
                Self.setSystemDefaultInputDevice(restoreID)
            }
        }
        if synchronous {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 1.5)
        } else if destroyEngine {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        } else {
            // Keep path: record the background stop so the next start can wait for it. Clears
            // itself when done; a slot that stayed set would disable prewarm.
            let box = TaskBox<Void, Never>()
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                work()
                await MainActor.run { [weak self] in
                    guard let self, self.engineQuiesceTask == box.task else { return }
                    self.engineQuiesceTask = nil
                }
            }
            box.task = task
            engineQuiesceTask = task
        }
    }

    /// Binds the kept engine's input unit to the device the next dictation will use, without a tap
    /// or IO, so no privacy indicator appears. Binding is the slow part of setup on pro USB and
    /// Thunderbolt interfaces; doing it while idle means even the first press only installs the tap
    /// and starts. Skipped during a session, when an engine exists, or without mic permission.
    /// Tracked in engineQuiesceTask so a press during the bind waits for it.
    func prewarmEngineBinding(deviceUID: String?) {
        guard !isRecording, !MicTestController.isCapturing,
              engineStorage == nil, engineQuiesceTask == nil else { return }
        guard AVAudioApplication.shared.recordPermission == .granted,
              AudioSetupActivity.begin() else { return }
        let engineRef = engine
        let box = TaskBox<Void, Never>()
        let task = Task.detached(priority: .utility) { [weak self] in
            defer {
                AudioSetupActivity.end()
                Task { @MainActor [weak self] in
                    guard let self, self.engineQuiesceTask == box.task else { return }
                    self.engineQuiesceTask = nil
                }
            }
            let targetID = deviceUID.map { AudioDeviceManager.deviceIDForUID($0) } ?? 0
            // First inputNode access instantiates the AUHAL bound to the
            // system default — already the whole win when default == target.
            let input = engineRef.inputNode
            guard targetID != 0, let audioUnit = input.audioUnit else { return }
            var currentDevice: AudioDeviceID = 0
            var cdSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let cdStatus = AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentDevice,
                &cdSize
            )
            if cdStatus == noErr, currentDevice == targetID { return }
            AudioUnitUninitialize(audioUnit)
            var mutableID = targetID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            AudioUnitInitialize(audioUnit)
        }
        box.task = task
        engineQuiesceTask = task
    }

    /// Synchronous best-effort teardown at quit, from AppState.shutdown() in willTerminate, where
    /// async work won't finish. Restores the default input with a 1.5 s timeout so a wedged audio
    /// system can't hold termination.
    func teardownEngineForShutdown() {
        pollingTask?.cancel()
        healthCheckTask?.cancel()
        teardownEngine(synchronous: true, destroyEngine: true)
        audioBuffers.clearSamples()
        isRecording = false
    }

    // MARK: - Audio Level Polling (~20Hz for equalizer animation)

    /// Copies the RMS level from the thread-safe store to `audioLevel` about 20 times a second.
    /// Starts before the engine is running, so it waits with `continue` until recording begins
    /// instead of exiting.
    func startAudioLevelPolling() {
        // Cancel any prior task before assigning so a fast back-to-back
        // session doesn't leave the previous task running silently.
        audioLevelTask?.cancel()
        let bufs = audioBuffers
        audioLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms = ~20Hz
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                guard self.isRecording else { continue }
                let newLevel = bufs.audioLevel
                let newPeak = bufs.audioPeak
                if abs(self.audioLevel - newLevel) >= 0.001 {
                    self.audioLevel = newLevel
                }
                if abs(self.audioPeak - newPeak) >= 0.001 {
                    self.audioPeak = newPeak
                }
            }
        }
    }

    func startLiveTailPolling() {
        liveTailPollingTask?.cancel()
        liveTailPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                guard self.isRecording else { continue }
                
                await MainActor.run { [weak self] in
                    self?.stagedTranscript.recomputeLiveTail()
                }
            }
        }
    }

    // MARK: - Audio Conversion (for polling buffer)

    /// Converts a buffer to mono 16 kHz samples on the audio tap thread: ChannelSelector takes one
    /// channel or mixes them at the device rate, then AudioResampler converts to 16 kHz. Without a
    /// selector it mixes all channels; without a resampler it interpolates linearly.
    nonisolated private static func convertToMono16k(
        buffer: AVAudioPCMBuffer,
        sourceSampleRate: Double,
        selector: ChannelSelector? = nil,
        resampler: AudioResampler? = nil
    ) -> [Float] {
        let mono: [Float]
        if let selector {
            mono = selector.selectAndDownmix(buffer)
        } else {
            mono = Self.legacyDownmixAllChannels(buffer: buffer)
        }
        guard !mono.isEmpty else { return [] }
        if let resampler {
            return resampler.resampleTo16k(samples: mono, sourceSampleRate: sourceSampleRate)
        }
        return Self.resampleLinearTo16k(samples: mono, sourceSampleRate: sourceSampleRate)
    }

    /// Historical downmix-all-channels path. Retained for compatibility
    /// with any tap caller that doesn't pass a ChannelSelector.
    nonisolated private static func legacyDownmixAllChannels(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        var mixed = [Float](repeating: 0, count: frameCount)
        for c in 0..<channels {
            vDSP_vadd(channelData[c], 1, mixed, 1, &mixed, 1, vDSP_Length(frameCount))
        }
        var div = Float(channels)
        vDSP_vsdiv(mixed, 1, &div, &mixed, 1, vDSP_Length(frameCount))
        return mixed
    }

    /// Linear interpolation to 16 kHz, about every 85 ms on small buffers. Aliases above 48 kHz;
    /// the high-quality path avoids that.
    nonisolated private static func resampleLinearTo16k(samples: [Float], sourceSampleRate: Double) -> [Float] {
        if sourceSampleRate == 16_000.0 { return samples }
        let ratio = 16_000.0 / sourceSampleRate
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
