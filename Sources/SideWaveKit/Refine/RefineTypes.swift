// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// The core-loop templates. The specialty set (Email Ready, Instructions,
/// AI Prompt) returns with its own module; the prompt text below is
/// carried verbatim for the templates that shipped.
public enum RefineTemplate: String, CaseIterable, Sendable, Identifiable {
    case standard
    case professional
    case concise
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .professional: return "Professional"
        case .concise: return "Concise"
        case .custom: return "Custom"
        }
    }

    public var subtitle: String {
        switch self {
        case .standard: return "Fix errors, grammar, and punctuation. Keeps your voice."
        case .professional: return "Clean professional writing that keeps your voice. Lifts the register, not your words."
        case .concise: return "Tighten and trim. Same meaning, fewer words."
        case .custom: return "Your custom instructions take priority. Write your own rules."
        }
    }

    /// Word-ratio bounds for refined output (carried tuning: a 40-word
    /// input producing a 70-word "refinement" is a hallucination, not an
    /// edit).
    public var outputRatioBounds: (min: Double, max: Double) {
        switch self {
        case .standard: return (0.4, 1.5)
        case .professional: return (0.5, 1.45)
        case .concise: return (0.25, 1.0)
        case .custom: return (0.2, 1.6)
        }
    }
}

/// Output language for refine. `.matchInput` keeps the dictated language;
/// anything else renders the output naturally in that language. The nine
/// are the languages both on-device engines handle natively at quality.
public enum RefineOutputLanguage: String, CaseIterable, Sendable, Identifiable {
    case matchInput = "match"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case japanese = "ja"
    case korean = "ko"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }
    public var isMatch: Bool { self == .matchInput }

    public var displayName: String {
        switch self {
        case .matchInput: return "Match input"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .simplifiedChinese: return "Chinese (Simplified)"
        }
    }

    /// English name used inside prompt directives ("translate into
    /// Simplified Chinese", not "Chinese (Simplified)").
    var promptName: String {
        switch self {
        case .matchInput: return ""
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .simplifiedChinese: return "Simplified Chinese"
        }
    }

    public static func from(code: String?) -> RefineOutputLanguage {
        guard let code else { return .matchInput }
        return RefineOutputLanguage(rawValue: code) ?? .matchInput
    }
}

/// Everything a refiner needs per call, held by the refiner and set by
/// the shell when settings change. Vocabulary and speaker profile arrive
/// pre-rendered so the kit stays free of the stores that build them.
public struct RefineSettings: Sendable {
    public var template: RefineTemplate
    public var outputLanguage: RefineOutputLanguage
    /// User-authored rules; only meaningful weight under `.custom` but
    /// honored by every template.
    public var customInstructions: String
    /// Compact description of how the speaker talks, used to PRESERVE
    /// their voice. Empty when the profile feature is off.
    public var speakerProfile: String
    /// Pre-rendered "Reference vocabulary" prompt section (preferred
    /// spellings, domain terms). Empty when no vocabulary applies.
    public var referenceVocabulary: String

    public init(
        template: RefineTemplate = .standard,
        outputLanguage: RefineOutputLanguage = .matchInput,
        customInstructions: String = "",
        speakerProfile: String = "",
        referenceVocabulary: String = ""
    ) {
        self.template = template
        self.outputLanguage = outputLanguage
        self.customInstructions = customInstructions
        self.speakerProfile = speakerProfile
        self.referenceVocabulary = referenceVocabulary
    }
}

public enum RefinerFailure: LocalizedError, Equatable {
    case backendNotReady
    case timedOut
    case refused
    case contextOverflow
    case implausibleOutput(ratio: Double)
    case changedSpeaker

    public var errorDescription: String? {
        switch self {
        case .backendNotReady: return "The refine model is not ready."
        case .timedOut: return "Refining took too long."
        case .refused: return "The model declined to process this text."
        case .contextOverflow: return "The dictation is too long to refine in one pass."
        case .changedSpeaker: return "Refine changed the speaker. The original text was kept."
        case .implausibleOutput(let ratio):
            return "The refined text failed the sanity check (\(String(format: "%.2f", ratio))x input length)."
        }
    }
}
