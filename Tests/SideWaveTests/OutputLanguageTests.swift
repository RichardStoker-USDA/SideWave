// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Tests for the dictation output-language feature's pure pieces: the
/// OutputLanguage code lookup, the TranscriptionEntry fields' tolerant
/// decoding of legacy history files, and the language-rule switch that flips a
/// refine prompt between "keep the spoken language" and "translate into X".
/// All model-free.
final class OutputLanguageTests: XCTestCase {

    typealias OutputLanguage = DictationFormatterService.OutputLanguage

    // MARK: - Code lookup

    func testFromCodeKnown() {
        XCTAssertEqual(OutputLanguage.from(code: "es"), .spanish)
        XCTAssertEqual(OutputLanguage.from(code: "zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(OutputLanguage.from(code: "match"), .matchInput)
    }

    func testFromCodeUnknownFallsBackToMatch() {
        XCTAssertEqual(OutputLanguage.from(code: nil), .matchInput)
        XCTAssertEqual(OutputLanguage.from(code: ""), .matchInput)
        XCTAssertEqual(OutputLanguage.from(code: "klingon"), .matchInput)
        XCTAssertEqual(OutputLanguage.from(code: "ES"), .matchInput) // case-sensitive raw codes
    }

    func testMatchInputIsTheDefaultRawValue() {
        XCTAssertEqual(OutputLanguage.matchInput.rawValue, "match")
        XCTAssertTrue(OutputLanguage.matchInput.isMatch)
        XCTAssertFalse(OutputLanguage.spanish.isMatch)
    }

    func testEveryCaseHasDistinctPromptAndDisplayNames() {
        // Guards against copy-paste errors in the two name tables.
        let display = Set(OutputLanguage.allCases.map(\.displayName))
        XCTAssertEqual(display.count, OutputLanguage.allCases.count)
        // promptName is empty only for Match input.
        for lang in OutputLanguage.allCases where lang != .matchInput {
            XCTAssertFalse(lang.promptName.isEmpty, "\(lang) has no prompt name")
        }
        XCTAssertTrue(OutputLanguage.matchInput.promptName.isEmpty)
    }

    // MARK: - AFM runtime supported-language gating

    func testIsSupportedMatchAlwaysTrue() {
        XCTAssertTrue(OutputLanguage.matchInput.isSupported(by: []))
    }

    func testIsSupportedByBaseLanguageCode() {
        let set: Set<Locale.Language> = [
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "es"),
            Locale.Language(identifier: "zh-Hans"),
        ]
        XCTAssertTrue(OutputLanguage.spanish.isSupported(by: set))
        XCTAssertTrue(OutputLanguage.english.isSupported(by: set))
        XCTAssertTrue(OutputLanguage.simplifiedChinese.isSupported(by: set))
        XCTAssertFalse(OutputLanguage.japanese.isSupported(by: set))
        XCTAssertFalse(OutputLanguage.korean.isSupported(by: set))
    }

    @MainActor
    func testGemmaOffersFullCuratedSet() {
        // Gemma is not OS-gated; the full list stands regardless of AFM state.
        let gemma = DictationFormatterService.offeredOutputLanguages(for: .gemma4E2B)
        XCTAssertEqual(Set(gemma), Set(OutputLanguage.allCases))
    }

    // MARK: - Language rule switch (prompt plumbing)

    func testLanguageRuleMatchLocksSameLanguage() {
        let rule = DictationFormatterService.refineLanguageRule(for: .matchInput)
        XCTAssertTrue(rule.contains("SAME LANGUAGE"))
        XCTAssertFalse(rule.uppercased().contains("TRANSLATE INTO"))
    }

    func testLanguageRuleTargetTranslates() {
        let rule = DictationFormatterService.refineLanguageRule(for: .spanish)
        XCTAssertTrue(rule.contains("TRANSLATE INTO SPANISH"))
        XCTAssertTrue(rule.contains("Spanish"))
        // Must not also carry the same-language lock (they contradict).
        XCTAssertFalse(rule.contains("SAME LANGUAGE"))
    }

    func testTurnRuleCarriesTarget() {
        let match = DictationFormatterService.refineLanguageRuleTurn(for: .matchInput)
        XCTAssertTrue(match.contains("LANGUAGE LOCK"))
        let target = DictationFormatterService.refineLanguageRuleTurn(for: .japanese)
        XCTAssertTrue(target.contains("Japanese"))
        XCTAssertFalse(target.contains("LANGUAGE LOCK"))
    }

    func testGen1RuleIsShortAndOnTopic() {
        let target = DictationFormatterService.refineLanguageRuleGen1(for: .french)
        XCTAssertTrue(target.contains("French"))
        let match = DictationFormatterService.refineLanguageRuleGen1(for: .matchInput)
        XCTAssertTrue(match.lowercased().contains("never translate"))
    }

    func testTranslationPromptsCoverFullSessionAndContinuationWithoutEnglishBoundaryRules() {
        for language in [OutputLanguage.simplifiedChinese, .korean, .spanish] {
            for prior in [nil, "Earlier translated text"] as [String?] {
                let settings = DictationFormatterService.Settings(
                    template: .standard, removeFillerWords: true, customFillerPhrases: [],
                    profanityMode: .none,
                    customInstructions: "", speakerProfile: "", vocabulary: .empty,
                    priorContext: prior, useThinkingMode: false, outputLanguage: language)
                let input = "we will review the figures before"
                let prompts = [
                    DictationFormatterService.buildPrompt(rawText: input, settings: settings),
                    DictationFormatterService.buildAFMTurnPrompt(
                        rawText: input, settings: settings, seedTail: prior, isFirstTurn: prior == nil)
                ]
                for prompt in prompts {
                    XCTAssertTrue(prompt.contains(input))
                    XCTAssertTrue(prompt.contains(language.promptName))
                    XCTAssertTrue(prompt.contains("unfinished"))
                    XCTAssertFalse(prompt.contains("normal English rules"))
                    XCTAssertFalse(prompt.contains("at the same words"))
                }
            }
        }
    }

    // MARK: - TranscriptionEntry tolerant decode

    /// Legacy history files predate the outputLanguage / backTranslation
    /// fields. Decoding one must succeed with both new fields nil.
    func testLegacyEntryDecodesWithNilNewFields() throws {
        let legacyJSON = """
        {
            "id": "11112222-3333-4444-5555-666677778888",
            "timestamp": 700000000.0,
            "text": "hello world",
            "appName": "TextEdit",
            "characterCount": 11
        }
        """.data(using: .utf8)!

        let entry = try JSONDecoder().decode(TranscriptionEntry.self, from: legacyJSON)
        XCTAssertEqual(entry.text, "hello world")
        XCTAssertNil(entry.outputLanguage)
        XCTAssertNil(entry.backTranslation)
        XCTAssertFalse(entry.wasTranslated)
        XCTAssertEqual(entry.outputLanguageValue, .matchInput)
    }

    /// An entry that kept the spoken language stores no code and is not
    /// flagged as translated.
    func testMatchEntryNotFlaggedTranslated() {
        let entry = TranscriptionEntry(text: "hola", appName: "Notes", outputLanguage: nil)
        XCTAssertFalse(entry.wasTranslated)
    }

    /// A translated entry round-trips its code and cached back-translation.
    func testTranslatedEntryRoundTrips() throws {
        let cached = BackTranslation(
            literalText: "I am going to break a leg",
            reasoning: "'Mucha mierda' localizes to the theater idiom, not a literal wish."
        )
        let entry = TranscriptionEntry(
            text: "Mucha mierda esta noche",
            appName: "Mail",
            rawText: "break a leg tonight",
            outputLanguage: "es",
            backTranslation: cached
        )
        XCTAssertTrue(entry.wasTranslated)
        XCTAssertEqual(entry.outputLanguageValue, .spanish)

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TranscriptionEntry.self, from: data)
        XCTAssertEqual(decoded.outputLanguage, "es")
        XCTAssertEqual(decoded.backTranslation, cached)
        XCTAssertTrue(decoded.wasTranslated)
    }

    /// A stored bogus code degrades to "not translated" rather than crashing
    /// or showing a broken action.
    func testUnknownStoredCodeIsNotTranslated() {
        let entry = TranscriptionEntry(text: "x", appName: "A", outputLanguage: "made-up")
        XCTAssertFalse(entry.wasTranslated)
        XCTAssertEqual(entry.outputLanguageValue, .matchInput)
    }
}
