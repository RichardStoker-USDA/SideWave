// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave
#if canImport(FoundationModels)
import FoundationModels

/// Retains the former compact schema for the opt-in plain/schema comparison.
@Generable
private struct AFMRefinedDictationGen1 {
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "The cleaned-up version of the input slice ONLY. Fix grammar, punctuation, capitalization, and transcription errors. Keep the speaker's own words and order. Do not add or complete unfinished thoughts. Keep every meaningful leading clause; remove spoken hesitations. Merge a mid-thought stray period into one flowing sentence. Preserve names and identifiers exactly. Never repeat a 3+ word phrase.")
    var cleanedText: String
}
#endif

/// Opt-in translation checks against the local Apple Foundation Model.
/// Set SIDEWAVE_TRANSLATION_PROBE=1 on an idle Mac with Apple Intelligence
/// enabled. Production checks cover segment, final-pass, and formatter paths;
/// plain/schema arms isolate the effect of constrained decoding.
final class ManualTranslationProbeTests: XCTestCase {

    private typealias OutputLanguage = DictationFormatterService.OutputLanguage
    private typealias Settings = DictationFormatterService.Settings
    private typealias Template = DictationFormatterService.Template

    /// Realistic English dictation, split into the kind of ~1-2 sentence slices
    /// the real-time refiner sees per segment. Deliberately mixes in a proper
    /// name (Sarah), a weekday, numbers, and a percentage — all of which the
    /// language rule says to PRESERVE — so a fully translated output still
    /// carries a little ASCII and the Han-ratio threshold stays honest.
    private let segments: [String] = [
        "so today I want to walk through the quarterly budget review and where we landed on the numbers",
        "the main thing is we came in about twelve percent under what we projected for the year",
        "I already looped in Sarah from finance and she is going to double check the figures before Friday",
        "if everything checks out we can move the extra funds into the hiring line for the new engineer",
        "let me know if you have any concerns otherwise I will send the final version to the whole team",
    ]

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        // Preserve fixture diagnostics if the test host exits during generation.
        setvbuf(stdout, nil, _IONBF, 0)
    }

    // MARK: - Gate

    private func requireProbeEnabled() throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_TRANSLATION_PROBE"] == "1" else {
            throw XCTSkip("Translation probe is opt-in. Set SIDEWAVE_TRANSLATION_PROBE=1 to run it.")
        }
    }

    // MARK: - Tests
    //
    // Run model arms in separate test processes to isolate model-session state.
    // The schema arm is diagnostic; production and plain arms assert results.

    // -- Simplified Chinese (the field-failure language) --

    func testZhProdArm() async throws {
        try await runArmTest(language: .simplifiedChinese, metric: .hanScript, arm: .prod, threshold: 0.5, hardAssert: true)
    }

    func testZhPlainArm() async throws {
        try await runArmTest(language: .simplifiedChinese, metric: .hanScript, arm: .plain, threshold: 0.5, hardAssert: true)
    }

    func testZhSchemaArm() async throws {
        try await runArmTest(language: .simplifiedChinese, metric: .hanScript, arm: .schema, threshold: 0.5, hardAssert: false)
    }

    /// The stop-time full-session final pass: the whole dictation refined in one
    /// shot through the real `buildPrompt` path (priorContext nil, no turn
    /// override) — a different prompt builder than the per-turn arms, and the
    /// path the owner's "Full Session" strategy and the smart/incremental tail
    /// merge feed. Confirms the tail doesn't drop back to English on the final
    /// pass.
    func testZhFinalPassArm() async throws {
        try await runFinalPassTest(language: .simplifiedChinese, metric: .hanScript, threshold: 0.5)
    }

    // -- Japanese / Korean (other CJK members of the offered set) --

    func testJaProdArm() async throws {
        try await runArmTest(language: .japanese, metric: .eastAsianScript, arm: .prod, threshold: 0.5, hardAssert: true)
    }

    func testKoProdArm() async throws {
        try await runArmTest(language: .korean, metric: .eastAsianScript, arm: .prod, threshold: 0.5, hardAssert: true)
    }

    // -- Spanish (Latin-script control) --

    func testEsProdArm() async throws {
        try await runArmTest(language: .spanish, metric: .spanishMarkers, arm: .prod, threshold: 0.5, hardAssert: true)
    }

    func testEsPlainArm() async throws {
        try await runArmTest(language: .spanish, metric: .spanishMarkers, arm: .plain, threshold: 0.5, hardAssert: true)
    }

    // -- End-to-end through the production `formatOrReturnRaw` entry --
    //
    // The arms above call `runAFMGeneration` directly, so they measure the
    // model, not the app path. The field leak was NOT in the model: generation
    // scored 1.00 while live dictation still pasted English. The culprit lived
    // one layer up, in `formatOrReturnRaw`'s word-ratio gate — `wordCount`
    // splits on whitespace, and Chinese has no spaces, so a correct 30-word
    // translation counted as ~1 word, blew the ratio floor, and the gate
    // discarded the translation and returned the raw English. This arm drives
    // the real `formatOrReturnRaw` on a long (>=15-word) input so the ratio gate
    // is actually in play; it would have caught the leak the direct arms missed.
    @MainActor
    func testZhFormatOrReturnRawEndToEnd() async throws {
        try requireProbeEnabled()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels requires macOS 26+.") }
        try requireAFMAvailable()

        let defaults = UserDefaults.standard
        let priorLang = defaults.string(forKey: "dictationOutputLanguage")
        let priorTemplate = defaults.string(forKey: "dictationCleanupTemplate")
        defaults.set("zh-Hans", forKey: "dictationOutputLanguage")
        defaults.set("standard", forKey: "dictationCleanupTemplate")
        defer {
            if let priorLang { defaults.set(priorLang, forKey: "dictationOutputLanguage") }
            else { defaults.removeObject(forKey: "dictationOutputLanguage") }
            if let priorTemplate { defaults.set(priorTemplate, forKey: "dictationCleanupTemplate") }
            else { defaults.removeObject(forKey: "dictationCleanupTemplate") }
        }

        let formatter = DictationFormatterService()
        formatter.setBackend(.appleIntelligence)
        // Explicitly load this opt-in fixture; automatic loading stays disabled in tests.
        await formatter.loadAppleIntelligence()
        defer { formatter.disable() }
        XCTAssertEqual(formatter.state, .ready)
        guard formatter.state == .ready else { return }

        // >=15 words so the ratio gate is engaged (short inputs skip it).
        let input = segments.joined(separator: ". ")
        let out = await formatter.formatOrReturnRaw(input, forceRefine: true, priorContext: nil, silentMode: true)
        let ratio = hanScriptRatio(out)
        print("[e2e formatOrReturnRaw zh] han-ratio=\(fmt(ratio)) :: \(out)")
        XCTAssertNotEqual(
            out.trimmingCharacters(in: .whitespacesAndNewlines),
            input.trimmingCharacters(in: .whitespacesAndNewlines),
            "formatOrReturnRaw returned the raw English input — the ratio gate leaked source language"
        )
        XCTAssertGreaterThanOrEqual(
            ratio, 0.5,
            "formatOrReturnRaw did not paste a Chinese translation (han-ratio \(fmt(ratio))): \(out)"
        )
        #else
        throw XCTSkip("FoundationModels not available in this build.")
        #endif
    }

    // -- Pure-logic guards (no AFM; run in the normal suite) --

    /// The translate-failure detector the refine worker uses to decide whether a
    /// segment came back untranslated (and must be retried or held) vs actually
    /// translated. Guards against a regression that would let the worker treat
    /// echoed English as a finished Chinese translation.
    func testTranslateLikelyFailedDetectsSourceLanguage() {
        typealias TS = TranscriptionService
        let zh = OutputLanguage.simplifiedChinese
        // Echo of the source input == failure.
        XCTAssertTrue(TS.translateLikelyFailed(
            output: "we came in twelve percent under",
            input: "we came in twelve percent under", target: zh))
        // Cleaned-but-still-English (no Han) == failure.
        XCTAssertTrue(TS.translateLikelyFailed(
            output: "We came in about 12% under budget.",
            input: "we came in twelve percent under", target: zh))
        // Empty == failure.
        XCTAssertTrue(TS.translateLikelyFailed(output: "   ", input: "anything", target: zh))
        // Real Chinese == success (not failed).
        XCTAssertFalse(TS.translateLikelyFailed(
            output: "我们比预算低了百分之十二。",
            input: "we came in twelve percent under", target: zh))
        // Chinese with a preserved Latin name + number stays above threshold.
        XCTAssertFalse(TS.translateLikelyFailed(
            output: "Sarah 会在周五前核对这些数字,大约低了 12%。",
            input: "Sarah will double check the figures by Friday", target: zh))
        // Latin-script targets fall back to the equality check only: a real
        // Spanish translation is NOT flagged, but an echo is.
        XCTAssertFalse(TS.translateLikelyFailed(
            output: "Vinimos alrededor de un doce por ciento por debajo.",
            input: "we came in twelve percent under", target: .spanish))
        XCTAssertTrue(TS.translateLikelyFailed(
            output: "we came in twelve percent under",
            input: "we came in twelve percent under", target: .spanish))
    }

    /// A held (source-language) span in the MIDDLE of otherwise-translated spans
    /// must be routed OUT of the reused body and INTO the stop-time tail, so the
    /// final pass re-covers it instead of pasting English. Without this the
    /// positional body/tail split buries the English segment in the body forever.
    @MainActor
    func testHeldSpanRoutesIntoStopTail() {
        let staged = StagedTranscript()
        let id1 = staged.ingestTdtCommitted("today I want to review the quarterly budget")
        staged.refineSpan(spanID: id1, refinedText: "今天我想回顾一下季度预算。")
        let id2 = staged.ingestTdtCommitted("we came in twelve percent under what we projected")
        staged.markHeldSourceLanguage(spanID: id2) // translate failed; English held
        let id3 = staged.ingestTdtCommitted("Sarah will double check the figures")
        staged.refineSpan(spanID: id3, refinedText: "Sarah 会核对这些数字。")

        let (body, tail) = staged.refinedBodyAndUnrefinedTail(includeRawEouTail: false)
        // Held English segment is excluded from the reused body...
        XCTAssertFalse(body.contains("twelve percent"), "held English segment leaked into the reused body")
        XCTAssertTrue(body.contains("今天"), "the translated prefix should remain the body")
        // ...and lands in the tail (with the trailing translated span) for the
        // stop-time re-translate pass.
        XCTAssertTrue(tail.contains("twelve percent"), "held English segment should route into the stop-time tail")
    }

    /// Runs one arm end to end, prints the aggregate + per-segment scores, and
    /// (optionally) asserts the aggregate clears the threshold.
    private func runArmTest(language: OutputLanguage, metric: Metric, arm: Arm, threshold: Double, hardAssert: Bool) async throws {
        try requireProbeEnabled()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels requires macOS 26+.") }
        try requireAFMAvailable()

        printLanguageSupport(language)
        let result = try await runArm(language: language, template: .standard, generation: AFMRuntime.generation, metric: metric, arm: arm)
        print("[probe] \(language.promptName) arm=\(arm) aggregate=\(fmt(result.aggregate)) per-segment=\(result.perSegment.map(fmt))")

        if hardAssert {
            for (index, score) in result.perSegment.enumerated() {
                XCTAssertGreaterThanOrEqual(
                    score, threshold,
                    "\(arm) segment \(index + 1) did not translate to \(language.promptName): \(result.outputs[index])"
                )
            }
        }
        #else
        throw XCTSkip("FoundationModels not available in this build.")
        #endif
    }

    /// Full-session final pass: refine the whole dictation in one shot through
    /// the production `runAFMGeneration` with `buildPrompt` (priorContext nil, no
    /// turn override), then score the entire output for target-language coverage.
    private func runFinalPassTest(language: OutputLanguage, metric: Metric, threshold: Double) async throws {
        try requireProbeEnabled()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels requires macOS 26+.") }
        try requireAFMAvailable()

        printLanguageSupport(language)
        let fullText = segments.joined(separator: ". ")
        let session = LanguageModelSession(
            model: AFMRuntime.makeModel(),
            instructions: DictationFormatterService.afmInstructions(for: .standard, generation: AFMRuntime.generation, outputLanguage: language)
        )
        let settings = makeSettings(template: .standard, language: language, priorContext: nil)
        let output = try await DictationFormatterService.runAFMGeneration(
            sessionHolder: session, rawText: fullText, settings: settings,
            promptOverride: nil, onStream: { _ in }
        )
        let s = score(output, metric: metric)
        print("[probe] \(language.promptName) arm=finalPass aggregate=\(fmt(s))")
        print("[finalPass] :: \(output)")
        XCTAssertGreaterThanOrEqual(
            s, threshold,
            "final-pass path did not translate to \(language.promptName) (score \(fmt(s))): \(output)"
        )
        #else
        throw XCTSkip("FoundationModels not available in this build.")
        #endif
    }

    // MARK: - Probe core

    private enum Metric { case hanScript, eastAsianScript, spanishMarkers }

    private struct ArmResult {
        var perSegment: [Double] = []
        var outputs: [String] = []
        var aggregate: Double { perSegment.isEmpty ? 0 : perSegment.reduce(0, +) / Double(perSegment.count) }
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func requireAFMAvailable() throws {
        let model = AFMRuntime.makeModel()
        guard case .available = model.availability else {
            throw XCTSkip("Apple Intelligence is not available on this Mac; cannot run the translation probe.")
        }
    }

    /// Log the device's own claim about a language — the gating signals
    /// `offeredOutputLanguages` could rely on (`supportsLocale` is the per-device
    /// pre-flight; `supportedLanguages` membership is the set the current code
    /// uses).
    @available(macOS 26, *)
    private func printLanguageSupport(_ language: OutputLanguage) {
        let model = AFMRuntime.makeModel()
        let claimsSupport = model.supportsLocale(Locale(identifier: language.rawValue))
        let inSupportedSet = model.supportedLanguages.contains {
            $0.languageCode == Locale.Language(identifier: language.rawValue).languageCode
        }
        print("[probe] \(language.promptName): supportsLocale=\(claimsSupport) inSupportedLanguages=\(inSupportedSet)")
    }

    private enum Arm { case prod, schema, plain }

    /// Mirrors the production session-turns loop, including the rebuild-and-
    /// reseed behavior of `prepareAFMTurnSession`: the AFM context window on
    /// this Mac is only 4096 tokens (queried live), and the constrained-schema
    /// arm's per-turn schema re-injection grows the transcript fast, so a naive
    /// one-session-for-all-turns loop overflows mid-dictation. We rebuild the
    /// session when the running token estimate crosses ~half the cap and, as a
    /// hard safety net, catch an overflow at generation time and rebuild+retry
    /// (the same hard-reset production does on `.contextOverflow`).
    @available(macOS 26, *)
    private func runArm(language: OutputLanguage, template: Template, generation: AFMRuntime.Generation, metric: Metric, arm: Arm) async throws -> ArmResult {
        let cap = DictationFormatterService.afmContextSize()
        let rebuildThreshold = Int(Double(cap) * 0.5)
        // Standard-template gen-2 Instructions are long; the constrained arm
        // also re-sends the @Generable schema every turn. Seed the base high so
        // the proactive rebuild triggers before the live window overflows.
        let sessionBase = arm == .plain ? 900 : 1400
        let schemaPerTurn = arm == .plain ? 0 : 420

        func makeSession() -> LanguageModelSession {
            LanguageModelSession(
                model: AFMRuntime.makeModel(),
                instructions: DictationFormatterService.afmInstructions(for: template, generation: generation, outputLanguage: language)
            )
        }

        var result = ArmResult()
        var priorContext = ""
        var session = makeSession()
        var tokenEstimate = sessionBase

        for raw in segments {
            let turnInputTokens = max(1, raw.count / 3) + 120

            // Proactive rebuild (production's threshold check).
            var isFirst = false
            if tokenEstimate + turnInputTokens >= rebuildThreshold {
                session = makeSession()
                tokenEstimate = sessionBase
                isFirst = true
            } else if priorContext.isEmpty {
                isFirst = true // first turn of the dictation
            }

            func promptFor(first: Bool) -> String {
                let settings = makeSettings(template: template, language: language, priorContext: first ? nil : priorContext)
                let seedTail: String? = (first && !priorContext.isEmpty) ? String(priorContext.suffix(600)) : nil
                return DictationFormatterService.buildAFMTurnPrompt(rawText: raw, settings: settings, seedTail: seedTail, isFirstTurn: first)
            }

            func generate(prompt: String) async throws -> String {
                let settings = makeSettings(template: template, language: language, priorContext: isFirst ? nil : priorContext)
                switch arm {
                case .prod:
                    return try await DictationFormatterService.runAFMGeneration(
                        sessionHolder: session, rawText: raw, settings: settings,
                        promptOverride: prompt, onStream: { _ in }
                    )
                case .schema:
                    return try await forceSchema(session: session, prompt: prompt, rawText: raw, generation: generation)
                case .plain:
                    return try await forcePlain(session: session, prompt: prompt, rawText: raw)
                }
            }

            var prompt = promptFor(first: isFirst)
            var output: String
            do {
                output = try await generate(prompt: prompt)
            } catch {
                // Hard-reset on overflow (or any generation error): rebuild the
                // session, reseed from the prior tail, retry the turn once. If
                // it still fails, record the error and keep going — one bad
                // segment must not abort the whole probe (and lose all data).
                session = makeSession()
                tokenEstimate = sessionBase
                isFirst = true
                prompt = promptFor(first: true)
                do {
                    output = try await generate(prompt: prompt)
                } catch {
                    output = "[gen-error: \(error)]"
                }
            }

            let segScore = score(output, metric: metric)
            result.outputs.append(output)
            result.perSegment.append(segScore)
            priorContext = priorContext.isEmpty ? output : priorContext + " " + output
            tokenEstimate += max(1, prompt.count / 3) + max(1, raw.count / 3) + schemaPerTurn
            // Incremental, flushed so partial results survive an early host exit.
            print("[\(arm) seg \(result.outputs.count)] score=\(fmt(segScore)) :: \(output)")
        }
        return result
    }

    /// Force the `@Generable` constrained path directly (bypasses any
    /// translation routing in `runAFMGeneration`), so the schema arm always
    /// reflects what constrained decoding does regardless of the fix.
    @available(macOS 26, *)
    private func forceSchema(session: LanguageModelSession, prompt: String, rawText: String, generation: AFMRuntime.Generation) async throws -> String {
        let options = DictationFormatterService.afmGenerationOptions(for: .standard, inputTokenEstimate: max(16, rawText.count / 4))
        var output = ""
        if generation == .gen1 {
            let stream = session.streamResponse(to: Prompt(prompt), generating: AFMRefinedDictationGen1.self, options: options)
            for try await partial in stream { if let t = partial.content.cleanedText { output = t } }
        } else {
            let stream = session.streamResponse(to: Prompt(prompt), generating: AFMRefinedDictation.self, options: options)
            for try await partial in stream { if let t = partial.content.cleanedText { output = t } }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Force the plain-String path directly (no response schema).
    @available(macOS 26, *)
    private func forcePlain(session: LanguageModelSession, prompt: String, rawText: String) async throws -> String {
        let options = DictationFormatterService.afmGenerationOptions(for: .standard, inputTokenEstimate: max(16, rawText.count / 4))
        var output = ""
        let stream = session.streamResponse(to: prompt, options: options)
        for try await partial in stream { output = partial.content }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    // MARK: - Settings builder

    private func makeSettings(template: Template, language: OutputLanguage, priorContext: String?) -> Settings {
        Settings(
            template: template,
            removeFillerWords: false,
            customFillerPhrases: [],
            profanityMode: .none,



            customInstructions: "",
            speakerProfile: "",
            vocabulary: .empty,
            priorContext: priorContext,
            useThinkingMode: false,
            outputLanguage: language
        )
    }

    // MARK: - Scoring

    private func score(_ text: String, metric: Metric) -> Double {
        switch metric {
        case .hanScript: return hanScriptRatio(text)
        case .eastAsianScript: return eastAsianScriptRatio(text)
        case .spanishMarkers: return spanishMarkerScore(text)
        }
    }

    /// Like `hanScriptRatio` but also counts Japanese kana and Korean Hangul as
    /// target-script, so a Japanese (kanji + kana) or Korean output scores as
    /// translated. Latin letters are the non-target half of the denominator.
    private func eastAsianScriptRatio(_ text: String) -> Double {
        var target = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isTarget =
                (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) ||  // Han
                (0xF900...0xFAFF).contains(v) || (0x20000...0x2A6DF).contains(v) ||
                (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) ||  // Hiragana / Katakana
                (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v)     // Hangul syllables / Jamo
            if isTarget { target += 1; continue }
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { latin += 1 }
        }
        let total = target + latin
        return total == 0 ? 0 : Double(target) / Double(total)
    }

    /// Fraction of "letter" content that is CJK Han script. Digits, whitespace,
    /// and punctuation are ignored so preserved numbers don't skew it; Latin
    /// letters (from preserved names / technical terms) are the denominator's
    /// non-Han half. 1.0 = all-Chinese, 0.0 = no Chinese at all.
    private func hanScriptRatio(_ text: String) -> Double {
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isHan =
                (0x4E00...0x9FFF).contains(v) ||
                (0x3400...0x4DBF).contains(v) ||
                (0xF900...0xFAFF).contains(v) ||
                (0x20000...0x2A6DF).contains(v)
            if isHan { han += 1; continue }
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { latin += 1 }
        }
        let total = han + latin
        return total == 0 ? 0 : Double(han) / Double(total)
    }

    /// Heuristic "a Spanish translation clearly happened" score in [0, 1].
    /// Latin script makes a pure ratio meaningless, so we look for Spanish
    /// function words that are rare/absent in English plus Spanish-specific
    /// diacritics. Scaled so ~3 distinct markers reads as a clear pass.
    private func spanishMarkerScore(_ text: String) -> Double {
        let lower = text.lowercased()
        let markers: Set<String> = [
            "el", "la", "los", "las", "una", "unos", "unas", "que", "de", "del",
            "por", "para", "con", "está", "están", "esto", "esta", "como", "pero",
            "más", "también", "según", "nosotros", "ustedes", "sobre", "hemos",
            "vamos", "hacia", "porque", "cuando", "si", "ya", "muy", "todo", "todos",
        ]
        let tokens = lower.split { !$0.isLetter }.map(String.init)
        let distinct = Set(tokens).intersection(markers)
        var score = Double(distinct.count) / 3.0
        // Any Spanish diacritic / inverted punctuation is a strong signal.
        if text.contains(where: { "áéíóúñ¿¡".contains($0) }) { score += 0.34 }
        return min(1.0, score)
    }

    // MARK: - Reporting

    private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }
}
