// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Foundation
import SideWaveKit

/// One owner per settings key, registration defaults for all of them.
/// The old app's settings sprawl (keys minted ad hoc across a dozen
/// files) is on the leave list; every SideWave2 preference goes through
/// here.
enum AppSettings {

    // MARK: Keys

    static let hotkeyKey = "hotkeyShortcut"
    static let activationModeKey = "activationMode"
    static let pttThresholdMsKey = "smartPTTThresholdMs"
    static let preferredDeviceUIDKey = "preferredDeviceUID"
    static let languageCodeKey = "asrLanguageCode"
    static let refineEnabledKey = "refineEnabled"
    static let refineBackendKey = "refineBackend"
    static let refineTemplateKey = "refineTemplate"
    static let appearanceKey = "appearance"
    static let onboardingDoneKey = "onboardingComplete"
    static let historyLimitKey = "historyLimit"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            pttThresholdMsKey: 500,
            languageCodeKey: "auto",
            refineEnabledKey: true,
            refineBackendKey: RefineBackendChoice.appleIntelligence.rawValue,
            refineTemplateKey: RefineTemplate.standard.rawValue,
            appearanceKey: AppearanceChoice.system.rawValue,
            historyLimitKey: 200,
        ])
    }

    // MARK: Typed access

    static var hotkey: HotkeyShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: hotkeyKey),
                let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            else { return .defaultShortcut }
            return shortcut
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: hotkeyKey)
            }
        }
    }

    static var pttThreshold: TimeInterval {
        let ms = UserDefaults.standard.integer(forKey: pttThresholdMsKey)
        return ms > 0 ? Double(ms) / 1000.0 : GestureClassifier.defaultThreshold
    }

    static var preferredDeviceUID: String? {
        get {
            let value = UserDefaults.standard.string(forKey: preferredDeviceUIDKey)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: preferredDeviceUIDKey) }
    }

    static var languageCode: String {
        UserDefaults.standard.string(forKey: languageCodeKey) ?? "auto"
    }

    static var refineEnabled: Bool {
        UserDefaults.standard.bool(forKey: refineEnabledKey)
    }

    static var refineBackend: RefineBackendChoice {
        RefineBackendChoice(rawValue: UserDefaults.standard.string(forKey: refineBackendKey) ?? "")
            ?? .appleIntelligence
    }

    static var refineTemplate: RefineTemplate {
        RefineTemplate(rawValue: UserDefaults.standard.string(forKey: refineTemplateKey) ?? "")
            ?? .standard
    }

    static var appearance: AppearanceChoice {
        AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "")
            ?? .system
    }

    static var onboardingComplete: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingDoneKey) }
    }
}

enum RefineBackendChoice: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case gemmaE2B
    case gemmaE4B

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .gemmaE2B: return "Gemma 4 E2B"
        case .gemmaE4B: return "Gemma 4 E4B"
        }
    }

    var gemmaVariant: RefinerGemma.Variant? {
        switch self {
        case .appleIntelligence: return nil
        case .gemmaE2B: return .e2b
        case .gemmaE4B: return .e4b
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The dictation language choices offered in settings-lite. "auto" runs
/// the full multilingual model; a specific code hints the engine and can
/// route to the faster Latin-pruned variant.
enum LanguageChoice: String, CaseIterable, Identifiable {
    case auto = "auto"
    case english = "en-US"
    case spanish = "es-ES"
    case french = "fr-FR"
    case german = "de-DE"
    case italian = "it-IT"
    case portuguese = "pt-BR"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case chinese = "zh-CN"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        }
    }
}
