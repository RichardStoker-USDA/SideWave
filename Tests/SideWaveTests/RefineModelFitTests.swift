// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Which Refine models fit a Mac, judged by its total memory and what is usually free.
final class RefineModelFitTests: XCTestCase {
    private typealias Backend = DictationFormatterService.Backend
    private let gb: UInt64 = 1_000_000_000
    private let gib: UInt64 = 1_073_741_824

    private func memory(total: UInt64, now: UInt64, usual: UInt64? = nil) -> RefineModelFit.Memory {
        RefineModelFit.Memory(total: total * gib, availableNow: now * gb, typicallyAvailable: usual.map { $0 * gb })
    }

    func testAppleIntelligenceRunsInMacOS() {
        XCTAssertEqual(RefineModelFit.verdict(for: .appleIntelligence, memory: memory(total: 8, now: 1)), .system)
    }

    func testRoomyMacFitsEveryGemmaModel() {
        let roomy = memory(total: 64, now: 40, usual: 30)
        for backend in [Backend.gemma4E2B, .gemma4E4B, .gemma4_12B] {
            XCTAssertEqual(RefineModelFit.verdict(for: backend, memory: roomy), .comfortable, backend.displayName)
        }
    }

    func testUsualFreeMemoryOutweighsAQuietMoment() {
        // Lots free right now, but the person's usual work leaves little: plan for the usual.
        let busy = memory(total: 16, now: 12, usual: 5)
        XCTAssertEqual(RefineModelFit.verdict(for: .gemma4E4B, memory: busy), .tooLarge)
        XCTAssertNotEqual(RefineModelFit.verdict(for: .gemma4E2B, memory: busy), .tooLarge)
    }

    func testABusyMomentLowersTheVerdictToo() {
        let now = memory(total: 32, now: 5, usual: 20)
        XCTAssertEqual(RefineModelFit.verdict(for: .gemma4_12B, memory: now), .tooLarge)
    }

    func testSmallMacCantSpareMemoryForLargeModels() {
        let small = memory(total: 8, now: 6, usual: 6)
        XCTAssertEqual(RefineModelFit.verdict(for: .gemma4_12B, memory: small), .tooLarge)
        XCTAssertEqual(RefineModelFit.verdict(for: .gemma4E4B, memory: small), .tooLarge)
    }

    func testTightWhenOnlyTheModelItselfFits() {
        guard let need = Backend.gemma4E2B.workingBytes else { return XCTFail("E2B has a size") }
        let tight = RefineModelFit.Memory(total: 16 * gib, availableNow: need + gb / 2, typicallyAvailable: nil)
        XCTAssertEqual(RefineModelFit.verdict(for: .gemma4E2B, memory: tight), .tight)
    }

    func testSuggestsE4BOnRoomyProMaxUltraChips() {
        let roomy = memory(total: 64, now: 40, usual: 30)
        XCTAssertEqual(RefineModelFit.suggested(memory: roomy, chip: .appleSiliconMax, appleIntelligenceAvailable: true), .gemma4E4B)
        XCTAssertEqual(RefineModelFit.suggested(memory: roomy, chip: .appleSiliconBase, appleIntelligenceAvailable: true), .gemma4E2B)
    }

    func testSuggestsAppleIntelligenceWithoutRoomForGemma() {
        let full = memory(total: 8, now: 2, usual: 2)
        XCTAssertEqual(RefineModelFit.suggested(memory: full, chip: .appleSiliconBase, appleIntelligenceAvailable: true), .appleIntelligence)
        XCTAssertEqual(RefineModelFit.suggested(memory: full, chip: .appleSiliconBase, appleIntelligenceAvailable: false), .gemma4E2B)
    }

    func testNeverSuggests12B() {
        let huge = memory(total: 192, now: 150, usual: 140)
        XCTAssertNotEqual(RefineModelFit.suggested(memory: huge, chip: .appleSiliconUltra, appleIntelligenceAvailable: true), .gemma4_12B)
    }

    func testNoteExplainsATightChoiceAndNamesOneThatFits() throws {
        let busy = memory(total: 16, now: 12, usual: 5)
        let note = try XCTUnwrap(RefineModelFit.note(for: .gemma4E4B, memory: busy, suggestion: .gemma4E2B))
        XCTAssertTrue(note.contains("Gemma 4 E4B"), note)
        XCTAssertTrue(note.contains("Gemma 4 E2B fits."), note)
        XCTAssertNil(RefineModelFit.note(for: .gemma4E2B, memory: memory(total: 64, now: 40, usual: 30), suggestion: .gemma4E2B))
    }

    func testGigabyteText() {
        XCTAssertEqual(RefineModelFit.gigabytes(3_580_000_000), "3.6 GB")
        XCTAssertEqual(RefineModelFit.memoryText(137_438_953_472), "128 GB")
        XCTAssertEqual(RefineModelFit.memoryText(11 * 536_870_912), "5.5 GB")
        XCTAssertEqual(RefineModelFit.memoryText(4 * 1_073_741_824), "4 GB")
    }

    // MARK: - History

    private func freshDefaults() -> UserDefaults {
        let name = "RefineModelFitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testHistoryNeedsSeveralSamplesBeforeItHasAUsualFigure() {
        let history = SystemMemory.History(defaults: freshDefaults())
        for index in 0..<5 { history.record(10 * gb, at: 1_000 + Double(index) * 700) }
        XCTAssertNil(history.typical(now: 5_000))
        history.record(10 * gb, at: 1_000 + 5 * 700)
        XCTAssertEqual(history.typical(now: 5_000), 10 * gb)
    }

    func testHistoryUsesTheTighterMoments() {
        let history = SystemMemory.History(defaults: freshDefaults())
        let free: [UInt64] = [30, 30, 30, 30, 30, 30, 30, 30, 30, 4]
        for (index, value) in free.enumerated() { history.record(value * gb, at: 1_000 + Double(index) * 700) }
        XCTAssertEqual(history.typical(now: 10_000), 30 * gb)
        history.record(4 * gb, at: 1_000 + 10 * 700)
        XCTAssertEqual(history.typical(now: 10_000), 4 * gb)
    }

    func testHistorySpacesSamplesAndForgetsOldOnes() {
        let history = SystemMemory.History(defaults: freshDefaults())
        history.record(8 * gb, at: 1_000)
        history.record(9 * gb, at: 1_100)
        XCTAssertEqual(history.samples.count, 1)
        history.record(9 * gb, at: 1_000 + SystemMemory.History.window + 10)
        XCTAssertEqual(history.samples.map(\.bytes), [9 * gb])
    }
}
