// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFoundation
import AppKit
import Foundation
import QuartzCore
import SideWaveKit
import os

/// The shell's one coordinator: owns the engine subsystems, consumes the
/// session signal stream, mirrors state for SwiftUI, and turns hotkey
/// gestures into session requests through the kit's GestureClassifier.
@MainActor
@Observable
final class AppModel {

    // MARK: Engine

    @ObservationIgnored let audio: AudioSourceCoreAudio
    @ObservationIgnored let recognizer: NemotronRecognizer
    @ObservationIgnored let refiner: RefinerRouter
    @ObservationIgnored let paster: PasterCascade
    @ObservationIgnored let controller: SessionController
    @ObservationIgnored let hotkey = HotkeyMonitor()
    @ObservationIgnored private var deviceWatcher: AudioDeviceSetWatcher?
    @ObservationIgnored private var pumps: [Task<Void, Never>] = []

    // MARK: Mirrored session state

    enum Phase: Equatable {
        case idle, starting, live, stopping
    }

    private(set) var phase: Phase = .idle
    private(set) var settledText = ""
    private(set) var settlingText = ""
    private(set) var resolvedDeviceName: String?
    /// Transient user-facing message (failure, suppression, paste note).
    private(set) var notice: String?
    /// Set briefly after a session delivers, for the overlay flash.
    private(set) var lastDelivery: SessionOutcome.Delivery?
    private(set) var lastOutcome: SessionOutcome?
    /// Bumps on every transcript update so the overlay wave surges.
    private(set) var transcriptPulse = 0
    /// Whether the in-flight stop is spending its time in refine.
    private(set) var refineInFlight = false
    /// "Using MacBook Pro Microphone" when the preferred device was
    /// missing and capture fell back.
    private(set) var deviceFallbackNotice: String?

    /// The overlay's whole world, derived. Pure data out; the panel's
    /// root view feeds it to the pure OverlayView.
    var overlayState: OverlayDisplayState {
        var state = OverlayDisplayState()
        state.settledText = settledText
        state.settlingText = settlingText
        state.activityPulse = transcriptPulse
        state.pttEngaged = pttEngaged
        state.hotkeyGlyph = AppSettings.hotkey.compactDisplayString
        state.refinePalette =
            AppSettings.refineBackend == .appleIntelligence ? .appleIntelligence : .gemma
        state.deviceNotice = deviceFallbackNotice

        switch phase {
        case .starting:
            state.phase = .starting
        case .live:
            state.phase = .live
        case .stopping:
            state.phase = .finishing(refining: refineInFlight)
        case .idle:
            if let notice {
                state.phase = .done(.notice(notice))
            } else {
                switch lastDelivery {
                case .pasted(let result):
                    if case .failed(let reason) = result {
                        state.phase = .done(.notice(reason))
                    } else {
                        state.phase = .done(.pasted)
                    }
                case .savedOnly:
                    state.phase = .done(.savedToHistory)
                case .discarded:
                    // An intentional cancel deserves a calm confirmation,
                    // not an error-shaped message.
                    state.phase = .done(.notice("Discarded."))
                case nil:
                    state.phase = .done(.notice("Ready."))
                }
            }
        }
        return state
    }

    // MARK: Gesture state (live-anchored PTT)

    /// Wall-anchored stamps for the carried classifier. Zero = unset.
    @ObservationIgnored private var pressDownAt: TimeInterval = 0
    @ObservationIgnored private var engineLiveAt: TimeInterval = 0
    /// True once the current hold crossed the live-anchored threshold
    /// (drives the overlay's "release to send" hint).
    private(set) var pttEngaged = false
    @ObservationIgnored private var pttHintTask: Task<Void, Never>?
    /// The press that started the session is still down.
    @ObservationIgnored private var holdActive = false

    // MARK: Model setup

    private(set) var setupProgress: ModelSetupProgress?
    private(set) var modelsReady = false
    private(set) var setupError: String?

    // MARK: Permissions

    private(set) var accessibilityGranted = AXIsProcessTrusted()

    // MARK: Sibling coexistence

    /// True while the original SideWave app is running. Both apps bind
    /// Right Option by default, so running them together would dictate
    /// and paste everything twice; this app yields its hotkey until the
    /// original quits. The Record button keeps working either way.
    private(set) var siblingAppRunning = false
    private static let siblingBundleIDs: Set<String> = [
        "com.sidewave.app.dev", "com.sidewave.app", "com.sidewave.app.devag",
    ]

    // MARK: Stores

    let history = HistoryStoreLite()
    let downloads = DownloadLedger()

    private let log = Logger(subsystem: "com.sidewave2.app", category: "shell")

    // MARK: Init

    init() {
        AppSettings.registerDefaults()

        audio = AudioSourceCoreAudio(
            options: AudioSourceCoreAudio.Options(
                cachedAutoChannel: { uid in
                    guard let uid else { return nil }
                    let v = UserDefaults.standard.integer(forKey: "autoChannel.\(uid)")
                    return v > 0 ? v : nil
                },
                onAutoCalibrated: { uid, channel in
                    guard let uid else { return }
                    UserDefaults.standard.set(channel, forKey: "autoChannel.\(uid)")
                }
            ))
        recognizer = NemotronRecognizer(
            options: NemotronRecognizer.Options(languageCode: AppSettings.languageCode))
        refiner = RefinerRouter()
        paster = PasterCascade()
        controller = SessionController(
            audio: audio, recognizer: recognizer, refiner: refiner, paster: paster)

        wireHotkey()
        startSignalPump()
        startInterruptionPump()
        startDeviceWatcher()

        PasterCascade.setAccessibilityMissingHandler { [weak self] in
            Task { @MainActor in
                self?.showNotice("SideWave needs Accessibility permission to type. Open System Settings > Privacy & Security > Accessibility.")
            }
        }
    }

    // MARK: Bring-up

    func onLaunch() {
        applyAppearance()
        PasterCascade.warmUpKeyboardLayout()
        refreshPermissions()
        startSiblingWatch()
        Task { await prepareModels() }
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted, !hotkey.isInstalled, !siblingAppRunning {
            hotkey.install()
        }
    }

    /// Watch the original SideWave come and go; yield or reclaim the
    /// hotkey accordingly. Observer tokens live for the app's lifetime.
    private func startSiblingWatch() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateSiblingState() }
            }
        }
        updateSiblingState()
    }

    private func updateSiblingState() {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return Self.siblingBundleIDs.contains(id)
        }
        siblingAppRunning = running
        if running {
            if hotkey.isInstalled {
                hotkey.teardown()
                log.notice("original SideWave running; hotkey yielded to avoid double dictation")
            }
        } else if accessibilityGranted, !hotkey.isInstalled {
            hotkey.install()
            log.notice("original SideWave quit; hotkey restored")
        }
    }

    func prepareModels() async {
        guard !modelsReady else { return }
        setupError = nil
        let clock = ContinuousClock()
        do {
            let sawNetwork = NetworkFetchFlag()
            let asrStart = clock.now
            try await recognizer.prepare { [weak self] progress in
                if progress.detail.hasPrefix("Downloading") { sawNetwork.set() }
                Task { @MainActor in self?.setupProgress = progress }
            }
            downloads.record(
                component: "Speech model + voice detector (\(AppSettings.languageCode), 1120 ms)",
                source: "huggingface.co/FluidInference",
                networkFetch: sawNetwork.get(),
                duration: clock.now - asrStart
            )

            await refiner.configure(
                backend: AppSettings.refineBackend, settings: currentRefineSettings())
            if AppSettings.refineBackend.gemmaVariant != nil {
                let gemmaNetwork = NetworkFetchFlag()
                let gemmaStart = clock.now
                try await refiner.prepareIfNeeded { [weak self] progress in
                    if progress.detail.hasPrefix("Downloading") { gemmaNetwork.set() }
                    Task { @MainActor in self?.setupProgress = progress }
                }
                downloads.record(
                    component: AppSettings.refineBackend.displayName,
                    source: "huggingface.co/mlx-community",
                    networkFetch: gemmaNetwork.get(),
                    duration: clock.now - gemmaStart
                )
            }
            modelsReady = true
            setupProgress = nil
            log.notice("models ready")
        } catch {
            setupError = "Model setup did not finish: \(error.localizedDescription)"
            setupProgress = nil
            log.error("model setup failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Settings changed: re-route the refiner, hint the recognizer, and
    /// re-prepare whatever the change needs.
    func settingsChanged() {
        Task {
            await recognizer.setLanguage(AppSettings.languageCode)
            await refiner.configure(
                backend: AppSettings.refineBackend, settings: currentRefineSettings())
            let ready = await recognizer.isReady
            if !ready {
                modelsReady = false
                await prepareModels()
            } else {
                do {
                    try await refiner.prepareIfNeeded { [weak self] progress in
                        Task { @MainActor in self?.setupProgress = progress }
                    }
                    setupProgress = nil
                } catch {
                    setupProgress = nil
                    showNotice("Could not load the refine model: \(error.localizedDescription)")
                }
            }
        }
        applyAppearance()
    }

    func applyAppearance() {
        NSApplication.shared.appearance = AppSettings.appearance.nsAppearance
    }

    private func currentRefineSettings() -> RefineSettings {
        RefineSettings(
            template: AppSettings.refineTemplate,
            outputLanguage: .matchInput
        )
    }

    // MARK: Gestures

    private func wireHotkey() {
        hotkey.onPressDown = { [weak self] in self?.gesturePressDown() }
        hotkey.onPressUp = { [weak self] in self?.gesturePressUp() }
        hotkey.onAborted = { [weak self] in self?.gestureAborted() }
        hotkey.isSessionActive = { [weak self] in
            guard let self else { return false }
            return self.phase != .idle
        }
        hotkey.onEscape = { [weak self] withControl in
            guard let self, self.phase == .starting || self.phase == .live else { return false }
            Task { await self.controller.requestCancel(save: !withControl) }
            return true
        }
    }

    private func gesturePressDown() {
        switch phase {
        case .idle:
            pressDownAt = CACurrentMediaTime()
            engineLiveAt = 0
            holdActive = true
            pttEngaged = false
            startSession()
        case .starting, .live:
            // Second press: the toggle stop. Queues safely during starting.
            holdActive = false
            Task { await controller.requestStop() }
        case .stopping:
            break
        }
    }

    private func gesturePressUp() {
        defer {
            holdActive = false
            pttHintTask?.cancel()
            pttHintTask = nil
        }
        guard holdActive else { return }
        // Live-anchored classification, carried: no engine confirmation
        // means no PTT, ever. A tap (release before threshold past
        // engine-live) leaves the session running as a toggle.
        let satisfied = GestureClassifier.pttHoldSatisfied(
            now: CACurrentMediaTime(),
            pressDown: pressDownAt,
            engineLiveAt: engineLiveAt,
            threshold: AppSettings.pttThreshold
        )
        if satisfied {
            pttEngaged = false
            Task { await controller.requestStop() }
        }
    }

    private func gestureAborted() {
        // The user typed a shortcut through the held modifier: this was
        // never a dictation gesture. Discard quietly.
        guard holdActive else { return }
        holdActive = false
        pttHintTask?.cancel()
        pttEngaged = false
        Task { await controller.requestCancel(save: false) }
    }

    /// Start requested from UI (dashboard button / menu); same session,
    /// no PTT semantics.
    func toggleFromUI() {
        switch phase {
        case .idle:
            pressDownAt = 0
            engineLiveAt = 0
            holdActive = false
            startSession()
        case .starting, .live:
            Task { await controller.requestStop() }
        case .stopping:
            break
        }
    }

    func cancelFromUI(save: Bool) {
        Task { await controller.requestCancel(save: save) }
    }

    private func startSession() {
        guard modelsReady else {
            showNotice("Speech models are still preparing. One moment.")
            return
        }
        // A denied microphone gets guidance, never a cryptic engine
        // failure. Not-yet-asked proceeds so macOS can show its prompt.
        let micAccess = AVCaptureDevice.authorizationStatus(for: .audio)
        if micAccess == .denied || micAccess == .restricted {
            showNotice("Microphone access is off for SideWave. Enable it in System Settings > Privacy & Security > Microphone.")
            return
        }
        notice = nil
        lastDelivery = nil
        let target = PasterCascade.captureSystemFocusedPID()
        let config = SessionConfiguration(
            preferredDeviceUID: AppSettings.preferredDeviceUID,
            refineEnabled: AppSettings.refineEnabled,
            refineContext: "",
            targetPID: target
        )
        Task { await controller.requestStart(config) }
    }

    // MARK: Signal consumption

    private func startSignalPump() {
        let signals = controller.signals
        let pump = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                await MainActor.run {
                    self.apply(signal)
                }
            }
        }
        pumps.append(pump)
    }

    private func apply(_ signal: SessionSignal) {
        switch signal {
        case .stateChanged(let state, _):
            switch state {
            case .idle:
                phase = .idle
                pttEngaged = false
                refineInFlight = false
            case .starting:
                phase = .starting
                settledText = ""
                settlingText = ""
                resolvedDeviceName = nil
                deviceFallbackNotice = nil
                refineInFlight = false
            case .live:
                phase = .live
                engineLiveAt = CACurrentMediaTime()
                armPttHint()
            case .stopping:
                phase = .stopping
                // Where the stop's time goes: refine when it's on and
                // words exist, otherwise just the drain.
                refineInFlight = AppSettings.refineEnabled && !settledText.isEmpty
            }

        case .deviceResolved(let name):
            resolvedDeviceName = name
            deviceFallbackNotice = Self.fallbackNotice(
                resolvedName: name, preferredUID: AppSettings.preferredDeviceUID)

        case .transcript(let settled, let settling):
            settledText = settled
            settlingText = settling
            transcriptPulse &+= 1

        case .suppressed(let reason):
            showNotice(reason)

        case .failed(let reason):
            showNotice(reason)
            NSSound(named: "Basso")?.play()

        case .completed(let outcome):
            lastOutcome = outcome
            lastDelivery = outcome.delivery
            settledText = outcome.finalText
            settlingText = ""
            if case .pasted(let result) = outcome.delivery {
                if case .failed(let reason) = result {
                    showNotice(reason)
                    NSSound(named: "Basso")?.play()
                } else {
                    NSSound(named: "Pop")?.play()
                }
            }
            let appName = PasteEngineAppName.frontmost()
            history.record(outcome: outcome, appName: appName)
        }
    }

    /// Flip the overlay hint once the hold crosses the live-anchored
    /// threshold; the hint's only owner, scheduled from engine-live the
    /// way the carried fix demands (never from key-down).
    private func armPttHint() {
        pttHintTask?.cancel()
        guard holdActive else { return }
        let threshold = AppSettings.pttThreshold
        pttHintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(threshold))
            guard !Task.isCancelled, let self, self.holdActive, self.phase == .live else { return }
            self.pttEngaged = true
        }
    }

    private func startInterruptionPump() {
        let interruptions = audio.interruptions
        let pump = Task { [weak self] in
            for await reason in interruptions {
                guard let self else { return }
                await self.controller.reportSubsystemFailure(reason: reason)
            }
        }
        pumps.append(pump)
    }

    /// Device-SET changes only abort a LIVE session (gracefully); between
    /// sessions nothing is cached, so nothing needs invalidating.
    private func startDeviceWatcher() {
        let watcher = AudioDeviceSetWatcher()
        deviceWatcher = watcher
        let pump = Task { [weak self] in
            for await _ in watcher.changes {
                guard let self else { return }
                let state = await self.controller.currentState
                if case .live = state {
                    await self.controller.reportSubsystemFailure(
                        reason: "The audio devices changed. Dictation stopped; press the hotkey to continue.")
                }
            }
        }
        pumps.append(pump)
    }

    // MARK: Notices

    @ObservationIgnored private var noticeClearTask: Task<Void, Never>?

    private func showNotice(_ text: String) {
        notice = text
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

extension AppModel {
    /// Honest fallback line for the overlay: only when a preferred device
    /// was set and capture landed somewhere else.
    static func fallbackNotice(resolvedName: String, preferredUID: String?) -> String? {
        guard let preferredUID, !preferredUID.isEmpty else { return nil }
        let devices = AudioDevices.listInputDevices()
        guard let preferred = devices.first(where: { $0.uid == preferredUID }) else {
            return "Using \(resolvedName)"
        }
        return preferred.name == resolvedName ? nil : "Using \(resolvedName)"
    }
}

/// Small helper for history labeling.
enum PasteEngineAppName {
    @MainActor
    static func frontmost() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    }
}

/// Sendable latch for progress closures noting a real network transfer.
final class NetworkFetchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
