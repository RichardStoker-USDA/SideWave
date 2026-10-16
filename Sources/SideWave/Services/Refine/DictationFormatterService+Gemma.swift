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
    // MARK: - Private: Generation (Gemma)

    /// Runs Gemma generation off the main actor, with inputs captured by value. `onStream` receives
    /// the accumulated text about 10 times a second for the preview.
    nonisolated static func runGemmaGeneration(
        container: ModelContainer,
        rawText: String,
        settings: Settings,
        onStream: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let signpostID = signposter.makeSignpostID()
        let signpostState = signposter.beginInterval("runGemmaGeneration", id: signpostID)
        defer { signposter.endInterval("runGemmaGeneration", signpostState) }

        if settings.template == .instructions || settings.template == .aiPrompt {
            return try await runGemmaDocumentGeneration(container: container, rawText: rawText, settings: settings, onStream: onStream)
        }
        let prompt = buildPrompt(rawText: rawText, settings: settings)
        let sysPrompt = gemmaSystemPrompt(
            for: settings.template,
            removeFillers: settings.removeFillerWords,
            outputLanguage: settings.outputLanguage,
            speakerProfile: settings.speakerProfile
        )
        let params = gemmaGenerateParameters(settings: settings, rawText: rawText)
        // Gemma 4 thinking mode through the chat template's `enable_thinking`. Off unless the user
        // enables it (`gemmaThinkingMode`) and only for hold to refine, since the hidden reasoning
        // block makes it two to three times slower.
        let useThinking = settings.useThinkingMode
        let additionalContext: [String: any Sendable] = ["enable_thinking": useThinking]
        // A new session per refine re-processes the whole prompt every call. Segment refines
        // normally use runGemmaTurnGeneration instead; this path covers whole-text passes, thinking
        // mode, and fallbacks.
        let session = ChatSession(container, instructions: sysPrompt, generateParameters: params,
                                  additionalContext: additionalContext)
        var output = ""
        var lastStreamUpdate: CFAbsoluteTime = 0
        for try await generation in session.streamDetails(to: prompt) {
            try Task.checkCancellation()
            if let info = generation.info { try checkCompletion(info) }
            guard let chunk = generation.chunk else { continue }
            output += chunk
            // Throttle UI updates to ~10fps to avoid flooding MainActor with Tasks
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastStreamUpdate > 0.1 {
                // Thinking mode emits a hidden <|think|> block first; never
                // surface it to the overlay. Strip is a no-op when absent.
                onStream(Self.stripGemmaThinkBlock(output))
                lastStreamUpdate = now
            }
        }
        // Strip the thinking-mode block before cleanup + the ratio gate. Without
        // this the <|think|> reasoning inflates the word count, blows the gate,
        // and hold-to-refine / full-pass on Gemma silently pastes raw.
        let cleaned = cleanupModelOutput(Self.stripGemmaThinkBlock(output))
        onStream(cleaned) // Final update with cleaned text
        return cleaned
    }

    /// Render fixed document formats from model data instead of generated markup.
    nonisolated private static func runGemmaDocumentGeneration(
        container: ModelContainer, rawText: String, settings: Settings,
        onStream: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let shape = documentDataInstructions(template: settings.template, outputLanguage: settings.outputLanguage)
        let instructions = shape
        var params = gemmaGenerateParameters(settings: settings, rawText: rawText)
        params.maxTokens = max(1_024, params.maxTokens ?? 1_024)
        let prompt = gemmaDocumentPrompt(rawText: rawText, settings: settings)
        var request = prompt
        for attempt in 0..<2 {
            let session = ChatSession(container, instructions: instructions, generateParameters: params,
                                      additionalContext: ["enable_thinking": attempt == 0 && settings.useThinkingMode])
            var output = ""
            for try await generation in session.streamDetails(to: request) {
                try Task.checkCancellation()
                if let info = generation.info { try checkCompletion(info) }
                if let chunk = generation.chunk { output += chunk }
            }
            let json = DocumentEditFormatting.clean(stripGemmaThinkBlock(output), original: rawText)
            do {
                let rendered: String
                if settings.template == .instructions {
                    rendered = try DocumentEditFormatting.renderInstructions(DocumentEditFormatting.decodeDocument(DocumentEditFormatting.InstructionDocument.self, from: json))
                } else {
                    rendered = try DocumentEditFormatting.renderPrompt(DocumentEditFormatting.decodeDocument(DocumentEditFormatting.PromptDocument.self, from: json))
                }
                onStream(rendered)
                return rendered
            } catch {
                try Task.checkCancellation()
                guard attempt == 0 else { throw DocumentEditFormatting.StructureError.invalid }
                request = prompt + "\n\nReturn the complete document as valid JSON matching this structure. " + shape
            }
        }
        throw DocumentEditFormatting.StructureError.invalid
    }

    nonisolated static func gemmaDocumentPrompt(rawText: String, settings: Settings) -> String {
        [processingInstructions(rawText: rawText, settings: settings),
         settings.vocabulary.buildPromptSection(for: rawText),
         "Only the content inside dictated_text belongs in the document. The editing rules and reference vocabulary are not document content.\n\n<dictated_text>\n\(rawText)\n</dictated_text>"]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    nonisolated static func documentDataInstructions(template: Template, outputLanguage: OutputLanguage) -> String {
        let shape: String
        if template == .instructions {
            shape = #"Return a JSON object with intro and steps. intro copies only background the speaker supplied before the first action; otherwise it is null. Never summarize the actions in intro. Each step's text contains its complete action without a list marker; preserve every condition and detail. number is the explicitly spoken step number as an unquoted JSON integer, or null. subSteps contains nested details or null. Sequencing words belong to the corresponding step, never the intro. JSON schema: {"type":"object","required":["intro","steps"],"properties":{"intro":{"type":["string","null"]},"steps":{"type":"array","items":{"type":"object","required":["text","number","subSteps"],"properties":{"text":{"type":"string"},"number":{"type":["integer","null"]},"subSteps":{"type":["array","null"],"items":{"type":"string"}}}}}}}"#
        } else {
            shape = #"Return a JSON object with two keys: task and sections. task is a string containing the complete task, including its deadline, scope, and conditions, using the speaker's words. sections is an array of objects with tag and text strings for the other information the speaker supplied. Put every restriction and requirement in a constraints section, including preservation requirements and prohibitions. A deadline stays with its task; do not replace a constraint with a deadline section. Example: "Clean the sensor before Monday. Keep the serial labels. Do not use solvents." becomes {"task":"Clean the sensor before Monday.","sections":[{"tag":"constraints","text":"Keep the serial labels. Do not use solvents."}]}. Omit categories the speaker did not mention; never generate empty, N/A, or invented sections. Keep every sentence's information. Do not shorten or summarize the task. Do not generate pasted_context. JSON schema: {"type":"object","required":["task","sections"],"properties":{"task":{"type":"string"},"sections":{"type":"array","items":{"type":"object","required":["tag","text"],"properties":{"tag":{"type":"string"},"text":{"type":"string"}}}}}}"#
        }
        return "Transform dictated content into structured document data. Keep every supplied fact, including names, dates, deadlines, measurements, and exceptions. Do not invent details or discard a condition when summarizing an action. Return only a JSON object, without a code fence or commentary. " + shape + " " + refineLanguageRule(for: outputLanguage)
    }

    /// Shared generation limits for fresh requests and session turns.
    nonisolated private static func gemmaGenerateParameters(settings: Settings, rawText: String) -> GenerateParameters {
        // Temperature per template: conservative templates stay greedy,
        // rewriting templates need some freedom to rephrase.
        var params = GenerateParameters()
        switch settings.template {
        case .standard:             params.temperature = 0.1
        case .custom:               params.temperature = 0
        case .concise:              params.temperature = 0.2
        case .professional:         params.temperature = 0.3
        case .emailReady:           params.temperature = 0
        case .instructions:         params.temperature = 0
        case .aiPrompt:             params.temperature = 0  // Structured output; low freedom
        }
        // Guards against degenerate loops ("the the the"). The penalty window is one token, so only
        // an immediate repeat is dampened and phrases like "day by day" are unaffected. 1.1 is
        // strong enough to break a loop and weak enough for real repetition to win.
        params.repetitionPenalty = 1.1
        params.repetitionContextSize = 1
        // Limit decoding to a length proportional to the input. A runaway (a loop or an echo of the
        // prompt) stops here instead of running to the timeout before the ratio check rejects it.
        // Thinking mode gets extra room for its reasoning block.
        let estInputTokens = max(16, rawText.count / 4)
        if settings.useThinkingMode {
            params.maxTokens = min(8_192, max(1_024, estInputTokens * 5 + 512))
        } else if settings.template.isSpecialty {
            let minimum = settings.template == .aiPrompt ? 1_024 : 384
            params.maxTokens = min(4_096, max(minimum, estInputTokens * 4 + 128))
        } else {
            params.maxTokens = max(96, estInputTokens * 2)
        }
        // Trim the improbable-token tail. Defaults (topP=1, topK=0, minP=0)
        // leave the full tail in play; a small floor steadies the low-temp
        // refine without touching legitimate word choice.
        params.minP = 0.02
        params.topK = 40
        return params
    }

    /// MLX verifies the actual token prefix, trims compatible caches, and rebuilds
    /// when tokenization or cache state cannot be reconciled safely.
    nonisolated static func runGemmaTurnGeneration(
        container: ModelContainer,
        turnState: GemmaTurnState,
        turnPrompt: String,
        rawText: String,
        settings: Settings,
        onStream: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let params = gemmaGenerateParameters(settings: settings, rawText: rawText)
        let session = turnState.session ?? ChatSession(container, instructions: turnState.instructions,
            generateParameters: params, additionalContext: ["enable_thinking": false])
        turnState.session = session
        session.generateParameters = params
        var output = ""
        var lastStreamUpdate: CFAbsoluteTime = 0
        do {
            for try await generation in session.streamDetails(to: turnPrompt) {
                try Task.checkCancellation()
                if let info = generation.info {
                    try checkCompletion(info)
                    turnState.cachedPromptTokens = info.cachedPromptTokenCount
                }
                if let chunk = generation.chunk {
                    output += chunk
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastStreamUpdate > 0.1 {
                        onStream(output)
                        lastStreamUpdate = now
                    }
                }
            }
            try Task.checkCancellation()
        } catch {
            turnState.session = nil
            throw error
        }
        let cleaned = cleanupModelOutput(Self.stripGemmaThinkBlock(output))
        onStream(cleaned)
        return cleaned
    }

    /// Gemma path for `generateRawText`, without the cleanup steps. Passes `useThinkingMode` to the
    /// chat template.
    nonisolated static func runRawGemmaGeneration(
        container: ModelContainer,
        prompt: String,
        useThinkingMode: Bool
    ) async throws -> String {
        let signpostID = signposter.makeSignpostID()
        let signpostState = signposter.beginInterval("runRawGemmaGeneration", id: signpostID)
        defer { signposter.endInterval("runRawGemmaGeneration", signpostState) }

        let instructions = "You follow the user's instructions exactly. Return only what they ask for, no preamble."

        // Bounded decoding for this path (document status and instruction edits): an
        // input-proportional length limit and the repeat penalty, as in gemmaGenerateParameters, so
        // a loop can't block the refine worker.
        var params = GenerateParameters()
        params.temperature = 0.2
        params.repetitionPenalty = 1.1
        params.repetitionContextSize = 1
        params.minP = 0.02
        params.topK = 40
        let estInputTokens = max(64, prompt.count / 4)
        // Document edits can legitimately return text near the input's length;
        // thinking mode adds a hidden block on top. Generous but finite.
        params.maxTokens = useThinkingMode ? max(512, estInputTokens * 4) : max(256, estInputTokens * 2)

        // Hard time limit sized to the prompt. A looping stream keeps producing output and could
        // use the whole token budget while the worker waits.
        let promptWords = Self.wordCount(prompt)
        let timeoutNanos = min(
            Self.rawMaxTimeoutNanos,
            max(Self.rawMinTimeoutNanos, UInt64(promptWords) * Self.perWordTimeoutNanos)
        )

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [params] in
                // Build the session inside the child so nothing non-Sendable
                // crosses the task boundary.
                let session = ChatSession(container, instructions: instructions, generateParameters: params,
                    additionalContext: ["enable_thinking": useThinkingMode])
                var output = ""
                for try await chunk in session.streamResponse(to: prompt) {
                    try Task.checkCancellation()
                    output += chunk
                }
                return Self.stripGemmaThinkBlock(output).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw FormatterError.timeout
            }
            guard let first = try await group.next() else {
                throw FormatterError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    /// Removes Gemma reasoning from a response. The chat template marks thinking with `<|think|>`,
    /// but the model writes its reasoning as `<|channel>thought ... <channel|>` before the answer.
    /// Both forms are handled; an unclosed block drops everything after its marker, so streaming
    /// stays clean while the model is still thinking.
    nonisolated static func stripGemmaThinkBlock(_ raw: String) -> String {
        var s = raw
        while let open = s.range(of: "<|channel>thought") {
            if let close = s.range(of: "<channel|>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
                break
            }
        }
        guard s.contains("<|think|>") else { return s }
        if let openRange = s.range(of: "<|think|>"),
           let closeRange = s.range(of: "<|/think|>", options: .backwards) {
            s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        } else if let openRange = s.range(of: "<|think|>") {
            s.removeSubrange(openRange.lowerBound..<s.endIndex)
        }
        return s
    }
}
