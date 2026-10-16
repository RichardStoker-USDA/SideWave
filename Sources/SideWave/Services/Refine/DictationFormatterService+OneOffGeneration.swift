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
    /// Generates an XML status of what the user has dictated so far, parsed into
    /// SpecialtyLiveStatus.
    func generateSpecialtyLiveStatus(
        _ rawText: String,
        priorContext: String?,
        template: Template
    ) async -> SpecialtyLiveStatus? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Backend readiness check.
        guard case .ready = state else { return nil }

        // Apple Intelligence runs the analysis in its own one-shot session with analysis
        // Instructions and a @Generable schema. The refine session's Instructions ("return only the
        // cleaned text") outweigh the prompt, so routing the analysis through it returns cleaned
        // text instead of a status.
        #if canImport(FoundationModels)
        if activeBackend == .appleIntelligence || activeBackend == .appleIntelligenceLegacy {
            let vocabSection = Settings.fromCurrentUserDefaults(customInstructions: customInstructions)
                .vocabulary.buildPromptSection(for: trimmed)
            return await Self.runAFMLiveStatus(
                rawText: trimmed,
                template: template,
                vocabSection: vocabSection
            )
        }
        #endif

        // Gemma path: the structured live-status XML prompt. generateRawText's
        // Gemma branch uses its own "follow the user's instructions" system
        // prompt (not the refine template), so the analysis prompt governs.
        let prompt = """
        You are an assistant analyzing a live dictation session for the template: \(template.displayName).
        Analyze the raw text dictated so far and provide a live status update in structured XML.

        Here is what the user has dictated so far:
        \"\"\"
        \(trimmed)
        \"\"\"

        Your output must be structured exactly using the following XML tags:
        <understanding>Provide a concise 1-2 sentence summary of your understanding of what the user dictates so far and what the final document is about.</understanding>
        <planned_action>Describe in 1 sentence how you plan to format or structure the final output once the user finished dictating (e.g. outline of email, step-by-step format, etc.).</planned_action>
        <questions>
        - [Question 1: Ask a clarifying question or list a detail needed to fulfill this template, if any]
        - [Question 2]
        </questions>

        Rules:
        1. Provide only the XML tags. No other introductory or concluding text.
        2. Be helpful, professional, and concise.
        3. Keep the questions focused on what is missing for a complete and high-quality \(template.displayName) document. If no questions are needed, write "None".
        """

        // Run generation via the active backend.
        do {
            let response = try await self.generateRawText(fullPrompt: prompt, useThinkingMode: false)
            return Self.parseSpecialtyXML(response)
        } catch {
            Self.signposter.emitEvent("generateSpecialtyLiveStatus error")
            Self.logger.error("generateSpecialtyLiveStatus error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated static func parseSpecialtyXML(_ xml: String) -> SpecialtyLiveStatus {
        func extractTag(_ tag: String) -> String {
            let openTag = "<\(tag)>"
            let closeTag = "</\(tag)>"

            guard let openRange = xml.range(of: openTag, options: .caseInsensitive) else {
                return ""
            }

            let startIdx = openRange.upperBound
            if let closeRange = xml.range(of: closeTag, options: .caseInsensitive, range: startIdx..<xml.endIndex) {
                return xml[startIdx..<closeRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Unclosed tag case: search for any next opening tag '<' or end of string
            if let nextTagRange = xml.range(of: "<", range: startIdx..<xml.endIndex) {
                return xml[startIdx..<nextTagRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return xml[startIdx...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let understanding = extractTag("understanding")
        let plannedAction = extractTag("planned_action")
        let questionsRaw = extractTag("questions")

        var questions: [String] = []
        let lines = questionsRaw.components(separatedBy: .newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }

            // strip bullet markers: - or * or numbered lists
            let pattern = "^[\\s\\-*•\\d\\.\\)]+\\s*"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: trimmedLine.utf16.count)
                let cleaned = regex.stringByReplacingMatches(in: trimmedLine, options: [], range: range, withTemplate: "")
                let finalCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalCleaned.isEmpty && finalCleaned.lowercased() != "none" {
                    questions.append(finalCleaned)
                }
            } else {
                if trimmedLine.lowercased() != "none" {
                    questions.append(trimmedLine)
                }
            }
        }

        return SpecialtyLiveStatus(
            understanding: understanding.isEmpty ? "Analyzing your dictation\u{2026}" : understanding,
            plannedAction: plannedAction.isEmpty ? "Structuring the final document\u{2026}" : plannedAction,
            questions: questions
        )
    }

    /// One-shot generation with a custom prompt, without the cleanup template, filler removal, or
    /// vocabulary. Used by flows such as the vocabulary extractor. `useThinkingMode` applies to
    /// Gemma only. Requires a ready model; throws `backendNotReady` otherwise. Returns the full
    /// text, without streaming.
    func generateRawText(
        fullPrompt: String,
        useThinkingMode: Bool = false
    ) async throws -> String {
        switch activeBackend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            guard let container = modelContainer else {
                throw FormatterError.backendNotReady
            }
            return try await Self.runRawGemmaGeneration(
                container: container,
                prompt: fullPrompt,
                useThinkingMode: useThinkingMode
            )
        case .appleIntelligence, .appleIntelligenceLegacy:
            guard let session = afmSessionHolder as? LanguageModelSession else {
                throw FormatterError.backendNotReady
            }
            let response = try await session.respond(to: fullPrompt)
            return response.content
        }
    }

    /// Outcome of an on-demand back-translation. Lets the History sheet tell
    /// "model not loaded" apart from "generation failed" so it can show the
    /// right plain-language message.
    enum BackTranslationOutcome: Sendable {
        case success(BackTranslation)
        case notReady
        case failed
    }

    /// Literal back-translation for History. Runs the active backend once and returns a
    /// word-for-word rendering of `translatedText` in the language of `originalText`, plus a
    /// sentence or two about choices that weren't literal. Uses its own prompt; the refine
    /// session's Instructions push toward translating again.
    func backTranslate(
        translatedText: String,
        originalText: String?,
        targetLanguage: OutputLanguage
    ) async -> BackTranslationOutcome {
        let translated = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return .failed }
        let targetName = targetLanguage.isMatch ? "another language" : targetLanguage.promptName
        let original = originalText?.trimmingCharacters(in: .whitespacesAndNewlines)

        let sourceAnchor: String
        if let original, !original.isEmpty {
            sourceAnchor = """
            The output must be in the SAME language as this ORIGINAL dictation (the source language, before it was translated into \(targetName)):
            \"\"\"
            \(original)
            \"\"\"
            """
        } else {
            sourceAnchor = "The output must be in the language the text was originally dictated in — the source language it was translated FROM into \(targetName)."
        }

        let task = """
        You show how faithful a translation is. Below is text that was translated into \(targetName). Produce a LITERAL, word-for-word back-translation of it, then briefly note anything that was localized rather than translated straight across.
        \(sourceAnchor)

        TRANSLATED TEXT (in \(targetName)) to back-translate literally:
        \"\"\"
        \(translated)
        \"\"\"

        Output EXACTLY this XML and nothing else:
        <literal>A literal, word-for-word back-translation of the translated text into the source language. Stay close to the words even if it reads a little stiff — this shows what the translation literally says.</literal>
        <reasoning>1-2 sentences naming any idioms, expressions, or phrasing that were rendered as a natural equivalent rather than translated literally. If the translation is essentially literal, say so.</reasoning>
        """

        switch activeBackend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            guard case .ready = state, let container = modelContainer else { return .notReady }
            do {
                let response = try await Self.runRawGemmaGeneration(
                    container: container, prompt: task, useThinkingMode: false
                )
                return Self.parseBackTranslation(response, fallbackLiteral: translated)
            } catch {
                Self.logger.error("backTranslate Gemma error: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
        case .appleIntelligence, .appleIntelligenceLegacy:
            let model = AFMRuntime.makeModel()
            guard case .available = model.availability else { return .notReady }
            let instructions = Instructions {
                "You produce a literal, word-for-word back-translation of a translated passage into its original source language, to show how faithful the translation is."
                "Do NOT re-translate into the passage's current language, and do NOT polish or improve it — a slightly stiff literal rendering is correct."
                "Then give 1-2 sentences on any idioms or expressions that were localized rather than translated literally."
                "Output only the requested XML."
            }
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(to: task)
                return Self.parseBackTranslation(response.content, fallbackLiteral: translated)
            } catch {
                Self.logger.error("backTranslate AFM error: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
        }
    }

    /// Parses the `<literal>` and `<reasoning>` response. Without the tags, the whole response is
    /// the literal text and the reasoning is empty.
    nonisolated static func parseBackTranslation(_ xml: String, fallbackLiteral: String) -> BackTranslationOutcome {
        func extractTag(_ tag: String) -> String? {
            let openTag = "<\(tag)>"
            let closeTag = "</\(tag)>"
            guard let openRange = xml.range(of: openTag, options: .caseInsensitive) else { return nil }
            let startIdx = openRange.upperBound
            if let closeRange = xml.range(of: closeTag, options: .caseInsensitive, range: startIdx..<xml.endIndex) {
                return xml[startIdx..<closeRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let nextTagRange = xml.range(of: "<", range: startIdx..<xml.endIndex) {
                return xml[startIdx..<nextTagRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return xml[startIdx...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let literalRaw = extractTag("literal")
        let reasoningRaw = extractTag("reasoning")
        let cleanedResponse = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = (literalRaw?.isEmpty == false)
            ? literalRaw!
            : (cleanedResponse.isEmpty ? fallbackLiteral : cleanedResponse)
        guard !literal.isEmpty else { return .failed }
        return .success(BackTranslation(literalText: literal, reasoning: reasoningRaw ?? ""))
    }
}
