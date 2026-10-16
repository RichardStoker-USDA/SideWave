// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import CoreAudio
import Foundation

/// A capturable input device as the settings picker and the session
/// resolver see it.
public struct AudioInputDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: UInt32
    public let inputChannelCount: Int

    public var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// CoreAudio device listing without stored state: every call reads the current hardware, so a dock
/// change between sessions can't leave a stale binding.
public enum AudioDevices {

    public static func listInputDevices() -> [AudioInputDeviceInfo] {
        allDeviceIDs().compactMap { info(for: $0) }.filter { $0.inputChannelCount > 0 }
    }

    public static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    /// The device for a session: the preferred UID if it's present now, otherwise the default
    /// input. The result includes the device name so the session can mention a fallback.
    public static func resolveForCapture(preferredUID: String?) -> (info: AudioInputDeviceInfo?, usedFallback: Bool) {
        let devices = listInputDevices()
        if let preferredUID, let match = devices.first(where: { $0.uid == preferredUID }) {
            return (match, false)
        }
        let defaultID = defaultInputDeviceID()
        if defaultID != 0, let info = info(for: defaultID), info.inputChannelCount > 0 {
            return (info, preferredUID != nil)
        }
        // No usable default reported; any live input beats none.
        return (devices.first, true)
    }

    // MARK: Property reads

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func info(for deviceID: AudioDeviceID) -> AudioInputDeviceInfo? {
        guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? uid
        return AudioInputDeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            transport: transportType(deviceID),
            inputChannelCount: inputChannelCount(deviceID)
        )
    }

    static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return transport
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
            size > 0
        else { return 0 }
        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, listPointer) == noErr
        else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            listPointer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

/// Watches devices arriving and leaving. During a session the app reports changes through
/// `SessionController.reportSubsystemFailure`; between sessions nothing needs updating, since every
/// start resolves the device again.
public final class AudioDeviceSetWatcher: Sendable {

    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let listenerQueue = DispatchQueue(label: "com.sidewave.kit.devicewatch")
    // Retained so the listener can be removed on invalidate; the block
    // itself only touches the Sendable continuation.
    private nonisolated(unsafe) let block: AudioObjectPropertyListenerBlock

    public init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.changes = stream
        self.continuation = continuation
        let sink = continuation
        self.block = { _, _ in sink.yield() }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
    }

    public func invalidate() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        continuation.finish()
    }

    deinit {
        invalidate()
    }
}
