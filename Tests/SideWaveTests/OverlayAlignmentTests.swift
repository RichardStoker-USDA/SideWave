// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Regression tests for `DictationOverlayContent.alignWords`, the EOU/TDT
/// word aligner behind the animated in-progress zone. Either array can be empty: at session
/// start the draft has words before the first TDT poll returns, and a TDT commit clears the
/// streaming slot.
@MainActor
final class OverlayAlignmentTests: XCTestCase {

    func testBothEmptyReturnsEmpty() {
        XCTAssertTrue(DictationOverlayContent.alignWords(eou: [], tdt: []).isEmpty)
    }

    func testEmptyTdtDoesNotTrap() {
        let pairs = DictationOverlayContent.alignWords(eou: ["hello", "world"], tdt: [])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.map(\.eou), ["hello", "world"])
        XCTAssertEqual(pairs.compactMap(\.tdt), [])
    }

    func testEmptyEouDoesNotTrap() {
        let pairs = DictationOverlayContent.alignWords(eou: [], tdt: ["Hello,", "world."])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.compactMap(\.eou), [])
        XCTAssertEqual(pairs.map(\.tdt), ["Hello,", "world."])
    }

    func testMatchedAlignmentPairsPositionally() {
        let pairs = DictationOverlayContent.alignWords(
            eou: ["hello", "world"],
            tdt: ["Hello,", "world."]
        )
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].eou, "hello")
        XCTAssertEqual(pairs[0].tdt, "Hello,")
        XCTAssertEqual(pairs[1].eou, "world")
        XCTAssertEqual(pairs[1].tdt, "world.")
    }

    func testInsertionAndDeletionAlign() {
        // EOU heard a stutter TDT dropped: extra EOU word pairs with nil TDT.
        let pairs = DictationOverlayContent.alignWords(
            eou: ["the", "the", "cat"],
            tdt: ["The", "cat"]
        )
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs.filter { $0.tdt == nil }.count, 1)
    }

    // MARK: - inProgressTrim (gray-tail preservation)
    //
    // The in-progress zone must track the live EOU tail, not stale
    // streaming TDT. A TDT-only pair past the last EOU-backed word is a
    // leftover poll from before the tail shrank; leaving it in whitened
    // phantom words and hid the gray tail.

    private func pair(_ eou: String?, _ tdt: String?) -> DictationOverlayContent.AlignedPair {
        DictationOverlayContent.AlignedPair(eou: eou, tdt: tdt)
    }

    func testTrailingTdtOnlyRunIsTrimmed() {
        // a,b covered; c is live gray EOU; D,E are stale trailing TDT.
        let pairs = [
            pair("a", "A"), pair("b", "B"), pair("c", nil),
            pair(nil, "D"), pair(nil, "E")
        ]
        let trim = DictationOverlayContent.inProgressTrim(alignedPairs: pairs)
        XCTAssertEqual(trim.pairCount, 3, "stale trailing TDT-only pairs dropped")
        XCTAssertEqual(trim.whiteEligibleTail, 2, "c stays gray; D,E don't whiten it")
    }

    func testInteriorTdtOnlyPairIsKept() {
        // Interior TDT-only (TDT split a word / caught one EOU missed)
        // must survive; only the trailing run is stale.
        let pairs = [pair("a", "A"), pair(nil, "X"), pair("b", "B")]
        let trim = DictationOverlayContent.inProgressTrim(alignedPairs: pairs)
        XCTAssertEqual(trim.pairCount, 3)
        XCTAssertEqual(trim.whiteEligibleTail, 3)
    }

    func testEmptyEouTailYieldsEmptyInProgressZone() {
        // Between commit and next EOU partial: streaming still set, tail
        // empty. Correct result is an empty zone (the "flash is fine" case).
        let pairs = [pair(nil, "A"), pair(nil, "B")]
        let trim = DictationOverlayContent.inProgressTrim(alignedPairs: pairs)
        XCTAssertEqual(trim.pairCount, 0)
        XCTAssertEqual(trim.whiteEligibleTail, 0)
    }

    func testStreamingEmptyKeepsWholeTailGray() {
        // Streaming TDT empty (just after commit, before next poll): every
        // EOU word is gray, none white-eligible.
        let pairs = [pair("a", nil), pair("b", nil)]
        let trim = DictationOverlayContent.inProgressTrim(alignedPairs: pairs)
        XCTAssertEqual(trim.pairCount, 2)
        XCTAssertEqual(trim.whiteEligibleTail, 0)
    }

    func testStaleStreamingLongerThanTailViaAligner() {
        // End-to-end: EOU tail is 2 words, stale streaming carries 4.
        // The 2 extra TDT words must be trimmed, leaving both EOU words
        // white-eligible and no phantom trailing whites.
        let pairs = DictationOverlayContent.alignWords(
            eou: ["the", "cat"],
            tdt: ["the", "cat", "sat", "on"]
        )
        let trim = DictationOverlayContent.inProgressTrim(alignedPairs: pairs)
        XCTAssertEqual(trim.pairCount, 2)
        XCTAssertEqual(trim.whiteEligibleTail, 2)
    }

    // MARK: - TdtTrailAnimator pointer math

    private let wordDur = TdtTrailAnimator().wordDuration

    func testPointerAdvancesOneWordPerWordDuration() {
        let next = TdtTrailAnimator.nextPointer(
            current: 2.0, target: 10, floor: 0,
            dt: wordDur, wordDuration: wordDur, isFirstTick: false
        )
        XCTAssertEqual(next, 3.0, accuracy: 1e-9)
    }

    func testCommitFloorLeapDoesNotTeleportPointer() {
        // A commit moves `floor` up by a whole segment; the pointer keeps its chase pace instead
        // of jumping to it.
        let next = TdtTrailAnimator.nextPointer(
            current: 4.0, target: 12, floor: 12,
            dt: 1.0 / 30.0, wordDuration: wordDur, isFirstTick: false
        )
        XCTAssertGreaterThan(next, 4.0, "still advancing")
        XCTAssertLessThan(next, 4.2, "did NOT teleport to the floor at 12")
    }

    func testPointerHoldsWhenTargetRetracts() {
        // Streaming retracted (target below pointer): hold, never rewind a
        // word that already went white.
        let next = TdtTrailAnimator.nextPointer(
            current: 8.0, target: 6, floor: 6,
            dt: 1.0 / 30.0, wordDuration: wordDur, isFirstTick: false
        )
        XCTAssertEqual(next, 8.0, accuracy: 1e-9)
    }

    func testPointerCapsAtTarget() {
        let next = TdtTrailAnimator.nextPointer(
            current: 9.9, target: 10, floor: 0,
            dt: wordDur, wordDuration: wordDur, isFirstTick: false
        )
        XCTAssertEqual(next, 10.0, accuracy: 1e-9)
    }

    func testFirstTickAnchorsAtConfirmedFloor() {
        // View created mid-session: confirmed words render white at once
        // rather than sweeping the whole history gray→white.
        let next = TdtTrailAnimator.nextPointer(
            current: 0.0, target: 25, floor: 20,
            dt: 0, wordDuration: wordDur, isFirstTick: true
        )
        XCTAssertEqual(next, 20.0, accuracy: 1e-9)
    }

    func testPointerVelocityIsFrameRateIndependent() {
        // One 0.3s step must land where two 0.15s steps do.
        let single = TdtTrailAnimator.nextPointer(
            current: 0, target: 100, floor: 0,
            dt: 0.30, wordDuration: wordDur, isFirstTick: false
        )
        let half = TdtTrailAnimator.nextPointer(
            current: 0, target: 100, floor: 0,
            dt: 0.15, wordDuration: wordDur, isFirstTick: false
        )
        let doubled = TdtTrailAnimator.nextPointer(
            current: half, target: 100, floor: 0,
            dt: 0.15, wordDuration: wordDur, isFirstTick: false
        )
        XCTAssertEqual(single, doubled, accuracy: 1e-9)
    }

    func testAdvanceLifecycleAnchorCommitReset() {
        let anim = TdtTrailAnimator()
        let t0 = 1_000.0
        // First tick mid-session: anchor at the confirmed floor (2).
        let p0 = anim.advance(targetWords: 5, floorWords: 2, at: t0)
        XCTAssertEqual(p0, 2.0, accuracy: 1e-9)
        // Normal advance.
        let p1 = anim.advance(targetWords: 5, floorWords: 2, at: t0 + 1.0 / 30.0)
        XCTAssertGreaterThan(p1, 2.0)
        XCTAssertLessThan(p1, 2.2)
        // Commit: floor leaps to 5. Pointer must keep pace, not teleport.
        let p2 = anim.advance(targetWords: 5, floorWords: 5, at: t0 + 2.0 / 30.0)
        XCTAssertGreaterThan(p2, p1)
        XCTAssertLessThan(p2, 2.5, "no teleport to the just-committed floor")
        // Session reset.
        let p3 = anim.advance(targetWords: 0, floorWords: 0, at: t0 + 3.0 / 30.0)
        XCTAssertEqual(p3, 0.0, accuracy: 1e-9)
    }

    // MARK: - InProgressTextLock (leading-edge stability)
    //
    // Once the pointer sweeps an in-progress word white, its text must not
    // change or shuffle as EOU and TDT keep revising behind the pointer.

    private func dword(_ text: String, tdt: String? = nil, space: Bool = false, refined: Bool = false, idx: Int = 0) -> DictationOverlayContent.DisplayWord {
        DictationOverlayContent.DisplayWord(text: text, tdtText: tdt, isRefined: refined, trailingSpace: space, refinedAt: nil, wordIndexInSpan: idx)
    }

    func testEngagedWordFreezesAgainstTdtRescore() {
        let lock = InProgressTextLock()
        let fade = 1.6
        // Pointer has swept word 0 fully white showing raw EOU "the".
        _ = lock.apply(words: [dword("the")], confirmedTdtCount: 0, pointer: 2.0, fadeWindow: fade)
        // Streaming TDT now rescores word 0 to "The"; but it's already white.
        let out = lock.apply(words: [dword("the", tdt: "The")], confirmedTdtCount: 0, pointer: 2.1, fadeWindow: fade)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(DictationOverlayContent.displayText(out[0], progress: 1.0), "the",
                       "an engaged word must not mutate when TDT rescores it")
    }

    func testGrayWordAheadRevisesFreely() {
        let lock = InProgressTextLock()
        let fade = 1.6
        // Pointer at 0.5 engages only word 0; word 1 is gray, ahead of it.
        _ = lock.apply(words: [dword("we", space: true), dword("meet", idx: 1)], confirmedTdtCount: 0, pointer: 0.5, fadeWindow: fade)
        // Word 1 (gray) revises before the pointer reaches it.
        let out = lock.apply(words: [dword("we", space: true), dword("meat", idx: 1)], confirmedTdtCount: 0, pointer: 0.5, fadeWindow: fade)
        XCTAssertEqual(out[1].text, "meat", "gray words ahead of the pointer still revise")
    }

    func testDroppedEngagedWordRematerializes() {
        let lock = InProgressTextLock()
        let fade = 1.6
        _ = lock.apply(words: [dword("again")], confirmedTdtCount: 0, pointer: 2.0, fadeWindow: fade)
        // EOU retracts the word while the pointer still covers it: it must
        // not vanish (GRAY_VANISH / ZONE_SHUFFLE guard).
        let out = lock.apply(words: [], confirmedTdtCount: 0, pointer: 2.0, fadeWindow: fade)
        XCTAssertEqual(out.count, 1, "a white word must not vanish")
        XCTAssertEqual(out[0].text, "again")
    }

    func testCommitClearsFreeze() {
        let lock = InProgressTextLock()
        let fade = 1.6
        // In-progress word frozen as a bad EOU guess "teh".
        _ = lock.apply(words: [dword("teh")], confirmedTdtCount: 0, pointer: 2.0, fadeWindow: fade)
        // Commit: word 0 is now a confirmed span (authoritative "The"). The
        // freeze must clear so the committed text wins.
        let out = lock.apply(words: [dword("The")], confirmedTdtCount: 1, pointer: 2.0, fadeWindow: fade)
        XCTAssertEqual(out[0].text, "The", "a commit clears the in-progress freeze")
    }

    func testSessionResetDropsGhosts() {
        let lock = InProgressTextLock()
        let fade = 1.6
        // First session sweeps a word white and freezes it.
        _ = lock.apply(words: [dword("quarterly")], confirmedTdtCount: 0, pointer: 2.0, fadeWindow: fade)
        // Reset: empty display + pointer rewound to 0.
        _ = lock.apply(words: [], confirmedTdtCount: 0, pointer: 0.0, fadeWindow: fade)
        // New session's first word must not inherit the old freeze as a ghost.
        let out = lock.apply(words: [dword("let", space: true), dword("us", idx: 1)], confirmedTdtCount: 0, pointer: 0.5, fadeWindow: fade)
        XCTAssertEqual(out.map(\.text), ["let", "us"], "no ghost words leak across a session reset")
    }
}
