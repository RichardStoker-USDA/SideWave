// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest

@testable import SideWaveKit

/// Opt-in end-to-end check of the AFM refine path against the real
/// on-device model. Requires Apple Intelligence enabled on this Mac.
///
/// Run with: TEST_RUNNER_SIDEWAVE_LIVE_MODELS=1 through xcodebuild.
final class RefinerLiveIntegrationTests: XCTestCase {

    func testLiveAFMRefinesMessyDictation() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("live model test skipped (set SIDEWAVE_LIVE_MODELS=1 to run)")
        }
        let refiner = RefinerAFM()
        guard await refiner.isReady else {
            throw XCTSkip(RefinerAFM.availabilityMessage() ?? "Apple Intelligence unavailable")
        }
        await refiner.setSettings(RefineSettings(template: .standard))

        let raw = "so um the thing is we need to improve the performance by like thirty percent before next quarter"
        let refined = try await refiner.refine(raw, context: "")
        print("[live-test] AFM refined: \"\(refined)\"")

        XCTAssertFalse(refined.isEmpty)
        let lowered = refined.lowercased()
        XCTAssertTrue(lowered.contains("performance"), "content must survive: \(refined)")
        XCTAssertTrue(lowered.contains("thirty percent") || lowered.contains("30 percent") || lowered.contains("30%"),
                      "the number must survive: \(refined)")
        XCTAssertFalse(lowered.split(whereSeparator: { !$0.isLetter }).contains("um"), "fillers must be cleaned: \(refined)")
        XCTAssertNotEqual(refined, raw, "refine must actually edit")
    }
}
