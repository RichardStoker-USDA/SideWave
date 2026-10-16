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
    // MARK: - Errors

    enum FormatterError: Error, LocalizedError {
        case timeout
        case backendNotReady
        case contextOverflow
        /// Apple Intelligence declined to process the input (guardrail
        /// violation or explicit refusal). Gemma never hits this branch.
        case refused

        var errorDescription: String? {
            switch self {
            case .timeout: return "Formatter timed out"
            case .backendNotReady: return "Refine model isn't loaded yet"
            case .contextOverflow: return "Dictation too long for the selected model"
            case .refused: return "Refine declined to process this input"
            }
        }
    }

    func editDocumentWithInstruction(
        _ currentText: String,
        instruction: String,
        template: Template = .custom,
        onStream: (@Sendable (String) -> Void)? = nil
    ) async -> String {
        let trimmedInst = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInst.isEmpty, currentGenerationTask == nil, state == .ready else { return currentText }
        let sysPrompt = template == .custom
            ? "Edit the supplied document according to the user's request. Preserve all facts unless the request changes them. When converting statements into a list, include every requested statement as a list item. Return only the complete updated document, including all requested list markers."
            : "You edit a document according to the user request. Return the complete edited document, and nothing else. Copy all unchanged lines exactly. Do not delete a title, subject, greeting, deadline, introduction, or closing unless the request explicitly changes it. Preserve list markers, indentation and paragraph breaks unless the user asks to reformat them. Do not add commentary, code fences or document boundary labels."
        let xmlDocument = template == .aiPrompt
            ? DocumentEditFormatting.separatingContextPlaceholder(currentText) : (body: currentText, suffix: "")
        let prompt = "Original document:\n\(xmlDocument.body)\n\nRequested changes:\n\(trimmedInst)"
        let backend = activeBackend
        let container = modelContainer
        let tokenCap = min(4096, max(512, (currentText.utf8.count + trimmedInst.utf8.count) / 2 + 256))
        state = .generating
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            #if canImport(FoundationModels)
            if backend == .appleIntelligence || backend == .appleIntelligenceLegacy {
                let model = AFMRuntime.makeModel()
                guard case .available = model.availability else { throw FormatterError.backendNotReady }
                let legacyCustom = template == .custom && Self.effectiveAFMGeneration == .gen1
                let session = LanguageModelSession(model: model, instructions: Instructions {
                    if legacyCustom {
                        "Edit the supplied document according to the user's request. Preserve all facts unless the request changes them. Return only the updated document, including any requested list markers."
                        trimmedInst
                    } else {
                        sysPrompt
                    }
                })
                if template == .aiPrompt, let sections = DocumentEditFormatting.xmlSections(xmlDocument.body) {
                    let data = try JSONEncoder().encode(sections)
                    let sectionPrompt = "Original sections:\n" + String(decoding: data, as: UTF8.self)
                        + "\n\nRequested changes:\n" + trimmedInst
                        + "\nReturn all sections, including every unchanged section. Keep the existing tags. Change only the requested text; section text is plain text and the app writes XML tags."
                    let response = try await session.respond(to: Prompt(sectionPrompt), generating: AFMXMLDocumentOutput.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: tokenCap))
                    try Task.checkCancellation()
                    guard let rendered = DocumentEditFormatting.renderXML(response.content.sections.map {
                        .init(tag: $0.tag, text: $0.text)
                    }) else { throw DocumentEditFormatting.StructureError.invalid }
                    return rendered + xmlDocument.suffix
                }
                var output = ""
                for try await partial in session.streamResponse(to: Prompt(legacyCustom ? currentText : prompt),
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: tokenCap)) {
                    try Task.checkCancellation()
                    output = DocumentEditFormatting.clean(partial.content, original: currentText)
                }
                return output
            }
            #endif
            guard let container else { throw FormatterError.backendNotReady }
            var params = GenerateParameters()
            params.temperature = 0
            params.maxTokens = tokenCap
            let session = ChatSession(container, instructions: sysPrompt, generateParameters: params,
                                      additionalContext: ["enable_thinking": false])
            var output = ""
            for try await chunk in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                output += chunk
            }
            return DocumentEditFormatting.clean(Self.stripGemmaThinkBlock(output), original: currentText) + xmlDocument.suffix
        }
        currentGenerationTask = task
        defer {
            if currentGenerationTask == task {
                currentGenerationTask = nil
                restoreReadyIfLoaded()
            }
        }
        let timeout = Self.refineTimeoutNanos(inputWords: Self.wordCount(currentText), translating: false, document: true)
            + Self.abandonMarginNanos
        let outcome = await withTaskCancellationHandler {
            await awaitRefineOrAbandon(task, hardDeadlineNanos: timeout)
        } onCancel: { task.cancel() }
        guard currentGenerationTask == task else { return currentText }
        switch outcome {
        case .value(let document) where !document.isEmpty:
            guard template != .aiPrompt || DocumentEditFormatting.preservesXMLStructure(document, original: currentText) else {
                onSilentFallback?("The edit returned incomplete structure. Your original document is preserved. Try a smaller change.")
                return currentText
            }
            onStream?(document)
            return document
        case .cancelled:
            return currentText
        case .abandoned:
            retireGeneration(task)
            onSilentFallback?("The edit took too long. Your original document is preserved.")
            return currentText
        default:
            onSilentFallback?("The edit could not finish. Your original document is preserved.")
            return currentText
        }
    }
}
