// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import AudioToolbox
import AVFAudio
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

@MainActor
extension AudioDeviceManager {
    // MARK: - Device Change Observation

    /// Posted after a device refresh whenever the set of input-device UIDs
    /// actually changed. TranscriptionService rebuilds its kept engine on
    /// this signal (see the observer next to didWakeNotification there).
    static let deviceSetChangedNotification = Notification.Name.sideWaveAudioDeviceSetChanged

    func installDeviceChangeListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)

        // Listener 1: Device list changes (add/remove). Coalesce bursts
        // through the debounced refresh path so a USB hub re-enumeration
        // doesn't schedule 10+ sequential refreshes.
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.scheduleDebouncedRefresh()
            }
        }
        deviceListBlock = devBlock
        var devAddr = deviceListAddress
        AudioObjectAddPropertyListenerBlock(system, &devAddr, nil, devBlock)

        // Listener 2: System default input device changes (AirPods connect, user changes in System Settings)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleDefaultInputChanged()
            }
        }
        defaultInputBlock = defaultBlock
        var defAddr = defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(system, &defAddr, nil, defaultBlock)
        if status != noErr {
            SWLog.note("[AudioDeviceManager] Failed to install default input listener: \(status)")
        }

        // Default output changes: Bluetooth headphones often switch only the output, because the
        // hands-free profile starts when something uses the mic. Handled the same way as input
        // changes.
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleDefaultInputChanged()
            }
        }
        defaultOutputBlock = outputBlock
        var outAddr = defaultOutputAddress
        let outStatus = AudioObjectAddPropertyListenerBlock(system, &outAddr, nil, outputBlock)
        if outStatus != noErr {
            SWLog.note("[AudioDeviceManager] Failed to install default output listener: \(outStatus)")
        }
    }

    /// Proactive audio recovery after sleep/wake. Fires faster than the health check timer.
    func installWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            
            // Stage 1: Fast wake refresh after 0.8 seconds to capture fast USB/built-in device changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                SWLog.note("[AudioDeviceManager] Fast wake device refresh (Stage 1)")
                self?.refreshDevices()
            }
            
            // Stage 2: Thorough wake refresh after 1.5 seconds to capture slower Bluetooth/HFP route negotiations
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                SWLog.note("[AudioDeviceManager] Thorough wake device refresh (Stage 2)")
                self?.refreshDevices()
            }
        }
    }

    // MARK: - Device ID Lookup (for AudioUnit configuration)

    /// Resolve a persistent UID string to a CoreAudio AudioDeviceID.
    /// Enumerates all devices and matches by UID. Returns 0 if not found.
    nonisolated static func deviceIDForUID(_ uid: String) -> AudioDeviceID {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &devicesAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(systemObject, &devicesAddress, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return 0 }

        for deviceID in deviceIDs {
            if let devUID = self.deviceUID(deviceID), devUID == uid {
                return deviceID
            }
        }
        return 0
    }

    /// Verify the HAL route before accepting audio. A failed bind must not silently use another mic.
    nonisolated static func bindInput(_ input: AVAudioInputNode, to deviceID: AudioDeviceID) throws {
        guard deviceID != 0, let unit = input.audioUnit else {
            throw NSError(domain: "SideWave.AudioInput", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The selected microphone is unavailable. Reconnect it or choose another input."])
        }
        func currentDevice() -> AudioDeviceID? {
            var current: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &current, &size)
            return status == noErr ? current : nil
        }
        if currentDevice() == deviceID { return }
        let stopped = AudioUnitUninitialize(unit)
        var target = deviceID
        let bound = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))
        let initialized = AudioUnitInitialize(unit)
        guard stopped == noErr, bound == noErr, initialized == noErr, currentDevice() == deviceID else {
            let code = [stopped, bound, initialized].first(where: { $0 != noErr }) ?? -1
            throw NSError(domain: "SideWave.AudioInput", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "SideWave could not connect to the selected microphone. Reconnect it or choose another input, then test the microphone in Settings."])
        }
    }

    nonisolated static func isBluetoothInput(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - Channel Selection (per device UID)

    /// Key used to save a channel mode when no device is selected.
    nonisolated private static let systemDefaultChannelKey = "__system_default__"

    nonisolated private static func storageKey(forUID uid: String?) -> String {
        return uid ?? systemDefaultChannelKey
    }

    /// Channel mode for a device UID, `.auto` when unset. Nonisolated so ChannelSelector can read
    /// it on the audio thread.
    nonisolated static func channelMode(forUID uid: String?) -> ChannelMode {
        let key = "audioChannelMode_\(storageKey(forUID: uid))"
        let raw = UserDefaults.standard.string(forKey: key) ?? "auto"
        return ChannelMode(rawValue: raw) ?? .auto
    }

    nonisolated static func setChannelMode(_ mode: ChannelMode, forUID uid: String?) {
        let key = "audioChannelMode_\(storageKey(forUID: uid))"
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }

    /// Cached auto-detection result. 1-based channel index. Returns nil if
    /// no calibration has run yet for this device.
    nonisolated static func autoDetectedChannel(forUID uid: String?) -> Int? {
        let key = "audioChannelAutoDetected_\(storageKey(forUID: uid))"
        let val = UserDefaults.standard.integer(forKey: key)
        return val >= 1 ? val : nil
    }

    nonisolated static func setAutoDetectedChannel(_ channel: Int?, forUID uid: String?) {
        let key = "audioChannelAutoDetected_\(storageKey(forUID: uid))"
        if let channel, channel >= 1 {
            UserDefaults.standard.set(channel, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Clear the cached auto-detection so the next recording with this
    /// device runs calibration again. Called from the "Re-detect" button
    /// in Settings → Audio → Advanced.
    nonisolated static func resetAutoDetectedChannel(forUID uid: String?) {
        setAutoDetectedChannel(nil, forUID: uid)
    }

    // MARK: - Input Auto-Switch (per-user, two modes)
    // Two settings share one priority list:
    //
    // 1. "Bluetooth takes over" (on by default): when the default input or output becomes Bluetooth,
    //    switch the default input to the first available non-Bluetooth device in the list. The output
    //    counts because many headphones only claim the input during a call.
    // 2. "Always" (off by default): reapply the list on any default-input change. Covers Bluetooth too.

    nonisolated static let autoOverrideBluetoothInputKey = "autoOverrideBluetoothInputDefault"
    nonisolated static let alwaysOverrideInputKey = "alwaysOverrideInputDefault"
    nonisolated static let audioInputPriorityKey = "audioInputPriorityList"
    nonisolated static let syncAppInputWithSystemKey = "syncAppInputWithSystemDefault"

    /// True when SideWave should override the macOS default input
    /// whenever it becomes a Bluetooth device. Default ON.
    nonisolated static var isAutoOverrideBluetoothInputEnabled: Bool {
        if UserDefaults.standard.object(forKey: autoOverrideBluetoothInputKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: autoOverrideBluetoothInputKey)
    }

    nonisolated static func setAutoOverrideBluetoothInput(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoOverrideBluetoothInputKey)
    }

    /// Whether to override the macOS default input on every change, not only Bluetooth. Off by
    /// default, since most people with a fixed setup don't want their choice rewritten.
    nonisolated static var isAlwaysOverrideInputEnabled: Bool {
        UserDefaults.standard.bool(forKey: alwaysOverrideInputKey)
    }

    nonisolated static func setAlwaysOverrideInput(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: alwaysOverrideInputKey)
    }

    /// True when EITHER override mode is on. Used by the listener and
    /// init paths to decide whether to evaluate the override at all.
    nonisolated static var isAnyInputOverrideEnabled: Bool {
        isAutoOverrideBluetoothInputEnabled || isAlwaysOverrideInputEnabled
    }

    /// Whether SideWave's mic selection and the macOS default input stay in sync. On by default, so
    /// dictation doesn't need to switch the default and rebind at each start. Turned off in
    /// Settings by people who want SideWave on a different mic than the rest of macOS.
    nonisolated static var isSyncAppInputWithSystemEnabled: Bool {
        if UserDefaults.standard.object(forKey: syncAppInputWithSystemKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: syncAppInputWithSystemKey)
    }

    nonisolated static func setSyncAppInputWithSystem(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: syncAppInputWithSystemKey)
    }

    /// Ordered list of device UIDs the override should pick from when
    /// Bluetooth becomes the macOS default. The first one currently
    /// available wins. Empty list disables the override.
    nonisolated static func audioInputPriorityUIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: audioInputPriorityKey) ?? []
    }

    nonisolated static func setAudioInputPriorityUIDs(_ uids: [String]) {
        UserDefaults.standard.set(uids, forKey: audioInputPriorityKey)
    }

    /// Expose deviceTransportType for the Settings UI (formatting per-row
    /// transport badges in the priority list).
    nonisolated static func transportTypeForUID(_ uid: String) -> UInt32 {
        let id = deviceIDForUID(uid)
        guard id != 0 else { return 0 }
        return deviceTransportType(id)
    }
}
