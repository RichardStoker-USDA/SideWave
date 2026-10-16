// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

public enum AudioSourceError: LocalizedError, Equatable {
    case alreadyRunning
    case noInputDevice
    case startTimedOut(deviceName: String)
    case formatNeverBecameValid(deviceName: String)
    case engineStartFailed(deviceName: String, status: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A capture session is already running."
        case .noInputDevice:
            return "No microphone is available."
        case .startTimedOut(let name):
            return "\(name) did not respond in time."
        case .formatNeverBecameValid(let name):
            return "\(name) is still initializing. Try again in a moment."
        case .engineStartFailed(let name, let status):
            return "Could not start capture on \(name) (\(status))."
        }
    }
}

/// CoreAudio capture. Rules carried over from the original app:
/// - A new AVAudioEngine per session, never reused: a cached engine keeps a device binding that goes
///   stale after dock or sleep changes.
/// - The device is resolved against the current hardware list at every start. A missing preferred
///   device falls back to the default, by name, so the session can say so.
/// - Everything that touches CoreAudio runs on a dedicated thread, never the cooperative pool:
///   `engine.inputNode` and format reads can block for seconds after wake. `start()` returns within
///   its timeout; a stuck setup thread is abandoned and cleans up when CoreAudio recovers, and the
///   abandonment flag keeps it from leaving the mic on.
/// - The input format is read again in a loop before installing the tap, because Bluetooth and pro
///   USB devices report an empty format while renegotiating after sleep or dock changes.
public actor AudioSourceCoreAudio: AudioSource {

    public struct Options: Sendable {
        public var useHighQualityResampling: Bool
        public var channelMode: InputChannelMode
        /// Looks up a previously measured channel for a device UID; nil means measure again.
        public var cachedAutoChannel: (@Sendable (String?) -> Int?)?
        /// Reported once when auto-calibration locks in a channel, so the
        /// shell can cache it.
        public var onAutoCalibrated: (@Sendable (String?, Int) -> Void)?
        /// Hard ceiling on engine bring-up before start() throws. Flat for
        /// every transport: the referee arms BEFORE any HAL call, so even
        /// a wedged coreaudiod cannot stretch a start past this.
        public var startTimeout: Duration

        public init(
            useHighQualityResampling: Bool = true,
            channelMode: InputChannelMode = .auto,
            cachedAutoChannel: (@Sendable (String?) -> Int?)? = nil,
            onAutoCalibrated: (@Sendable (String?, Int) -> Void)? = nil,
            startTimeout: Duration = .seconds(8)
        ) {
            self.useHighQualityResampling = useHighQualityResampling
            self.channelMode = channelMode
            self.cachedAutoChannel = cachedAutoChannel
            self.onAutoCalibrated = onAutoCalibrated
            self.startTimeout = startTimeout
        }
    }

    /// Reasons the CURRENT session died under us (engine configuration
    /// change: device unplugged, default rerouted by the OS). The shell
    /// forwards these to `SessionController.reportSubsystemFailure`.
    public nonisolated let interruptions: AsyncStream<String>
    private nonisolated let interruptionOut: AsyncStream<String>.Continuation

    private let options: Options
    private var session: CaptureSession?
    private let log = Logger(subsystem: "com.sidewave.kit", category: "audio")

    public init(options: Options = Options()) {
        self.options = options
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.interruptions = stream
        self.interruptionOut = continuation
    }

    // MARK: AudioSource

    public func start(
        preferredDeviceUID: String?,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) async throws -> String {
        guard session == nil else { throw AudioSourceError.alreadyRunning }

        let newSession = CaptureSession(
            preferredDeviceUID: preferredDeviceUID,
            options: options,
            waitForTeardown: lastTeardownDone,
            onSamples: onSamples,
            onInterrupted: { [interruptionOut] reason in
                interruptionOut.yield(reason)
            }
        )
        session = newSession

        do {
            let resolvedName = try await newSession.bringUp()
            log.notice("capture live on \(resolvedName, privacy: .public)")
            return resolvedName
        } catch {
            // A failed or timed-out start must not leave a half-open session in the way of the next
            // start; the abandonment flag also stops a late setup thread from installing its tap.
            lastTeardownDone = newSession.tearDown()
            session = nil
            throw error
        }
    }

    public func stop() async {
        guard let current = session else { return }
        session = nil
        lastTeardownDone = current.tearDown()
        log.notice("capture stopped")
    }

    /// Signaled when the previous session's teardown finishes. The next setup waits on it, with a
    /// limit, so a quick stop and start can't overlap teardown and setup.
    private var lastTeardownDone: DispatchSemaphore?
}

/// One session's engine, taps, and threads. Class (not actor) because its
/// state crosses a dedicated setup thread, the CoreAudio IO thread, and
/// the owning actor; the lock keeps that honest.
private final class CaptureSession: @unchecked Sendable {

    private let lock = NSLock()
    private var abandoned = false
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?
    private var continuation: CheckedContinuation<String, any Error>?

    private let preferredDeviceUID: String?
    private let options: AudioSourceCoreAudio.Options
    private let waitForTeardown: DispatchSemaphore?
    private let onSamples: @Sendable ([Float]) -> Void
    private let onInterrupted: @Sendable (String) -> Void
    private let log = Logger(subsystem: "com.sidewave.kit", category: "audio")

    init(
        preferredDeviceUID: String?,
        options: AudioSourceCoreAudio.Options,
        waitForTeardown: DispatchSemaphore?,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) {
        self.preferredDeviceUID = preferredDeviceUID
        self.options = options
        self.waitForTeardown = waitForTeardown
        self.onSamples = onSamples
        self.onInterrupted = onInterrupted
    }

    // MARK: Bring-up

    /// Every CoreAudio call, including resolving the device list, runs on the setup thread: a stuck
    /// coreaudiod can block reads for tens of seconds (38 s with an interface in deep standby),
    /// which would stall the cooperative pool. This method only waits on the continuation, which
    /// the timeout always resolves.
    func bringUp() async throws -> String {
        let name: String = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let thread = Thread { [weak self] in
                self?.setupThreadMain()
            }
            thread.name = "com.sidewave.kit.audio-setup"
            thread.qualityOfService = .userInteractive
            thread.start()

            // The timeout referee, armed BEFORE any HAL work anywhere.
            // Whoever resolves the continuation first wins; the loser
            // sees it already taken and unwinds.
            Task { [weak self] in
                try? await Task.sleep(for: self?.options.startTimeout ?? .seconds(8))
                guard let self else { return }
                if let pending = self.takeContinuation() {
                    self.markAbandoned()
                    pending.resume(
                        throwing: AudioSourceError.startTimedOut(
                            deviceName: self.resolvedDeviceName() ?? "The microphone"))
                }
            }
        }
        return name
    }

    /// Runs on the dedicated setup thread. Blocking calls are expected
    /// and safe here. Stage timings go to the log so a slow start names
    /// its slow stage.
    private func setupThreadMain() {
        let stageClock = ContinuousClock()
        var stageStart = stageClock.now
        func stamp(_ stage: String) {
            let elapsed = stageClock.now - stageStart
            stageStart = stageClock.now
            if elapsed > .milliseconds(250) {
                log.notice("setup stage \(stage, privacy: .public) took \(elapsed.formatted(), privacy: .public)")
            }
        }

        // Let the previous session's teardown clear coreaudiod before new
        // HAL work; bounded so a wedged teardown can't block a start.
        if let waitForTeardown {
            _ = waitForTeardown.wait(timeout: .now() + 3.0)
            stamp("teardown-wait")
        }
        if isAbandoned { return }

        let (resolved, _) = AudioDevices.resolveForCapture(preferredUID: preferredDeviceUID)
        stamp("resolve")
        guard let device = resolved else {
            if let pending = takeContinuation() {
                pending.resume(throwing: AudioSourceError.noInputDevice)
            }
            return
        }
        storeResolvedDeviceName(device.name)
        if isAbandoned { return }

        let created = AVAudioEngine()
        lock.lock()
        engine = created
        lock.unlock()

        // The first inputNode access binds to the system default. Rebind to the resolved device
        // when they differ; the property only takes effect after uninitialize, set, and initialize.
        let input = created.inputNode
        stamp("inputNode")
        if isAbandoned { unwindAfterAbandonment(created); return }

        let currentDefault = AudioDevices.defaultInputDeviceID()
        if device.id != currentDefault, let audioUnit = input.audioUnit {
            var currentDevice: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let readStatus = AudioUnitGetProperty(
                audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &currentDevice, &size)
            if readStatus != noErr || currentDevice != device.id {
                AudioUnitUninitialize(audioUnit)
                var target = device.id
                let setStatus = AudioUnitSetProperty(
                    audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &target,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
                let initStatus = AudioUnitInitialize(audioUnit)
                if setStatus != noErr || initStatus != noErr {
                    log.error("AUHAL rebind to \(device.name, privacy: .public) failed (set=\(setStatus) init=\(initStatus))")
                }
            }
        }

        // Wait out renegotiation: BT profile flips and pro USB drivers
        // report zero-format while settling after sleep / dock changes.
        var inFormat = input.inputFormat(forBus: 0)
        let maxRetries = device.isBluetooth ? 30 : 12
        var retries = 0
        while inFormat.sampleRate == 0 || inFormat.channelCount == 0 {
            retries += 1
            if retries > maxRetries || isAbandoned {
                failFromSetupThread(
                    .formatNeverBecameValid(deviceName: device.name), engine: created)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
            inFormat = input.inputFormat(forBus: 0)
        }
        if retries > 0 {
            log.notice("input format ready after \(retries) retries: \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch")
        }
        stamp("rebind+format")

        let selector = ChannelSelector(
            mode: options.channelMode,
            channelCount: Int(inFormat.channelCount),
            deviceUID: device.uid,
            cachedAutoChannel: options.cachedAutoChannel?(device.uid),
            onAutoCalibrated: options.onAutoCalibrated
        )
        let resampler = AudioResampler(useHQ: options.useHighQualityResampling)
        let sourceRate = inFormat.sampleRate
        let deliver = onSamples

        // Last check before the mic turns on: if the timeout already gave up, installing the tap
        // would leave an orphaned capture.
        if isAbandoned { unwindAfterAbandonment(created); return }

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let mono = selector.selectAndDownmix(buffer)
            guard !mono.isEmpty else { return }
            let mono16k = resampler.resampleTo16k(samples: mono, sourceSampleRate: sourceRate)
            if !mono16k.isEmpty {
                deliver(mono16k)
            }
        }
        markTapInstalled()

        created.prepare()
        do {
            try created.start()
        } catch {
            failFromSetupThread(
                .engineStartFailed(deviceName: device.name, status: error.localizedDescription),
                engine: created)
            return
        }
        stamp("tap+start")

        if isAbandoned { unwindAfterAbandonment(created); return }

        // The engine stopping mid-session (device unplugged, system reroute) is a failure the app
        // must hear about. Binding a non-default device makes the engine post this notification for
        // our own rebind, so only an engine that actually stopped counts, checked now and again
        // after a short delay.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: created,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.reportIfEngineDied()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.reportIfEngineDied()
            }
        }
        lock.lock()
        configObserver = observer
        lock.unlock()

        if let pending = takeContinuation() {
            pending.resume(returning: device.name)
        } else {
            // Timeout already reported failure; nobody wants this engine.
            unwindAfterAbandonment(created)
        }
    }

    // MARK: Teardown

    /// Safe to call repeatedly from any context. Marks the session abandoned, so a stuck setup
    /// thread can't turn the mic on, and tears down whatever started on a separate thread, since
    /// engine.stop can block too. The returned semaphore signals when teardown is done; the next
    /// setup waits on it.
    @discardableResult
    func tearDown() -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        markAbandoned()
        lock.lock()
        let engineToStop = engine
        let hadTap = tapInstalled
        let observer = configObserver
        engine = nil
        tapInstalled = false
        configObserver = nil
        lock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let engineToStop else {
            done.signal()
            return done
        }
        let thread = Thread {
            if hadTap {
                engineToStop.inputNode.removeTap(onBus: 0)
            }
            engineToStop.stop()
            done.signal()
        }
        thread.name = "com.sidewave.kit.audio-teardown"
        thread.start()
        return done
    }

    // MARK: Coordination

    private var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    private func markAbandoned() {
        lock.lock()
        abandoned = true
        lock.unlock()
    }

    private func markTapInstalled() {
        lock.lock()
        tapInstalled = true
        lock.unlock()
    }

    private var _resolvedDeviceName: String?
    private var interruptionReported = false

    /// Configuration-change handler: interrupt the session only when the
    /// engine really stopped, once.
    private func reportIfEngineDied() {
        lock.lock()
        let engineNow = engine
        let alreadyReported = interruptionReported
        let dead = abandoned
        lock.unlock()
        guard !dead, !alreadyReported, let engineNow, !engineNow.isRunning else { return }
        lock.lock()
        interruptionReported = true
        lock.unlock()
        onInterrupted("The microphone changed or was disconnected.")
    }

    private func storeResolvedDeviceName(_ name: String) {
        lock.lock()
        _resolvedDeviceName = name
        lock.unlock()
    }

    private func resolvedDeviceName() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _resolvedDeviceName
    }

    private func takeContinuation() -> CheckedContinuation<String, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    private func failFromSetupThread(_ error: AudioSourceError, engine: AVAudioEngine) {
        unwindAfterAbandonment(engine)
        if let pending = takeContinuation() {
            pending.resume(throwing: error)
        }
    }

    /// Setup-thread-side unwind when the session was abandoned or failed
    /// before handoff: never leave a tap or a running engine behind.
    private func unwindAfterAbandonment(_ engine: AVAudioEngine) {
        lock.lock()
        let hadTap = tapInstalled
        tapInstalled = false
        self.engine = nil
        lock.unlock()
        if hadTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
    }
}
