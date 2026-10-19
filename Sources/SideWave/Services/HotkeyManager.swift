// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Carbon
import Foundation
import OSLog
import QuartzCore
import Synchronization

// Hotkey state tracing in debug builds; release builds use a disabled logger.
private let hotkeyTraceLog: Logger = {
    #if DEBUG
    return Logger(subsystem: "com.sidewave.dev", category: "hotkey-trace")
    #else
    return Logger(OSLog.disabled)
    #endif
}()

enum ActivationMode: String, CaseIterable, Identifiable {
    case toggle = "Toggle"
    case pushToTalk = "Push-to-Talk"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .toggle: return "Press to start, press again to stop"
        case .pushToTalk: return "Hold to record, release to paste"
        }
    }
}

// MARK: - Thread-Safe State

/// All state accessed from the nonisolated CGEvent callback is protected by a Mutex.
/// MainActor properties are mirrored here whenever they change.
private struct HotkeyStateData: @unchecked Sendable {
    // Mirrored from MainActor properties
    var shortcut: HotkeyShortcut = .defaultShortcut
    var activationMode: ActivationMode = .toggle
    var isRecording: Bool = false
    var isCapturingShortcut: Bool = false

    // CGEvent callback state
    var modifierOnlyKeyDown = false
    var otherKeyPressedDuringModifier = false
    var pendingHoldModeStart: Task<Void, Never>?
    var holdTickTask: Task<Void, Never>?

    // Double-tap to paste again (toggle mode). Time of the last clean activation. A second press is
    // compared against startPressDownTime while recording, or this while a start is in flight;
    // under doubleTapThreshold it pastes again.
    var lastActivationTime: CFTimeInterval = 0
    // No longer scheduled: starts are immediate, and double-tap detection uses press times. The
    // Escape handler still clears it.
    var pendingSinglePress: DispatchWorkItem?
    var singlePressGeneration: Int = 0

    // Hold to refine (toggle mode): the stop press is a tap or a hold depending on the time between
    // its key down and key up. A hold past the threshold sends the dictation through Refine
    // whatever the Refine setting.
    var stopPressDownTime: CFTimeInterval = 0

    // Smart Push-to-Talk: the press time of the start press. Holding past the threshold makes the
    // session push-to-talk, and release stops and pastes.
    var startPressDownTime: CFTimeInterval = 0
    // When AppState reported recording live. Push-to-talk is measured from here, not from the key
    // press, so engine startup time doesn't count toward the hold: a tap that lingers while the
    // overlay appears stays a toggle.
    var recordingConfirmedAt: CFTimeInterval = 0
    var isSmartPTTSession: Bool = false
    var smartPTTEnabled: Bool = true
    var holdToRewriteEnabled = false
    var refinementAvailable = false
    // Hold time past recording-live that makes a release push-to-talk. Copied here so the event tap
    // thread can read it.
    var smartPTTThreshold: CFTimeInterval = 0.25
}

// MARK: - HotkeyManager

@Observable
@MainActor
final class HotkeyManager {
    var isInitialized = false

    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    /// Escape during recording: soft stop (save text, don't paste, show pending card).
    var onSoftStop: (() -> Void)?
    var onRepaste: (() -> Void)?
    /// Fired instead of onStopRecording when the user HELD the hotkey at
    /// the end of a capture instead of tapping. Routes the capture through
    /// Refine even if the dashboard Refine toggle is off.
    var onStopRefinedRecording: (() -> Void)?
    /// Called when Return or keypad Enter is pressed while holding the hotkey. AppState cancels the
    /// recording without saving and shows a toast, and the key reaches the target app.
    var onCombinationCancel: (() -> Void)?

    /// Progress of the currently-forming hold gesture, 0.0 → 1.0, written
    /// from the CGEvent callback via MainActor. Nil when no hold is in
    /// progress. The overlay observes this to render its hold-ring.
    var holdProgress: Double? = nil

    /// The Task driving the hold-progress animation. Stored so it can be
    // holdTickTask moved into HotkeyStateData behind the Mutex to
    // eliminate the data race between CGEvent callback and MainActor.

    /// Double-tap window: second press within 300ms triggers re-paste instead of new dictation.
    /// Lower bound of 50ms filters out key autorepeat events.
    private let doubleTapThreshold: CFTimeInterval = 0.3

    /// Duration the hotkey must be held on a STOP press to trigger Refine
    /// instead of a plain send. Tuned to match Apple's long-press timing.
    nonisolated static let holdRewriteThreshold: CFTimeInterval = 0.5

    nonisolated static func shouldRewriteOnStop(enabled: Bool, heldFor: CFTimeInterval) -> Bool {
        enabled && heldFor.isFinite && heldFor >= holdRewriteThreshold
    }

    var holdToRewriteEnabled = UserDefaults.standard.bool(forKey: "holdToRewriteEnabled") {
        didSet {
            UserDefaults.standard.set(holdToRewriteEnabled, forKey: "holdToRewriteEnabled")
            state.withLock { $0.holdToRewriteEnabled = holdToRewriteEnabled }
        }
    }

    /// Runtime availability does not overwrite the user's gesture preference.
    var refinementAvailable = false {
        didSet { state.withLock { $0.refinementAvailable = refinementAvailable } }
    }

    /// Default hold time past recording-live for push-to-talk. 500 ms matches Apple's long-press
    /// timing: relaxed taps stay under it, and a real hold-and-speak can't finish a word sooner.
    /// 250 ms counted slow taps as push-to-talk, ending the session on release. Adjustable in
    /// Settings > Advanced.
    static let smartPTTThresholdDefault: CFTimeInterval = 0.5
    static let smartPTTThresholdMin: CFTimeInterval = 0.15
    static let smartPTTThresholdMax: CFTimeInterval = 1.0
    static let smartPTTThresholdKey = "smartPTTThresholdSeconds"

    /// The push-to-talk rule, shared by the release handler and the "Release to send" hint so they
    /// always agree. The hold is measured from when recording went live, not key down, because waiting
    /// for a slow engine isn't a deliberate hold:
    /// - A relaxed 300 to 450 ms tap on a warm engine stays a toggle.
    /// - Releasing during a slow start never triggers push-to-talk; the session continues as a toggle.
    /// - Push-to-talk still triggers as soon as a hold reaches the threshold past live.
    nonisolated static func smartPTTHoldSatisfied(
        now: CFTimeInterval,
        pressDown: CFTimeInterval,
        engineLiveAt: CFTimeInterval,
        threshold: CFTimeInterval
    ) -> Bool {
        guard pressDown > 0, engineLiveAt > 0 else { return false }
        return now - max(pressDown, engineLiveAt) >= threshold
    }

    /// The push-to-talk threshold, stored in UserDefaults and copied into the locked state for the
    /// event tap thread. Clamped on every write.
    var smartPTTThreshold: CFTimeInterval = {
        let stored = UserDefaults.standard.object(forKey: HotkeyManager.smartPTTThresholdKey) as? Double
        let value = stored ?? HotkeyManager.smartPTTThresholdDefault
        return min(max(value, HotkeyManager.smartPTTThresholdMin), HotkeyManager.smartPTTThresholdMax)
    }() {
        didSet {
            let clamped = min(max(smartPTTThreshold, Self.smartPTTThresholdMin), Self.smartPTTThresholdMax)
            if clamped != smartPTTThreshold {
                smartPTTThreshold = clamped
                return
            }
            UserDefaults.standard.set(smartPTTThreshold, forKey: Self.smartPTTThresholdKey)
            state.withLock { $0.smartPTTThreshold = smartPTTThreshold }
        }
    }

    /// Whether smart PTT is enabled (on by default, user can toggle).
    var smartPTTEnabled: Bool = {
        UserDefaults.standard.object(forKey: "smartPushToTalkEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "smartPushToTalkEnabled")
    }() {
        didSet {
            UserDefaults.standard.set(smartPTTEnabled, forKey: "smartPushToTalkEnabled")
            state.withLock { $0.smartPTTEnabled = smartPTTEnabled }
        }
    }

    /// True when the current recording session is in smart PTT mode.
    var isSmartPTTActive: Bool {
        state.withLock { $0.isSmartPTTSession }
    }

    /// True while a start press is held past the threshold, so the overlay and dashboard show
    /// "Release to send". Reset on release, cancel, or when the start phase ends.
    var isSmartPTTHolding: Bool = false

    /// Sets `isSmartPTTHolding` once the threshold passes during a start-press hold. Cancelled on
    /// release, cancel, or when the press becomes a stop press.
    private var smartPTTHoldDetectTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupGeneration = UUID()

    /// Visual delay before the ring appears. Quick taps under this threshold
    /// never show the ring at all. When the ring does appear after this delay
    /// it renders already partially filled (the timer started earlier).
    private let holdVisualDelay: CFTimeInterval = 0.15

    // nonisolated(unsafe) so deinit can access these for cleanup.
    // Only ever written/read from MainActor; deinit has no concurrent access.
    @ObservationIgnored nonisolated(unsafe) private var eventTap: CFMachPort?
    @ObservationIgnored nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored nonisolated(unsafe) private var healthCheckTask: Task<Void, Never>?

    /// Thread-safe state container for CGEvent callback access
    private let state = Mutex(HotkeyStateData())

    init() {
        // Copy the saved push-to-talk settings into the locked state; didSet only runs on later
        // writes.
        state.withLock {
            $0.holdToRewriteEnabled = holdToRewriteEnabled
            $0.refinementAvailable = refinementAvailable
            $0.smartPTTEnabled = smartPTTEnabled
            $0.smartPTTThreshold = smartPTTThreshold
        }
    }

    // If the manager is released while the event tap is active, remove the tap and run loop source.
    // Nothing else can reference it at this point.
    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        healthCheckTask?.cancel()
    }

    // MARK: - Public API

    /// Cancel any in-flight hold-to-refine tick Task and reset all hold
    /// state. Called from every recording-stop path in AppState so the tick
    /// Task can never outlive the recording session it belongs to.
    func cancelHoldTracking() {
        state.withLock {
            $0.holdTickTask?.cancel()
            $0.holdTickTask = nil
            $0.stopPressDownTime = 0
            $0.startPressDownTime = 0
            $0.isSmartPTTSession = false
        }
        holdProgress = nil
        smartPTTHoldDetectTask?.cancel()
        smartPTTHoldDetectTask = nil
        isSmartPTTHolding = false
    }

    var shortcut: HotkeyShortcut {
        get { state.withLock { $0.shortcut } }
        set { state.withLock { $0.shortcut = newValue } }
    }

    var activationMode: ActivationMode {
        get { state.withLock { $0.activationMode } }
        set { state.withLock { $0.activationMode = newValue } }
    }

    var isRecording: Bool {
        get { state.withLock { $0.isRecording } }
        set {
            // This copy lets the event tap ignore a repeated start immediately. It doesn't mean the
            // engine is live; that's recordingConfirmedAt, set by AppState, so push-to-talk can't
            // trigger in the gap between accepting the press and capturing audio.
            state.withLock { $0.isRecording = newValue }
            hotkeyTraceLog.notice("set isRecording=\(newValue, privacy: .public)")
            if !newValue {
                clearEngineLive()
            }
        }
    }

    /// Called by AppState when recording is live. Push-to-talk requires the engine to be running,
    /// so a short tap during startup isn't treated as a hold (which would stop the session right
    /// after it started). Also shows "Release to send" right away if the user is already holding
    /// past the threshold.
    func confirmEngineLive() {
        let timestamp = CACurrentMediaTime()
        state.withLock { $0.recordingConfirmedAt = timestamp }
        hotkeyTraceLog.notice("confirmEngineLive at=\(timestamp, format: .fixed(precision: 3), privacy: .public)")

        // Schedule the "Release to send" hint, which only this code sets. The hold counts from
        // engine-live, so the hint can't become true before the threshold from now; an earlier
        // timer showed the hint on taps that turned out to be toggles.
        let threshold = smartPTTThreshold
        let keyStillDown = state.withLock {
            $0.modifierOnlyKeyDown && $0.smartPTTEnabled && $0.isRecording && $0.startPressDownTime > 0
        }
        guard keyStillDown else { return }

        smartPTTHoldDetectTask?.cancel()
        let box = TaskBox<Void, Never>()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let satisfied = self.state.withLock { s in
                s.modifierOnlyKeyDown && s.smartPTTEnabled && s.isRecording
                    && Self.smartPTTHoldSatisfied(
                        now: CACurrentMediaTime(),
                        pressDown: s.startPressDownTime,
                        engineLiveAt: s.recordingConfirmedAt,
                        threshold: s.smartPTTThreshold
                    )
            }
            if satisfied {
                self.isSmartPTTHolding = true
            }
            if self.smartPTTHoldDetectTask == box.task {
                self.smartPTTHoldDetectTask = nil
            }
        }
        box.task = task
        smartPTTHoldDetectTask = task
    }

    /// Called by AppState when the recording session ends (clean stop or
    /// engine failure). Cancels the smart-PTT hint timer and clears the
    /// confirmation timestamp so a stale value can't gate the next press.
    func clearEngineLive() {
        state.withLock { $0.recordingConfirmedAt = 0 }
        smartPTTHoldDetectTask?.cancel()
        smartPTTHoldDetectTask = nil
        if isSmartPTTHolding {
            isSmartPTTHolding = false
        }
        hotkeyTraceLog.notice("clearEngineLive")
    }

    /// When true, the event tap passes all key events through without
    /// intercepting them. Set by the hotkey recorder UI so the user
    /// can press the hotkey without triggering dictation.
    var isCapturingShortcut: Bool {
        get { state.withLock { $0.isCapturingShortcut } }
        set { state.withLock { $0.isCapturingShortcut = newValue } }
    }

    func start() {
        guard !isInitialized, startupTask == nil else { return }
        let generation = UUID()
        startupGeneration = generation
        startupTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) }
            catch { return }
            guard let self, self.startupGeneration == generation else { return }
            defer { if self.startupGeneration == generation { self.startupTask = nil } }
            await self.setupWithRetry()
            guard !Task.isCancelled, self.startupGeneration == generation else { return }
            self.startHealthCheck()
        }
    }

    func stop() {
        startupGeneration = UUID()
        startupTask?.cancel()
        startupTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        cleanupEventTap()
        isInitialized = false
    }

    func updateShortcut(_ newShortcut: HotkeyShortcut) {
        shortcut = newShortcut
    }

    func updateActivationMode(_ mode: ActivationMode) {
        activationMode = mode
    }

    // MARK: - Event Tap Setup

    private func setupWithRetry() async {
        var attempts = 0
        let maxAttempts = 5

        while attempts < maxAttempts {
            guard !Task.isCancelled else { return }
            if setupGlobalHotkey() {
                isInitialized = true
                SWLog.note("[HotkeyManager] Event tap created on attempt \(attempts + 1)")
                return
            }
            attempts += 1
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }
        }

        SWLog.note("[HotkeyManager] Failed to create event tap after \(maxAttempts) attempts")
        isInitialized = false
    }

    @discardableResult
    private func setupGlobalHotkey() -> Bool {
        cleanupEventTap()

        guard AXIsProcessTrusted() else {
            SWLog.note("[HotkeyManager] Accessibility not granted")
            return false
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleKeyEvent(type: type, event: event)
            },
            userInfo: refcon
        )

        guard let tap = eventTap else {
            SWLog.note("[HotkeyManager] CGEvent.tapCreate failed")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = runLoopSource else {
            SWLog.note("[HotkeyManager] CFRunLoopSource creation failed")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        guard isEventTapEnabled() else {
            SWLog.note("[HotkeyManager] Event tap could not be enabled")
            cleanupEventTap()
            return false
        }

        return true
    }

    private func cleanupEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func isEventTapEnabled() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    guard let self else { return }
                    if !self.validateEventTapHealth() {
                        SWLog.note("[HotkeyManager] Health check failed, recovering")
                        if self.setupGlobalHotkey() {
                            self.isInitialized = true
                        } else {
                            self.isInitialized = false
                        }
                    }
                }
            }
        }
    }

    private func validateEventTapHealth() -> Bool {
        guard let tap = eventTap else { return false }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }
        return true
    }

    // MARK: - Key Event Handling (nonisolated -- runs on CGEvent callback thread)

    /// Reads `shortcut`, `activationMode`, and `isRecording` through `state.withLock`, never
    /// main-actor storage, since this runs on the event tap thread.
    private nonisolated func handleKeyEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let self, let tap = self.eventTap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Pass through all events when the hotkey recorder UI is active
        if state.withLock({ $0.isCapturingShortcut }) {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Escape during recording: soft stop (Esc) or hard cancel (Ctrl+Esc)
        if type == .keyDown && keyCode == 53 {
            let recording = state.withLock { $0.isRecording }
            if recording {
                if flags.contains(.maskControl) {
                    // Ctrl+Escape: hard cancel (discard text)
                    DispatchQueue.main.async { [weak self] in
                        self?.onCancelRecording?()
                    }
                } else {
                    // Plain Escape: soft stop (save text, don't paste)
                    DispatchQueue.main.async { [weak self] in
                        self?.onSoftStop?()
                    }
                }
                return nil
            }
            // Cancel any pending single-press waiting for double-tap window to expire
            state.withLock {
                $0.singlePressGeneration += 1 // invalidate any pending
                $0.pendingSinglePress?.cancel()
                $0.pendingSinglePress = nil
            }
            return Unmanaged.passUnretained(event)
        }

        let targetShortcut = state.withLock { $0.shortcut }
        let targetMode = state.withLock { $0.activationMode }

        if targetShortcut.isModifierOnly {
            return handleModifierOnlyKey(
                type: type, keyCode: keyCode, flags: flags, event: event,
                targetShortcut: targetShortcut, targetMode: targetMode
            )
        }

        return handleRegularKey(
            type: type, keyCode: keyCode, flags: flags, event: event,
            targetShortcut: targetShortcut, targetMode: targetMode
        )
    }

    private nonisolated func handleModifierOnlyKey(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        event: CGEvent,
        targetShortcut: HotkeyShortcut,
        targetMode: ActivationMode
    ) -> Unmanaged<CGEvent>? {
        // Not our modifier's flagsChanged: check for another key pressed while the modifier is
        // held.
        guard type == .flagsChanged && keyCode == targetShortcut.keyCode else {
            if type == .keyDown {
                let now = CACurrentMediaTime()
                let snapshot = state.withLock { s -> (held: Bool, comboGracePeriod: Bool) in
                    let held = s.modifierOnlyKeyDown
                    if held {
                        s.otherKeyPressedDuringModifier = true
                        s.pendingHoldModeStart?.cancel()
                        s.pendingHoldModeStart = nil
                        // Clear stopPressDownTime right away so a running hold timer sees no held
                        // press and exits before it can trigger hold to refine. The rest of the
                        // cleanup runs in cancelHoldTracking on main.
                        s.stopPressDownTime = 0
                    }
                    // True if the modifier went down less than 500 ms ago. Engine startup is now
                    // under 100 ms, so checking engine-live no longer separates the cases; time
                    // does: a quick combination cancels, a slower one is the target app's own
                    // shortcut during dictation.
                    let pressTime = s.startPressDownTime
                    let withinGrace = pressTime > 0 && (now - pressTime) < 0.5
                    return (held, withinGrace)
                }
                // Modifier plus Return, two cases:
                //
                // 1. Quick combination (modifier down under 500 ms ago): the user meant the app's shortcut, not
                //    dictation. Cancel the start so the overlay goes away and let Return through.
                //    onCombinationCancel is safe to call before the engine starts.
                //
                // 2. During dictation (over 500 ms): the user is using the app's shortcut (Terminal new line, chat
                //    send). Keep dictating, but clear hold tracking so neither hold to refine nor push-to-talk
                //    triggers. Return passes through.
                if snapshot.held && (keyCode == 36 || keyCode == 76) {
                    if snapshot.comboGracePeriod {
                        DispatchQueue.main.async { [weak self] in
                            self?.onCombinationCancel?()
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            self?.cancelHoldTracking()
                        }
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let isModifierDown = isTargetModifierPressed(keyCode: keyCode, flags: flags)

        if isModifierDown {
            let wasRecording = state.withLock {
                $0.modifierOnlyKeyDown = true
                $0.otherKeyPressedDuringModifier = false
                return $0.isRecording
            }
            let pressTime = CACurrentMediaTime()

            if targetMode == .pushToTalk {
                let box = TaskBox<Void, Never>()
                let task = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms combo detection
                    guard let self, !Task.isCancelled else { return }
                    let shouldStart = self.state.withLock {
                        $0.modifierOnlyKeyDown && !$0.otherKeyPressedDuringModifier
                    }
                    let recording = self.state.withLock { $0.isRecording }
                    if shouldStart && !recording {
                        self.onStartRecording?()
                    }
                    self.state.withLock {
                        if $0.pendingHoldModeStart == box.task {
                            $0.pendingHoldModeStart = nil
                        }
                    }
                }
                box.task = task
                state.withLock { $0.pendingHoldModeStart = task }
            } else if wasRecording {
                // Double-tap detection: if the start press happened < 300ms ago,
                // cancel the in-flight session and re-paste the last dictation.
                let startTime = state.withLock { $0.startPressDownTime }
                if startTime > 0 && (pressTime - startTime) < doubleTapThreshold {
                    hotkeyTraceLog.notice("DOWN branch=double-tap-recording press=\(pressTime, format: .fixed(precision: 3), privacy: .public) startTime=\(startTime, format: .fixed(precision: 3), privacy: .public) gap=\((pressTime - startTime) * 1000, format: .fixed(precision: 0), privacy: .public)ms")
                    state.withLock { $0.startPressDownTime = 0 }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onCancelRecording?()
                        self.onRepaste?()
                    }
                    return nil
                }
                hotkeyTraceLog.notice("DOWN branch=stop-press press=\(pressTime, format: .fixed(precision: 3), privacy: .public)")

                // Toggle mode while recording: this is a stop press. Clear startPressDownTime so
                // its release isn't read as push-to-talk, and start timing the hold for hold to
                // refine.
                state.withLock {
                    $0.stopPressDownTime = pressTime
                    $0.startPressDownTime = 0
                }
                guard state.withLock({ $0.holdToRewriteEnabled && $0.refinementAvailable }) else {
                    return Unmanaged.passUnretained(event)
                }
                let thresholdSeconds = Self.holdRewriteThreshold
                let visualDelay = holdVisualDelay

                // Cancel any prior tick Task (shouldn't exist, but defensive).
                self.state.withLock { $0.holdTickTask?.cancel() }

                let newTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let tickInterval: UInt64 = 30_000_000 // 30ms

                    while !Task.isCancelled {
                        let held = self.state.withLock { $0.stopPressDownTime } > 0
                        guard held else {
                            self.holdProgress = nil
                            return
                        }

                        let elapsed = CACurrentMediaTime() - pressTime

                        // Delayed appearance: don't show anything for the
                        // first ~150ms so quick taps never flash the ring.
                        if elapsed < visualDelay {
                            // holdProgress stays nil; ring is hidden
                        } else {
                            self.holdProgress = min(1.0, elapsed / thresholdSeconds)
                        }

                        if elapsed >= thresholdSeconds {
                            // The completed ring arms a rewrite. Release commits it.
                            self.holdProgress = 1.0
                            return
                        }

                        try? await Task.sleep(nanoseconds: tickInterval)
                    }
                }
                self.state.withLock { $0.holdTickTask = newTask }
            } else {
                // Toggle mode while not recording: this is a start press. Recording starts on key
                // down so the first words aren't lost. The press time is used for push-to-talk on
                // release and for double-tap.
                let prevStart = state.withLock { $0.startPressDownTime }
                let isRecentDoubleTap = prevStart > 0
                    && (pressTime - prevStart) < doubleTapThreshold

                if isRecentDoubleTap {
                    // Race-safe double-tap: if the previous start press was
                    // very recent, the local isRecording mirror may not have
                    // caught up yet. Treat this as a double-tap re-paste.
                    hotkeyTraceLog.notice("DOWN branch=double-tap-race press=\(pressTime, format: .fixed(precision: 3), privacy: .public) prevStart=\(prevStart, format: .fixed(precision: 3), privacy: .public) gap=\((pressTime - prevStart) * 1000, format: .fixed(precision: 0), privacy: .public)ms")
                    state.withLock { $0.startPressDownTime = 0 }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onCancelRecording?()
                        self.onRepaste?()
                    }
                } else {
                    hotkeyTraceLog.notice("DOWN branch=start-press press=\(pressTime, format: .fixed(precision: 3), privacy: .public)")
                    state.withLock {
                        $0.startPressDownTime = pressTime
                        $0.isSmartPTTSession = false
                        $0.lastActivationTime = pressTime
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.onStartRecording?()
                    }
                    // The "Release to send" hint is armed by confirmEngineLive
                    // (its only owner), because the smart-PTT hold clock starts
                    // at engine-live, not at this press.
                }
            }

            return Unmanaged.passUnretained(event)
        } else {
            // Modifier released
            let wasCleanPress = state.withLock {
                let clean = $0.modifierOnlyKeyDown && !$0.otherKeyPressedDuringModifier
                $0.modifierOnlyKeyDown = false
                $0.otherKeyPressedDuringModifier = false
                $0.pendingHoldModeStart?.cancel()
                $0.pendingHoldModeStart = nil
                return clean
            }

            // The hold is over: clear the push-to-talk hint and cancel its timer if it hadn't
            // fired.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.smartPTTHoldDetectTask?.cancel()
                self.smartPTTHoldDetectTask = nil
                if self.isSmartPTTHolding {
                    self.isSmartPTTHolding = false
                }
            }

            if targetMode == .pushToTalk {
                let recording = state.withLock { $0.isRecording }
                if recording {
                    DispatchQueue.main.async { [weak self] in
                        self?.onStopRecording?()
                    }
                }
            } else if wasCleanPress {
                let recording = state.withLock { $0.isRecording }
                if recording {
                    let now = CACurrentMediaTime()
                    let snapshot = state.withLock { s -> (stop: CFTimeInterval, confirmed: CFTimeInterval, ptt: Bool, threshold: CFTimeInterval, start: CFTimeInterval) in
                        return (s.stopPressDownTime, s.recordingConfirmedAt, s.smartPTTEnabled, s.smartPTTThreshold, s.startPressDownTime)
                    }
                    let confirmedAge = snapshot.confirmed > 0 ? (now - snapshot.confirmed) * 1000 : -1
                    let pressAge = snapshot.start > 0 ? (now - snapshot.start) * 1000 : -1

                    // Claim the stop press (clear stopPressDownTime only if still set) so this
                    // release and the hold timer can't both stop. If the timer already fired, this
                    // returns false.
                    let claimedStop = state.withLock { s -> Bool in
                        guard s.stopPressDownTime > 0 else { return false }
                        s.stopPressDownTime = 0
                        s.lastActivationTime = 0
                        return true
                    }
                    if claimedStop {
                        hotkeyTraceLog.notice("UP branch=stop-release recording=true now=\(now, format: .fixed(precision: 3), privacy: .public) stopPress=\(snapshot.stop, format: .fixed(precision: 3), privacy: .public)")
                        // Stop-press release; this path won the claim. Plain stop,
                        // fire onStopRecording.
                        let rewrite = Self.shouldRewriteOnStop(
                            enabled: state.withLock { $0.holdToRewriteEnabled && $0.refinementAvailable }, heldFor: now - snapshot.stop)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.cancelHoldTracking()
                            if rewrite { self.onStopRefinedRecording?() }
                            else { self.onStopRecording?() }
                        }
                    } else if snapshot.ptt
                        && Self.smartPTTHoldSatisfied(
                            now: now,
                            pressDown: snapshot.start,
                            engineLiveAt: snapshot.confirmed,
                            threshold: snapshot.threshold
                        )
                    {
                        hotkeyTraceLog.notice("UP branch=smart-ptt-FIRED confirmedAge=\(confirmedAge, format: .fixed(precision: 0), privacy: .public)ms pressAge=\(pressAge, format: .fixed(precision: 0), privacy: .public)ms threshold=\(snapshot.threshold * 1000, format: .fixed(precision: 0), privacy: .public)ms ptt=\(snapshot.ptt, privacy: .public)")
                        // Start-press release past the threshold: push-to-talk stops and pastes
                        // (AppState decides whether to refine). cancelHoldTracking() isn't called
                        // because it would clear isSmartPTTSession before onStopRecording reads it.
                        state.withLock {
                            $0.startPressDownTime = 0
                            $0.isSmartPTTSession = true
                            $0.lastActivationTime = 0
                        }
                        DispatchQueue.main.async { [weak self] in
                            self?.onStopRecording?()
                        }
                    } else {
                        hotkeyTraceLog.notice("UP branch=quick-toggle-no-op confirmedAge=\(confirmedAge, format: .fixed(precision: 0), privacy: .public)ms pressAge=\(pressAge, format: .fixed(precision: 0), privacy: .public)ms threshold=\(snapshot.threshold * 1000, format: .fixed(precision: 0), privacy: .public)ms ptt=\(snapshot.ptt, privacy: .public)")
                    }
                    // A quick toggle release, or hold to refine already fired: nothing to do. Keep
                    // startPressDownTime for double-tap detection.
                } else {
                    hotkeyTraceLog.notice("UP branch=external-stop-cleanup recording=false")
                    // Recording stopped elsewhere (Escape, audio health) while the key was held.
                    // Reset so the next press starts fresh.
                    state.withLock {
                        $0.startPressDownTime = 0
                        $0.isSmartPTTSession = false
                        $0.lastActivationTime = 0
                    }
                }
            }

            return Unmanaged.passUnretained(event)
        }
    }

    private nonisolated func handleRegularKey(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        event: CGEvent,
        targetShortcut: HotkeyShortcut,
        targetMode: ActivationMode
    ) -> Unmanaged<CGEvent>? {
        guard keyCode == targetShortcut.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Check modifier flags match
        if !targetShortcut.modifierFlags.isEmpty {
            let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            let relevant = nsFlags.intersection([.command, .option, .control, .shift])
            guard relevant == targetShortcut.modifierFlags else {
                return Unmanaged.passUnretained(event)
            }
        }

        if targetMode == .pushToTalk {
            if type == .keyDown {
                let recording = state.withLock { $0.isRecording }
                if !recording {
                    DispatchQueue.main.async { [weak self] in self?.onStartRecording?() }
                }
            } else if type == .keyUp {
                let recording = state.withLock { $0.isRecording }
                if recording {
                    DispatchQueue.main.async { [weak self] in self?.onStopRecording?() }
                }
            }
        } else {
            if type == .keyDown {
                // Filter autorepeat so held keys don't trigger double-tap
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat { return Unmanaged.passUnretained(event) }

                let recording = state.withLock { $0.isRecording }
                let pressTime = CACurrentMediaTime()
                if recording {
                    // Stop press: check double-tap, otherwise plain stop.
                    let startTime = state.withLock { $0.startPressDownTime }
                    if startTime > 0 && (pressTime - startTime) < doubleTapThreshold {
                        state.withLock { $0.startPressDownTime = 0 }
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.onCancelRecording?()
                            self.onRepaste?()
                        }
                    } else {
                        state.withLock {
                            $0.startPressDownTime = 0
                            $0.lastActivationTime = 0
                        }
                        DispatchQueue.main.async { [weak self] in
                            self?.onStopRecording?()
                        }
                    }
                } else {
                    // Start press: instant start, capture time for smart PTT.
                    state.withLock {
                        $0.startPressDownTime = pressTime
                        $0.isSmartPTTSession = false
                        $0.lastActivationTime = pressTime
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.onStartRecording?()
                    }
                }
            } else if type == .keyUp {
                // Push-to-talk if recording has been live past the threshold at release, measured
                // from recording-confirmed, not key down.
                let now = CACurrentMediaTime()
                let snapshot = state.withLock { s -> (recording: Bool, confirmed: CFTimeInterval, ptt: Bool, threshold: CFTimeInterval, start: CFTimeInterval) in
                    return (s.isRecording, s.recordingConfirmedAt, s.smartPTTEnabled, s.smartPTTThreshold, s.startPressDownTime)
                }
                if snapshot.recording
                    && snapshot.ptt
                    && snapshot.confirmed > 0
                    && snapshot.start > 0
                    && (now - snapshot.start) >= snapshot.threshold
                {
                    state.withLock {
                        $0.startPressDownTime = 0
                        $0.isSmartPTTSession = true
                        $0.lastActivationTime = 0
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.onStopRecording?()
                    }
                }
            }
        }

        return nil // consume
    }

    private nonisolated func isTargetModifierPressed(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 58, 61: return flags.contains(.maskAlternate)
        case 55, 54: return flags.contains(.maskCommand)
        case 59, 62: return flags.contains(.maskControl)
        case 56, 60: return flags.contains(.maskShift)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }
}
