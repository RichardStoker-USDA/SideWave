// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
@preconcurrency import AVFAudio
import CoreAudio
import Foundation

/// A short, memory-only microphone check using dictation's channel and resampling path.
@Observable
@MainActor
final class MicTestController {
    private static var activeController: MicTestController?
    static var isCapturing: Bool {
        guard let controller = activeController else { return false }
        return controller.isStarting || controller.isRunning || controller.isStopping
    }
    var audioLevel: Double = 0
    var audioPeak: Double = 0
    private(set) var testMaximumLevel: Double = 0
    private(set) var testMaximumPeak: Double = 0
    private(set) var testFinished = false
    private(set) var receivedBufferCount = 0
    private(set) var isStopping = false
    private var captureStart = CaptureStartState()
    var isStarting: Bool { captureStart.isStarting }
    private(set) var isRunning = false
    private(set) var detectedSampleRate: Double = 0
    private(set) var detectedChannelCount = 0
    private(set) var detectedChannel: Int?
    private(set) var lastError: String?

    private var capture: MicrophonePreviewCapture?
    private var setupTask: Task<MicrophonePreviewCapture, Error>?
    private var setupWorkerActive = false
    private let bufferStore = TestAudioBufferStore()
    private var levelTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    static let previewDurationSeconds: Double = 3

    func start(deviceUID: String?) async {
        guard !Self.isCapturing, let attempt = captureStart.begin() else { return }
        Self.activeController = self
        defer {
            captureStart.finish(attempt)
            setupTask = nil
            if !isRunning && !isStopping && !setupWorkerActive, Self.activeController === self { Self.activeController = nil }
        }
        lastError = nil
        bufferStore.reset()
        audioLevel = 0
        audioPeak = 0
        testMaximumLevel = 0
        testMaximumPeak = 0
        receivedBufferCount = 0
        testFinished = false
        detectedSampleRate = 0
        detectedChannelCount = 0
        detectedChannel = nil
        let granted = await requestMicPermission()
        guard captureStart.accepts(attempt), !Task.isCancelled else { return }
        guard granted else {
            lastError = "Microphone access is off. Enable SideWave in System Settings > Privacy & Security > Microphone."
            return
        }
        let store = bufferStore
        setupWorkerActive = true
        let task = Task {
            try await AudioSetupOperation<MicrophonePreviewCapture>.run(timeout: 5, work: { operation in
                try MicrophonePreviewCapture.open(deviceUID: deviceUID, store: store, operation: operation)
            }, dispose: { $0.close() }, workFinished: {
                Task { @MainActor in
                    self.setupWorkerActive = false
                    if self.capture == nil && !self.isRunning { self.isStopping = false }
                    if !self.isStarting && !self.isRunning && !self.isStopping, Self.activeController === self {
                        Self.activeController = nil
                    }
                }
            })
        }
        setupTask = task
        do {
            let opened = try await task.value
            guard captureStart.accepts(attempt), !Task.isCancelled else {
                await Task.detached { opened.close() }.value
                return
            }
            capture = opened
            detectedSampleRate = opened.sampleRate
            detectedChannelCount = opened.channelCount
            isRunning = true
            levelTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                    self?.updateLevels()
                }
            }
            autoStopTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Self.previewDurationSeconds)) } catch { return }
                self?.stop()
            }
        } catch {
            isStopping = setupWorkerActive
            if captureStart.accepts(attempt), !(error is CancellationError) {
                lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        captureStart.cancel()
        setupTask?.cancel()
        if setupWorkerActive { isStopping = true }
        levelTask?.cancel()
        levelTask = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        guard let opened = capture else { return }
        updateLevels()
        capture = nil
        isRunning = false
        testFinished = true
        isStopping = true
        audioLevel = 0
        audioPeak = 0
        Task {
            await Task.detached { opened.close() }.value
            isStopping = false
            if Self.activeController === self { Self.activeController = nil }
        }
    }

    private func updateLevels() {
        let levels = bufferStore.snapshot
        audioLevel = levels.rms
        audioPeak = levels.peak
        testMaximumLevel = levels.maximumRMS
        testMaximumPeak = levels.maximumPeak
        receivedBufferCount = levels.count
        detectedChannel = levels.channel
    }

    var audioInputDisplayPercent: Int { Self.displayPercent(audioLevel) }
    var testMaximumDisplayPercent: Int { Self.displayPercent(testMaximumLevel) }
    private static func displayPercent(_ level: Double) -> Int {
        let rms = max(level.isFinite ? level : 0, 0.001)
        return Int((max(0, min(1, (20 * log10(rms) + 50) / 47)) * 100).rounded())
    }

    var audioInputStatus: TranscriptionService.AudioInputStatus {
        guard isRunning || testFinished else { return .idle }
        let peak = testFinished ? testMaximumPeak : audioPeak
        let level = testFinished ? testMaximumLevel : audioLevel
        if peak >= 0.95 { return .clipping }
        if level < 0.0056 { return .silent }
        if level < 0.0316 { return .quiet }
        if level < 0.2512 { return .balanced }
        return .loud
    }

    var resultDescription: String? {
        guard testFinished else { return nil }
        if receivedBufferCount == 0 { return "No audio arrived. Check the input device and cable, then test again." }
        if testMaximumPeak >= 0.95 { return "Audio received, but it clipped. Lower the input gain and test again." }
        if testMaximumLevel < 0.0056 { return "Audio arrived but no clear signal was detected. Speak during the test; for a mixer, select the physical input channel." }
        if testMaximumLevel < 0.0316 { return "Audio received at a low level. Move closer or raise the microphone gain, then test again." }
        return "Audio received. The selected input is reaching SideWave."
    }

    private func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
    }
}

/// Owns all HAL resources. A timed-out setup cleans itself up when its blocked call returns.
private final class MicrophonePreviewCapture: @unchecked Sendable {
    let engine = AVAudioEngine()
    var sampleRate: Double = 0
    var channelCount = 0
    private var input: AVAudioInputNode?
    private var tapInstalled = false
    private var originalDefault: AudioDeviceID = 0
    private var redirectedTo: AudioDeviceID = 0
    private let closeLock = NSLock()
    private var closed = false

    static func open(deviceUID: String?, store: TestAudioBufferStore,
                     operation: AudioSetupOperation<MicrophonePreviewCapture>) throws -> MicrophonePreviewCapture {
        let capture = MicrophonePreviewCapture()
        var adopted = false
        defer { if !adopted { capture.close() } }
        capture.originalDefault = AudioDeviceManager.defaultInputDeviceID()
        let target = deviceUID.map(AudioDeviceManager.deviceIDForUID) ?? capture.originalDefault
        guard target != 0 else {
            throw NSError(domain: "SideWave.AudioInput", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The selected microphone is disconnected. Choose another input and test again."])
        }
        if target != capture.originalDefault {
            AudioDeviceManager.setSystemDefaultInputDevice(target)
            if AudioDeviceManager.defaultInputDeviceID() == target { capture.redirectedTo = target }
        }
        guard !operation.isAbandoned else { throw CancellationError() }
        let input = capture.engine.inputNode
        capture.input = input
        try AudioDeviceManager.bindInput(input, to: target)
        var format = input.inputFormat(forBus: 0)
        let retries = AudioDeviceManager.isBluetoothInput(target) ? 30 : 12
        for _ in 0..<retries where !format.sampleRate.isFinite || format.sampleRate <= 0 || format.channelCount == 0 {
            guard !operation.isAbandoned else { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.1)
            format = input.inputFormat(forBus: 0)
        }
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "SideWave.AudioInput", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The microphone did not provide an audio format. Reconnect it or choose another input."])
        }
        capture.sampleRate = format.sampleRate
        capture.channelCount = Int(format.channelCount)
        let uid = AudioDeviceManager.deviceUID(target)
        let selector = ChannelSelector(mode: AudioDeviceManager.channelMode(forUID: uid),
            channelCount: capture.channelCount, deviceUID: uid,
            cachedAutoChannel: AudioDeviceManager.autoDetectedChannel(forUID: uid))
        let resampler = AudioResampler(useHQ: UserDefaults.standard.object(forKey: "useHighQualityResampling") as? Bool ?? true)
        let rate = format.sampleRate
        guard !operation.isAbandoned else { throw CancellationError() }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard !operation.isAbandoned else { return }
            let samples = resampler.resampleTo16k(samples: selector.selectAndDownmix(buffer), sourceSampleRate: rate)
            guard !samples.isEmpty else { return }
            var square: Float = 0
            var peak: Float = 0
            vDSP_measqv(samples, 1, &square, vDSP_Length(samples.count))
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
            store.receive(rms: Double(sqrtf(square)), peak: Double(peak), channel: selector.selectedChannel)
        }
        capture.tapInstalled = true
        capture.engine.prepare()
        try capture.engine.start()
        guard !operation.isAbandoned else { throw CancellationError() }
        adopted = true
        return capture
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        let ownsRoute = AudioSetupActivity.begin()
        defer { if ownsRoute { AudioSetupActivity.end() } }
        if tapInstalled { input?.removeTap(onBus: 0) }
        engine.stop()
        if redirectedTo != 0, originalDefault != 0,
           AudioDeviceManager.defaultInputDeviceID() == redirectedTo {
            AudioDeviceManager.setSystemDefaultInputDevice(originalDefault)
        }
    }
}

private final class TestAudioBufferStore: @unchecked Sendable {
    struct Levels {
        var rms = 0.0
        var peak = 0.0
        var maximumRMS = 0.0
        var maximumPeak = 0.0
        var count = 0
        var channel: Int?
    }
    private let lock = NSLock()
    private var levels = Levels()
    var snapshot: Levels { lock.withLock { levels } }
    func reset() { lock.withLock { levels = Levels() } }
    func receive(rms: Double, peak: Double, channel: Int?) {
        lock.withLock {
            levels.rms = rms.isFinite ? rms : 0
            levels.peak = peak.isFinite ? peak : 0
            levels.maximumRMS = max(levels.maximumRMS, levels.rms)
            levels.maximumPeak = max(levels.maximumPeak, levels.peak)
            levels.count += 1
            levels.channel = channel
        }
    }
}
