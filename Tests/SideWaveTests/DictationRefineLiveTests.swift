// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest
@testable import SideWave

final class DictationRefineLiveTests: XCTestCase {
    func testSmallMLXCandidateAgainstRefinementContract() async throws {
        guard let repo = ProcessInfo.processInfo.environment["SIDEWAVE_CANDIDATE_MODEL"] else {
            throw XCTSkip("Candidate qualification requires an explicit model repository")
        }
        let container = try await ModelTokenizerLoader.loadContainer(
            from: MLXDownloadInterceptor(upstream: #hubDownloader(), displayName: "Refine candidate"),
            configuration: ModelConfiguration(id: repo), progressHandler: { _ in })
        let fixtures: [(DictationFormatterService.Template, String, [String])] = [
            (.standard, "um we need to review the samples on friday and send the report before lunch", ["friday", "samples", "lunch"]),
            (.professional, "i will send my report on friday after lunch", ["my", "report", "friday"]),
            (.concise, "we approved 420 dollars for the samples and we need the report on friday", ["420", "samples", "friday"]),
            (.instructions, "First label the samples. Second put them in the freezer. Third send the report on Friday.", ["samples", "freezer", "friday"])
        ]
        for (template, input, required) in fixtures {
            let settings = DictationFormatterService.Settings(template: template, removeFillerWords: true,
                customFillerPhrases: [], profanityMode: .none,
                customInstructions: "", speakerProfile: "", vocabulary: .empty, priorContext: nil,
                useThinkingMode: false, outputLanguage: .matchInput)
            let start = Date()
            let output = try await DictationFormatterService.runGemmaGeneration(container: container,
                rawText: input, settings: settings, onStream: { _ in })
            print("CANDIDATE template=\(template.rawValue) seconds=\(Date().timeIntervalSince(start))")
            for word in required { XCTAssertTrue(output.localizedCaseInsensitiveContains(word), output) }
            XCTAssertFalse(output.lowercased().split(whereSeparator: { !$0.isLetter }).contains("um"), output)
            XCTAssertFalse(RefineValidation.changesSpeakerNumber(input: input, output: output), output)
            XCTAssertFalse(output.contains("<think>"), output)
            XCTAssertLessThan(output.count, input.count * 3, output)
        }
    }

    func testGemmaReusesVerifiedPrefixWithoutRepeatingEarlierDictation() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Live refine requires SIDEWAVE_LIVE_MODELS=1")
        }
        URLProtocol.registerClass(TransparencyURLProtocol.self)
        TransparencyURLProtocol.setupSwizzling()
        let container = try await ModelTokenizerLoader.loadContainer(
            from: MLXDownloadInterceptor(upstream: #hubDownloader(), displayName: "Gemma 4 E2B"),
            configuration: LLMRegistry.gemma4_e2b_it_4bit, progressHandler: { _ in })
        let state = DictationFormatterService.GemmaTurnState(instructions:
            DictationFormatterService.gemmaSystemPrompt(for: .standard, removeFillers: true))
        let inputs = ["um we will review the samples on friday", "then send the report before lunch", "and keep the measurements in centimeters"]
        var prior = ""
        for (index, input) in inputs.enumerated() {
            let settings = DictationFormatterService.Settings(template: .standard, removeFillerWords: true,
                customFillerPhrases: [], profanityMode: .none,
                customInstructions: "", speakerProfile: "", vocabulary: .empty, priorContext: prior,
                useThinkingMode: false, outputLanguage: .matchInput)
            let prompt = DictationFormatterService.buildAFMTurnPrompt(rawText: input, settings: settings,
                seedTail: nil, isFirstTurn: index == 0)
            let start = Date()
            let output = try await DictationFormatterService.runGemmaTurnGeneration(container: container,
                turnState: state, turnPrompt: prompt, rawText: input, settings: settings, onStream: { _ in })
            XCTAssertFalse(output.isEmpty)
            XCTAssertTrue(output.localizedCaseInsensitiveContains(["friday", "lunch", "centimeters"][index]), output)
            if index > 0 {
                XCTAssertGreaterThan(state.cachedPromptTokens, 0)
                XCTAssertFalse(output.localizedCaseInsensitiveContains("friday"), output)
            }
            print("CACHE_TURN index=\(index) reused_tokens=\(state.cachedPromptTokens) seconds=\(Date().timeIntervalSince(start))")
            prior += " " + output
        }
    }

    private func refine(
        _ input: String, template: DictationFormatterService.Template,
        language: DictationFormatterService.OutputLanguage = .matchInput
    ) async throws -> String {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Live refine requires SIDEWAVE_LIVE_MODELS=1")
        }
        let model = AFMRuntime.makeModel()
        guard case .available = model.availability else { throw XCTSkip("Apple Intelligence is unavailable") }
        let settings = DictationFormatterService.Settings(
            template: template, removeFillerWords: true, customFillerPhrases: [],
            profanityMode: .none,
            customInstructions: "", speakerProfile: "", vocabulary: .empty,
            priorContext: nil, useThinkingMode: false, outputLanguage: language
        )
        let session = LanguageModelSession(model: model, instructions: DictationFormatterService.afmInstructions(
            for: template, generation: AFMRuntime.generation, outputLanguage: language
        ))
        return try await DictationFormatterService.runAFMGeneration(
            sessionHolder: session, rawText: input, settings: settings, onStream: { _ in }
        )
    }

    func testStandardKeepsFactsAndRemovesHesitations() async throws {
        let output = try await refine("um we need to review the the samples on friday and send the report before lunch", template: .standard)
        let words = output.lowercased().split(whereSeparator: { !$0.isLetter })
        XCTAssertFalse(words.contains("um"))
        XCTAssertTrue(words.contains("friday"))
        XCTAssertTrue(words.contains("lunch"))
        XCTAssertFalse(output.lowercased().contains("the the"))
    }

    func testStandardDoesNotInventAnUnspokenEnding() async throws {
        for input in ["Keep the samples cold until", "We can send the measurements after"] {
            let output = try await refine(input, template: .standard)
            let words = output.lowercased().split(whereSeparator: { !$0.isLetter })
            XCTAssertEqual(words.last, input.split(separator: " ").last, output)
            XCTAssertTrue(output.localizedCaseInsensitiveContains(input.contains("samples") ? "samples" : "measurements"), output)
        }
    }

    func testProfessionalPreservesDistinctPoints() async throws {
        let output = try await refine("so um the thing is we basically need to improve performance by thirty percent before next quarter because the customers keep complaining about it", template: .professional)
        let lowered = output.lowercased()
        XCTAssertFalse(lowered.split(whereSeparator: { !$0.isLetter }).contains("um"))
        XCTAssertTrue(lowered.contains("thirty") || lowered.contains("30"))
        XCTAssertTrue(lowered.contains("quarter"))
        XCTAssertTrue(lowered.contains("customer"))
    }

    func testTranslationDoesNotFallBackToEnglish() async throws {
        let output = try await refine("Please review the report before Friday. Send the updated figures after lunch.", template: .standard, language: .spanish)
        let lowered = output.lowercased()
        XCTAssertTrue(lowered.contains("viernes"))
        XCTAssertTrue(lowered.contains("informe") || lowered.contains("reporte"))
        XCTAssertFalse(lowered.contains("please review"))
    }

    func testInstructionsKeepActionsNumbersAndSuppliedDetails() async throws {
        let cases: [(String, [String])] = [
            ("First label the samples. Second put the samples in the freezer. Third send the report on Friday.",
             ["1.", "2.", "3.", "samples", "freezer", "Friday"]),
            ("Step five open the settings. Step six select the microphone. Step eight run the audio test.",
             ["5.", "6.", "8.", "settings", "microphone", "audio test"]),
            ("We are preparing the monthly report. First compare the totals. Keep the control group separate. Then email the report before noon.",
             ["monthly report", "1.", "2.", "totals", "control group", "noon"])
        ]
        for (input, required) in cases {
            let output = try await refine(input, template: .instructions)
            for text in required { XCTAssertTrue(output.localizedCaseInsensitiveContains(text), output) }
            XCTAssertLessThanOrEqual(output.split(whereSeparator: \.isWhitespace).count,
                                     input.split(whereSeparator: \.isWhitespace).count * 2, output)
            XCTAssertFalse(output.lowercased().hasPrefix("here is"), output)
        }
    }

    func testGemmaPreservesSpeakersFactsAndUnfinishedBoundaries() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Live refine requires SIDEWAVE_LIVE_MODELS=1")
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
            configuration: LLMRegistry.gemma4_e2b_it_4bit)
        let settings = DictationFormatterService.Settings(
            template: .standard, removeFillerWords: true, customFillerPhrases: [],
            profanityMode: .none,
            customInstructions: "", speakerProfile: "", vocabulary: .empty,
            priorContext: nil, useThinkingMode: false, outputLanguage: .matchInput)
        let cases: [(String, [String])] = [
            ("so um the thing is we need to improve the performance by thirty percent before next quarter", ["we", "performance", "quarter"]),
            ("i will send my report on friday after lunch", ["i", "my", "friday", "lunch"]),
            ("because our samples are still in the freezer we need to wait until", ["because", "our", "freezer", "until"])
        ]
        for (input, required) in cases {
            let output = try await DictationFormatterService.runGemmaGeneration(
                container: container, rawText: input, settings: settings, onStream: { _ in })
            let words = output.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            for word in required { XCTAssertTrue(words.contains(word), "Missing \(word): \(output)") }
            XCTAssertFalse(words.contains("um"))
            XCTAssertFalse(RefineValidation.changesSpeakerNumber(input: input, output: output))
            if input.hasSuffix("until") { XCTAssertEqual(words.last, "until", output) }
        }
    }

    func testGemmaTranslatesFactsIntoSelectedLanguage() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Live refine requires SIDEWAVE_LIVE_MODELS=1")
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
            configuration: LLMRegistry.gemma4_e2b_it_4bit)
        let input = "We approved 420 dollars for the samples. Please review the report before Friday."
        for language in [DictationFormatterService.OutputLanguage.simplifiedChinese, .korean] {
            let settings = DictationFormatterService.Settings(
                template: .standard, removeFillerWords: true, customFillerPhrases: [],
                profanityMode: .none,
                customInstructions: "", speakerProfile: "", vocabulary: .empty,
                priorContext: nil, useThinkingMode: false, outputLanguage: language)
            let output = try await DictationFormatterService.runGemmaGeneration(
                container: container, rawText: input, settings: settings, onStream: { _ in })
            XCTAssertFalse(TranscriptionService.translateLikelyFailed(output: output, input: input, target: language))
            XCTAssertTrue(output.contains("420"), output)
            XCTAssertFalse(output.lowercased().contains("please review"), output)
            if language == .simplifiedChinese {
                XCTAssertTrue(output.contains("周五") || output.contains("星期五"), output)
            } else {
                XCTAssertTrue(output.contains("금요일"), output)
            }
        }
    }
}
