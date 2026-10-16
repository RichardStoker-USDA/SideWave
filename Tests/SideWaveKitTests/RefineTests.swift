// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest

@testable import SideWaveKit

/// Pins the carried output-hygiene passes. Each transform exists because
/// a real model shipped that exact garbage.
final class RefineHygieneTests: XCTestCase {

    // MARK: cleanupModelOutput

    func testStripsWrappingQuotes() {
        XCTAssertEqual(RefineHygiene.cleanupModelOutput("\"Hello world.\""), "Hello world.")
    }

    func testStripsPreamble() {
        XCTAssertEqual(
            RefineHygiene.cleanupModelOutput("Here is the corrected text: Hello world."),
            "Hello world.")
    }

    func testStripsCodeFences() {
        XCTAssertEqual(
            RefineHygiene.cleanupModelOutput("```\nHello world.\n```"),
            "Hello world.")
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(
            RefineHygiene.cleanupModelOutput("Just a normal sentence."),
            "Just a normal sentence.")
    }

    // MARK: stripTrailingRepeat

    func testStripsFabricatedTailRestart() {
        // The AFM partial-restart failure mode: same 4+ word phrase twice,
        // second copy at the very end.
        let input = "We will roll this out incrementally over a quarter and then review it an incrementally over a quarter"
        let out = RefineHygiene.stripTrailingRepeat(input)
        XCTAssertFalse(out.hasSuffix("over a quarter"), "repeated tail must strip: \(out)")
        XCTAssertTrue(out.hasPrefix("We will roll this out"))
    }

    func testKeepsLegitimateShortEcho() {
        let input = "It grows day by day, week by week"
        XCTAssertEqual(RefineHygiene.stripTrailingRepeat(input), input)
    }

    func testShortTextsAreUntouched() {
        let input = "one two three four five"
        XCTAssertEqual(RefineHygiene.stripTrailingRepeat(input), input)
    }

    // MARK: mergeMidSentenceConjunctions

    func testMergesAFMInsertedMidThoughtPeriod() {
        XCTAssertEqual(
            RefineHygiene.mergeMidSentenceConjunctions("I went to the store. And then home."),
            "I went to the store and then home.")
    }

    func testLeavesLongSentenceBoundariesAlone() {
        let input = "We finished the deployment and verified every host in the fleet was healthy. But the monitoring dashboard still needs work."
        XCTAssertEqual(RefineHygiene.mergeMidSentenceConjunctions(input), input)
    }

    func testCascadingMergesResolve() {
        XCTAssertEqual(
            RefineHygiene.mergeMidSentenceConjunctions("Ship it. And test it. But keep notes."),
            "Ship it and test it but keep notes.")
    }

    // MARK: think-block strip

    func testStripsGemmaThinkBlock() {
        XCTAssertEqual(
            RefineHygiene.stripGemmaThinkBlock("reasoning goes here<|/think|>\nThe answer."),
            "The answer.")
    }

    func testNoThinkBlockIsNoOp() {
        XCTAssertEqual(RefineHygiene.stripGemmaThinkBlock("The answer."), "The answer.")
    }

    // MARK: ratio gate

    func testRatioGateRejectsHallucinatedGrowth() {
        let input = Array(repeating: "word", count: 40).joined(separator: " ")
        let output = Array(repeating: "word", count: 70).joined(separator: " ")
        let violation = RefineHygiene.ratioViolation(input: input, output: output, template: .standard)
        XCTAssertNotNil(violation, "40 -> 70 words on Standard is the pinned hallucination case")
    }

    func testRatioGateAcceptsNormalEdit() {
        let input = "so um the thing is we need to improve the performance by like thirty percent before next quarter"
        let output = "The thing is, we need to improve the performance by thirty percent before next quarter."
        XCTAssertNil(RefineHygiene.ratioViolation(input: input, output: output, template: .standard))
    }

    func testRatioGateSkipsVeryShortInputs() {
        XCTAssertNil(RefineHygiene.ratioViolation(input: "ok then", output: "Okay, then — understood, thanks!", template: .standard))
    }

    func testConciseMustNotGrow() {
        let input = Array(repeating: "word", count: 20).joined(separator: " ")
        let output = Array(repeating: "word", count: 24).joined(separator: " ")
        XCTAssertNotNil(RefineHygiene.ratioViolation(input: input, output: output, template: .concise))
    }
}

/// Sanity pins on the carried prompt library: the tuned sentences that
/// must survive any refactor.
final class RefinePromptsTests: XCTestCase {

    func testGemmaSystemPromptCarriesHardRules() {
        let prompt = RefinePrompts.gemmaSystemPrompt(
            for: .standard, outputLanguage: .matchInput, speakerProfile: "")
        XCTAssertTrue(prompt.contains("HARD RULE — DO NOT EXTEND THE INPUT"))
        XCTAssertTrue(prompt.contains("HARD RULE — DO NOT TRUNCATE THE START OF THE INPUT"))
        XCTAssertTrue(prompt.contains("HARD RULE — SAME LANGUAGE"))
        XCTAssertTrue(prompt.contains("Never repeat the same 3+ word phrase"))
    }

    func testTranslationRuleReplacesSameLanguageRule() {
        let prompt = RefinePrompts.gemmaSystemPrompt(
            for: .standard, outputLanguage: .german, speakerProfile: "")
        XCTAssertTrue(prompt.contains("TRANSLATE INTO GERMAN"))
        XCTAssertFalse(prompt.contains("HARD RULE — SAME LANGUAGE"))
    }

    func testSpeakerProfileFoldsInWithGuardrails() {
        let prompt = RefinePrompts.gemmaSystemPrompt(
            for: .standard, outputLanguage: .matchInput, speakerProfile: "Talks in short bursts.")
        XCTAssertTrue(prompt.contains("Talks in short bursts."))
        XCTAssertTrue(prompt.contains("Do NOT copy it into the output"))
    }

    func testUserPromptCarriesCustomInstructionsAndVocabulary() {
        let settings = RefineSettings(
            template: .custom,
            customInstructions: "Always spell it enRiched.",
            referenceVocabulary: "Reference vocabulary:\n- enRiched")
        let prompt = RefinePrompts.buildUserPrompt(rawText: "hello", settings: settings)
        XCTAssertTrue(prompt.contains("USER INSTRUCTIONS"))
        XCTAssertTrue(prompt.contains("Always spell it enRiched."))
        XCTAssertTrue(prompt.contains("Reference vocabulary:"))
        XCTAssertTrue(prompt.hasSuffix("Dictated text:\nhello"))
    }

    func testCustomInstructionsAreLengthCapped() {
        let long = String(repeating: "x", count: 5_000)
        let prompt = RefinePrompts.buildUserPrompt(
            rawText: "hi", settings: RefineSettings(customInstructions: long))
        XCTAssertLessThan(prompt.count, 1_200 + 60)
    }

    func testTimeoutScalesWithInputAndClamps() {
        XCTAssertEqual(RefinePrompts.refineTimeout(inputWords: 1, translating: false), .seconds(6))
        XCTAssertEqual(RefinePrompts.refineTimeout(inputWords: 100, translating: false), .seconds(15))
        XCTAssertEqual(RefinePrompts.refineTimeout(inputWords: 1_000, translating: false), .seconds(30))
        XCTAssertEqual(RefinePrompts.refineTimeout(inputWords: 1, translating: true), .seconds(12))
    }

    func testEveryTemplateBuildsNonEmptyPrompts() {
        for template in RefineTemplate.allCases {
            let system = RefinePrompts.gemmaSystemPrompt(
                for: template, outputLanguage: .matchInput, speakerProfile: "")
            XCTAssertGreaterThan(system.count, 200, "\(template) system prompt suspiciously short")
            XCTAssertFalse(RefinePrompts.templateTail(template).isEmpty)
        }
    }
}
