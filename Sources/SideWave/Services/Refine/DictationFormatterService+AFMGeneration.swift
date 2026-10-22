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

#if canImport(FoundationModels)

extension DictationFormatterService {
    /// Content-preserving templates use greedy sampling. Prose templates use
    /// narrow nucleus sampling, with a bounded response to stop runaway output.
    nonisolated static func afmGenerationOptions(for template: Template, inputTokenEstimate: Int) -> GenerationOptions {
        // Limit decoding to a length proportional to the input so a runaway echo stops early.
        // Generous on purpose: a real refine stays under twice its input, structured templates get
        // more room, and concise output is always shorter.
        let est = max(16, inputTokenEstimate)
        let cap: Int
        switch template {
        case .concise:                   cap = max(80, Int(Double(est) * 1.5))
        case .emailReady, .instructions: cap = max(160, Int(Double(est) * 3.0))
        default:                         cap = max(96, Int(Double(est) * 2.0))
        }
        switch template {
        case .standard:
            return GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cap)
        case .custom:
            return GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cap)
        case .concise:
            return GenerationOptions(samplingMode: .random(probabilityThreshold: 0.4), maximumResponseTokens: cap)
        case .professional:
            return GenerationOptions(samplingMode: .random(probabilityThreshold: 0.4), maximumResponseTokens: cap)
        case .emailReady:
            return GenerationOptions(samplingMode: .random(probabilityThreshold: 0.5), maximumResponseTokens: cap)
        case .instructions:
            return GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cap)
        case .aiPrompt:
            // Structured XML uses greedy sampling, per Apple's guidance for transformations, so the
            // same input gives the same tags. XML can grow well past the input, so it gets the most
            // room.
            return GenerationOptions(samplingMode: .greedy, maximumResponseTokens: max(256, est * 4))
        }
    }

    /// A new session for each cleanup request. A session keeps every prompt and answer in its
    /// transcript and replays it, so reusing one would feed each segment the earlier segments on top of
    /// `priorContext` (bringing back duplication) and grow toward the first generation's 4K limit.
    /// Rebuilding is cheap by comparison. Instructions match the running generation; guardrails are
    /// permissive because the content is the user's own.
    func ensureAFMSession(for template: Template, outputLanguage: OutputLanguage = .matchInput, customInstructions: String = "") {
        let model = AFMRuntime.makeModel()
        guard case .available = model.availability else { return }
        let session = LanguageModelSession(
            model: model,
            instructions: Instructions {
                Self.afmInstructions(for: template, generation: Self.effectiveAFMGeneration, outputLanguage: outputLanguage, speakerProfile: SpeechProfileStore.shared.promptText)
                if template == .custom, !customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    "The user selected this document format: \(String(customInstructions.prefix(Self.maxCustomInstructionsChars)))"
                }
            }
        )
        // prewarm() is a synchronous load hint that can block for hundreds
        // of ms; on the MainActor it stalls the live-preview paints that
        // queue behind it. Fire it off-main; generation works either way.
        let warmSession = session
        Task.detached(priority: .utility) { warmSession.prewarm() }
        afmSessionHolder = session
        afmSessionTemplate = template
    }

    /// Session-turns version of `ensureAFMSession`: one session per dictation and a short turn prompt
    /// per segment. Earlier text lives in the session transcript, so a turn processes about 40 tokens
    /// plus a reminder instead of about 600 tokens of Instructions and the growing context.
    ///
    /// The session is rebuilt, and its first turn reseeded with recent refined text, when:
    /// - there's no session yet,
    /// - the template changed,
    /// - beginDictation cleared the previous context, or
    /// - the token estimate would pass about 55% of the context window. The window is 4096 tokens and
    ///   the transcript counts against it, so a long dictation would otherwise overflow.
    ///
    /// Returns nil if the model became unavailable, and the caller starts fresh. Main actor only.
    func prepareAFMTurnSession(settings: Settings, rawText: String) -> String? {
        let template = settings.template
        let priorContext = settings.priorContext ?? ""
        let priorEmpty = priorContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Cached at (re)build; the OS context window can't change mid-
        // dictation, and afmContextSize() is an out-of-process query that was
        // running on the MainActor once per turn.
        if afmTurnContextCap == 0 { afmTurnContextCap = Self.afmContextSize() }
        let cap = afmTurnContextCap
        // Conservative estimate: characters divided by 4 under-counted real tokens by 40 to 50% in
        // testing, and an overflowed session stays overflowed. Estimate characters divided by 3,
        // rebuild at 55% of the window, and treat contextOverflow during generation as a hard
        // reset. The base covers Instructions and the schema.
        let rebuildThreshold = Int(Double(cap) * 0.55)
        let sessionBaseTokens = 900
        // Approx tokens this turn's input adds: the slice plus reminder overhead.
        let turnInputTokens = max(1, rawText.count / 3) + 120

        var needsRebuild = false
        if afmTurnSessionHolder == nil { needsRebuild = true }
        else if afmTurnIdentity != settings.turnPromptIdentity { needsRebuild = true }
        else if afmTurnSessionOutputLanguage != settings.outputLanguage { needsRebuild = true }
        else if afmTurnTokenEstimate + turnInputTokens >= rebuildThreshold { needsRebuild = true }

        if needsRebuild {
            let model = AFMRuntime.makeModel()
            guard case .available = model.availability else { return nil }
            let session = LanguageModelSession(
                model: model,
                instructions: Self.afmInstructions(for: template, generation: Self.effectiveAFMGeneration, outputLanguage: settings.outputLanguage, speakerProfile: settings.speakerProfile)
            )
            // prewarm() is a synchronous load hint that can block for hundreds
            // of ms; on the MainActor it stalls the live-preview paints that
            // queue behind it. Fire it off-main; generation works either way.
            let warmSession = session
            Task.detached(priority: .utility) { warmSession.prewarm() }
            afmTurnSessionHolder = session
            afmTurnIdentity = settings.turnPromptIdentity
            afmTurnSessionTemplate = template
            afmTurnSessionOutputLanguage = settings.outputLanguage
            // Base estimate for Instructions + schema, counted once per session.
            afmTurnTokenEstimate = sessionBaseTokens
        }

        // Seed a compact tail of the prior refined text into the first turn of a
        // freshly (re)built session so continuity survives the rebuild. On a
        // genuine fresh start (priorEmpty) there is nothing to seed.
        let seedTail: String? = (needsRebuild && !priorEmpty) ? Self.continuitySeed(priorContext) : nil
        let prompt = Self.buildAFMTurnPrompt(
            rawText: rawText,
            settings: settings,
            seedTail: seedTail,
            isFirstTurn: needsRebuild
        )
        // Account for this turn's prompt and the model's reply (both land in the
        // transcript). Reply ≈ the slice length; estimate it from the input.
        afmTurnTokenEstimate += max(1, prompt.count / 3) + max(1, rawText.count / 3)
        return prompt
    }

    /// Activates Apple Intelligence: nothing to download, so this checks availability and prepares
    /// a default session to reduce first-use latency. Moves to `.unavailable` with an explanation
    /// if Apple Intelligence is off or the Mac isn't eligible.
    func loadAppleIntelligence() async {
        state = .loading
        // Permissive guardrails, since this transforms the user's own dictation. Apple recommends
        // this for text transformation.
        let model = AFMRuntime.makeModel()
        switch model.availability {
        case .available:
            let defaultTemplate = Template(rawValue: UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? "") ?? .standard
            // Warm-up session with the saved output language, so a first refine that skips the
            // rebuild still uses it.
            let outputLanguage = OutputLanguage.from(code: UserDefaults.standard.string(forKey: "dictationOutputLanguage"))
            let session = LanguageModelSession(
                model: model,
                instructions: Self.afmInstructions(for: defaultTemplate, generation: Self.effectiveAFMGeneration, outputLanguage: outputLanguage, speakerProfile: SpeechProfileStore.shared.promptText)
            )
            // Finish the off-main warm-up before reporting Ready.
            let warmSession = session
            await Task.detached(priority: .utility) { warmSession.prewarm() }.value
            guard !Task.isCancelled, activeBackend == .appleIntelligence || activeBackend == .appleIntelligenceLegacy else { return }
            // Check for teardown before keeping the session: if Refine was turned off during
            // warm-up, drop it.
            switch state {
            case .disabled, .unloaded:
                return
            default:
                break
            }
            self.afmSessionHolder = session
            self.afmSessionTemplate = defaultTemplate
            self.state = .ready
            SWLog.note("[DictationFormatter] Apple Intelligence ready")
        case .unavailable(let reason):
            self.state = .unavailable(Self.afmUnavailableMessage(for: reason))
        @unknown default:
            self.state = .unavailable("Apple Intelligence is unavailable on this device.")
        }
    }

    /// Apple Intelligence generation with schema-constrained decoding. Template rules are in the
    /// session Instructions; the prompt carries context, vocabulary, and the text.
    /// - Parameter promptOverride: In session-turns mode, the turn prompt to send instead of
    ///   `buildPrompt`'s full prompt.
    nonisolated static func runAFMGeneration(
        sessionHolder: Any?,
        rawText: String,
        settings: Settings,
        promptOverride: String? = nil,
        onStream: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let signpostID = signposter.makeSignpostID()
        let signpostState = signposter.beginInterval("runAFMGeneration", id: signpostID)
        defer { signposter.endInterval("runAFMGeneration", signpostState) }

        guard let preparedSession = sessionHolder as? LanguageModelSession else {
            throw FormatterError.backendNotReady
        }
        let structured = settings.template == .aiPrompt || settings.template == .instructions
        let session: LanguageModelSession
        if structured && promptOverride == nil {
            session = LanguageModelSession(model: AFMRuntime.makeModel(), instructions: Instructions {
                afmInstructions(for: settings.template, generation: effectiveAFMGeneration,
                    outputLanguage: settings.outputLanguage, speakerProfile: settings.speakerProfile)
                processingInstructions(rawText: rawText, settings: settings)
            })
        } else {
            session = preparedSession
        }
        let prompt = promptOverride ?? buildPrompt(rawText: rawText, settings: settings, structuredDocument: structured)

        // Check token usage against the context window only when the prompt might be near it. The
        // count is an on-device round trip of 20 to 80 ms, which added up across segment refines.
        // Prompts under 8000 characters (about 2100 tokens) are far below the limit and skip it. A
        // prompt that still overflows mid-stream falls back to the TDT text through the error path.
        if #available(macOS 26.4, *), prompt.count > 8_000 {
            if let usage = await afmTokenUsage(forPrompt: prompt, template: settings.template),
               usage.ratio >= 0.85 {
                // Past the safe limit: fall back to TDT text through the contextOverflow path.
                // AppState shows a short toast.
                throw FormatterError.contextOverflow
            }
        }

        var output = ""
        // CFAbsoluteTimeGetCurrent avoids per-token Date() allocation in the
        // tight streaming loop.
        var lastStreamUpdate: CFAbsoluteTime = 0

        let options = Self.afmGenerationOptions(for: settings.template, inputTokenEstimate: max(16, rawText.count / 4))

        // Translation skips schema-constrained decoding. Every schema's guide is a fixed English
        // string about English cleanup, and under guided generation it outweighs the translate
        // instruction, so the model answered in the source language on most turns. On an M4 Max
        // with macOS 27, the constrained path translated only the first turn of a 5-segment Chinese
        // dictation, while plain text translated all of them. Structured templates lose enforced
        // shape when translating; their formatting rules still apply through the Instructions.
        //
        // Second generation guided instructions can also reject harmless requests, so document data
        // is decoded as a string and rendered with the same checked renderer as Gemma.
        if settings.outputLanguage == .matchInput,
           Self.effectiveAFMGeneration == .gen2, settings.template == .instructions {
            let dataOptions = GenerationOptions(samplingMode: .greedy,
                maximumResponseTokens: max(512, rawText.count * 3))
            var request = prompt
            for attempt in 0..<2 {
                let response = try await session.respond(to: Prompt(request), options: dataOptions)
                try Task.checkCancellation()
                do {
                    let json = DocumentEditFormatting.clean(response.content, original: rawText)
                    let document = try DocumentEditFormatting.decodeDocument(DocumentEditFormatting.InstructionDocument.self, from: json)
                    let instructionText = session.transcript.compactMap { entry -> String? in
                        guard case .instructions(let value) = entry else { return nil }
                        return value.segments.compactMap { segment -> String? in
                            guard case .text(let text) = segment else { return nil }
                            return text.content
                        }.joined(separator: "\n")
                    }.joined(separator: "\n")
                    let checked = DocumentEditFormatting.excludingInstructionEcho(document, source: rawText, instructions: instructionText)
                    let rendered = try DocumentEditFormatting.renderInstructions(checked)
                    onStream(rendered)
                    return rendered
                } catch {
                    guard attempt == 0 else { throw DocumentEditFormatting.StructureError.invalid }
                    request = prompt + "\n\nReturn a complete valid JSON object matching the required document structure."
                }
            }
            throw DocumentEditFormatting.StructureError.invalid
        }
        // AFM 2 follows sentence-repair instructions more reliably in plain text.
        // A single-field schema can preserve an ASR break despite those instructions.
        if settings.outputLanguage != .matchInput
            || (Self.effectiveAFMGeneration == .gen1
                && [.standard, .professional, .concise].contains(settings.template)) {
            return try await runAFMPlainGeneration(session: session, prompt: prompt, options: options, onStream: onStream)
        }

        do {
            // Typed email and instruction responses stream rendered text.
            // XML is validated before delivery; custom layouts use free text.
            switch settings.template {
            case .emailReady:
                let stream = session.streamResponse(
                    to: Prompt(prompt),
                    generating: AFMEmailReadyOutput.self,
                    options: options
                )
                for try await partial in stream {
                    try Task.checkCancellation()
                    let partialRender = Self.renderEmailReadyPartial(partial.content)
                    if !partialRender.isEmpty {
                        output = partialRender
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastStreamUpdate > 0.1 {
                            onStream(output)
                            lastStreamUpdate = now
                        }
                    }
                }
            case .instructions:
                let stream = session.streamResponse(
                    to: Prompt(prompt),
                    generating: AFMInstructionListOutput.self,
                    options: options
                )
                for try await partial in stream {
                    try Task.checkCancellation()
                    let partialRender = Self.renderInstructionListPartial(partial.content)
                    if !partialRender.isEmpty {
                        output = partialRender
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastStreamUpdate > 0.1 {
                            onStream(output)
                            lastStreamUpdate = now
                        }
                    }
                }
            case .aiPrompt:
                let response = try await session.respond(to: Prompt(prompt), generating: AFMPromptDocumentOutput.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: max(512, rawText.count)))
                try Task.checkCancellation()
                output = try DocumentEditFormatting.renderPrompt(.init(sections: [.init(tag: "task", text: response.content.task)] + response.content.sections.filter { $0.tag != "task" }.map {
                    .init(tag: $0.tag, text: $0.text)
                }))
                onStream(output)
            case .professional:
                let stream = session.streamResponse(
                    to: Prompt(prompt),
                    generating: AFMProfessionalOutput.self,
                    options: options
                )
                for try await partial in stream {
                    try Task.checkCancellation()
                    let partialRender = Self.renderProfessionalPartial(partial.content)
                    if !partialRender.isEmpty {
                        output = partialRender
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastStreamUpdate > 0.1 {
                            onStream(output)
                            lastStreamUpdate = now
                        }
                    }
                }
            case .custom:
                // Custom layouts need the model's text stream. A cleanup schema
                // can suppress the requested list markers on macOS 26.
                let stream = session.streamResponse(to: Prompt(prompt), options: options)
                for try await partial in stream {
                    try Task.checkCancellation()
                    output = DocumentEditFormatting.clean(partial.content, original: rawText)
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastStreamUpdate > 0.1 {
                        onStream(output)
                        lastStreamUpdate = now
                    }
                }
            case .standard, .concise:
                let stream = session.streamResponse(
                    to: Prompt(prompt),
                    generating: AFMRefinedDictation.self,
                    options: options
                )
                for try await partial in stream {
                    try Task.checkCancellation()
                    if let text = partial.content.cleanedText {
                        output = text
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastStreamUpdate > 0.1 {
                            onStream(output)
                            lastStreamUpdate = now
                        }
                    }
                }
            }
        } catch let error as LanguageModelSession.GenerationError {
            // The first generation model (macOS 26) refuses some harmless transformation prompts
            // under constrained decoding. Retry once with a plain prompt and use that output;
            // cleanupModelOutput removes common preambles.
            if Self.effectiveAFMGeneration == .gen1, case .refusal = error {
                return try await runAFMPlainGeneration(
                    session: session,
                    prompt: prompt,
                    options: options,
                    onStream: onStream
                )
            }
            if Self.retriesDeclineAsPlainText(settings.template) {
                switch error {
                case .guardrailViolation, .refusal:
                    return try await runAFMPlainRetry(session: session, prompt: prompt, rawText: rawText,
                                                      options: options, onStream: onStream)
                default: break
                }
            }
            // Map framework errors to FormatterError so AppState can surface
            // specific silent-fallback toasts.
            switch error {
            case .exceededContextWindowSize:
                throw FormatterError.contextOverflow
            case .guardrailViolation, .refusal:
                // On gen-2 a refusal falls through to here (gen-1 retried
                // above). Surface the dedicated refusal copy rather than the
                // generic "Refine failed" from the outer catch.
                throw FormatterError.refused
            case .assetsUnavailable, .unsupportedLanguageOrLocale:
                throw FormatterError.backendNotReady
            default:
                throw error
            }
        } catch {
            // macOS 27 reports LanguageModelError instead of the deprecated
            // GenerationError.unsupportedLanguageOrLocale. The type exists only in the macOS 27 SDK
            // (Swift 6.4 and later), so it needs both this compiler check and an availability
            // check. Apps built with the macOS 26 SDK receive GenerationError even on macOS 27, so
            // the catch below covers them.
            #if compiler(>=6.4)
            if #available(macOS 27, *), let lmError = error as? LanguageModelError {
                switch lmError {
                case .contextSizeExceeded:
                    throw FormatterError.contextOverflow
                case .guardrailViolation, .refusal:
                    if Self.retriesDeclineAsPlainText(settings.template) {
                        return try await runAFMPlainRetry(session: session, prompt: prompt, rawText: rawText,
                                                          options: options, onStream: onStream)
                    }
                    throw FormatterError.refused
                case .unsupportedLanguageOrLocale:
                    throw FormatterError.backendNotReady
                default:
                    throw error
                }
            }
            #endif
            throw error
        }

        let final = output.trimmingCharacters(in: .whitespacesAndNewlines)
        onStream(final)
        return final
    }

    /// The second generation model's guardrails also apply to guided output, while permissive
    /// guardrails let plain text through, so a declined prose refine is asked again as plain text.
    /// Structured templates keep their schemas and fall back to the captured text.
    nonisolated static func retriesDeclineAsPlainText(_ template: Template) -> Bool {
        effectiveAFMGeneration == .gen2 && [.standard, .concise, .professional].contains(template)
    }

    nonisolated private static func runAFMPlainRetry(
        session: LanguageModelSession,
        prompt: String,
        rawText: String,
        options: GenerationOptions,
        onStream: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let output = try await runAFMPlainGeneration(session: session, prompt: prompt, options: options, onStream: { _ in })
        guard !looksLikeModelRefusal(output, input: rawText) else { throw FormatterError.refused }
        onStream(output)
        return output
    }

    /// A plain-text answer can decline in words instead of with an error. It counts as a decline
    /// when it adds a first-person refusal or apology the speaker didn't say, or when almost none
    /// of its words are the speaker's. Punctuation and contractions are normalized first, so a
    /// dictated "sorry but I can't make it" stays a dictation.
    nonisolated static func looksLikeModelRefusal(_ output: String, input: String) -> Bool {
        func normalized(_ text: String) -> String {
            var text = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
            text = String(text.map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " })
            for (short, long) in [("can't", "cannot"), ("can not", "cannot"), ("won't", "will not"),
                                  ("i'm", "i am"), ("don't", "do not"), ("'d", " would")] {
                text = text.replacingOccurrences(of: short, with: long)
            }
            return " " + text.split(separator: " ").joined(separator: " ") + " "
        }
        let answer = normalized(output)
        let spoken = normalized(input)
        let markers = ["i cannot", "i am unable", "i am not able", "i will not be able", "i must decline",
                       "i do not feel comfortable", "i apologize", "i am sorry", "sorry but", "as an ai",
                       "unable to assist", "unable to help", "cannot assist", "cannot help with",
                       "cannot provide", "cannot fulfill"]
        if markers.contains(where: { answer.contains(" \($0) ") && !spoken.contains(" \($0) ") }) { return true }
        // Backstop for a refusal without those words. A cleanup keeps far more of the speaker's
        // words than this, even with grammar fixes and acronyms.
        let answerWords = answer.split(separator: " ").filter { $0.count >= 3 }
        guard answerWords.count >= 4 else { return false }
        let said = Set(spoken.split(separator: " "))
        return Double(answerWords.filter(said.contains).count) / Double(answerWords.count) < 0.2
    }

    /// Apple Intelligence generation without a schema: streams text, cleans preambles, quotes, and
    /// fences with `cleanupModelOutput`, and throws `FormatterError.refused` on refusal so AppState
    /// can fall back. Used for translation, first generation prose and refusal recovery, and second
    /// generation numbered instructions.
    nonisolated private static func runAFMPlainGeneration(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions,
        onStream: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        var output = ""
        var lastStreamUpdate: CFAbsoluteTime = 0
        do {
            let stream = session.streamResponse(to: prompt, options: options)
            for try await partial in stream {
                try Task.checkCancellation()
                output = partial.content
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastStreamUpdate > 0.1 {
                    onStream(output)
                    lastStreamUpdate = now
                }
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw FormatterError.contextOverflow
            case .guardrailViolation, .refusal:
                throw FormatterError.refused
            case .assetsUnavailable, .unsupportedLanguageOrLocale:
                throw FormatterError.backendNotReady
            default:
                throw error
            }
        } catch {
            // macOS 27 error type; see the note in runAFMGeneration.
            #if compiler(>=6.4)
            if #available(macOS 27, *), let lmError = error as? LanguageModelError {
                switch lmError {
                case .contextSizeExceeded:
                    throw FormatterError.contextOverflow
                case .guardrailViolation, .refusal:
                    throw FormatterError.refused
                case .unsupportedLanguageOrLocale:
                    throw FormatterError.backendNotReady
                default:
                    throw error
                }
            }
            #endif
            throw error
        }
        let cleaned = cleanupModelOutput(output)
        onStream(cleaned)
        return cleaned
    }

    /// Apple Intelligence live status in its own one-shot session, with analysis Instructions and
    /// the user's vocabulary, decoded into the AFMLiveStatus schema. Separate from the refine
    /// session, whose Instructions would override the analysis prompt.
    nonisolated static func runAFMLiveStatus(
        rawText: String,
        template: Template,
        vocabSection: String
    ) async -> SpecialtyLiveStatus? {
        let model = AFMRuntime.makeModel()
        guard case .available = model.availability else { return nil }

        let instructions = Instructions {
            "You analyze a live, in-progress dictation and report your understanding of it. You do NOT edit, clean, rewrite, or output the dictation itself."
            "Summarize what the speaker is dictating and how you would format the final \(template.displayName) document once they finish."
            "List clarifying questions ONLY when real information is missing to complete a high-quality \(template.displayName); otherwise return an empty list."
            "The prompt may include a Reference vocabulary section — use it to read the speaker's jargon, names, and acronyms correctly."
        }
        let session = LanguageModelSession(model: model, instructions: instructions)

        var prompt = """
        Here is what the user has dictated so far:
        \"\"\"
        \(rawText)
        \"\"\"
        """
        if !vocabSection.isEmpty {
            prompt += "\n\n" + vocabSection
        }

        do {
            var understanding = ""
            var plannedAction = ""
            var questions: [String] = []
            let stream = session.streamResponse(
                to: Prompt(prompt),
                generating: AFMLiveStatus.self,
                options: GenerationOptions(samplingMode: .greedy)
            )
            for try await partial in stream {
                try Task.checkCancellation()
                if let u = partial.content.understanding { understanding = u }
                if let p = partial.content.plannedAction { plannedAction = p }
                if let q = partial.content.questions { questions = q }
            }
            let cleanedQuestions = questions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.lowercased() != "none" }
            return SpecialtyLiveStatus(
                understanding: understanding.isEmpty ? "Analyzing your dictation\u{2026}" : understanding,
                plannedAction: plannedAction.isEmpty ? "Structuring the final document\u{2026}" : plannedAction,
                questions: cleanedQuestions
            )
        } catch {
            Self.logger.error("runAFMLiveStatus error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
#endif
