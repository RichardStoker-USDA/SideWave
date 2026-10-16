// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class RefineValidationTests: XCTestCase {
    @MainActor
    func testUncooperativeGenerationBlocksReplacementWithoutBlockingCaller() async {
        let service = DictationFormatterService()
        var finish: CheckedContinuation<String, Error>?
        let task = Task<String, Error> { try await withCheckedThrowingContinuation { finish = $0 } }
        while finish == nil { await Task.yield() }
        service.retireGeneration(task)
        let start = ContinuousClock.now
        let allowed = await service.drainGenerationBeforeLoad(deadlineNanos: 20_000_000)
        XCTAssertFalse(allowed)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        if case .error = service.state { } else { XCTFail("Stopping feedback must stay visible") }
        let stillBlocked = await service.drainGenerationBeforeLoad(deadlineNanos: 20_000_000)
        XCTAssertFalse(stillBlocked)
        finish?.resume(returning: "Late result")
        _ = try? await task.value
        let released = await service.drainGenerationBeforeLoad(deadlineNanos: 20_000_000)
        XCTAssertTrue(released)
    }

    func testCachedInstructionsInvalidateWhenUserContextChanges() {
        func identity(custom: String = "", profile: String = "", vocabulary: VocabularyStore.Snapshot = .empty,
                      prior: String? = nil, fillers: Bool = true, customFillers: [String] = [],
                      profanity: DictationFormatterService.Settings.ProfanityMode = .none) -> DictationFormatterService.TurnPromptIdentity {
            DictationFormatterService.Settings(template: .standard, removeFillerWords: fillers,
                customFillerPhrases: customFillers, profanityMode: profanity,
                customInstructions: custom, speakerProfile: profile, vocabulary: vocabulary, priorContext: prior,
                useThinkingMode: false, outputLanguage: .matchInput).turnPromptIdentity
        }
        XCTAssertEqual(identity(), identity(prior: "An earlier sentence."))
        XCTAssertNotEqual(identity(), identity(custom: "Use metric units."))
        XCTAssertNotEqual(identity(), identity(profile: "Use short sentences."))
        XCTAssertNotEqual(identity(), identity(fillers: false))
        XCTAssertNotEqual(identity(), identity(customFillers: ["you know"]))
        XCTAssertNotEqual(identity(), identity(profanity: .redact))
        let vocabulary = VocabularyStore.Snapshot(contextBlurbs: ["Plant science"], terms: [], preserveCanonicals: [])
        XCTAssertNotEqual(identity(), identity(vocabulary: vocabulary))
    }

    @MainActor
    func testLegacyRedactionPreferencesCannotAlterPrompts() {
        let defaults = UserDefaults.standard
        let keys = ["redactPII", "redactSSN", "redactCreditCard", "redactAPIKey", "redactPhone", "redactEmail", "redactURL", "redactIPAddress"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.set(false, forKey: $0) }
        let before = DictationFormatterService.Settings.fromCurrentUserDefaults(customInstructions: "")
        keys.forEach { defaults.set(true, forKey: $0) }
        let after = DictationFormatterService.Settings.fromCurrentUserDefaults(customInstructions: "")
        let input = "Send the measurements to reviewer@example.com before Friday."
        XCTAssertEqual(before.turnPromptIdentity, after.turnPromptIdentity)
        XCTAssertEqual(DictationFormatterService.buildPrompt(rawText: input, settings: before),
                       DictationFormatterService.buildPrompt(rawText: input, settings: after))
        XCTAssertEqual(DictationFormatterService.buildAFMTurnPrompt(rawText: input, settings: before, seedTail: nil, isFirstTurn: true),
                       DictationFormatterService.buildAFMTurnPrompt(rawText: input, settings: after, seedTail: nil, isFirstTurn: true))
        let instructions = DictationFormatterService.processingInstructions(rawText: input, settings: after)
        XCTAssertFalse(instructions.contains("Mask any remaining"))
        XCTAssertFalse(instructions.contains("[SSN redacted]"))
    }

    func testStructuredDocumentKeepsEditingRulesOutOfSourceContent() {
        for template in [DictationFormatterService.Template.instructions, .aiPrompt] {
            let settings = DictationFormatterService.Settings(template: template,
                removeFillerWords: true, customFillerPhrases: [], profanityMode: .redact,
                customInstructions: "Keep measurements.", speakerProfile: "", vocabulary: .empty,
                priorContext: nil, useThinkingMode: false, outputLanguage: .matchInput)
            let input = "First label the samples. Then put them in the freezer."
            let prompt = DictationFormatterService.buildPrompt(rawText: input, settings: settings, structuredDocument: true)
            XCTAssertTrue(prompt.contains(input))
            for rule in ["nonsemantic", "first letter", "Keep measurements."] {
                XCTAssertFalse(prompt.contains(rule), "Processing preferences must not become extracted document content")
                XCTAssertTrue(DictationFormatterService.processingInstructions(rawText: input, settings: settings).contains(rule))
            }
        }
    }

    @MainActor
    func testStructuredPromptPreviewShowsTheBackendSpecificInstructionChannel() {
        let key = "dictationCleanupTemplate"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("instructions", forKey: key)
        for backend in [DictationFormatterService.Backend.appleIntelligence, .gemma4E2B] {
            let preview = DictationFormatterService.makePromptPreview(customInstructions: "Use centimeters.", backend: backend)
            XCTAssertTrue(preview.userPrompt.contains(preview.sampleDictation))
            XCTAssertEqual(preview.systemInstructions.contains("Use centimeters."), backend == .appleIntelligence)
            XCTAssertEqual(preview.userPrompt.contains("Use centimeters."), backend == .gemma4E2B)
        }
    }

    @MainActor
    func testApplePromptPreviewContainsRealInstructionsWithoutRunningInference() {
        for backend in [DictationFormatterService.Backend.appleIntelligence, .appleIntelligenceLegacy] {
            let preview = DictationFormatterService.makePromptPreview(customInstructions: "Keep measurements.", backend: backend)
            XCTAssertGreaterThan(preview.systemInstructions.count, 100)
            XCTAssertFalse(preview.systemInstructions.contains("[Apple Intelligence Instructions channel"))
            XCTAssertTrue(preview.userPrompt.contains(preview.sampleDictation))
        }
    }

    func testDocumentBudgetsAllowFormattingWithoutSlowingOrdinaryCleanup() {
        XCTAssertEqual(DictationFormatterService.refineTimeoutNanos(inputWords: 10, translating: false), 6_000_000_000)
        XCTAssertEqual(DictationFormatterService.refineTimeoutNanos(inputWords: 10, translating: false, document: true), 15_000_000_000)
        XCTAssertEqual(DictationFormatterService.refineTimeoutNanos(inputWords: 10, translating: false, document: true, thinking: true), 45_000_000_000)
        XCTAssertEqual(DictationFormatterService.refineTimeoutNanos(inputWords: 10_000, translating: false, document: true), 60_000_000_000)
        XCTAssertEqual(DictationFormatterService.refineTimeoutNanos(inputWords: 10_000, translating: false, thinking: true), 120_000_000_000)
    }

    func testRefineMustNotSwitchBetweenIndividualAndGroup() {
        XCTAssertTrue(RefineValidation.changesSpeakerNumber(input: "We need the results.", output: "I need the results."))
        XCTAssertTrue(RefineValidation.changesSpeakerNumber(input: "My report is ready.", output: "Our report is ready."))
        XCTAssertTrue(RefineValidation.changesSpeakerNumber(input: "Send us the data.", output: "Send me the data."))
        XCTAssertFalse(RefineValidation.changesSpeakerNumber(input: "we we need the results", output: "We need the results."))
        XCTAssertFalse(RefineValidation.changesSpeakerNumber(input: "I will send our report.", output: "I'll send our report."))
        XCTAssertFalse(RefineValidation.changesSpeakerNumber(input: "We should review it.", output: "Review it."))
    }
}
