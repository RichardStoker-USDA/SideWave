// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

@MainActor
final class FinalRefinementTests: XCTestCase {
    func testFinalWindowCanRepairAFalseSentenceBreak() {
        let window = RefinementWindow(refinedBody: "The samples are frozen. The report is ready. Send it before.",
                                      unrefinedTail: "Lunch on Friday.")
        XCTAssertEqual(window.prefix, "The samples are frozen.")
        XCTAssertEqual(window.editable, "The report is ready. Send it before. Lunch on Friday.")
        XCTAssertEqual(window.context, window.prefix)
    }

    func testEmptyTailStillChecksTheLastSentence() {
        let window = RefinementWindow(refinedBody: "Please review the the samples.", unrefinedTail: "")
        XCTAssertEqual(window.editable, "Please review the the samples.")
        XCTAssertTrue(window.prefix.isEmpty)
    }

    func testLongUnpunctuatedInputIsBoundedWithoutLosingWords() {
        let input = (0..<1_200).map { "word\($0)" }.joined(separator: " ")
        let boundary = RefinementWindow.splitBoundary(input)
        XCTAssertEqual(boundary.tail.split(separator: " ").count, 64)
        XCTAssertEqual(RefinementWindow.join(boundary.prefix, boundary.tail), input)
        XCTAssertEqual(RefinementWindow.recentContext(input).split(separator: " ").count, 400)
        var remainder = input
        var chunks: [String] = []
        while !remainder.isEmpty {
            let part = RefinementWindow.nextChunk(remainder)
            XCTAssertLessThanOrEqual(part.chunk.split(separator: " ").count, 160)
            XCTAssertLessThan(part.remaining.count, remainder.count)
            chunks.append(part.chunk)
            remainder = part.remaining
        }
        XCTAssertEqual(chunks.joined(separator: " "), input)
    }

    func testRefinementWindowPreservesExistingParagraphs() {
        let body = "The first group is ready.\n\nThe second group is frozen.\n\nSend the report. Review the labels."
        let window = RefinementWindow(refinedBody: body, unrefinedTail: "Finish tomorrow.")
        XCTAssertEqual(window.prefix, "The first group is ready.\n\nThe second group is frozen.\n\n")
        XCTAssertEqual(RefinementWindow.join(window.prefix, window.editable), body + " Finish tomorrow.")
        let long = String(repeating: "Keep each label.\n\n", count: 80)
        let chunk = RefinementWindow.nextChunk(long)
        XCTAssertEqual(RefinementWindow.join(chunk.chunk, chunk.remaining), long.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testFailedEarlierSpanIsNotHiddenBehindLaterSuccess() throws {
        let transcript = StagedTranscript()
        let first = try XCTUnwrap(transcript.ingestTdtCommitted("The first sample is frozen."))
        _ = transcript.ingestTdtCommitted("The the second sample needs review.")
        let third = try XCTUnwrap(transcript.ingestTdtCommitted("The last sample is ready."))
        transcript.markRefinedNoChange(spanID: first)
        transcript.markRefinedNoChange(spanID: third)
        let split = transcript.refinedBodyAndUnrefinedTail(includeRawEouTail: false)
        XCTAssertEqual(split.body, "The first sample is frozen.")
        XCTAssertEqual(split.tail, "The the second sample needs review. The last sample is ready.")
    }

    func testBoundaryContextDoesNotFalselyCountAsRefined() throws {
        let transcript = StagedTranscript()
        let first = try XCTUnwrap(transcript.ingestTdtCommitted("The the samples are ready. Send them"))
        let second = try XCTUnwrap(transcript.ingestTdtCommitted("Before lunch."))
        transcript.applyBoundaryMerge(prevSpanID: first, prevTextWithoutBoundary: "The the samples are ready.",
                                      currSpanID: second, currRefinedText: "Send them before lunch.")
        let split = transcript.refinedBodyAndUnrefinedTail(includeRawEouTail: false)
        XCTAssertTrue(split.body.isEmpty)
        XCTAssertTrue(split.tail.contains("The the samples"))
    }

    func testCompletedCaptureDoesNotRunAnotherModelPass() async {
        let state = AppState()
        state.dictationFormatter.disable()
        var attempted = false
        state.dictationFormatter.onSilentFallback = { _ in attempted = true }
        let body = "The samples stay frozen. Send the report on Friday."
        let result = await state.finishIncrementalRefinement(refinedBody: body,
            unrefinedTail: "  \n", onStream: { _ in XCTFail("Settled text must not restart streaming") })
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.text, body)
        XCTAssertFalse(attempted)
    }

    func testUnavailableFinalRefinementKeepsRecoverableText() async {
        let state = AppState()
        state.dictationFormatter.disable()
        let input = "The samples must stay frozen until Friday."
        let result = await state.finishIncrementalRefinement(refinedBody: "", unrefinedTail: input, onStream: { _ in })
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.text, input)
        state.preserveUnfinishedRefinement(result.text)
        XCTAssertEqual(state.pendingSessionText, input)
        XCTAssertEqual(state.historyStore.entries.first?.text, input)
        XCTAssertNil(state.historyStore.entries.first?.refineBackend)
        XCTAssertEqual(state.dictationSessionPhase, .failed)
        XCTAssertFalse(state.isCleaningUp)
    }

    func testFinalFragmentDoesNotReapplyWholeSessionWordMinimum() async {
        let formatter = DictationFormatterService()
        formatter.minimumWordCount = 50
        var reachedReadinessCheck = false
        formatter.onSilentFallback = { _ in reachedReadinessCheck = true }
        _ = await formatter.refine("Send it tomorrow.", forceRefine: true, finishing: true)
        XCTAssertTrue(reachedReadinessCheck, "The caller already checked the complete capture's word count")
    }

    func testFinalBudgetDoesNotCutOffAtTheOldEightSecondLimit() {
        XCTAssertEqual(DictationFormatterService.refineTimeoutNanos(inputWords: 10, translating: false, finishing: true), 15_000_000_000)
        XCTAssertEqual(DictationFormatterService.refineTimeoutNanos(inputWords: 160, translating: false, finishing: true), 40_000_000_000)
        XCTAssertEqual(DictationFormatterService.refineTimeoutNanos(inputWords: 10_000, translating: false, finishing: true), 60_000_000_000)
    }

    func testLiveStopFinishesShortTailAndRetiresBusyGeneration() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SIDEWAVE_LIVE_MODELS"] == "1", env["SIDEWAVE_ALLOW_MODEL_LOAD_IN_TESTS"] == "1" else {
            throw XCTSkip("Requires explicit local model test opt-in")
        }
        URLProtocol.registerClass(TransparencyURLProtocol.self)
        TransparencyURLProtocol.setupSwizzling()
        let backend = try XCTUnwrap(DictationFormatterService.Backend(rawValue: env["SIDEWAVE_REFINE_BACKEND"] ?? "apple-intelligence"))
        let defaults = UserDefaults.standard
        let keys = ["dictationCleanupTemplate", "dictationOutputLanguage", "removeFillerWords", "gemmaThinkingMode", "gemmaSessionTurns", "redactPII", "redactSSN", "redactCreditCard", "redactAPIKey", "redactPhone", "redactEmail", "redactURL", "redactIPAddress"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "redactPII")
        defaults.set("standard", forKey: "dictationCleanupTemplate")
        defaults.set("match", forKey: "dictationOutputLanguage")
        defaults.set(true, forKey: "removeFillerWords")
        defaults.set(false, forKey: "gemmaThinkingMode")
        defaults.set(true, forKey: "gemmaSessionTurns")
        let state = AppState()
        let formatter = state.dictationFormatter
        formatter.minimumWordCount = 0
        formatter.setBackend(backend)
        formatter.enable()
        defer { formatter.disable() }
        let preparation = Date()
        while formatter.state != .ready, Date().timeIntervalSince(preparation) < 900 {
            switch formatter.state {
            case .error(let message), .unavailable(let message): XCTFail(message); return
            default: break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(formatter.state, .ready)
        formatter.beginDictation()
        let first = await formatter.refine("um the samples must stay frozen until Friday", forceRefine: true, priorContext: "")
        XCTAssertTrue(first.completed)
        let fixtures = [
            ("The report is ready. We should send it before.", "Lunch on Friday."),
            ("The instructions should be easy to.", "Read."),
            ("", "um send the report tomorrow")
        ]
        for template in ["standard", "professional", "concise"] {
            defaults.set(template, forKey: "dictationCleanupTemplate")
            formatter.beginDictation()
            for (body, tail) in fixtures {
                let start = Date()
                let result = await state.finishIncrementalRefinement(refinedBody: body, unrefinedTail: tail, onStream: { _ in })
                XCTAssertTrue(result.completed, "Final refinement must complete")
                XCTAssertFalse(result.text.lowercased().contains("um "), result.text)
                XCTAssertFalse(result.text.lowercased().contains("before. lunch"), result.text)
                XCTAssertFalse(result.text.lowercased().contains("to. read"), result.text)
                let required = tail.contains("Friday") ? ["Friday", "lunch", "report"] : tail.contains("Read") ? ["read", "instructions"] : ["tomorrow", "report"]
                for word in required { XCTAssertTrue(result.text.localizedCaseInsensitiveContains(word), result.text) }
                print("FINAL_REFINE backend=\(backend.rawValue) template=\(template) seconds=\(Date().timeIntervalSince(start))")
            }
            if backend.huggingFaceRepoID != nil {
                XCTAssertGreaterThan(formatter.reusedPromptTokens, 0, "Editable overlap must reuse the active capture's cache")
                print("FINAL_CACHE_REUSED backend=\(backend.rawValue) template=\(template) tokens=\(formatter.reusedPromptTokens)")
            }
        }
        defaults.set("standard", forKey: "dictationCleanupTemplate")
        formatter.beginDictation()
        XCTAssertEqual(formatter.reusedPromptTokens, 0)
        let busy = Task { await formatter.refine(String(repeating: "Review the sample measurements before Friday. ", count: 20),
                                                forceRefine: true, priorContext: "") }
        let waiting = Date()
        while formatter.state != .generating, Date().timeIntervalSince(waiting) < 3 { await Task.yield() }
        XCTAssertEqual(formatter.state, .generating)
        let result = await state.finishIncrementalRefinement(refinedBody: "The samples stay frozen.",
            unrefinedTail: "um send the report tomorrow", onStream: { _ in })
        XCTAssertTrue(result.completed, "Stopping during live inference must finish a new final pass")
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("tomorrow"), result.text)
        XCTAssertFalse(result.text.lowercased().contains("um "), result.text)
        _ = await busy.value
        XCTAssertEqual(formatter.state, .ready)
        formatter.beginDictation()
        for key in ["redactPII", "redactSSN", "redactCreditCard", "redactAPIKey", "redactPhone", "redactEmail", "redactURL", "redactIPAddress"] {
            defaults.set(true, forKey: key)
        }
        let backlog = """
        The sampling budget is 420 dollars and the review is on Tuesday. We need to keep the north field separate from the south field because the soil treatments differ. The north field received nitrogen while the south field received compost. Each sample has a printed label with its collection date, plot number, and depth. Keep those labels attached throughout preparation and storage. The first collection started at sunrise and finished before the irrigation system switched on. The second collection happened after lunch with the same equipment and the same depth settings. Record the weather conditions alongside the measurements so the team can compare the two collections later. The control samples stay in the freezer until the calibration check is complete. Use the green tray for controls and the blue tray for treated samples. Keep the spare labels in the cabinet next to the balance. The scale needs a calibration check before the next batch is weighed. The report should include the raw measurements, the calibration results, the sample inventory, and a short explanation of any missing values. Send a draft to the review team first so they can check the calculations. Do not distribute the final report until every discrepancy has been resolved. The last delivery goes to the west laboratory on Thursday.
        """
        XCTAssertGreaterThan(backlog.split(whereSeparator: \.isWhitespace).count, 160)
        let resultForBacklog = await state.finishIncrementalRefinement(refinedBody: "", unrefinedTail: backlog, onStream: { _ in })
        XCTAssertTrue(resultForBacklog.completed)
        let spelling = NumberFormatter()
        spelling.locale = Locale(identifier: "en_US")
        spelling.numberStyle = .spellOut
        let spelledAmount = try XCTUnwrap(spelling.string(from: 420))
        XCTAssertTrue(resultForBacklog.text.contains("420") || resultForBacklog.text.localizedCaseInsensitiveContains(spelledAmount),
                      "The numeric value must survive whether written as digits or words: \(resultForBacklog.text)")
        for fact in ["Tuesday", "north", "south", "nitrogen", "compost", "sunrise", "irrigation", "green", "blue", "calibration", "west", "Thursday"] {
            XCTAssertTrue(resultForBacklog.text.localizedCaseInsensitiveContains(fact), "Missing fact: \(fact). Output: \(resultForBacklog.text)")
        }
    }
}
