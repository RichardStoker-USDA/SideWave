// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import AudioToolbox
import AVFAudio
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

// MARK: - Audio Device Manager

/// Lists the Mac's audio inputs and tracks the selected one. Follows plug and unplug and system
/// default changes, moves away from Bluetooth when it becomes the default, and returns to the
/// preferred device when it reappears.
@Observable
@MainActor
final class AudioDeviceManager {
    var availableDevices: [AudioInputDevice] = []
    var selectedDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(selectedDeviceUID, forKey: Self.defaultsKey)
        }
    }

    /// Returns the AudioInputDevice matching the persisted selection, or nil for system default.
    var selectedDevice: AudioInputDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return availableDevices.first(where: { $0.uid == uid })
    }

    /// The current default input, taken from `availableDevices` so its name and badges match the
    /// picker. Shown as "System Default · <device>".
    var resolvedDefaultDevice: AudioInputDevice? {
        availableDevices.first(where: { $0.isDefault })
    }

    /// Called when the manager auto-switches the device (e.g., Bluetooth failover, reconnect).
    /// Parameters: (deviceName: String, reason: String)
    var onDeviceAutoSwitched: ((String, String) -> Void)?

    /// Wired by AppState. Returns true when a dictation is active. The
    /// BT auto-override skips firing when true so it doesn't fight
    /// TranscriptionService's per-session redirect-and-bind.
    var isDictationActive: (() -> Bool)?

    /// UID of the last explicitly selected non-Bluetooth device.
    /// Used for reconnection when a USB/wired device reappears after being unplugged.
    var preferredDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: Self.preferredKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.preferredKey) }
    }

    private static let defaultsKey = "selectedAudioDeviceUID"
    private static let preferredKey = "preferredAudioDeviceUID"
    nonisolated static let warmingLock = NSLock()

    // Store listener block references for cleanup in deinit.
    @ObservationIgnored nonisolated(unsafe) var deviceListBlock: AudioObjectPropertyListenerBlock?
    let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    @ObservationIgnored nonisolated(unsafe) var defaultInputBlock: AudioObjectPropertyListenerBlock?
    let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    // Also watch the default output: Bluetooth headphones often take the input only during a call,
    // so the output is the better sign the user is wearing them. The override runs when either one
    // switches to Bluetooth.
    @ObservationIgnored nonisolated(unsafe) var defaultOutputBlock: AudioObjectPropertyListenerBlock?
    let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // Debounce for listener refreshes. CoreAudio sends bursts of notifications when several devices
    // change at once (hub re-enumeration, dock, sleep and wake).
    private var refreshScheduled: Bool = false
    private static let refreshDebounceMs: Int = 100

    // Device UIDs from the previous refresh, to detect the preferred device coming back. Without
    // it, every refresh, including the first at launch, would treat the preferred device as
    // reconnected.
    private var lastSeenDeviceUIDs: Set<String> = []
    private var hasSeenInitialDevices: Bool = false

    // When the user last changed the selection with the macOS default following it. The
    // default-input listener skips the Bluetooth override for about a second afterward, so choosing
    // a Bluetooth mic isn't immediately undone.
    private var lastUserDirectedSyncAt: TimeInterval = 0
    private static let userDirectedSyncSuppressionWindow: TimeInterval = 1.0

    // Delay for a second refresh after a default-input change. The property can briefly report the
    // old value, and the second read keeps the "(Default)" label right.
    private static let defaultChangedDeferredRefreshMs: Int = 250

    init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.defaultsKey)
        guard !AppPaths.isTestHost else { return }
        refreshDevices()
        installDeviceChangeListeners()
        installWakeNotification()

        // First run: if the priority list was never set and the built-in mic exists, add it, so the
        // Bluetooth override has a device to switch to.
        if UserDefaults.standard.object(forKey: Self.audioInputPriorityKey) == nil,
           let builtIn = availableDevices.first(where: {
               Self.deviceTransportType($0.id) == kAudioDeviceTransportTypeBuiltIn
           })
        {
            Self.setAudioInputPriorityUIDs([builtIn.uid])
        }

        // Linked mode at launch: apply a stored non-Bluetooth selection to the macOS default now,
        // so the first dictation doesn't need to redirect. Skipped in independent mode, with System
        // Default, and for Bluetooth selections, which the Bluetooth override would immediately
        // reverse.
        if Self.isSyncAppInputWithSystemEnabled,
           let uid = selectedDeviceUID,
           let device = availableDevices.first(where: { $0.uid == uid }),
           !device.isBluetooth
        {
            let currentDefault = Self.defaultInputDeviceID()
            if device.id != currentDefault {
                lastUserDirectedSyncAt = Date().timeIntervalSinceReferenceDate
                Self.setSystemDefaultInputDevice(device.id)
            }
        }

        // If macOS launched with a Bluetooth default and the override is on, switch the default
        // before anything reads it; otherwise use SideWave's own failover. After the linked-mode
        // sync above, the default is usually already non-Bluetooth.
        if !attemptBluetoothDefaultOverride(),
           selectedDeviceUID == nil && selectedDeviceIsBluetooth {
            performBluetoothFailover(silent: true)
        }
    }

    deinit {
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let block = deviceListBlock {
            var addr = deviceListAddress
            AudioObjectRemovePropertyListenerBlock(system, &addr, nil, block)
        }
        if let block = defaultInputBlock {
            var addr = defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(system, &addr, nil, block)
        }
        if let block = defaultOutputBlock {
            var addr = defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(system, &addr, nil, block)
        }
    }

    // MARK: - Device Enumeration

    func refreshDevices() {
        // External / explicit refreshes go through immediately. Listener-
        // triggered refreshes flow through scheduleDebouncedRefresh which
        // coalesces bursts.
        refreshScheduled = false
        performRefresh()
    }

    /// Collapses bursts of notifications into one refresh after refreshDebounceMs. Safe to call
    /// repeatedly.
    func scheduleDebouncedRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.refreshDebounceMs)) { [weak self] in
            guard let self else { return }
            if self.refreshScheduled {
                self.refreshScheduled = false
                self.performRefresh()
            }
        }
    }

    private func performRefresh() {
        let inputDevices = Self.enumerateInputDevices()
        let oldDevices = availableDevices
        availableDevices = inputDevices
        rememberInputNames(inputDevices)

        // Notify the engine when the set of devices changed (dock connect or disconnect, USB
        // re-enumeration after wake), so TranscriptionService rebuilds its kept engine. Wake
        // notifications alone miss this: dock devices can appear seconds later, and a dock can be
        // plugged in without sleeping.
        if Set(oldDevices.map(\.uid)) != Set(inputDevices.map(\.uid)) {
            NotificationCenter.default.post(name: .sideWaveAudioDeviceSetChanged, object: nil)
        }

        #if DEBUG
        let defID = Self.defaultInputDeviceID()
        let defName = inputDevices.first(where: { $0.id == defID })?.name ?? "<none>"
        SWLog.note("[AudioDeviceManager] Refreshed devices (\(inputDevices.count) input). Default ID=\(defID), name=\(defName)")
        #endif

        // Track UIDs between refreshes to detect a reconnect. The first refresh only records them,
        // so the picker isn't changed at launch.
        let newSeenUIDs = Set(inputDevices.map { $0.uid })
        let preferredJustReappeared: Bool
        if hasSeenInitialDevices {
            preferredJustReappeared = preferredDeviceUID.map { uid in
                !lastSeenDeviceUIDs.contains(uid) && newSeenUIDs.contains(uid)
            } ?? false
        } else {
            preferredJustReappeared = false
            hasSeenInitialDevices = true
        }
        lastSeenDeviceUIDs = newSeenUIDs

        // If the selected device is no longer available, try to reconnect or fall back
        if let uid = selectedDeviceUID,
           !inputDevices.contains(where: { $0.uid == uid })
        {
            // Stash as preferred if it was a non-Bluetooth device (for reconnection later)
            if let old = oldDevices.first(where: { $0.uid == uid }), !old.isBluetooth {
                preferredDeviceUID = uid
            }
            selectedDeviceUID = nil
            SWLog.note("[AudioDeviceManager] Selected device disappeared, falling back to system default")
        }

        // Switch back to the preferred device when it goes from missing to present (USB mic plugged
        // in, dock attached). Not at launch, and not when the macOS default already is the
        // preferred device.
        let currentDefaultUID = Self.deviceUID(Self.defaultInputDeviceID())
        if selectedDeviceUID == nil,
           preferredJustReappeared,
           let preferred = preferredDeviceUID,
           currentDefaultUID != preferred,
           let reconnected = inputDevices.first(where: { $0.uid == preferred }),
           !reconnected.isBluetooth
        {
            selectedDeviceUID = preferred
            onDeviceAutoSwitched?(reconnected.name, "reconnected")
            SWLog.note("[AudioDeviceManager] Preferred device reconnected: \(reconnected.name)")

            // Linked mode: also make it the macOS default, so the next dictation binds directly.
            // Not in independent mode or during dictation.
            if Self.isSyncAppInputWithSystemEnabled,
               !(isDictationActive?() ?? false)
            {
                lastUserDirectedSyncAt = Date().timeIntervalSinceReferenceDate
                Self.setSystemDefaultInputDevice(reconnected.id)
            }
        }
    }

    // MARK: - Bluetooth Failover

    func knownInputName(forUID uid: String) -> String? {
        availableDevices.first(where: { $0.uid == uid })?.name
            ?? (UserDefaults.standard.dictionary(forKey: "audioInputDeviceNames") as? [String: String])?[uid]
    }

    private func rememberInputNames(_ devices: [AudioInputDevice]) {
        let defaults = UserDefaults.standard
        let previous = defaults.dictionary(forKey: "audioInputDeviceNames") as? [String: String] ?? [:]
        let retained = Set(Self.audioInputPriorityUIDs() + [selectedDeviceUID, preferredDeviceUID].compactMap { $0 })
        var names = previous.filter { retained.contains($0.key) }
        for device in devices { names[device.uid] = device.name }
        if names != previous { defaults.set(names, forKey: "audioInputDeviceNames") }
    }

    /// Switch away from Bluetooth to the best non-Bluetooth alternative.
    /// Called automatically when system default changes to Bluetooth, or manually.
    func performBluetoothFailover(silent: Bool = false) {
        guard let alternative = recommendedNonBluetoothDevice else {
            SWLog.note("[AudioDeviceManager] Bluetooth failover: no non-Bluetooth alternative available")
            return
        }
        selectedDeviceUID = alternative.uid

        // Also remember this as the preferred device
        if !alternative.isBluetooth {
            preferredDeviceUID = alternative.uid
        }

        if !silent {
            onDeviceAutoSwitched?(alternative.name, "bluetooth_failover")
        }
        SWLog.note("[AudioDeviceManager] Bluetooth failover: switched to \(alternative.name)")
    }

    /// Aligns the macOS default with SideWave's selection right away, when the sync option is
    /// turned on. Skipped during dictation, when TranscriptionService manages the default, and with
    /// System Default.
    func syncMacOSDefaultToSelection() {
        guard let uid = selectedDeviceUID,
              let device = availableDevices.first(where: { $0.uid == uid }),
              !(isDictationActive?() ?? false)
        else { return }
        let currentDefault = Self.defaultInputDeviceID()
        guard device.id != currentDefault else { return }
        lastUserDirectedSyncAt = Date().timeIntervalSinceReferenceDate
        Self.setSystemDefaultInputDevice(device.id)
    }

    /// Called when the effective input changes (user choice or default sync). AppState rebinds mic
    /// standby so it keeps the device the next dictation will use awake.
    var onInputSelectionChanged: (() -> Void)?

    /// Brings SideWave's selection in line with the macOS default after an outside change (Sound
    /// settings, another app, the Bluetooth override), so the next dictation doesn't have to
    /// rebind. Skipped with System Default, which already follows it.
    private func syncSelectionFromMacOSDefault() {
        guard selectedDeviceUID != nil else { return }
        let currentDefaultID = Self.defaultInputDeviceID()
        guard currentDefaultID != 0,
              let currentDefaultUID = Self.deviceUID(currentDefaultID),
              currentDefaultUID != selectedDeviceUID
        else { return }

        selectedDeviceUID = currentDefaultUID
        defer { onInputSelectionChanged?() }
        if let device = availableDevices.first(where: { $0.uid == currentDefaultUID }),
           !device.isBluetooth
        {
            preferredDeviceUID = currentDefaultUID
        }
    }

    /// Called from every mic picker. Updates the selection and, in linked mode, the macOS default
    /// input, so dictation doesn't need to redirect.
    func userDidSelectDevice(_ uid: String?) {
        selectedDeviceUID = uid
        defer { onInputSelectionChanged?() }
        if let uid, let device = availableDevices.first(where: { $0.uid == uid }), !device.isBluetooth {
            preferredDeviceUID = uid
        }

        // Linked mode keeps the macOS default aligned with the selection, which avoids rebinding
        // the input unit at each start. Skipped for System Default, in independent mode, and during
        // dictation, when TranscriptionService manages the default.
        guard let uid,
              Self.isSyncAppInputWithSystemEnabled,
              !(isDictationActive?() ?? false),
              let device = availableDevices.first(where: { $0.uid == uid })
        else { return }

        // Note the time so the listener skips the Bluetooth override for this change; otherwise
        // choosing a Bluetooth mic would be reversed.
        lastUserDirectedSyncAt = Date().timeIntervalSinceReferenceDate
        Self.setSystemDefaultInputDevice(device.id)
    }

    // MARK: - Bluetooth Acknowledgment Tracking

    /// Per-UID set of Bluetooth devices the user has explicitly acknowledged
    /// using as a microphone. Stored in UserDefaults so the prompt only
    /// shows once per device, not on every selection.
    private static let acknowledgedKey = "acknowledgedBluetoothMicUIDs"

    private static func acknowledgedBluetoothUIDs() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: acknowledgedKey) ?? []
        return Set(array)
    }

    /// Whether the user already confirmed a Bluetooth device as their microphone, to decide whether
    /// the pickers ask again.
    static func hasAcknowledgedBluetoothMic(uid: String) -> Bool {
        acknowledgedBluetoothUIDs().contains(uid)
    }

    /// Record that the user has confirmed using this Bluetooth device as
    /// microphone input. Future picker selections of the same UID skip
    /// the confirmation prompt.
    static func acknowledgeBluetoothMic(uid: String) {
        var set = acknowledgedBluetoothUIDs()
        set.insert(uid)
        UserDefaults.standard.set(Array(set), forKey: acknowledgedKey)
    }

    // MARK: - Default Input Change Handling

    func handleDefaultInputChanged() {
        // CoreAudio can notify before the new default reads back. Refresh now, and again shortly
        // after, so the "(Default)" badge is right.
        performRefresh()
        if !isWithinUserDirectedSyncWindow {
            runDefaultChangedFailovers()
            syncSelectionIfLinkedAndIdle()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.defaultChangedDeferredRefreshMs)) { [weak self] in
            guard let self else { return }
            self.performRefresh()
            // Check the suppression window again for the delayed refresh.
            if !self.isWithinUserDirectedSyncWindow {
                self.runDefaultChangedFailovers()
                self.syncSelectionIfLinkedAndIdle()
            }
        }
    }

    /// Syncs the selection from the macOS default, only in linked mode and outside dictation:
    /// TranscriptionService changes the default during a session, and following it would overwrite
    /// the user's choice.
    private func syncSelectionIfLinkedAndIdle() {
        guard Self.isSyncAppInputWithSystemEnabled,
              !(isDictationActive?() ?? false)
        else { return }
        syncSelectionFromMacOSDefault()
    }

    private var isWithinUserDirectedSyncWindow: Bool {
        let elapsed = Date().timeIntervalSinceReferenceDate - lastUserDirectedSyncAt
        return elapsed >= 0 && elapsed < Self.userDirectedSyncSuppressionWindow
    }

    /// Failover when the macOS default input changes. First the system-wide override: walk the
    /// priority list and switch the macOS default per the auto-switch settings (Bluetooth mode, on
    /// by default, reacts to Bluetooth; Always mode, off by default, to any change). If that didn't
    /// act, the user is on System Default, and the new default is Bluetooth, fall back to
    /// SideWave's own failover.
    private func runDefaultChangedFailovers() {
        if attemptInputOverride() {
            return
        }
        guard selectedDeviceUID == nil else { return }
        if selectedDeviceIsBluetooth {
            performBluetoothFailover()
        }
    }

    /// Switches the macOS default input using the priority list, per the two auto-switch settings.
    /// Returns true if it did. Bluetooth detection checks the default output as well as the input,
    /// since many headphones only claim the input during a call; if the output is Bluetooth and the
    /// input is fine, it still moves the input to the preferred non-Bluetooth mic.
    @discardableResult
    private func attemptInputOverride() -> Bool {
        guard Self.isAnyInputOverrideEnabled else { return false }
        // Not during dictation; TranscriptionService manages the default for the session.
        if isDictationActive?() ?? false { return false }

        let currentDefault = Self.defaultInputDeviceID()
        guard currentDefault != 0 else { return false }
        let inputTransport = Self.deviceTransportType(currentDefault)
        let inputIsBT = inputTransport == kAudioDeviceTransportTypeBluetooth
            || inputTransport == kAudioDeviceTransportTypeBluetoothLE
        let outputIsBT = Self.isDefaultOutputBluetooth()
        let btDetected = inputIsBT || outputIsBT

        let alwaysMode = Self.isAlwaysOverrideInputEnabled
        // BT-only mode: skip when neither input nor output is BT.
        if !alwaysMode && !btDetected { return false }

        for uid in Self.audioInputPriorityUIDs() {
            guard let device = availableDevices.first(where: { $0.uid == uid }) else { continue }
            // BT-only mode: don't swap to another BT device, that's pointless.
            if !alwaysMode && device.isBluetooth { continue }
            // Already on this device; nothing to do.
            if device.id == currentDefault { return false }

            Self.setSystemDefaultInputDevice(device.id)
            let reason: String
            if alwaysMode {
                reason = "input_default_override"
            } else if inputIsBT {
                reason = "bt_input_default_override"
            } else {
                reason = "bt_output_default_override"
            }
            SWLog.note("[AudioDeviceManager] Input override (\(alwaysMode ? "always" : "bt-only"), inputBT=\(inputIsBT) outputBT=\(outputIsBT)): macOS default → \(device.name)")
            onDeviceAutoSwitched?(device.name, reason)
            return true
        }
        return false
    }

    @discardableResult
    private func attemptBluetoothDefaultOverride() -> Bool {
        attemptInputOverride()
    }

}
