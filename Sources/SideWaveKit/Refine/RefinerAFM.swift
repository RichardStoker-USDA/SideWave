// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which on-device Apple Foundation Model generation the running OS
/// ships. Carried single-source-of-truth: the generation split and the
/// permissive-guardrails construction live here and nowhere else.
public enum AFMGeneration: Sendable, Equatable {
    /// macOS 26 Tahoe: weaker instruction following, needs the short
    /// prompt profile and the plain-prompt refusal retry.
    case gen1
    /// macOS 27+: AFM 3, strong instruction following, full prompts.
    case gen2

    public static let current: AFMGeneration = {
        if #available(macOS 27, *) { return .gen2 }
        return .gen1
    }()
}

#if canImport(FoundationModels)

// MARK: - Carried @Generable schemas
// Constrained decoding physically prevents the wrong shape; the @Guide
// text is part of the tuned prompt surface (carried verbatim).

@Generable
struct RefinedDictationOutput {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "Preserve every meaningful opening clause, conjunction, and incomplete starting phrase. Remove nonsemantic hesitations and empty spoken setup only; never discard an idea. The refined version of the new slice ONLY. Do NOT echo or restate prior-text content. If the slice ends mid-thought, leave it mid-thought UNLESS the prior text above already contains the exact words that would complete the sentence (then you may complete using ONLY those grounded words). NEVER invent or fabricate completion words. CRITICAL: when the input contains a period mid-thought (the dictation engine inserted it at a brief silence), DROP that period and merge the two halves into one flowing sentence. Examples: 'I went to the store. and then home' becomes 'I went to the store and then home'; 'so we need to ship. But also keep tests green' becomes 'so we need to ship but also keep tests green'. Only keep periods that mark genuine sentence boundaries. Preserve all named entities, proper nouns, and identifiers from the slice exactly as written. NEVER repeat the same 3+ word phrase verbatim within your output. May include line breaks, bullet points, and paragraph structure when the template requires it.")
    var cleanedText: String
}

/// Gen-1 variant: same field, ~300-char guide (the full guide overruns
/// gen-1's weaker instruction following).
@Generable
struct RefinedDictationOutputGen1 {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "The cleaned-up version of the input slice ONLY. Fix grammar, punctuation, capitalization, and transcription errors. Keep the speaker's own words and order. Do not add or complete unfinished thoughts. Keep every meaningful leading clause; remove spoken hesitations. Merge a mid-thought stray period into one flowing sentence. Preserve names and identifiers exactly. Never repeat a 3+ word phrase.")
    var cleanedText: String
}

@Generable
struct ProfessionalRefineOutput {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "Preserve every meaningful opening clause, conjunction, and incomplete starting phrase. Remove nonsemantic hesitations and empty spoken setup only; never discard an idea. You may remove leading spoken hesitations and empty setup phrases, but must preserve every meaningful leading clause. Polished professional rewrite of the new slice, split into paragraphs. One entry per coherent paragraph the speaker created. Each paragraph is grammatical professional prose, fixed for ALL grammar and punctuation, register lifted while keeping the speaker's own voice and everyday words (smooth only the roughest slang, don't swap words wholesale), filler removed. KEEP every distinct point and idea. If the slice is short and one paragraph suffices, return a single-entry array. NEVER fabricate paragraphs beyond what the speaker said. NEVER complete unfinished sentences unless the prior context above unambiguously contains the ending.")
    var paragraphs: [String]
}

#endif

/// Refine with Apple Foundation Models. The model runs in a system process, so its weights don't
/// use this app's memory. A new session per refine, so no session carries over earlier text.
public actor RefinerAFM: Refiner {

    private var settings = RefineSettings()
    private let log = Logger(subsystem: "com.sidewave.kit", category: "refine-afm")

    #if canImport(FoundationModels)
    /// One session stays prewarmed (model loaded, instructions prefilled) so refining doesn't wait
    /// for setup. Each session is used for exactly one refine, and the next one warms up after it.
    private var prewarmed: (session: LanguageModelSession, fingerprint: String)?
    #endif

    public init() {}

    public func setSettings(_ new: RefineSettings) {
        settings = new
        schedulePrewarm()
    }

    private func settingsFingerprint() -> String {
        "\(settings.template.rawValue)|\(settings.outputLanguage.rawValue)|\(settings.speakerProfile.hashValue)"
    }

    private func schedulePrewarm() {
        #if canImport(FoundationModels)
        let model = Self.makeModel()
        guard case .available = model.availability else {
            prewarmed = nil
            return
        }
        let fingerprint = settingsFingerprint()
        if prewarmed?.fingerprint == fingerprint { return }
        let session = LanguageModelSession(
            model: model,
            instructions: Self.instructions(
                for: settings.template,
                generation: AFMGeneration.current,
                outputLanguage: settings.outputLanguage,
                speakerProfile: settings.speakerProfile
            )
        )
        // prewarm() can block for hundreds of ms; never on this actor.
        let warm = session
        Task.detached(priority: .utility) { warm.prewarm() }
        prewarmed = (session, fingerprint)
        #endif
    }

    public var isReady: Bool {
        #if canImport(FoundationModels)
        if case .available = Self.makeModel().availability { return true }
        return false
        #else
        return false
        #endif
    }

    /// Availability with a user-facing reason, for settings-lite and
    /// onboarding copy.
    public static func availabilityMessage() -> String? {
        #if canImport(FoundationModels)
        let model = makeModel()
        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence. Switch to Gemma to use Refine on this device."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri."
            case .modelNotReady:
                return "Apple Intelligence is still downloading. Check back in a few minutes."
            @unknown default:
                return "Apple Intelligence is unavailable."
            }
        @unknown default:
            return "Apple Intelligence is unavailable on this device."
        }
        #else
        return "Apple Intelligence is unavailable in this build."
        #endif
    }

    public func refine(_ text: String, context: String) async throws -> String {
        let settings = self.settings
        #if canImport(FoundationModels)
        let model = Self.makeModel()
        guard case .available = model.availability else {
            throw RefinerFailure.backendNotReady
        }

        let generation = AFMGeneration.current
        let session: LanguageModelSession
        if let warm = prewarmed, warm.fingerprint == settingsFingerprint() {
            session = warm.session
            prewarmed = nil
        } else {
            session = LanguageModelSession(
                model: model,
                instructions: Self.instructions(
                    for: settings.template,
                    generation: generation,
                    outputLanguage: settings.outputLanguage,
                    speakerProfile: settings.speakerProfile
                )
            )
        }
        // The next session warms while this one generates.
        schedulePrewarm()
        let prompt = RefinePrompts.buildUserPrompt(rawText: text, settings: settings)
        let translating = !settings.outputLanguage.isMatch
        let timeout = RefinePrompts.refineTimeout(
            inputWords: RefineHygiene.wordCount(text), translating: translating)

        let inputTokenEstimate = max(16, text.count / 4)
        let raw = try await RefineDeadline.run(timeout: timeout) { [settings] in
            try await Self.generate(
                session: session,
                prompt: prompt,
                template: settings.template,
                translating: translating,
                generation: generation,
                inputTokenEstimate: inputTokenEstimate
            )
        }

        let cleaned = RefineHygiene.cleanupModelOutput(raw)
        guard !cleaned.isEmpty else { throw RefinerFailure.implausibleOutput(ratio: 0) }
        if settings.outputLanguage.isMatch, settings.template != .custom,
           RefineValidation.changesSpeakerNumber(input: text, output: cleaned) {
            throw RefinerFailure.changedSpeaker
        }
        if settings.outputLanguage.isMatch, let ratio = RefineHygiene.ratioViolation(
            input: text, output: cleaned, template: settings.template)
        {
            log.error("ratio gate rejected AFM output at \(ratio, format: .fixed(precision: 2), privacy: .public)x")
            throw RefinerFailure.implausibleOutput(ratio: ratio)
        }
        return cleaned
        #else
        throw RefinerFailure.backendNotReady
        #endif
    }

    #if canImport(FoundationModels)

    /// The only place a SystemLanguageModel is created. Permissive guardrails, because every use
    /// transforms the user's own dictation, as Apple recommends for transformation.
    static func makeModel() -> SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    // MARK: Instructions (carried, per generation)

    static func instructions(
        for template: RefineTemplate,
        generation: AFMGeneration,
        outputLanguage: RefineOutputLanguage,
        speakerProfile: String
    ) -> Instructions {
        let base =
            generation == .gen1
            ? gen1Instructions(for: template, outputLanguage: outputLanguage)
            : gen2Instructions(for: template, outputLanguage: outputLanguage)
        guard !speakerProfile.isEmpty else { return base }
        return Instructions {
            base
            "About this speaker (how they naturally talk and write): \(speakerProfile) Use this only to preserve the speaker's own voice, vocabulary, and phrasing. Do NOT copy it into the output, add topics or opinions it mentions, or restyle beyond what the current input actually says."
        }
    }

    private static func gen1Instructions(
        for template: RefineTemplate, outputLanguage: RefineOutputLanguage
    ) -> Instructions {
        switch template {
        case .custom:
            return Instructions {
                RefinePrompts.gen1BoundaryRule
                RefinePrompts.refineLanguageRuleGen1(for: outputLanguage)
                "Process the dictation per the user's custom instructions in the prompt — their instructions have top priority."
                "Fix obvious grammar, punctuation, and transcription errors."
                "Apply the Reference vocabulary spellings from the prompt."
                "Return only the processed text."
            }
        case .standard:
            return Instructions {
                RefinePrompts.gen1BoundaryRule
                RefinePrompts.refineLanguageRuleGen1(for: outputLanguage)
                "Clean up the dictation: fix grammar, punctuation, capitalization, and transcription errors. Remove nonsemantic hesitations and stutters. Preserve literal quoted words."
                "Always capitalize the pronoun \"I\" and the first word of every sentence."
                "Keep the speaker's own words, voice, and sentence order. Do not rewrite or restyle."
                "Apply the Reference vocabulary spellings from the prompt."
                "Return only the corrected text."
            }
        case .professional:
            return Instructions {
                RefinePrompts.gen1BoundaryRule
                RefinePrompts.refineLanguageRuleGen1(for: outputLanguage)
                "Clean up the dictation into professional writing while keeping the speaker's own voice. Fix all grammar, punctuation, and spelling."
                "Lift the register and smooth only the roughest slang; do not replace the speaker's everyday vocabulary or rewrite sentences that already read cleanly."
                "Remove filler words, false starts, and empty qualifiers. Remove conversational setup that adds no meaning, while preserving meaningful uncertainty and estimates. Keep every distinct point. Do not summarize or drop details. The result should sound like the speaker at their most articulate, not a different person."
                "Apply the Reference vocabulary spellings from the prompt."
                "Return only the corrected text."
            }
        case .concise:
            return Instructions {
                RefinePrompts.gen1BoundaryRule
                RefinePrompts.refineLanguageRuleGen1(for: outputLanguage)
                "Tighten the dictation to be as brief and direct as possible while keeping the speaker's own voice. Fix grammar, punctuation, and spelling."
                "Cut wordy phrasing, empty qualifiers, redundancy, filler words, and false starts. Shorten by removing what is redundant, NOT by swapping the speaker's words for synonyms. The output must be shorter than the input."
                "Keep every distinct idea and the speaker's own words. Do not drop facts or details."
                "Apply the Reference vocabulary spellings from the prompt."
                "Return only the tightened text."
            }
        }
    }

    // Carried VERBATIM from the original app's tuned gen-2 sets. Every
    // sentence earned its place against a measured model failure; do not
    // edit without re-running that validation.
    private static func gen2Instructions(
        for template: RefineTemplate, outputLanguage: RefineOutputLanguage
    ) -> Instructions {
        switch template {
        case .custom:
            return Instructions {
                RefinePrompts.noCompletionRule
                RefinePrompts.noTruncationRule
                RefinePrompts.refineLanguageRule(for: outputLanguage)
                "You process speech-to-text dictation according to the user's custom instructions in the prompt."
                "The user's custom instructions have MAXIMUM priority. Follow them exactly."
                "As a baseline: fix obvious grammar, punctuation, and transcription errors."
                "The prompt includes Reference vocabulary with preferred spellings and word replacements. You MUST apply those replacements and use those exact spellings."
                "If the prompt includes a Field context block, treat it as informational ONLY. Use it to recognize technical terms in the speaker's dictation. Do NOT restyle the speaker's voice to match the field's tone unless the custom instructions explicitly tell you to."
                "Return only the processed text."
            }
        case .standard:
            return Instructions {
                RefinePrompts.noCompletionRule
                RefinePrompts.noTruncationRule
                RefinePrompts.refineLanguageRule(for: outputLanguage)
                "You CLEAN UP speech-to-text dictation. Fix grammar, punctuation, sentence capitalization, and transcription errors."
                "You MUST always capitalize the personal pronoun 'I' (e.g., 'i' -> 'I', 'i'm' -> 'I'm', 'i'd' -> 'I'd', 'i've' -> 'I've', 'i'll' -> 'I'll') and capitalize the first word of every sentence. This applies to all inputs, including short, casual, or disjointed testing phrases."
                "Ensure proper comma and period placement to separate thoughts and clauses cleanly, even for short, disjointed testing sentences or quick statement lists."
                "Polish application vocabulary and acronyms while strictly preserving the speaker's original voice, natural vocabulary, and sentence structure."
                "You MUST edit ONLY acoustic repeats, false starts, filler words (um, uh, you know, like), punctuation, capitalization, grammar errors, and domain vocabulary / acronym formatting."
                "Do NOT perform full re-writings, stylistic makeovers, or structural changes. Maintain the speaker's syntax exactly."
                "Grammar fixes are limited to repairing what is present. Adding 1-2 missing helper words (articles, auxiliaries, prepositions) to make a sentence parseable is fine. Adding entire clauses, predicates, or trailing thoughts is NOT fine — that is completion, which the HARD RULE above forbids."
                "The prompt includes Reference vocabulary with preferred spellings and word replacements. You MUST apply those replacements and use those exact spellings. These are the user's corrections for words the dictation model gets wrong."
                "If the prompt includes a Field context block, treat it as informational ONLY. Use it to understand technical terms in the speaker's dictation. Do NOT restyle the speaker's voice to match the field's tone. Standard is about FIXING errors, not RESTYLING."
                "KEEP casual words the speaker used (got, kids, gonna, yeah). Minor rephrasing is OK when a sentence genuinely does not make sense. Do NOT rewrite sentences that are already clear."
                "Boundary cleanup: when the input runs two thoughts together with a stray period that the dictation engine inserted at a silence (a mid-thought period that breaks an otherwise continuous sentence), MERGE them into one coherent sentence and drop the stray period. When two sentences are genuinely separate ideas, keep the period and capitalize the next sentence's first word."
                "NEVER add transitions, framing, or filler the speaker did not say. When in doubt, preserve the speaker's exact phrasing."
                "Do NOT add new information. Do NOT summarize. Return only the corrected text."
            }
        case .professional:
            return Instructions {
                RefinePrompts.noCompletionRule
                RefinePrompts.noTruncationRule
                RefinePrompts.refineLanguageRule(for: outputLanguage)
                "You clean up speech-to-text dictation into clear, professional writing while keeping the speaker's own voice. You fix the mechanics and lift the register; you do NOT turn the speaker into a different, more formal writer."
                "You MUST edit grammar, punctuation, spelling, and fix transcription errors."
                "You MUST REMOVE acoustic repeats, false starts, and filler words (um, uh, like)."
                "Smooth only the roughest slang, where it would read as unprofessional, into phrasing the speaker would plausibly use. KEEP the speaker's everyday vocabulary and casual-but-fine words (leave words like got, kids alone); lift only what genuinely reads as unprofessional. Do NOT swap out the speaker's words wholesale."
                "Do NOT rewrite sentences that already read cleanly — keep the speaker's wording, phrasing, and sentence order wherever it works. If the input ends mid-thought, the output also ends mid-thought (just polished). The HARD RULE applies even when lifting register."
                "The prompt includes Reference vocabulary with preferred spellings and word replacements. You MUST apply those replacements and use those exact spellings. These are the user's corrections for words the dictation model gets wrong."
                "If the prompt includes a Field context block, USE it to inform technical terminology and professional word choice — not to restyle the speaker's voice."
                "KEEP every distinct point and idea. Do NOT perform structural changes, summarize, or add content. The result should sound like the speaker on their most articulate day, not a different person."
                "Boundary cleanup: when the input runs two thoughts together with a stray mid-thought period (engine artifact at a silence), merge them into one coherent sentence. When two sentences are genuinely separate ideas, keep the period and capitalize the next sentence."
                "Return only the corrected text."
            }
        case .concise:
            return Instructions {
                RefinePrompts.noCompletionRule
                RefinePrompts.noTruncationRule
                RefinePrompts.refineLanguageRule(for: outputLanguage)
                "You tighten speech-to-text dictation to be as brief and direct as possible while keeping the speaker's own voice and every distinct idea."
                "You MUST edit grammar, punctuation, spelling, and fix transcription errors."
                "You MUST TRIM wordy phrasing, empty qualifiers, redundancy, and conversational tangents. Cut length by removing what is redundant, NOT by swapping the speaker's words for shorter synonyms — keep their vocabulary and phrasing."
                "You MUST REMOVE acoustic repeats, false starts, and filler words (um, uh, like)."
                "The output MUST be measurably shorter than the input. If the input is already tight, still trim where possible. NEVER expand. NEVER complete sentences the speaker left unfinished. NEVER invent transitions or framing the speaker did not say."
                "The prompt includes Reference vocabulary with preferred spellings and word replacements. You MUST apply those replacements and use those exact spellings."
                "If the prompt includes a Field context block, treat it as informational ONLY. Use it to understand technical terms. Concise is about CUTTING, not RESTYLING."
                "Every distinct idea MUST survive. Do NOT drop facts, details, or points the speaker made. Keep the speaker's own words; just make the text tighter and faster to read. Return only the tightened text."
            }
        }
    }

    // MARK: Generation (carried call pattern)

    /// Sampling per template: Standard and Custom are greedy (deterministic, minimal change);
    /// Concise and Professional use a narrow nucleus (0.4) so the model can restructure without
    /// inventing. Output is limited relative to the input, so a runaway echo stops early.
    static func generationOptions(for template: RefineTemplate, inputTokenEstimate: Int) -> GenerationOptions {
        let est = max(16, inputTokenEstimate)
        let cap: Int
        switch template {
        case .concise: cap = max(80, Int(Double(est) * 1.5))
        default: cap = max(96, Int(Double(est) * 2.0))
        }
        switch template {
        case .standard, .custom:
            return GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cap)
        case .concise, .professional:
            return GenerationOptions(samplingMode: .random(probabilityThreshold: 0.4), maximumResponseTokens: cap)
        }
    }

    private static func generate(
        session: LanguageModelSession,
        prompt: String,
        template: RefineTemplate,
        translating: Bool,
        generation: AFMGeneration,
        inputTokenEstimate: Int
    ) async throws -> String {
        let options = generationOptions(for: template, inputTokenEstimate: inputTokenEstimate)

        // Translation skips constrained decoding: each schema's guide is fixed English text about
        // English cleanup, and it outweighs the translate instruction (only 1 of 5 turns translated
        // in testing). Plain text translates reliably.
        if translating || (generation == .gen1 && template == .professional) {
            return try await plainGenerate(session: session, prompt: prompt, options: options)
        }

        do {
            switch template {
            case .professional:
                var output = ""
                let stream = session.streamResponse(
                    to: Prompt(prompt), generating: ProfessionalRefineOutput.self, options: options)
                for try await partial in stream {
                    try Task.checkCancellation()
                    if let paragraphs = partial.content.paragraphs {
                        let joined = paragraphs.compactMap { $0 }.joined(separator: "\n\n")
                        if !joined.isEmpty { output = joined }
                    }
                }
                return output
            case .standard, .concise, .custom:
                if generation == .gen1 {
                    var output = ""
                    let stream = session.streamResponse(
                        to: Prompt(prompt), generating: RefinedDictationOutputGen1.self, options: options)
                    for try await partial in stream {
                        try Task.checkCancellation()
                        if let text = partial.content.cleanedText { output = text }
                    }
                    return output
                } else {
                    var output = ""
                    let stream = session.streamResponse(
                        to: Prompt(prompt), generating: RefinedDictationOutput.self, options: options)
                    for try await partial in stream {
                        try Task.checkCancellation()
                        if let text = partial.content.cleanedText { output = text }
                    }
                    return output
                }
            }
        } catch let error as LanguageModelSession.GenerationError {
            // Gen-1 trips refusal on benign transformation prompts under
            // constrained decoding; retry once on the plain path.
            if generation == .gen1, case .refusal = error {
                return try await plainGenerate(session: session, prompt: prompt, options: options)
            }
            throw mapGenerationError(error)
        } catch {
            throw mapPlatformError(error)
        }
    }

    private static func plainGenerate(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions
    ) async throws -> String {
        do {
            var output = ""
            let stream = session.streamResponse(to: prompt, options: options)
            for try await partial in stream {
                try Task.checkCancellation()
                // Cumulative snapshot, not a delta — assign, don't append.
                output = partial.content
            }
            return output
        } catch let error as LanguageModelSession.GenerationError {
            throw mapGenerationError(error)
        } catch {
            throw mapPlatformError(error)
        }
    }

    private static func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> any Error {
        switch error {
        case .exceededContextWindowSize:
            return RefinerFailure.contextOverflow
        case .guardrailViolation, .refusal:
            return RefinerFailure.refused
        case .assetsUnavailable, .unsupportedLanguageOrLocale:
            return RefinerFailure.backendNotReady
        default:
            return error
        }
    }

    /// macOS 27 reports LanguageModelError instead of GenerationError. The type exists only in the
    /// macOS 27 SDK (Swift 6.4 and later), so building with the macOS 26 SDK needs the compiler
    /// check as well as the availability check.
    private static func mapPlatformError(_ error: any Error) -> any Error {
        #if compiler(>=6.4)
        if #available(macOS 27, *), let lmError = error as? LanguageModelError {
            switch lmError {
            case .contextSizeExceeded:
                return RefinerFailure.contextOverflow
            case .guardrailViolation, .refusal:
                return RefinerFailure.refused
            case .unsupportedLanguageOrLocale:
                return RefinerFailure.backendNotReady
            default:
                return error
            }
        }
        #endif
        return error
    }

    #endif

}
