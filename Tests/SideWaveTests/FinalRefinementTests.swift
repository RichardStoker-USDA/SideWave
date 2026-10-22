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
        XCTAssertEqual(transcript.finalPassRuns(includeRawEouTail: false), [
            .init(text: "The first sample is frozen.", pending: false),
            .init(text: "The the second sample needs review.", pending: true),
            .init(text: "The last sample is ready.", pending: false),
        ])
    }

    func testDeclinedSpanMidSessionKeepsLaterRefinedText() async throws {
        let transcript = StagedTranscript()
        let first = try XCTUnwrap(transcript.ingestTdtCommitted("The samples are frozen."))
        _ = transcript.ingestTdtCommitted("um we sent the the report to")
        let third = try XCTUnwrap(transcript.ingestTdtCommitted("Sarah on Friday. The labels are done."))
        let fourth = try XCTUnwrap(transcript.ingestTdtCommitted("The freezer is at minus eighty."))
        for id in [first, third, fourth] { transcript.markRefinedNoChange(spanID: id) }
        let runs = transcript.finalPassRuns(includeRawEouTail: false)
        XCTAssertEqual(runs, [
            .init(text: "The samples are frozen.", pending: false),
            .init(text: "um we sent the the report to Sarah on Friday.", pending: true),
            .init(text: "The labels are done. The freezer is at minus eighty.", pending: false),
        ], "Only the declined span and the rest of its sentence go back to the model")

        let state = AppState()
        state.dictationFormatter.disable()
        let settled = await state.finishPendingRuns([runs[0], runs[2]], after: "Earlier text.", onStream: { _ in })
        XCTAssertTrue(settled.completed)
        XCTAssertEqual(settled.text, "Earlier text. The samples are frozen. The labels are done. The freezer is at minus eighty.")
        let failed = await state.finishPendingRuns(runs, after: "Earlier text.", onStream: { _ in })
        XCTAssertFalse(failed.completed)
        XCTAssertEqual(failed.text, "Earlier text. " + runs.map(\.text).joined(separator: " "),
                       "A failed stop pass keeps the whole session, not the part before the failure")
    }

    func testBorrowedSentenceKeepsTheParagraphBreakAfterIt() async throws {
        let transcript = StagedTranscript()
        _ = transcript.ingestTdtCommitted("we sent the report to")
        let refined = try XCTUnwrap(transcript.ingestTdtCommitted("Sarah on Friday.\n\nThe labels are done."))
        transcript.markRefinedNoChange(spanID: refined)
        let runs = transcript.finalPassRuns(includeRawEouTail: false)
        XCTAssertEqual(runs.map(\.pending), [true, false])
        XCTAssertEqual(runs[0].text, "we sent the report to Sarah on Friday.")
        let state = AppState()
        state.dictationFormatter.disable()
        let failed = await state.finishPendingRuns(runs, after: "", onStream: { _ in })
        XCTAssertEqual(failed.text, "we sent the report to Sarah on Friday.\n\nThe labels are done.")
        let settled = await state.finishPendingRuns([.init(text: "The samples are frozen.", pending: false), runs[1]],
                                                    after: "", onStream: { _ in })
        XCTAssertEqual(settled.text, "The samples are frozen.\n\nThe labels are done.")
    }

    func testDeclinedPartIsSentAsCapturedAndNotSentAgain() async {
        let state = AppState()
        var declinedRequests = 0
        state.finalPassRefine = { chunk, _ in
            if chunk.contains("lockout") {
                declinedRequests += 1
                return .original(chunk, failure: .declined)
            }
            return .refined(chunk.replacingOccurrences(of: "um ", with: ""))
        }
        let runs: [StagedTranscript.FinalPassRun] = [
            .init(text: "um the samples are frozen. Check the account lockout logs.", pending: true),
            .init(text: "The report is ready.", pending: false),
            .init(text: "um send it Friday.", pending: true),
        ]
        let outcome = await state.finishPendingRuns(runs, after: "", budget: .seconds(10), onStream: { _ in })
        XCTAssertEqual(declinedRequests, 1, "A declined part stays out of later requests")
        XCTAssertTrue(outcome.declined)
        XCTAssertFalse(outcome.completed)
        XCTAssertEqual(outcome.text, "um the samples are frozen. Check the account lockout logs. The report is ready. send it Friday.",
                       "The declined part is kept as captured and the rest is still refined")
        XCTAssertEqual(outcome.runs, [
            .init(text: "um the samples are frozen. Check the account lockout logs.", pending: true),
            .init(text: "The report is ready. send it Friday.", pending: false),
        ], "A captured part stays unfinished, so Resume or a held translation tries it again")
        XCTAssertTrue(AppState.sameWords(StagedTranscript.FinalPassRun.joinedText(outcome.runs), outcome.text))
        XCTAssertEqual(AppState.finalPassNotice(outcome),
                       "Apple Intelligence declined part of this dictation. That part was sent as captured.")
    }

    func testFinalPassSendsUnfinishedTextWhenItsBudgetRunsOut() async {
        let state = AppState()
        state.finalPassRefine = { chunk, _ in
            try? await Task.sleep(for: .seconds(5))
            return .refined(chunk)
        }
        let runs: [StagedTranscript.FinalPassRun] = [
            .init(text: "um first part", pending: true),
            .init(text: "Middle part.", pending: false),
            .init(text: "um last part", pending: true),
        ]
        let started = ContinuousClock.now
        let outcome = await state.finishPendingRuns(runs, after: "Earlier.", budget: .milliseconds(200), onStream: { _ in })
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.text, "Earlier. um first part Middle part. um last part")
        XCTAssertEqual(outcome.runs.filter(\.pending).map(\.text), ["um first part", "um last part"])
        XCTAssertNotNil(AppState.finalPassNotice(outcome))
    }

    func testStoppedPassKeepsFinishedPartsSoResumeRefinesOnlyTheRest() async {
        let state = AppState()
        var requests = 0
        state.finalPassRefine = { [weak state] chunk, _ in
            requests += 1
            if requests == 1 { return .refined("The samples are frozen.") }
            state?.cancelRequestedDuringStop = true
            return .original(chunk, failure: .cancelled)
        }
        let runs: [StagedTranscript.FinalPassRun] = [
            .init(text: "um the samples are frozen", pending: true),
            .init(text: "The report is ready.", pending: false),
            .init(text: "um send it Friday", pending: true),
        ]
        let outcome = await state.finishPendingRuns(runs, after: "", budget: .seconds(10), onStream: { _ in })
        XCTAssertTrue(outcome.cancelled)
        XCTAssertNil(AppState.finalPassNotice(outcome))
        state.preserveRawOnCleanupCancel = true
        state.bailFromCleanupCancel(rawText: "raw text",
                                    parked: AppState.ParkedFinalPass(runs: outcome.runs, outputLanguage: .matchInput))
        let paused = try? XCTUnwrap(state.pendingSessionText)
        XCTAssertEqual(paused, "The samples are frozen. The report is ready. um send it Friday")
        XCTAssertEqual(state.pendingSessionPass?.runs.filter(\.pending).map(\.text), ["um send it Friday"])

        let resumed = AppState.finalPassInput(
            stagedRuns: [.init(text: "New words.", pending: false)],
            continuedText: paused ?? "",
            parked: state.pendingSessionPass,
            outputLanguage: .matchInput,
            resumedNeedsRefinement: true,
            newText: "New words.",
            assembledText: (paused ?? "") + " New words.")
        XCTAssertEqual(resumed.runs, [
            .init(text: "The samples are frozen. The report is ready.", pending: false),
            .init(text: "um send it Friday New words.", pending: true),
        ], "Resume refines only what the stopped pass left unfinished, plus the first new sentence")
        let junction = AppState.finalPassInput(
            stagedRuns: [.init(text: "Lunch on Friday. The labels are done.", pending: false)],
            continuedText: "Send it before.",
            parked: .init(runs: [.init(text: "Send it before.", pending: false)], outputLanguage: .matchInput),
            outputLanguage: .matchInput, resumedNeedsRefinement: true,
            newText: "Lunch on Friday. The labels are done.", assembledText: "")
        XCTAssertEqual(junction.runs, [
            .init(text: "Send it before.", pending: false),
            .init(text: "Lunch on Friday.", pending: true),
            .init(text: "The labels are done.", pending: false),
        ], "A sentence split by the pause gets a request that sees both sides")
        XCTAssertEqual(resumed.prefix, "")
    }

    func testFinalPassInputFallsBackWhenPausedRunsDoNotMatch() {
        let stale = AppState.finalPassInput(
            stagedRuns: [.init(text: "New words.", pending: false)],
            continuedText: "Edited paused text.",
            parked: .init(runs: [.init(text: "Different text.", pending: false)], outputLanguage: .matchInput),
            outputLanguage: .matchInput,
            resumedNeedsRefinement: true,
            newText: "New words.",
            assembledText: "Edited paused text. New words.")
        XCTAssertEqual(stale.runs, [.init(text: "Edited paused text. New words.", pending: true)])
        let otherLanguage = AppState.finalPassInput(
            stagedRuns: [],
            continuedText: "The report is ready.",
            parked: .init(runs: [.init(text: "The report is ready.", pending: false)], outputLanguage: .matchInput),
            outputLanguage: .spanish,
            resumedNeedsRefinement: true,
            newText: "",
            assembledText: "The report is ready.")
        XCTAssertEqual(otherLanguage.runs, [.init(text: "The report is ready.", pending: true)],
                       "Text finished for one output language is unfinished for another")
        let normal = AppState.finalPassInput(
            stagedRuns: [.init(text: "um tail", pending: true)],
            continuedText: "",
            parked: nil,
            outputLanguage: .matchInput,
            resumedNeedsRefinement: false,
            newText: "um tail",
            assembledText: "um tail")
        XCTAssertEqual(normal.runs, [.init(text: "um tail", pending: true)])
    }

    func testParagraphBreakSurvivesNextToADeclinedPart() async {
        let state = AppState()
        state.finalPassRefine = { chunk, _ in
            chunk.contains("lockout") ? .original(chunk, failure: .declined)
                : .refined(chunk.replacingOccurrences(of: "um ", with: ""))
        }
        let runs: [StagedTranscript.FinalPassRun] = [
            .init(text: "Check the lockout logs.", pending: true),
            .init(text: "\n\num send it Friday.", pending: true),
        ]
        let outcome = await state.finishPendingRuns(runs, after: "", budget: .seconds(10), onStream: { _ in })
        XCTAssertEqual(outcome.text, "Check the lockout logs.\n\nsend it Friday.")
        XCTAssertEqual(StagedTranscript.FinalPassRun.joinedText(outcome.runs), outcome.text)
        let window = RefinementWindow(refinedBody: "Keep this.", unrefinedTail: "\n\nNext paragraph.", lockedCount: 10)
        XCTAssertEqual(RefinementWindow.join(window.prefix, window.editable), "Keep this.\n\nNext paragraph.")
    }

    func testHeldTranslationKeepsTranslatedPartsForResume() {
        let state = AppState()
        let parked = AppState.ParkedFinalPass(runs: [
            .init(text: "Las muestras están congeladas.", pending: false),
            .init(text: "send the report Friday", pending: true),
        ], outputLanguage: .spanish)
        state.preserveUnfinishedRefinement("raw text", parked: parked)
        XCTAssertEqual(state.pendingSessionText, "Las muestras están congeladas. send the report Friday")
        let resumed = AppState.finalPassInput(stagedRuns: [], continuedText: state.pendingSessionText ?? "",
            parked: state.pendingSessionPass, outputLanguage: .spanish, resumedNeedsRefinement: true,
            newText: "", assembledText: state.pendingSessionText ?? "")
        XCTAssertEqual(resumed.runs, parked.runs, "Resume translates only the part still in English")
    }

    func testPauseKeepsFinishedPartsEvenWithoutNewSpeech() {
        let earlier = AppState.ParkedFinalPass(runs: [
            .init(text: "The samples are frozen.", pending: false),
            .init(text: "um send it Friday", pending: true),
        ], outputLanguage: .matchInput)
        let quiet = AppState.pausedPass(earlier: earlier, accumulatedText: earlier.text, stagedRuns: [],
                                        newText: "", outputLanguage: .matchInput)
        XCTAssertEqual(quiet, earlier)
        let more = AppState.pausedPass(earlier: earlier, accumulatedText: earlier.text,
                                       stagedRuns: [.init(text: "The labels are done.", pending: false)],
                                       newText: "The labels are done.", outputLanguage: .matchInput)
        XCTAssertEqual(more?.runs.map(\.pending), [false, true, false])
        let unknown = AppState.pausedPass(earlier: nil, accumulatedText: "Earlier words.",
                                          stagedRuns: [.init(text: "New words.", pending: false)],
                                          newText: "New words.", outputLanguage: .matchInput)
        XCTAssertEqual(unknown?.runs, [.init(text: "Earlier words.", pending: true), .init(text: "New words.", pending: false)])
        XCTAssertNil(AppState.pausedPass(earlier: nil, accumulatedText: "Earlier words.", stagedRuns: [],
                                         newText: "", outputLanguage: .matchInput))
    }

    func testFinalPassBudgetScalesWithPendingWords() {
        XCTAssertEqual(AppState.finalPassBudget(pendingWords: 0), .seconds(10))
        XCTAssertEqual(AppState.finalPassBudget(pendingWords: 160), .milliseconds(15_600))
        XCTAssertEqual(AppState.finalPassBudget(pendingWords: 5_000), .seconds(25))
    }

    func testLockedTextStaysOutOfTheEditableWindow() {
        let body = "Check the lockout logs. The report is ready."
        let locked = "Check the lockout logs.".count
        let window = RefinementWindow(refinedBody: body, unrefinedTail: "Send it.", lockedCount: locked)
        XCTAssertEqual(window.editable, "The report is ready. Send it.")
        XCTAssertEqual(RefinementWindow.join(window.prefix, window.editable), body + " Send it.")
        let paragraph = RefinementWindow(refinedBody: "Check the lockout logs.\n\nThe report is ready.",
                                         unrefinedTail: "", lockedCount: locked)
        XCTAssertEqual(RefinementWindow.join(paragraph.prefix, "The report is ready."),
                       "Check the lockout logs.\n\nThe report is ready.")
        let all = RefinementWindow(refinedBody: body, unrefinedTail: "Send it.", lockedCount: body.count)
        XCTAssertEqual(all.prefix, body)
        XCTAssertEqual(all.editable, "Send it.")
    }

    func testPlainTextRetryTreatsAWrittenRefusalAsDeclined() {
        XCTAssertTrue(DictationFormatterService.looksLikeModelRefusal("I’m sorry, but I can’t help with that.", input: "check the lockout logs"))
        XCTAssertFalse(DictationFormatterService.looksLikeModelRefusal("I'm sorry I missed the meeting.", input: "i'm sorry i missed the meeting"))
        XCTAssertFalse(DictationFormatterService.looksLikeModelRefusal("Check the lockout logs.", input: "check the lockout logs"))
        let input = "check the account lockout logs and summarize today's failed attempts"
        let refusal = DictationFormatterService.looksLikeModelRefusal
        XCTAssertTrue(refusal("I cannot provide assistance with that request.", input))
        XCTAssertTrue(refusal("I cannot summarize today's failed attempts.", input), "A refusal can repeat the request")
        XCTAssertTrue(refusal("This request involves sensitive security topics.", input),
                      "An answer made almost entirely of other words is not a cleanup")
        XCTAssertFalse(refusal("Please review the account lockout logs and summarize today's failed sign-in attempts.", input))
        XCTAssertFalse(refusal("They have gone.", "um they they has went"), "Grammar fixes change most short words")
        XCTAssertFalse(refusal("RNA, DNA, and PCR.", "r n a d n a and p c r"))
        XCTAssertFalse(refusal("Sorry, but I cannot attend the meeting.", "sorry but i can't attend the meeting"))
        XCTAssertFalse(refusal("I'm sorry I missed the call.", "i am sorry i missed the call"))
    }

    func testLeadingSentenceSplitIsBounded() {
        XCTAssertTrue(RefinementWindow.splitLeadingSentence("Sarah on Friday. The labels are done.")
            == ("Sarah on Friday.", "The labels are done."))
        let unpunctuated = (0..<100).map { "word\($0)" }.joined(separator: " ")
        let split = RefinementWindow.splitLeadingSentence(unpunctuated)
        XCTAssertEqual(split.head.split(separator: " ").count, 64)
        XCTAssertEqual(RefinementWindow.join(split.head, split.rest), unpunctuated)
        XCTAssertTrue(RefinementWindow.endsSentence("Done. "))
        XCTAssertFalse(RefinementWindow.endsSentence("sent the report to"))
    }

    func testBoundaryContextDoesNotFalselyCountAsRefined() throws {
        let transcript = StagedTranscript()
        let first = try XCTUnwrap(transcript.ingestTdtCommitted("The the samples are ready. Send them"))
        let second = try XCTUnwrap(transcript.ingestTdtCommitted("Before lunch."))
        transcript.applyBoundaryMerge(prevSpanID: first, prevTextWithoutBoundary: "The the samples are ready.",
                                      currSpanID: second, currRefinedText: "Send them before lunch.")
        XCTAssertEqual(transcript.finalPassRuns(includeRawEouTail: false), [
            .init(text: "The the samples are ready.", pending: true),
            .init(text: "Send them before lunch.", pending: false),
        ])
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
