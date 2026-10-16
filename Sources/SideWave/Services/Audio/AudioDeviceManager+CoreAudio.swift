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
    // MARK: - CoreAudio Enumeration (static, nonisolated)

    /// Enumerate all audio input devices using CoreAudio property queries.
    nonisolated static func enumerateInputDevices() -> [AudioInputDevice] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        // Get all audio device IDs
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &devicesAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(systemObject, &devicesAddress, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }

        // Get default input device for comparison
        let defaultInputID = defaultInputDeviceID()

        // Filter to input-capable devices and build models
        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            let transport = deviceTransportType(deviceID)
            if transport == kAudioDeviceTransportTypeAggregate, isPrivateAggregate(deviceID) { continue }
            let channelCount = inputChannelCount(deviceID)
            guard channelCount > 0 else { continue }
            guard let uid = deviceUID(deviceID) else { continue }
            let name = deviceName(deviceID) ?? "Unknown Device"
            let isDefault = (deviceID == defaultInputID)
            result.append(AudioInputDevice(
                id: deviceID, uid: uid, name: name,
                isDefault: isDefault, transportType: transport,
                channelCount: channelCount
            ))
        }
        return result
    }

    /// AVAudioEngine creates temporary aggregates that are not user-selectable inputs.
    nonisolated private static func isPrivateAggregate(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var composition: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &composition) == noErr,
              let composition else { return false }
        let properties = composition.takeRetainedValue() as NSDictionary
        return (properties[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    /// Returns the total number of input channels for a device, summed
    /// across all input streams. 0 if the device has no input or the
    /// stream configuration query fails.
    nonisolated private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: Int(dataSize) / MemoryLayout<AudioBufferList>.stride + 1
        )
        defer { bufferListPointer.deallocate() }

        var mutableSize = dataSize
        let getStatus = AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &mutableSize, bufferListPointer)
        guard getStatus == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var totalChannels: UInt32 = 0
        for buffer in bufferList {
            totalChannels += buffer.mNumberChannels
        }
        return Int(totalChannels)
    }

    /// Get the persistent UID string for a device.
    nonisolated static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>? = nil
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &dataSize, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Get human-readable device name.
    nonisolated private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>? = nil
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &dataSize, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Get the system's current default input device ID.
    nonisolated static func defaultInputDeviceID() -> AudioDeviceID {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr else { return 0 }
        return deviceID
    }

    /// Wakes a device's CoreAudio state so the next engine start reads its format on the first try.
    /// A cold device makes setup retry in 100 ms steps, adding 200 to 500 ms (more for Bluetooth)
    /// to the first press. Reads several properties (format, transport, configuration, sample
    /// rates), as the Sound settings pane does when it opens; one property isn't enough.
    nonisolated static func warmInputDeviceHAL(_ deviceID: AudioDeviceID) {
        guard deviceID != 0 else { return }

        // 1. Stream format on the input scope — what AVAudioEngine reads.
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioObjectGetPropertyData(deviceID, &fmtAddr, 0, nil, &fmtSize, &format)

        // 2. Transport type (built-in, USB, Bluetooth, Continuity, etc.).
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transport)

        // 3. Stream configuration on input scope (channel count + buffer layout).
        var streamCfgAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamCfgSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &streamCfgAddr, 0, nil, &streamCfgSize) == noErr,
           streamCfgSize > 0 {
            let bufList = UnsafeMutableRawPointer.allocate(byteCount: Int(streamCfgSize), alignment: 8)
            defer { bufList.deallocate() }
            _ = AudioObjectGetPropertyData(deviceID, &streamCfgAddr, 0, nil, &streamCfgSize, bufList)
        }

        // 4. Available nominal sample rates — forces the driver to expose its
        // rate table, which Sound settings reads on open.
        var ratesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ratesSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &ratesAddr, 0, nil, &ratesSize) == noErr,
           ratesSize > 0 {
            let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(ratesSize), alignment: 8)
            defer { buf.deallocate() }
            _ = AudioObjectGetPropertyData(deviceID, &ratesAddr, 0, nil, &ratesSize, buf)
        }
    }

    /// Wakes every audio device, like the Sound pane does on open. The broad sweep is what makes
    /// the first engine start read its format right away.
    nonisolated static func warmAllInputDevicesHAL() {
        guard warmingLock.try() else {
            // A warming pass is already active. Skip to prevent overlapping HAL IPC stalls.
            return
        }
        defer { warmingLock.unlock() }

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &devicesAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(systemObject, &devicesAddress, 0, nil, &dataSize, &deviceIDs) == noErr
        else { return }

        for deviceID in deviceIDs where deviceID != 0 {
            warmInputDeviceHAL(deviceID)
        }
    }

    /// Runs a real IO cycle on the default input so coreaudiod fully engages the device; property
    /// reads alone don't. Avoids a cold start of about 2 s on the first press after launch. Shows
    /// the mic indicator for about 150 ms, so run it once after permission is granted, not per
    /// press. Returns false if the device is unavailable, permission is missing, or the driver
    /// refused, so the keep-alive task can retry.
    @discardableResult
    nonisolated static func primeDefaultInputIOProc() -> Bool {
        let deviceID = defaultInputDeviceID()
        guard deviceID != 0 else { return false }

        var procID: AudioDeviceIOProcID? = nil
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            deviceID,
            nil // run on internal CoreAudio thread
        ) { _, _, _, _, _ in
            // Empty IO proc: only engages the device; no audio is copied.
        }
        guard createStatus == noErr, let procID else { return false }

        // Hold for 150 ms so the driver fully engages (Bluetooth needs 100 ms or more to switch
        // profiles), then stop and destroy. About 180 to 250 ms in total.
        let startStatus = AudioDeviceStart(deviceID, procID)
        let started = (startStatus == noErr)
        if started {
            usleep(150_000) // 150 ms
            AudioDeviceStop(deviceID, procID)
        }
        AudioDeviceDestroyIOProcID(deviceID, procID)
        return started
    }

    /// Starts and stops a real `AVAudioEngine` with an empty tap. AVAudioEngine has its own
    /// first-use cost (format negotiation, graph setup, render thread), 500 to 1500 ms even when
    /// the device is awake. Doing it at launch makes the first dictation start fast. Called once
    /// after mic permission; the mic indicator shows briefly. Nonisolated so it can run off the
    /// main actor.
    @discardableResult
    nonisolated static func primeAVAudioEngineForDefaultInput() -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Sanity: zero-channel format means the input isn't actually
        // available (mic permission not granted, or no devices).
        guard format.channelCount > 0, format.sampleRate.isFinite, format.sampleRate > 0 else { return false }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in
            // Empty tap: only sets up the engine; no audio is kept.
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }

        // 100 ms is enough for the AUHAL graph to settle; further hold
        // time mostly extends the privacy indicator without warming
        // anything new.
        usleep(100_000)

        engine.stop()
        input.removeTap(onBus: 0)
        return true
    }

    /// Get the transport type for a device (built-in, Bluetooth, USB, etc.).
    nonisolated static func deviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &dataSize, &transportType)
        guard status == noErr else { return 0 }
        return transportType
    }

    // MARK: - Bluetooth Detection

    /// Whether the currently selected (or system default) input device is Bluetooth.
    var selectedDeviceIsBluetooth: Bool {
        if let device = selectedDevice {
            return device.isBluetooth
        }
        // No explicit selection: check the system default
        let defaultID = Self.defaultInputDeviceID()
        guard defaultID != 0 else { return false }
        let transport = Self.deviceTransportType(defaultID)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// A non-Bluetooth alternative, in order:
    /// 1. The last preferred device.
    /// 2. Continuity (iPhone or iPad mic): wireless like Bluetooth but without the profile switch, and a
    ///    much better mic, so it's the best choice with the laptop closed.
    /// 3. The built-in mic.
    /// 4. Any other non-Bluetooth device.
    var recommendedNonBluetoothDevice: AudioInputDevice? {
        if let preferred = preferredDeviceUID,
           let device = availableDevices.first(where: { $0.uid == preferred && !$0.isBluetooth })
        {
            return device
        }
        if let continuity = availableDevices.first(where: { $0.isContinuityCapture }) {
            return continuity
        }
        if let builtIn = availableDevices.first(where: { $0.isBuiltIn }) {
            return builtIn
        }
        return availableDevices.first(where: { !$0.isBluetooth })
    }

    // MARK: - System Volume Control

    /// Whether the default output is Bluetooth. Changing its volume makes some headsets
    /// renegotiate, which interrupts the audio, so ducking is skipped.
    nonisolated static func isDefaultOutputBluetooth() -> Bool {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return false }
        let transport = deviceTransportType(deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Whether any process is playing to the default output, as a rough sign that music is on.
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` also counts silent streams.
    nonisolated static func isDefaultOutputRunning() -> Bool {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return value != 0
    }

    /// Get the current system output volume (0.0 to 1.0).
    nonisolated static func systemOutputVolume() -> Float32 {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return 1.0 }
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 1.0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &dataSize, &volume)
        return volume
    }

    /// Set the system output volume (0.0 to 1.0).
    nonisolated static func setSystemOutputVolume(_ volume: Float32) {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return }
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = max(0.0, min(1.0, volume))
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(deviceID, &volumeAddress, 0, nil, dataSize, &vol)
    }

    /// Get the current system mute state.
    nonisolated static func isSystemOutputMuted() -> Bool {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return false }
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &dataSize, &muted)
        return muted != 0
    }

    /// Set system output mute state.
    nonisolated static func setSystemOutputMuted(_ muted: Bool) {
        let deviceID = defaultOutputDeviceID()
        guard deviceID != 0 else { return }
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, dataSize, &value)
    }

    /// Sets the system default input. Used by TranscriptionService during a session and by the
    /// Bluetooth override.
    nonisolated static func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) {
        guard deviceID != 0 else { return }
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        if status != noErr {
            print("[AudioDeviceManager] Failed to set system default input (\(status))")
        }
    }

    /// Get the system's current default output device ID.
    nonisolated private static func defaultOutputDeviceID() -> AudioDeviceID {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr else { return 0 }
        return deviceID
    }
}
