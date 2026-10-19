// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Pins the string-similarity guard: the word-level check that keeps a CTC
/// acoustic-rescue replacement only when the replaced span resembles the
/// vocabulary term.
final class CtcVocabBoosterTests: XCTestCase {

    private let floor: Float = 0.75

    // MARK: stringSimilarity

    func testIdenticalStringsScoreOne() {
        XCTAssertEqual(CtcVocabBooster.stringSimilarity("claude", "claude"), 1.0)
    }

    func testEmptyStringScoresZero() {
        XCTAssertEqual(CtcVocabBooster.stringSimilarity("", "claude"), 0.0)
        XCTAssertEqual(CtcVocabBooster.stringSimilarity("claude", ""), 0.0)
    }

    func testPrefixOverlapClassStaysBelowFloor() {
        // Shared prefix, different word: must not be replaced.
        XCTAssertLessThan(CtcVocabBooster.stringSimilarity("anthropology", "anthropic"), floor)
    }

    func testUnrelatedWordsScoreLow() {
        XCTAssertLessThan(CtcVocabBooster.stringSimilarity("team", "rust"), 0.3)
    }

    // MARK: spanMatchesTerm; sim bait cases (must all be rejected)

    func testBaitSpansRejected() {
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "called the team this", term: "Claude", floor: floor))
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "the team", term: "Rust", floor: floor))
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "cleaned up the issue.", term: "Claude", floor: floor))
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "I studied anthropology in", term: "Anthropic", floor: floor))
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "the pipeline from Kafka", term: "Anthropic", floor: floor))
    }

    // MARK: spanMatchesTerm; sim positive-control cases (must all pass)

    func testLegitSpansAccepted() {
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(span: "talking with Claude", term: "Claude", floor: floor))
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(span: "system written in Rust.", term: "Rust", floor: floor))
    }

    func testPunctuationAndCaseNormalized() {
        // Trailing punctuation and case differences must not block a real match.
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(span: "KAFKA,", term: "Kafka", floor: floor))
    }

    func testEmptyTermNeverMatches() {
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "anything at all", term: "", floor: floor))
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "anything at all", term: "...", floor: floor))
    }

    // MARK: spanMatchesTerm; multi-word terms (the per-word check alone can't
    // reach the floor against these, so the whole-span window path must)

    func testMultiWordTermMatchesInsideSpan() {
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(
            span: "talking about GitHub Actions", term: "GitHub Actions", floor: floor))
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(
            span: "on the Mac Studio now", term: "Mac Studio", floor: floor))
    }

    func testMultiWordTermRejectsUnrelatedSpan() {
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(
            span: "the build finally passed", term: "GitHub Actions", floor: floor))
    }

    // MARK: applyAcceptedReplacements; whole-word, first-occurrence, positional

    func testReplacementDoesNotCorruptSubstring() {
        // A substring replace of "rust" would rewrite the "rust" inside
        // "trust". Whole-word matching must not.
        let out = CtcVocabBooster.applyAcceptedReplacements(
            to: "I do not trust rust here",
            replacements: [(originalWord: "rust", replacementWord: "Rust")]
        )
        XCTAssertEqual(out.text, "I do not trust Rust here")
        XCTAssertEqual(out.count, 1)
    }

    func testReplacementIsFirstOccurrenceOnly() {
        // One accepted result replaces exactly one site (not every occurrence).
        let single = CtcVocabBooster.applyAcceptedReplacements(
            to: "rust and rust again",
            replacements: [(originalWord: "rust", replacementWord: "Rust")]
        )
        XCTAssertEqual(single.text, "Rust and rust again")
        XCTAssertEqual(single.count, 1)

        // Two accepted results for the same span consume successive sites.
        let both = CtcVocabBooster.applyAcceptedReplacements(
            to: "rust and rust again",
            replacements: [
                (originalWord: "rust", replacementWord: "Rust"),
                (originalWord: "rust", replacementWord: "Rust"),
            ]
        )
        XCTAssertEqual(both.text, "Rust and Rust again")
        XCTAssertEqual(both.count, 2)
    }

    func testMultiWordSpanReplaced() {
        let out = CtcVocabBooster.applyAcceptedReplacements(
            to: "called the team this morning",
            replacements: [(originalWord: "the team", replacementWord: "Claude")]
        )
        XCTAssertEqual(out.text, "called Claude this morning")
        XCTAssertEqual(out.count, 1)
    }

    func testReplacementPreservesTrailingPunctuation() {
        let out = CtcVocabBooster.applyAcceptedReplacements(
            to: "written in rust.",
            replacements: [(originalWord: "rust", replacementWord: "Rust")]
        )
        XCTAssertEqual(out.text, "written in Rust.")
        XCTAssertEqual(out.count, 1)
    }

    func testReplacementPreservesNewlines() {
        // Positional edits touch only the matched word; surrounding layout,
        // including newlines, is untouched.
        let out = CtcVocabBooster.applyAcceptedReplacements(
            to: "first line rust\nsecond line",
            replacements: [(originalWord: "rust", replacementWord: "Rust")]
        )
        XCTAssertEqual(out.text, "first line Rust\nsecond line")
        XCTAssertEqual(out.count, 1)
    }

    func testUnmatchedReplacementNotCounted() {
        let out = CtcVocabBooster.applyAcceptedReplacements(
            to: "hello world",
            replacements: [(originalWord: "banana", replacementWord: "Rust")]
        )
        XCTAssertEqual(out.text, "hello world")
        XCTAssertEqual(out.count, 0)
    }

    // MARK: spanMatchesTerm; short terms demand exact matches

    // Every spoken "help" became "Helm" from a glossary term. "help" and
    // "helm" are 0.75 similar, exactly the floor, and one edit around a 4 or
    // 5 letter term covers many common words, so short terms only match
    // exactly.
    func testShortTermRejectsOneEditNeighbor() {
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "help", term: "Helm", floor: 0.75))
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "can you help me", term: "Helm", floor: 0.75))
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "cast", term: "k8s", floor: 0.75))
    }

    func testShortTermStillMatchesExactSpeech() {
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(span: "helm", term: "Helm", floor: 0.75))
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(span: "deploy the helm chart", term: "Helm", floor: 0.75))
    }

    func testLongerTermsKeepFuzzyRescue() {
        // Six letters and up keep fuzzy rescue, including terms the recognizer
        // divided into short phonetic pieces.
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(span: "claud", term: "Claude", floor: 0.75))
        XCTAssertTrue(CtcVocabBooster.spanMatchesTerm(span: "coober netties", term: "Kubernetes", floor: 0.6))
        XCTAssertFalse(CtcVocabBooster.spanMatchesTerm(span: "called the team this", term: "Kubernetes", floor: 0.6))
    }
}
