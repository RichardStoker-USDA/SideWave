// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

@MainActor
extension DictationFormatterService {
    // MARK: - Templates

    /// Cleanup style presets that shape the prompt's core task section.
    enum Template: String, CaseIterable, Sendable, Identifiable {
        case standard
        case professional
        case concise
        case emailReady
        case instructions
        case aiPrompt
        case custom

        var id: String { rawValue }

        var isSpecialty: Bool {
            switch self {
            case .emailReady, .instructions, .aiPrompt, .custom: return true
            default: return false
            }
        }

        var displayName: String {
            switch self {
            case .standard: return "Standard"
            case .professional: return "Professional"
            case .concise: return "Concise"
            case .emailReady: return "Email"
            case .instructions: return "Instructions"
            case .aiPrompt: return "AI Prompt"
            case .custom: return "Custom"
            }
        }

        var subtitle: String {
            switch self {
            case .standard: return "Correct grammar and punctuation while keeping your wording."
            case .professional: return "Use formal wording while preserving your meaning."
            case .concise: return "Remove repetition and shorten the text while preserving your meaning."
            case .emailReady: return "Format an email with a subject, greeting, body, and sign-off."
            case .instructions: return "Organize instructions into numbered steps and supporting details."
            case .aiPrompt: return "Organize your instructions into an XML prompt."
            case .custom: return "Format the dictation using your own instructions."
            }
        }
    }

    /// Output language for Refine. `.matchInput` keeps the spoken language. Choosing a language makes
    /// Refine render each part in it naturally, carrying intent, idioms, and register rather than
    /// swapping words. The raw value is stored in `dictationOutputLanguage`.
    ///
    /// The list is the nine languages Apple Intelligence supports for on-device generation on macOS
    /// 26.0, which the small Gemma models also handle well. Japanese, Korean, and Chinese read better
    /// on Gemma E4B than E2B; the model isn't switched automatically.
    ///
    /// Apple Intelligence also filters the list at runtime with `offeredOutputLanguages(for:)`, so a
    /// newer OS can offer more. Russian, Hindi, and Arabic are left out: macOS 27 only on Apple and the
    /// weakest tier on small Gemma models.
    enum OutputLanguage: String, CaseIterable, Sendable, Identifiable {
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

        var id: String { rawValue }

        var isMatch: Bool { self == .matchInput }

        /// Picker label.
        var displayName: String {
            switch self {
            case .matchInput: return "As spoken"
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

        /// Compact label for the live-panel indicator pill.
        var shortLabel: String {
            switch self {
            case .simplifiedChinese: return "Chinese"
            default: return displayName
            }
        }

        /// English name used inside the model prompt directives. Distinct from
        /// `displayName` so the prompt reads naturally ("translate into
        /// Simplified Chinese" rather than "Chinese (Simplified)").
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

        /// Tolerant lookup — unknown / legacy codes fall back to Match input.
        static func from(code: String?) -> OutputLanguage {
            guard let code else { return .matchInput }
            return OutputLanguage(rawValue: code) ?? .matchInput
        }

        /// Whether an Apple Intelligence `supportedLanguages` set covers this language. As spoken
        /// is always supported. Compares base language codes, which keeps all nine on macOS 26.0
        /// without a script mismatch dropping one.
        func isSupported(by languages: Set<Locale.Language>) -> Bool {
            guard !isMatch else { return true }
            guard let code = Locale.Language(identifier: rawValue).languageCode else { return true }
            return languages.contains { $0.languageCode == code }
        }
    }

    /// Output languages to offer for a backend, always including As spoken. Apple Intelligence uses
    /// the model's `supportsLocale(_:)`, which handles script and region fallbacks (zh-Hans and
    /// zh-Hant) that a base-code match can't; there are no per-language downloads to check. Fails
    /// open to the full list when the model is unavailable or reports nothing. Gemma's list is
    /// fixed.
    @MainActor
    static func offeredOutputLanguages(for backend: Backend) -> [OutputLanguage] {
        switch backend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            return OutputLanguage.allCases
        case .appleIntelligence, .appleIntelligenceLegacy:
            let model = AFMRuntime.makeModel()
            // Picker is informational; if AFM isn't usable, fail open rather than
            // hand back an empty menu (generation still falls back to raw).
            guard case .available = model.availability else { return OutputLanguage.allCases }
            let offered = OutputLanguage.allCases.filter {
                $0.isMatch || model.supportsLocale(Locale(identifier: $0.rawValue))
            }
            // An available model supports at least English; if supportsLocale
            // came back false for everything (anomalous), fall back to the
            // supportedLanguages base-code filter, then to the full set.
            if offered.count > 1 { return offered }
            let supported = model.supportedLanguages
            guard !supported.isEmpty else { return OutputLanguage.allCases }
            let byCode = OutputLanguage.allCases.filter { $0.isSupported(by: supported) }
            return byCode.count > 1 ? byCode : OutputLanguage.allCases
        }
    }

    struct TurnPromptIdentity: Equatable, Sendable {
        let template: Template
        let removeFillers: Bool
        let customFillers: [String]
        let profanityMode: Settings.ProfanityMode
        let customInstructions: String
        let speakerProfile: String
        let vocabulary: VocabularyStore.Snapshot
        let outputLanguage: OutputLanguage
    }

    // MARK: - Dynamic prompt configuration

    /// Snapshot of the user's text-processing preferences relevant to the
    /// formatter's prompt. Built on the MainActor (from UserDefaults) and
    /// passed into the non-isolated static `buildPrompt` by value.
    struct Settings: Sendable {
        let template: Template
        let removeFillerWords: Bool
        let customFillerPhrases: [String]
        let profanityMode: ProfanityMode
        let customInstructions: String
        /// The speech profile: a short description of how the user talks and writes, built on this
        /// Mac from their dictation. Goes in the system prompt or Instructions, separate from
        /// vocabulary, so Refine keeps the speaker's voice. Empty when off.
        let speakerProfile: String
        /// Snapshot of enabled vocabulary packs (built-in presets + user packs).
        /// Rendered into the Refine user prompt as a Reference Vocabulary
        /// section so the model can prefer domain spellings and meanings.
        let vocabulary: VocabularyStore.Snapshot
        /// Text from earlier segments that are already refined. When set, the model refines only
        /// `rawText` and uses this for flow. Nil for whole-text passes.
        let priorContext: String?
        /// Gemma 4 thinking mode for this call: sets `enable_thinking` in the chat session context,
        /// which makes the model write a hidden reasoning block first. Two to three times slower,
        /// so it's for end-of-session passes on complex input, never per-segment refines. Off by
        /// default; Settings asks for confirmation.
        let useThinkingMode: Bool

        /// Target language for the output. `.matchInput` keeps the spoken language. Read from
        /// `dictationOutputLanguage`.
        let outputLanguage: OutputLanguage

        var turnPromptIdentity: TurnPromptIdentity {
            .init(template: template, removeFillers: removeFillerWords,
                  customFillers: customFillerPhrases, profanityMode: profanityMode,
                  customInstructions: customInstructions, speakerProfile: speakerProfile,
                  vocabulary: vocabulary, outputLanguage: outputLanguage)
        }

        enum ProfanityMode: Sendable, Equatable {
            case none
            case redact    // f***
            case replace   // "frick"
        }

        /// Build from current UserDefaults and CustomDictionary snapshot.
        @MainActor
        static func fromCurrentUserDefaults(customInstructions: String) -> Settings {
            let defaults = UserDefaults.standard

            let templateRaw = defaults.string(forKey: "dictationCleanupTemplate") ?? Template.standard.rawValue
            let template = Template(rawValue: templateRaw) ?? .standard

            let removeFillers = defaults.bool(forKey: "removeFillerWords")
            // Custom filler phrases are stored as JSON data, so use the service's loader.
            let customFillers = TranscriptionService.loadCustomFillerPhrases()

            let removeProfanity = defaults.bool(forKey: "removeProfanity")
            let replaceProfanity = defaults.bool(forKey: "replaceProfanity")
            let profanityMode: ProfanityMode
            if removeProfanity {
                profanityMode = .redact
            } else if replaceProfanity {
                profanityMode = .replace
            } else {
                profanityMode = .none
            }

            // Thinking requires the user's preference and an eligible full
            // document or Hold-to-Refine pass. Live segments stay in fast mode.
            let thinkingMode = false

            let outputLanguage = OutputLanguage.from(code: defaults.string(forKey: "dictationOutputLanguage"))

            return Settings(
                template: template,
                removeFillerWords: removeFillers,
                customFillerPhrases: customFillers,
                profanityMode: profanityMode,

                customInstructions: customInstructions,
                speakerProfile: SpeechProfileStore.shared.promptText,
                vocabulary: VocabularyStore.shared.makeSnapshot(),
                priorContext: nil,
                useThinkingMode: thinkingMode,
                outputLanguage: outputLanguage
            )
        }
    }

    struct PromptPreview: Sendable {
        let sampleDictation: String
        let systemInstructions: String
        let userPrompt: String
    }

    /// Build a prompt preview for the current backend + template.
    @MainActor
    static func makePromptPreview(
        customInstructions: String,
        backend: Backend = .gemma4E2B
    ) -> PromptPreview {
        let settings = Settings.fromCurrentUserDefaults(customInstructions: customInstructions)
        let structured = settings.template == .aiPrompt || settings.template == .instructions
        let userPrompt = structured && backend.huggingFaceRepoID != nil
            ? gemmaDocumentPrompt(rawText: samplePreviewDictation, settings: settings)
            : buildPrompt(rawText: samplePreviewDictation, settings: settings, structuredDocument: structured)

        let sysPrompt: String
        switch backend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            sysPrompt = structured ? documentDataInstructions(template: settings.template, outputLanguage: settings.outputLanguage) : gemmaSystemPrompt(
                for: settings.template,
                removeFillers: settings.removeFillerWords,
                outputLanguage: settings.outputLanguage,
                speakerProfile: settings.speakerProfile
            )
        case .appleIntelligence, .appleIntelligenceLegacy:
            #if canImport(FoundationModels)
            let generation = backend == .appleIntelligenceLegacy ? .gen1 : effectiveAFMGeneration
            let instructions = Instructions {
                afmInstructions(for: settings.template, generation: generation,
                    outputLanguage: settings.outputLanguage, speakerProfile: settings.speakerProfile)
                if structured { processingInstructions(rawText: samplePreviewDictation, settings: settings) }
            }
            let session = LanguageModelSession(instructions: instructions)
            sysPrompt = session.transcript.compactMap { entry -> String? in
                guard case .instructions(let value) = entry else { return nil }
                return value.segments.compactMap { segment -> String? in
                    guard case .text(let text) = segment else { return nil }
                    return text.content
                }.joined(separator: "\n")
            }.joined(separator: "\n")
            #else
            sysPrompt = "Apple Intelligence requires macOS 26 or later."
            #endif
        }

        return PromptPreview(
            sampleDictation: samplePreviewDictation,
            systemInstructions: sysPrompt,
            userPrompt: userPrompt
        )
    }
}
