// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Pins the map-reduce chunker that keeps long meetings inside the model's
/// working window. The chunker is pure: it takes segments plus a token budget
/// and returns runs of whole speaker turns. These tests hold the load-bearing
/// invariants: no text is dropped or reordered, ordinary turns stay together,
/// long monologues split within the budget, and short
/// meetings collapse to a single chunk (so map-reduce is bypassed upstream).
final class MeetingFormatterChunkingTests: XCTestCase {
    @MainActor
    func testNoSpeechCannotStartFormattingOrReuseEarlierNotes() {
        let formatter = MeetingFormatterService()
        for texts in [[], [" \n\t"], ["...", "—"]] as [[String]] {
            let transcript = MeetingTranscript(segments: texts.map {
                MeetingSegment(speakerId: "speaker_0", speakerLabel: "Speaker 1", text: $0, startTime: 0, endTime: 1)
            }, speakerNames: [:], duration: 6, timestamp: Date(), isPartial: true)
            XCTAssertFalse(transcript.hasSpeech)
            for backend in MeetingFormatterBackend.allCases {
                formatter.setBackend(backend)
                formatter.state = .complete(output: "Earlier notes")
                formatter.format(transcript: transcript, as: .minutes)
                guard case .error(let message) = formatter.state else {
                    XCTFail("Empty speech must be rejected before model preparation"); continue
                }
                XCTAssertTrue(message.contains("No speech"))
                XCTAssertFalse(formatter.state.isBusy)
            }
        }
    }

    func testTranscriptSpeechDetectionIncludesNonLatinWordsAndNumbers() {
        for text in ["はい", "مرحبا", "42", "Agreed."] {
            let transcript = MeetingTranscript(segments: [.init(speakerId: "speaker_0", speakerLabel: "Speaker 1", text: text, startTime: 0, endTime: 1)], speakerNames: [:], duration: 1, timestamp: Date())
            XCTAssertTrue(transcript.hasSpeech)
        }
    }


    @MainActor
    func testMeetingBackendCannotDiscardAnActiveFormattingOperation() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "meetingFormatterBackend")
        defer {
            if let saved { defaults.set(saved, forKey: "meetingFormatterBackend") }
            else { defaults.removeObject(forKey: "meetingFormatterBackend") }
        }
        let state = AppState()
        state.meetingFormatterBackend = MeetingFormatterBackend.gemma4E2B.rawValue
        for busyState in [FormatterState.loading, .generating(output: "# Draft notes", note: "Summarizing")] {
            state.formatterService.state = busyState
            state.meetingFormatterBackend = MeetingFormatterBackend.gemma4_12B.rawValue
            XCTAssertEqual(state.meetingFormatterBackend, MeetingFormatterBackend.gemma4E2B.rawValue)
            XCTAssertEqual(state.formatterService.selectedBackend, .gemma4E2B)
            XCTAssertTrue(state.formatterService.state.isBusy)
            XCTAssertEqual(defaults.string(forKey: "meetingFormatterBackend"), MeetingFormatterBackend.gemma4E2B.rawValue)
        }
        state.formatterService.cancel()
        state.meetingFormatterBackend = MeetingFormatterBackend.gemma4_12B.rawValue
        XCTAssertEqual(state.formatterService.selectedBackend, .gemma4_12B)
    }

    // Builds a segment with text of a requested length so token math is
    // predictable. Speaker cycles so chunks span multiple turns.
    private func segment(index: Int, textLength: Int) -> MeetingSegment {
        let text = String(repeating: "a", count: textLength)
        return MeetingSegment(
            speakerId: "Speaker \(index % 3)",
            speakerLabel: "Speaker \(index % 3)",
            text: text,
            startTime: Double(index),
            endTime: Double(index) + 1
        )
    }

    // Token cost the chunker charges a segment, computed the same way it does.
    private func tokens(_ segment: MeetingSegment) -> Int {
        MeetingFormatterService.estimatedTokens(
            forCharacters: MeetingFormatterService.renderedLength(of: segment)
        )
    }

    // MARK: - Empty / trivial

    func testEmptyInputReturnsNoChunks() {
        XCTAssertTrue(MeetingFormatterService.chunkSegments([], tokenBudget: 6000).isEmpty)
    }

    func testShortMeetingIsSingleChunk() {
        // A handful of small turns fit one chunk, so runGemmaFormatting's caller
        // stays on the single-pass path instead of map-reduce.
        let segments = (0..<5).map { segment(index: $0, textLength: 80) }
        let chunks = MeetingFormatterService.chunkSegments(segments, tokenBudget: 6000)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.count, 5)
    }

    // MARK: - No dropped / reordered segments

    func testEverySegmentAppearsOnceInOrder() {
        let segments = (0..<40).map { segment(index: $0, textLength: 120) }
        let chunks = MeetingFormatterService.chunkSegments(segments, tokenBudget: 200)
        let flattened = chunks.flatMap { $0 }
        XCTAssertEqual(flattened.count, segments.count, "no segment dropped or duplicated")
        XCTAssertEqual(flattened.map(\.id), segments.map(\.id), "original order preserved")
    }

    func testNoChunkIsEmpty() {
        let segments = (0..<25).map { segment(index: $0, textLength: 90) }
        let chunks = MeetingFormatterService.chunkSegments(segments, tokenBudget: 100)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty)
        }
    }

    // MARK: - Turn boundaries never split

    func testChunksAreContiguousRunsOfWholeTurns() {
        // Every chunk must be a contiguous slice of the original array: turns are
        // atomic, so the split points fall only between whole segments.
        let segments = (0..<30).map { segment(index: $0, textLength: 150) }
        let chunks = MeetingFormatterService.chunkSegments(segments, tokenBudget: 250)
        var expectedIndex = 0
        for chunk in chunks {
            for seg in chunk {
                XCTAssertEqual(seg.id, segments[expectedIndex].id)
                expectedIndex += 1
            }
        }
        XCTAssertEqual(expectedIndex, segments.count)
    }

    // MARK: - Budget respected

    func testMultiSegmentChunksStayWithinBudget() {
        let budget = 200
        let segments = (0..<40).map { segment(index: $0, textLength: 120) }
        let chunks = MeetingFormatterService.chunkSegments(segments, tokenBudget: budget)
        for chunk in chunks where chunk.count > 1 {
            let total = chunk.reduce(0) { $0 + tokens($1) }
            XCTAssertLessThanOrEqual(total, budget, "a chunk holding 2+ turns must fit the budget")
        }
    }

    func testEachChunkStartsFreshOnceBudgetWouldOverflow() {
        // With uniform segments, greedy packing puts as many whole turns in each
        // chunk as fit, so adding one more to any chunk would exceed the budget.
        let budget = 200
        let segments = (0..<40).map { segment(index: $0, textLength: 120) }
        let chunks = MeetingFormatterService.chunkSegments(segments, tokenBudget: budget)
        let perSegment = tokens(segments[0])
        for chunk in chunks {
            let total = chunk.reduce(0) { $0 + tokens($1) }
            XCTAssertGreaterThan(total + perSegment, budget,
                                 "chunk should be packed until one more turn would overflow")
        }
    }

    // MARK: - Oversized single turn

    func testLongMonologueIsSplitWithoutLosingTextOrAttribution() {
        let small1 = segment(index: 0, textLength: 100)
        let huge = segment(index: 1, textLength: 5000)
        let small2 = segment(index: 2, textLength: 100)
        let chunks = MeetingFormatterService.chunkSegments([small1, huge, small2], tokenBudget: 200)
        let pieces = chunks.flatMap { $0 }
        XCTAssertEqual(pieces.map(\.text).joined(), small1.text + huge.text + small2.text)
        let monologue = pieces.filter { $0.id == huge.id }
        XCTAssertGreaterThan(monologue.count, 1)
        XCTAssertTrue(monologue.allSatisfy { $0.speakerId == huge.speakerId && $0.startTime == huge.startTime && $0.endTime == huge.endTime })
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.reduce(0) { $0 + tokens($1) }, 200) }
    }

    func testLongTurnSplitsAtWordsAndKeepsUnicodeAndWhitespace() {
        let text = String(repeating: "日本語 café sample 🌿\n", count: 50)
        let source = MeetingSegment(speakerId: "1", speakerLabel: "Speaker 1", text: text, startTime: 0, endTime: 60)
        let pieces = MeetingFormatterService.chunkSegments([source], tokenBudget: 100).flatMap { $0 }
        XCTAssertEqual(pieces.map(\.text).joined(), text)
        XCTAssertTrue(pieces.dropLast().allSatisfy { $0.text.last?.isWhitespace == true })
    }

    func testDenseTokenizationSplitsUnicodeWithinTheMeasuredBudget() {
        let text = String(repeating: "日本語 café 🌿\n", count: 100)
        let source = MeetingSegment(speakerId: "1", speakerLabel: "Speaker 1", text: text, startTime: 0, endTime: 60)
        let budget = 200
        let chunks = MeetingFormatterService.chunkSegments([source], tokenBudget: budget, tokenCount: { $0.utf8.count })
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.text).joined(), text)
        for chunk in chunks {
            let rendered = chunk.map { "[\($0.formattedTimeRange)] \($0.speakerLabel): \($0.text)\n\n" }.joined()
            XCTAssertLessThanOrEqual(rendered.utf8.count, budget)
        }
    }

    func testRepeatedFormatsReserveSpaceForTheNextOutput() {
        XCTAssertTrue(MeetingFormatterService.canReuseContext(cachedTokens: 2_000, promptTokens: 300, contextCap: 16_384))
        XCTAssertFalse(MeetingFormatterService.canReuseContext(cachedTokens: 12_000, promptTokens: 300, contextCap: 16_384))
    }

    func testIntermediateNotesAreGroupedWithoutExceedingTheWindow() {
        let notes = (0..<30).map { "Section \($0): " + String(repeating: "sample ", count: 40) }
        let groups = MeetingFormatterService.groupNotes(notes, tokenBudget: 200)
        XCTAssertEqual(groups.flatMap { $0 }, notes)
        XCTAssertGreaterThan(groups.count, 1)
        for group in groups {
            XCTAssertLessThanOrEqual(MeetingFormatterService.estimatedTokens(forCharacters: group.joined(separator: "\n\n").count), 200)
        }
    }

    func testNotesInputCollapsesRepeatedBlocksWithoutLosingBoundaryFacts() {
        let first = "The approved budget is 735 dollars. "
        let repeated = "The labels are blue. The inventory was checked. "
        let last = "Delivery is due on Tuesday."
        XCTAssertEqual(MeetingFormatterService.notesSource(first + String(repeating: repeated, count: 40) + last),
                       first + repeated + last)
        let changes = "The labels are blue. The labels are red. The labels are blue."
        XCTAssertEqual(MeetingFormatterService.notesSource(changes), changes)
        XCTAssertEqual(MeetingFormatterService.notesSource("日本語 café 🌿"), "日本語 café 🌿")
    }

    func testNumericFactsKeepAmountsDatesAndDecimalsDistinct() {
        let input = "The budget is $1,250.50. Use 12 samples at 2.5 percent on 2026-11-03. ABC42 is an identifier."
        XCTAssertEqual(MeetingFormatterService.numericFacts(in: input), ["1250.50", "12", "2.5", "2026", "11", "03"])
        XCTAssertEqual(MeetingFormatterService.numericFacts(in: "The budget is 1250.50; the rate is 2.5."), ["1250.50", "2.5"])
        XCTAssertFalse(MeetingFormatterService.numericFacts(in: input).isSubset(of:
            MeetingFormatterService.numericFacts(in: "Use 12 samples at 2.5 percent on 2026-11-03.")))
    }

    func testDecisionCoverageDoesNotTreatProposalsAsAgreements() {
        let notes = "- [Decision] Ada: Approved 735 dollars.\n- [Proposal] Sam: Suggested 980 dollars.\n- [Fact] Lee: There are 12 samples."
        XCTAssertEqual(MeetingFormatterService.decisionNumericFacts(in: notes), ["735"])
    }

    func testNumericSourceExcerptsKeepTheExactCommitmentAndSpeaker() {
        let source = MeetingSegment(speakerId: "a", speakerLabel: "Speaker 1",
            text: "We approved 735 dollars. The samples are ready. We rejected 980 dollars.", startTime: 0, endTime: 12)
        let excerpts = MeetingFormatterService.numericSourceExcerpts([source], speakerNames: ["a": "Ada"])
        XCTAssertTrue(excerpts.contains("[Source] Ada: We approved 735 dollars."))
        XCTAssertTrue(excerpts.contains("[Source] Ada: We rejected 980 dollars."))
        XCTAssertFalse(excerpts.contains("samples are ready"))
    }

    // MARK: - Determinism

    func testChunkingIsDeterministic() {
        let segments = (0..<30).map { segment(index: $0, textLength: 110) }
        let first = MeetingFormatterService.chunkSegments(segments, tokenBudget: 180)
        let second = MeetingFormatterService.chunkSegments(segments, tokenBudget: 180)
        XCTAssertEqual(first.map { $0.map(\.id) }, second.map { $0.map(\.id) })
    }
}
