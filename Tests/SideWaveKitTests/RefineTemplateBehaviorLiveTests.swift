// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest

@testable import SideWaveKit

/// Opt-in behavioral proof for each carried template against the real
/// AFM model: not just "did it answer," but "did it honor the template's
/// contract." Greedy sampling keeps outputs stable enough to assert.
///
/// Run with: TEST_RUNNER_SIDEWAVE_LIVE_MODELS=1 through xcodebuild.
final class RefineTemplateBehaviorLiveTests: XCTestCase {

    private let messy =
        "so um the thing is we basically need to you know improve the performance by like thirty percent before next quarter because the the customers keep complaining about it"

    private func refiner(_ template: RefineTemplate, custom: String = "") async throws -> RefinerAFM {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("live model test skipped (set SIDEWAVE_LIVE_MODELS=1 to run)")
        }
        let refiner = RefinerAFM()
        guard await refiner.isReady else {
            throw XCTSkip(RefinerAFM.availabilityMessage() ?? "Apple Intelligence unavailable")
        }
        await refiner.setSettings(
            RefineSettings(template: template, customInstructions: custom))
        return refiner
    }

    func testStandardFixesWithoutRestyling() async throws {
        let refiner = try await refiner(.standard)
        let out = try await refiner.refine(messy, context: "")
        print("[live-test] standard: \"\(out)\"")
        let lowered = out.lowercased()
        XCTAssertFalse(lowered.split(whereSeparator: { !$0.isLetter }).contains("um"), "fillers must go: \(out)")
        XCTAssertFalse(lowered.contains("you know"), "fillers must go: \(out)")
        XCTAssertTrue(lowered.contains("thirty percent") || lowered.contains("30 percent") || lowered.contains("30%"))
        XCTAssertTrue(lowered.contains("customers"), "content must survive: \(out)")
        XCTAssertFalse(lowered.contains("the the"), "acoustic repeat must collapse: \(out)")
    }

    func testProfessionalLiftsRegisterKeepsPoints() async throws {
        let refiner = try await refiner(.professional)
        let out = try await refiner.refine(messy, context: "")
        print("[live-test] professional: \"\(out)\"")
        let lowered = out.lowercased()
        XCTAssertFalse(lowered.split(whereSeparator: { !$0.isLetter }).contains("um"))
        XCTAssertFalse(lowered.contains("basically"), "empty qualifier should smooth away: \(out)")
        XCTAssertTrue(lowered.contains("thirty percent") || lowered.contains("30"))
        XCTAssertTrue(lowered.contains("customer"), "the complaint point must survive: \(out)")
    }

    func testConciseIsMeasurablyShorter() async throws {
        let refiner = try await refiner(.concise)
        let out = try await refiner.refine(messy, context: "")
        print("[live-test] concise: \"\(out)\"")
        XCTAssertLessThan(
            RefineHygiene.wordCount(out), RefineHygiene.wordCount(messy),
            "Concise must shrink the text: \(out)")
        XCTAssertTrue(out.lowercased().contains("thirty") || out.contains("30"))
    }

    func testCustomInstructionsTakePriority() async throws {
        let refiner = try await refiner(
            .custom, custom: "Rewrite the text as exactly one sentence that starts with the word DECISION in capital letters.")
        let out = try await refiner.refine(messy, context: "")
        print("[live-test] custom: \"\(out)\"")
        XCTAssertTrue(
            out.hasPrefix("DECISION"),
            "custom instructions have maximum priority: \(out)")
    }
}
