// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import AudioToolbox
import AVFAudio
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

// MARK: - Channel Selection Mode

/// Which input channel feeds the recognizer on a device with several channels. Saved per device
/// UID.
enum ChannelMode: Equatable, Sendable {
    /// Pick the loudest channel automatically. Runs a brief calibration
    /// during the first recording per device, caches the result.
    case auto
    /// User explicitly selected this 1-based channel index.
    case channel(Int)
    /// Mix (average) all channels — historical default before this knob
    /// existed. Useful for legitimately stereo sources (binaural mics,
    /// stereo line-in).
    case mix

    var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .channel(let n): return "channel:\(n)"
        case .mix: return "mix"
        }
    }

    init?(rawValue: String) {
        if rawValue == "auto" { self = .auto; return }
        if rawValue == "mix" { self = .mix; return }
        if rawValue.hasPrefix("channel:"),
           let n = Int(rawValue.dropFirst("channel:".count)),
           n >= 1
        {
            self = .channel(n)
            return
        }
        return nil
    }

    var displayLabel: String {
        switch self {
        case .auto: return "Auto (loudest channel)"
        case .channel(let n): return "Channel \(n)"
        case .mix: return "Mix all channels"
        }
    }
}

// MARK: - Audio Input Device Model

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool
    let transportType: UInt32
    /// Input channels CoreAudio reported. The channel picker appears only when this is more than 1;
    /// 0 means unknown, and channel options are hidden.
    let channelCount: Int

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    var isContinuityCapture: Bool {
        transportType == kAudioDeviceTransportTypeContinuityCaptureWired
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    var transportDescription: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity Camera"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity Camera"
        default: return "External"
        }
    }

    /// Transport tag for the picker (USB, Thunderbolt, Aggregate, Virtual, AirPlay). Nil for
    /// built-in devices and for Bluetooth and Continuity, which have their own badges.
    private var transportPickerTag: String? {
        switch transportType {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        default: return nil
        }
    }

    /// The picker label: Bluetooth and Continuity always get badges, other external transports get
    /// a tag, built-in stays plain. "(Default)" is added for the system default when
    /// `includeDefault` is true; pickers with a separate System Default row pass false.
    func pickerLabel(includeDefault: Bool = true) -> String {
        var tags: [String] = []
        if includeDefault, isDefault { tags.append("Default") }
        if isBluetooth {
            tags.append("Bluetooth")
        } else if isContinuityCapture {
            tags.append("Continuity")
        } else if let tag = transportPickerTag {
            tags.append(tag)
        }
        guard !tags.isEmpty else { return name }
        return "\(name) (\(tags.joined(separator: " · ")))"
    }
}
