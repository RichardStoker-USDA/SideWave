// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit

// MARK: - Sound Event

/// Events that trigger sound effects during dictation workflow.
enum SoundEvent: String, CaseIterable, Identifiable {
    case recordingStart = "recordingStart"
    case recordingStop = "recordingStop"
    case promptConfirmed = "promptConfirmed"
    case error = "error"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recordingStart: return "Dictation starts"
        case .recordingStop: return "Dictation stops"
        case .promptConfirmed: return "Text delivered"
        case .error: return "Problem"
        }
    }

    var description: String {
        switch self {
        case .recordingStart: return "The microphone is ready to record."
        case .recordingStop: return "Recording ends and your words are processed."
        case .promptConfirmed: return "Your dictation is pasted, or a document is ready."
        case .error: return "Dictation couldn't start, or text couldn't be pasted."
        }
    }

    var iconName: String {
        switch self {
        case .recordingStart: return "mic.fill"
        case .recordingStop: return "stop.fill"
        case .promptConfirmed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// UserDefaults key for this event's selected sound.
    var defaultsKey: String { "soundEffect_\(rawValue)" }

    /// The factory default sound for this event.
    var factoryDefault: SoundOption {
        switch self {
        case .recordingStart: return .system("Blow")
        case .recordingStop: return .none
        case .promptConfirmed: return .system("Bottle")
        case .error: return .system("Basso")
        }
    }
}

// MARK: - Sound Option

/// A playable sound, either from /System/Library/Sounds or silence.
enum SoundOption: Equatable, Hashable {
    case none
    case system(String)

    /// Stable string for UserDefaults persistence.
    var persistenceKey: String {
        switch self {
        case .none: return "__none__"
        case .system(let name): return name
        }
    }

    /// Human-readable label for the picker.
    var displayName: String {
        switch self {
        case .none: return "None"
        case .system(let name): return name
        }
    }

    /// Restore from a persisted string.
    static func from(persistenceKey: String) -> SoundOption {
        if persistenceKey == "__none__" { return .none }
        return .system(persistenceKey)
    }

    /// Known macOS system alert sounds. Hardcoded to avoid FileManager directory
    /// scanning which can trigger TCC permission prompts on Sequoia/Tahoe for
    /// cloud-synced directories (OneDrive, iCloud, etc.).
    static let allSystemSounds: [SoundOption] = [
        .system("Basso"), .system("Blow"), .system("Bottle"), .system("Frog"),
        .system("Funk"), .system("Glass"), .system("Hero"), .system("Morse"),
        .system("Ping"), .system("Pop"), .system("Purr"), .system("Sosumi"),
        .system("Submarine"), .system("Tink"),
    ]

    /// Complete picker list: None + all system sounds.
    static let allOptions: [SoundOption] = [.none] + allSystemSounds
}

// MARK: - Sound Effect Service

/// Plays sound effects for dictation state changes.
/// Supports per-event sound selection, volume control, and preview playback.
/// All settings persist via UserDefaults.
@MainActor
final class SoundEffectService {

    static let shared = SoundEffectService()

    // NSSound is used for system alert sounds to avoid the Apple Music
    // permission prompt that AVAudioPlayer triggers on macOS 15+.

    private init() {}

    // MARK: - UserDefaults Keys

    private static let enabledKey = "soundEffectsEnabled"
    private static let volumeKey = "soundEffectsVolume"

    // MARK: - Public API

    /// Whether sound effects are enabled globally.
    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
            }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// Global volume for sound effects (0.0 ... 1.0). Defaults to 0.3.
    var volume: Float {
        get {
            if UserDefaults.standard.object(forKey: Self.volumeKey) == nil {
                UserDefaults.standard.set(Float(0.3), forKey: Self.volumeKey)
            }
            return UserDefaults.standard.float(forKey: Self.volumeKey)
        }
        set { UserDefaults.standard.set(newValue.clamped(to: 0...1), forKey: Self.volumeKey) }
    }

    /// Get the currently selected sound for an event.
    func sound(for event: SoundEvent) -> SoundOption {
        guard let key = UserDefaults.standard.string(forKey: event.defaultsKey) else {
            return event.factoryDefault
        }
        return SoundOption.from(persistenceKey: key)
    }

    /// Set the sound for an event.
    func setSound(_ option: SoundOption, for event: SoundEvent) {
        UserDefaults.standard.set(option.persistenceKey, forKey: event.defaultsKey)
    }

    /// Reset all events to factory defaults.
    func resetToDefaults() {
        for event in SoundEvent.allCases {
            UserDefaults.standard.removeObject(forKey: event.defaultsKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.volumeKey)
    }

    /// Play the sound configured for an event. Respects enabled/volume settings.
    /// Also suppresses the sound when default output is Bluetooth and another
    /// app is actively streaming through it (likely music). Our NSSound.play
    /// hits the shared BT route and compounds the unavoidable A2DP-to-HFP
    /// codec switch when dictation begins, producing an extra audible drop.
    /// The mic-open renegotiation cannot be prevented at the app level but
    /// the compounding noise can.
    func play(_ event: SoundEvent) {
        guard isEnabled else { return }
        let option = sound(for: event)
        let vol = volume
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if AudioDeviceManager.isDefaultOutputBluetooth()
                && AudioDeviceManager.isDefaultOutputRunning() {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.playSound(option, volumeOverride: vol)
            }
        }
    }

    /// Play the configured sound assuming the caller has ALREADY evaluated the
    /// Bluetooth-output suppression gate off the main thread. The recording-
    /// start path runs that CoreAudio check on a background queue (it can stall
    /// a few hundred ms mid-A2DP-renegotiation) so the overlay paints first,
    /// then hops to the main actor here for the AppKit NSSound playback. Keeps
    /// NSSound and the MainActor-isolated settings on the main thread without
    /// re-running the slow check.
    func playSkippingOutputCheck(_ event: SoundEvent) {
        guard isEnabled else { return }
        playSound(sound(for: event))
    }

    /// Preview a sound at the current volume. Ignores enabled toggle.
    func preview(_ option: SoundOption) {
        playSound(option)
    }

    // MARK: - Playback

    private func playSound(_ option: SoundOption, volumeOverride: Float? = nil) {
        guard case .system(let name) = option else { return }

        // Use NSSound for system alert sounds -- it doesn't trigger the
        // Apple Music/media library permission prompt that AVAudioPlayer causes
        // when reading from /System/Library/Sounds/ on macOS 15+.
        guard let nsSound = NSSound(named: NSSound.Name(name)) else { return }
        nsSound.volume = volumeOverride ?? volume
        nsSound.play()
    }

    // MARK: - Static API

    /// Plays an event through the shared service.
    static func play(_ event: SoundEvent) {
        shared.play(event)
    }

    /// Static convenience for `playSkippingOutputCheck`. See the instance method.
    static func playSkippingOutputCheck(_ event: SoundEvent) {
        shared.playSkippingOutputCheck(event)
    }
}

// MARK: - Comparable Clamping

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
