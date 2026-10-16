// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import os

/// Refine over on-device Gemma via MLX. The model container loads once
/// (`prepare`) and stays resident; each refine runs a fresh one-shot
/// ChatSession so no history can bleed between dictations.
public actor RefinerGemma: Refiner {

    public enum Variant: String, CaseIterable, Sendable, Identifiable {
        /// Smaller and faster; the default.
        case e2b
        /// Larger; noticeably better on CJK output.
        case e4b

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .e2b: return "Gemma 4 E2B"
            case .e4b: return "Gemma 4 E4B"
            }
        }

        var configuration: ModelConfiguration {
            switch self {
            case .e2b: return LLMRegistry.gemma4_e2b_it_4bit
            case .e4b: return LLMRegistry.gemma4_e4b_it_4bit
            }
        }
    }

    private var settings = RefineSettings()
    private var container: ModelContainer?
    private var loadedVariant: Variant?
    private var preparation: (id: UUID, variant: Variant, task: Task<ModelContainer, Error>)?
    private var preparationGeneration = UUID()
    private let log = Logger(subsystem: "com.sidewave.kit", category: "refine-gemma")

    public init() {}

    public func setSettings(_ new: RefineSettings) {
        settings = new
    }

    public var isReady: Bool { container != nil }
    public var currentVariant: Variant? { loadedVariant }

    /// Download (if needed) and load the model weights. Multi-GB on first
    /// run; cached loads take seconds.
    public func prepare(
        variant: Variant = .e2b,
        progress: (@Sendable (ModelSetupProgress) -> Void)? = nil
    ) async throws {
        if container != nil, loadedVariant == variant { return }
        let request: (id: UUID, variant: Variant, task: Task<ModelContainer, Error>)
        if let pending = preparation, pending.variant == variant {
            request = pending
        } else {
            preparation?.task.cancel()
            container = nil
            loadedVariant = nil
            let attempt = UUID()
            preparationGeneration = attempt
            progress?(ModelSetupProgress(fraction: 0, detail: "Checking \(variant.displayName)"))
            let task = Task { [weak self] in
                let loaded = try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                    configuration: variant.configuration
                ) { [weak self] p in
                    let update = ModelSetupProgress(
                        fraction: min(0.98, p.fractionCompleted),
                        detail: p.fractionCompleted < 1.0 ? "Downloading \(variant.displayName)" : "Loading \(variant.displayName)")
                    Task { await self?.reportPreparation(update, attempt: attempt, progress: progress) }
                }
                try Task.checkCancellation()
                await self?.reportPreparation(.init(fraction: 0.99, detail: "Preparing the first response"),
                                              attempt: attempt, progress: progress)
                _ = try await RefineDeadline.run(timeout: .seconds(30)) {
                    var parameters = GenerateParameters()
                    parameters.maxTokens = 1
                    parameters.temperature = 0
                    let session = ChatSession(loaded, instructions: "Reply with OK.", generateParameters: parameters,
                                              additionalContext: ["enable_thinking": false])
                    return try await session.respond(to: "ok")
                }
                try Task.checkCancellation()
                return loaded
            }
            request = (attempt, variant, task)
            preparation = request
        }
        defer { if preparation?.id == request.id { preparation = nil } }
        let loaded = try await request.task.value
        try Task.checkCancellation()
        guard preparationGeneration == request.id else { throw CancellationError() }
        container = loaded
        loadedVariant = variant
        progress?(ModelSetupProgress(fraction: 1, detail: "Ready"))
        log.notice("Gemma ready (\(variant.rawValue, privacy: .public))")
    }

    private func reportPreparation(_ update: ModelSetupProgress, attempt: UUID,
                                   progress: (@Sendable (ModelSetupProgress) -> Void)?) {
        guard preparation?.id == attempt else { return }
        progress?(update)
    }

    /// Release the weights (multi-GB of unified memory).
    public func unload() {
        preparationGeneration = UUID()
        preparation?.task.cancel()
        preparation = nil
        container = nil
        loadedVariant = nil
    }

    public func refine(_ text: String, context: String) async throws -> String {
        let settings = self.settings
        guard let container else { throw RefinerFailure.backendNotReady }

        let systemPrompt = RefinePrompts.gemmaSystemPrompt(
            for: settings.template,
            outputLanguage: settings.outputLanguage,
            speakerProfile: settings.speakerProfile
        )
        let prompt = RefinePrompts.buildUserPrompt(rawText: text, settings: settings)
        let params = Self.generateParameters(template: settings.template, rawText: text)
        let translating = !settings.outputLanguage.isMatch
        let timeout = RefinePrompts.refineTimeout(
            inputWords: RefineHygiene.wordCount(text), translating: translating)

        let raw = try await RefineDeadline.run(timeout: timeout) {
            let session = ChatSession(container, instructions: systemPrompt, generateParameters: params,
                                      additionalContext: ["enable_thinking": false])
            var output = ""
            for try await chunk in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                output += chunk
            }
            return output
        }

        let cleaned = RefineHygiene.cleanupModelOutput(RefineHygiene.stripGemmaThinkBlock(raw))
        guard !cleaned.isEmpty else { throw RefinerFailure.implausibleOutput(ratio: 0) }
        if settings.outputLanguage.isMatch, settings.template != .custom,
           RefineValidation.changesSpeakerNumber(input: text, output: cleaned) {
            throw RefinerFailure.changedSpeaker
        }
        if settings.outputLanguage.isMatch, let ratio = RefineHygiene.ratioViolation(
            input: text, output: cleaned, template: settings.template)
        {
            log.error("ratio gate rejected Gemma output at \(ratio, format: .fixed(precision: 2), privacy: .public)x")
            throw RefinerFailure.implausibleOutput(ratio: ratio)
        }
        return cleaned
    }

    /// Carried generation tuning: per-template temperature, single-token
    /// repetition guard against degenerate loops, input-proportional
    /// decode cap so a runaway is cut instead of burning the wall-clock
    /// timeout, and a small tail floor to steady low-temp sampling.
    static func generateParameters(template: RefineTemplate, rawText: String) -> GenerateParameters {
        var params = GenerateParameters()
        switch template {
        case .standard: params.temperature = 0.1
        case .custom: params.temperature = 0.2
        case .concise: params.temperature = 0.2
        case .professional: params.temperature = 0.3
        }
        params.repetitionPenalty = 1.1
        params.repetitionContextSize = 1
        let estInputTokens = max(16, rawText.count / 4)
        params.maxTokens = max(96, estInputTokens * 2)
        params.minP = 0.02
        params.topK = 40
        return params
    }

}
