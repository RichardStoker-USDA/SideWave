// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Characterization tests for `StagedTranscript`, the data model that drives
/// the dictation preview overlay (gray EOU tail + confirmed/refined spans) and
/// the paste-on-stop assembly. This model is the single most regression-prone
/// surface in the app ("EOU text must ALWAYS stream when the user speaks"), and
/// it had no automated coverage. These tests pin the behavior so the
/// per-partial re-split and boundary logic can be optimized later without a
/// live-audio repro.
@MainActor
final class StagedTranscriptTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The live EOU tail is gated on this flag; tests want it on so the
        // tail/ingest paths are exercised.
        UserDefaults.standard.set(true, forKey: "showLiveGhostText")
    }

    // MARK: - Empty / reset

    func testFreshTranscriptIsEmpty() {
        let t = StagedTranscript()
        XCTAssertTrue(t.confirmedSpans.isEmpty)
        XCTAssertEqual(t.liveEouTail, "")
        XCTAssertEqual(t.finalText(), "")
        XCTAssertEqual(t.originalText(), "")
    }

    func testResetClearsEverything() {
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        t.ingestTdtCommitted("Hello world.")
        XCTAssertFalse(t.confirmedSpans.isEmpty)

        t.reset()
        XCTAssertTrue(t.confirmedSpans.isEmpty)
        XCTAssertEqual(t.liveEouTail, "")
        XCTAssertEqual(t.finalText(), "")
    }

    // MARK: - Live EOU tail

    func testResumedSpeechKeepsCoincidentalBoundaryWordAcrossPartials() {
        var clock: TimeInterval = 10
        let transcript = StagedTranscript(now: { clock })
        transcript.ingestEouPartial("we should review this")
        transcript.ingestTdtCommitted("We should review this.")
        clock += 2
        transcript.ingestEouPartial("we should review this this result")
        XCTAssertEqual(transcript.liveEouTail, "this result")
        clock += 0.1
        transcript.ingestEouPartial("we should review this this result is ready")
        XCTAssertEqual(transcript.liveEouTail, "this result is ready")
        XCTAssertTrue(transcript.finalText().lowercased().contains("this result is ready"))
    }

    func testWaitingToPasteDoesNotResurrectAnAlreadyStrippedEcho() {
        var clock: TimeInterval = 10
        let transcript = StagedTranscript(now: { clock })
        transcript.ingestEouPartial("we should review this")
        transcript.ingestTdtCommitted("We should review this.")
        clock += 0.1
        transcript.ingestEouPartial("we should review this this result")
        let beforePause = transcript.finalText()
        clock += 4
        XCTAssertEqual(transcript.finalText(), beforePause)
    }

    func testEouOnlyShowsAsLiveTail() {
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        // No TDT span yet, so the whole EOU accumulator is the live tail.
        XCTAssertEqual(t.liveEouTail, "hello world")
        // finalText with the raw EOU tail included reflects the same words.
        XCTAssertEqual(t.finalText(includeRawEouTail: true), "hello world")
    }

    func testDuplicateEouEmitIsNoOp() {
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        let before = t.liveEouTail
        // EOU re-emits the SAME accumulator during silence; must be a no-op.
        t.ingestEouPartial("hello world")
        XCTAssertEqual(t.liveEouTail, before)
    }

    func testEouTailGrowsForwardWithSpeech() {
        let t = StagedTranscript()
        t.ingestEouPartial("hello")
        t.ingestEouPartial("hello there")
        t.ingestEouPartial("hello there friend")
        // The gray tail moves strictly forward as new words arrive.
        XCTAssertEqual(t.liveEouTail, "hello there friend")
    }

    func testEouAccumulatorShrinkRecomputesTailCleanly() {
        // Parakeet can internally reset and re-emit a much shorter accumulator
        // (model reload / context-window pressure). The shrink-detection branch
        // in ingestEouPartial must recompute the tail to the new content, not
        // crash, dump stale text, or leave the cached split (eouAccumulatedWords)
        // out of sync. Regression net for the turn-27 split cache.
        let t = StagedTranscript()
        t.ingestEouPartial("one two three four five six")
        XCTAssertEqual(t.liveEouTail, "one two three four five six")
        // Significant shrink (6 -> 1 words): the live tail follows the new text.
        t.ingestEouPartial("alpha")
        XCTAssertEqual(t.liveEouTail, "alpha")
        // And it can grow forward again from the reset state.
        t.ingestEouPartial("alpha beta")
        XCTAssertEqual(t.liveEouTail, "alpha beta")
    }

    func testShowLiveGhostTextOffClearsTail() {
        UserDefaults.standard.set(false, forKey: "showLiveGhostText")
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        XCTAssertEqual(t.liveEouTail, "")
        // Restore for any later tests in the same process.
        UserDefaults.standard.set(true, forKey: "showLiveGhostText")
    }

    func testTailReflectsSpeechAfterCommit() {
        // Realistic flow that exercises both recomputeLiveTail paths: the
        // precomputed-words path (ingestEouPartial) and the re-split path
        // (ingestTdtCommitted). Words spoken AFTER a TDT commit must stream in
        // the live gray tail, while the committed span stays in the paste.
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        t.ingestTdtCommitted("Hello world.")
        t.ingestEouPartial("hello world brand new words")
        XCTAssertTrue(t.liveEouTail.contains("new"),
                      "post-commit speech should show in the tail; tail was '\(t.liveEouTail)'")
        XCTAssertTrue(t.finalText().contains("Hello world."),
                      "committed span should persist; finalText was '\(t.finalText())'")
    }

    // MARK: - Paste assembly matches the overlay (shared boundary strip)

    func testPasteTailMatchesOverlayTailCommonCase() {
        // After a normal commit, words spoken next stream in the gray overlay
        // tail (`liveEouTail`). The paste path (`finalText(includeRawEouTail:)`)
        // must end with exactly that same tail content -- the paste and the
        // overlay now share one boundary-strip helper, so what gets pasted is
        // what the user saw. Compared case-insensitively because finalText runs
        // sentence-boundary capitalization over the joined string.
        let t = StagedTranscript()
        t.ingestEouPartial("the quick brown fox")
        t.ingestTdtCommitted("The quick brown fox.")
        t.ingestEouPartial("the quick brown fox jumps over the lazy dog")
        let tail = t.liveEouTail
        XCTAssertFalse(tail.isEmpty, "expected a live tail of post-commit speech")
        let paste = t.finalText(includeRawEouTail: true)
        XCTAssertTrue(paste.lowercased().hasSuffix(tail.lowercased()),
                      "paste must end with the overlay tail; paste='\(paste)' tail='\(tail)'")
        // The committed span survives and isn't duplicated by the tail.
        XCTAssertTrue(paste.contains("The quick brown fox."),
                      "committed span should persist; paste='\(paste)'")
        XCTAssertEqual(paste.lowercased().components(separatedBy: "jumps").count - 1, 1,
                       "tail words must appear exactly once (no boundary duplication); paste='\(paste)'")
    }

    func testIncludeRawEouTailGatesTheTrailingTail() {
        // includeRawEouTail:false drops the uncovered EOU tail (committed spans
        // only); :true appends it. The stop path now always passes true so the
        // user's final spoken words can't be dropped -- pin both directions.
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        t.ingestTdtCommitted("Hello world.")
        t.ingestEouPartial("hello world and then some more")
        let withTail = t.finalText(includeRawEouTail: true)
        let withoutTail = t.finalText(includeRawEouTail: false)
        XCTAssertTrue(withTail.lowercased().contains("more"),
                      "tail words missing with includeRawEouTail:true; got '\(withTail)'")
        XCTAssertFalse(withoutTail.lowercased().contains("more"),
                       "tail must be excluded with includeRawEouTail:false; got '\(withoutTail)'")
        XCTAssertTrue(withoutTail.contains("Hello world."),
                      "committed span should remain; got '\(withoutTail)'")
    }

    // MARK: - TDT commit -> confirmed span

    func testTdtCommitCreatesConfirmedSpan() {
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        t.ingestTdtCommitted("Hello world.")

        XCTAssertEqual(t.confirmedSpans.count, 1)
        XCTAssertEqual(t.confirmedSpans.first?.stage, .tdt)
        XCTAssertEqual(t.confirmedSpans.first?.text, "Hello world.")
        // The committed, capitalized TDT text appears in the paste assembly.
        XCTAssertTrue(t.finalText().contains("Hello world."),
                      "finalText was '\(t.finalText())'")
    }

    func testRefineUpgradesSpanText() {
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        t.ingestTdtCommitted("hello world")
        guard let id = t.confirmedSpans.first?.id else {
            return XCTFail("expected a confirmed span")
        }
        t.refineSpan(spanID: id, refinedText: "Hello, world!")

        XCTAssertEqual(t.confirmedSpans.first?.stage, .refined)
        XCTAssertTrue(t.finalText().contains("Hello, world!"),
                      "finalText was '\(t.finalText())'")
    }

    func testFinalTextPrefersRefinedOriginalTextKeepsTdt() {
        let t = StagedTranscript()
        t.ingestEouPartial("hello world")
        t.ingestTdtCommitted("hello world")
        guard let id = t.confirmedSpans.first?.id else {
            return XCTFail("expected a confirmed span")
        }
        t.refineSpan(spanID: id, refinedText: "Hello, world!")

        // finalText() = refined; originalText() keeps the pre-refine TDT text.
        XCTAssertTrue(t.finalText().contains("Hello, world!"))
        XCTAssertTrue(t.originalText().contains("hello world"),
                      "originalText was '\(t.originalText())'")
        XCTAssertFalse(t.originalText().contains("Hello, world!"))
    }

    // MARK: - Sentence-boundary capitalization (pure)

    func testFixSentenceBoundaryCapitalization() {
        XCTAssertEqual(
            StagedTranscript.fixSentenceBoundaryCapitalization("hi. there"),
            "hi. There"
        )
        XCTAssertEqual(
            StagedTranscript.fixSentenceBoundaryCapitalization("wait? ok then"),
            "wait? Ok then"
        )
        // No space after the terminator: leave it (avoids "U.S.A." breakage).
        XCTAssertEqual(
            StagedTranscript.fixSentenceBoundaryCapitalization("no!yes"),
            "no!yes"
        )
        // Already capitalized: idempotent.
        XCTAssertEqual(
            StagedTranscript.fixSentenceBoundaryCapitalization("done. Next"),
            "done. Next"
        )
        // Empty input.
        XCTAssertEqual(StagedTranscript.fixSentenceBoundaryCapitalization(""), "")
    }

    // MARK: - Mid-session EOU accumulator restart (epoch model)

    // The EOU engine can restart its accumulator mid-session (FluidAudio
    // reset() after feeder errors, audio recovery, internal reset under long-
    // session pressure). Without epochs, after a restart session-lifetime
    // coverage exceeded the fresh accumulator's word count on every partial,
    // so the shrink branch re-zeroed both cursors ~6x/second and the entire
    // post-restart accumulator rendered as a permanent gray tail duplicating
    // already-refined content. These tests pin the epoch semantics that fix it.

    /// Runs a "phase A" session: three committed segments, EOU fully covered.
    private func buildCoveredSession(_ t: StagedTranscript) {
        t.ingestEouPartial("the quick brown fox")
        t.ingestTdtCommitted("The quick brown fox.")
        t.ingestEouPartial("the quick brown fox jumps over the lazy dog")
        t.ingestTdtCommitted("Jumps over the lazy dog.")
        t.ingestEouPartial("the quick brown fox jumps over the lazy dog and runs far away")
        t.ingestTdtCommitted("And runs far away.")
        XCTAssertEqual(t.confirmedSpans.count, 3)
    }

    func testMidSessionEouRestartDoesNotDumpCoveredTextIntoTail() {
        let t = StagedTranscript()
        buildCoveredSession(t)

        // Engine restart: fresh accumulator, head shares nothing with the
        // session's first span. 12 words so the 8-word boundary-strip cap
        // can't mask a cursor-zeroing dump in the assertions below.
        let fresh = "switching topics completely here comes a totally different set of new words"
        t.ingestEouPartial(fresh)
        XCTAssertEqual(t.liveEouTail, fresh,
                       "post-restart accumulator should render as genuinely-new tail")

        // TDT catches up and commits the fresh segment.
        t.ingestTdtCommitted("Switching topics completely here comes a totally different set of new words.")

        // The next partial extends the restarted accumulator. Under the old
        // code, session-lifetime coverage (> accumulator length) re-tripped
        // the shrink branch here, zeroed both cursors, and the tail dumped
        // ALL 15 words — 12 of them already committed above.
        t.ingestEouPartial(fresh + " plus three more")
        XCTAssertEqual(t.liveEouTail, "plus three more",
                       "tail must only hold words past the committed fresh segment, got '\(t.liveEouTail)'")

        // Paste assembly shares the cursor — no duplication there either.
        let final = t.finalText()
        let occurrences = final.components(separatedBy: "totally different set").count - 1
        XCTAssertEqual(occurrences, 1, "committed fresh segment must appear exactly once in paste, got: \(final)")
    }

    func testResetEouAlignmentStartsNewEpoch() {
        let t = StagedTranscript()
        buildCoveredSession(t)

        // Audio-recovery path: engine + alignment reset, spans preserved.
        t.resetEouAlignment()
        XCTAssertEqual(t.liveEouTail, "")

        // Fresh engine output after recovery — must not trip the shrink
        // branch against pre-recovery coverage.
        t.ingestEouPartial("hello again after recovery")
        XCTAssertEqual(t.liveEouTail, "hello again after recovery")

        t.ingestTdtCommitted("Hello again after recovery.")
        t.ingestEouPartial("hello again after recovery more words now")
        XCTAssertEqual(t.liveEouTail, "more words now",
                       "post-recovery epoch must consume covered words, got '\(t.liveEouTail)'")
    }

    func testCumulativeFilterShrinkKeepsCoverage() {
        let t = StagedTranscript()
        t.ingestEouPartial("alpha beta gamma delta epsilon zeta eta theta")
        t.ingestTdtCommitted("Alpha beta gamma delta epsilon zeta eta theta.")

        // Filter chain collapses the processed accumulator by >3 words but
        // the head still matches the session's first span: cumulative, not
        // a restart. Coverage must survive; nothing dumps into the tail.
        t.ingestEouPartial("alpha beta gamma delta")
        XCTAssertEqual(t.liveEouTail, "",
                       "cumulative shrink must not dump covered words, got '\(t.liveEouTail)'")
    }

    func testFalseEpochFromTransientEmptyPartialSelfHeals() {
        let t = StagedTranscript()
        buildCoveredSession(t)
        let session = "the quick brown fox jumps over the lazy dog and runs far away"

        // Transient empty partial rolls the epoch even though the engine
        // never actually reset.
        t.ingestEouPartial("")

        // Next partial re-carries the full session history plus new words.
        // The self-heal path must restore session coverage instead of
        // dumping the whole accumulator as gray.
        t.ingestEouPartial(session + " fresh words here")
        XCTAssertEqual(t.liveEouTail, "fresh words here",
                       "false epoch must self-heal, got '\(t.liveEouTail)'")
    }

    // MARK: - Standalone pronoun "i"

    func testFixStandalonePronounICapitalizesPronounAndContractions() {
        XCTAssertEqual(
            StagedTranscript.fixStandalonePronounI("i think i'm sure i'll go and i've said what i'd say"),
            "I think I'm sure I'll go and I've said what I'd say")
        XCTAssertEqual(
            StagedTranscript.fixStandalonePronounI("so i said yes. and then i left"),
            "so I said yes. and then I left")
        // Sentence-final "i." (no letter after the period) still capitalizes.
        XCTAssertEqual(StagedTranscript.fixStandalonePronounI("it was i."), "it was I.")
    }

    func testFixStandalonePronounIPreservesWordsAndAbbreviations() {
        XCTAssertEqual(
            StagedTranscript.fixStandalonePronounI("my iPhone uses Wi-Fi in this vicinity"),
            "my iPhone uses Wi-Fi in this vicinity")
        XCTAssertEqual(
            StagedTranscript.fixStandalonePronounI("use the flag, i.e. the short form"),
            "use the flag, i.e. the short form")
        // Idempotent: already-correct text passes through unchanged.
        XCTAssertEqual(
            StagedTranscript.fixStandalonePronounI("I know I'm right"),
            "I know I'm right")
    }
    func testHiddenPreviewDoesNotDuplicateCommittedText() {
        UserDefaults.standard.set(false, forKey: "showLiveGhostText")
        let transcript = StagedTranscript()
        transcript.ingestEouPartial("prepare the slides for monday")
        let span = transcript.ingestTdtCommitted("Prepare the slides for Monday.")
        transcript.refineSpan(spanID: span, refinedText: "Prepare Monday's slides.")
        XCTAssertEqual(transcript.liveEouTail, "")
        XCTAssertEqual(transcript.finalText(), "Prepare Monday's slides.")
        XCTAssertEqual(transcript.originalText(), "Prepare the slides for Monday.")
    }

    func testPreviewVisibilityDoesNotChangeCoverageOrLookahead() {
        func assemble(showPreview: Bool) -> String {
            UserDefaults.standard.set(showPreview, forKey: "showLiveGhostText")
            let transcript = StagedTranscript()
            transcript.ingestEouPartial("prepare the slides for monday then check")
            transcript.ingestTdtCommitted("Prepare the slides for Monday.")
            transcript.ingestEouPartial("prepare the slides for monday then check the figures before lunch")
            transcript.ingestTdtCommitted("Then check the figures.")
            return transcript.finalText()
        }
        let visible = assemble(showPreview: true)
        XCTAssertEqual(assemble(showPreview: false), visible)
        XCTAssertEqual(visible, "Prepare the slides for Monday. Then check the figures. Before lunch")
    }

    func testReenablingPreviewShowsOnlyUncommittedWords() {
        UserDefaults.standard.set(false, forKey: "showLiveGhostText")
        let transcript = StagedTranscript()
        transcript.ingestEouPartial("review the sample list")
        transcript.ingestTdtCommitted("Review the sample list.")
        UserDefaults.standard.set(true, forKey: "showLiveGhostText")
        transcript.ingestEouPartial("review the sample list before tomorrow")
        XCTAssertEqual(transcript.liveEouTail, "before tomorrow")
        XCTAssertEqual(transcript.finalText(), "Review the sample list. Before tomorrow")
    }

    func testRefinementOnlyRevealsNewOrChangedWords() throws {
        var time = 1.0
        let transcript = StagedTranscript(now: { time })
        let id = transcript.ingestTdtCommitted("Review the sample before Friday.")
        transcript.markRefinedNoChange(spanID: id)
        let initial = try XCTUnwrap(transcript.confirmedSpans.first)
        XCTAssertEqual(initial.refinementRevealStarts.count, 5)
        XCTAssertTrue(initial.refinementRevealStarts.allSatisfy { $0 != nil })
        time = 10
        transcript.refineSpan(spanID: id, refinedText: "Review the revised sample before Monday.")
        let updated = try XCTUnwrap(transcript.confirmedSpans.first)
        for (newIndex, oldIndex) in [(0,0), (1,1), (3,2), (4,3)] {
            XCTAssertEqual(updated.refinementRevealStarts[newIndex], initial.refinementRevealStarts[oldIndex])
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(updated.refinementRevealStarts[2]), 10)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(updated.refinementRevealStarts[5]), 10)
        time = 20
        transcript.markRefinedNoChange(spanID: id)
        XCTAssertEqual(transcript.confirmedSpans.first?.refinementRevealStarts, updated.refinementRevealStarts)
    }

    func testBoundaryMovePreservesSettledWordsAndRevealsContinuation() throws {
        var time = 1.0
        let transcript = StagedTranscript(now: { time })
        let first = transcript.ingestTdtCommitted("The sample is ready. Send the report")
        transcript.markRefinedNoChange(spanID: first)
        let original = try XCTUnwrap(transcript.confirmedSpans.first)
        let second = transcript.ingestTdtCommitted("Before Friday.")
        time = 10
        transcript.applyBoundaryMerge(prevSpanID: first, prevTextWithoutBoundary: "The sample is ready.",
            currSpanID: second, currRefinedText: "Send the report before Friday.")
        let spans = transcript.confirmedSpans
        XCTAssertEqual(spans[0].refinementRevealStarts, Array(original.refinementRevealStarts.prefix(4)))
        XCTAssertEqual(Array(spans[1].refinementRevealStarts.prefix(3)), Array(original.refinementRevealStarts.suffix(3)))
        XCTAssertTrue(spans[1].refinementRevealStarts.suffix(2).allSatisfy { ($0 ?? 0) >= 10 })
        XCTAssertEqual(transcript.finalText(), "The sample is ready. Send the report before Friday.")
    }

    func testRepeatedWordsDeletionAndPunctuationKeepTheirOwnRevealTimes() throws {
        var time = 1.0
        let transcript = StagedTranscript(now: { time })
        let id = transcript.ingestTdtCommitted("Check the label and the sample sample.")
        transcript.markRefinedNoChange(spanID: id)
        let original = try XCTUnwrap(transcript.confirmedSpans.first)
        time = 10
        transcript.refineSpan(spanID: id, refinedText: "Check the label, and the sample.")
        let updated = try XCTUnwrap(transcript.confirmedSpans.first)
        XCTAssertEqual(updated.refinementRevealStarts[1], original.refinementRevealStarts[1])
        XCTAssertEqual(updated.refinementRevealStarts[4], original.refinementRevealStarts[4])
        XCTAssertEqual(updated.refinementRevealStarts[5], original.refinementRevealStarts[6])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(updated.refinementRevealStarts[2]), 10)
        let layout = DictationOverlayContent.computeDisplayLayout(spans: [updated], streamingTdt: "", tail: "", isSpecialty: false)
        XCTAssertEqual(layout.words.map(\.refinedAt), updated.refinementRevealStarts)
    }

}
