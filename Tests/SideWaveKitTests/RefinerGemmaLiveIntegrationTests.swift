// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest

@testable import SideWaveKit

/// Opt-in end-to-end check of the Gemma refine path with real weights.
/// Loads from the shared HuggingFace cache when present (multi-GB
/// download otherwise, so double-gated behind the live flag).
///
/// Run with: TEST_RUNNER_SIDEWAVE_LIVE_MODELS=1 through xcodebuild.
final class RefinerGemmaLiveIntegrationTests: XCTestCase {

    func testLiveGemmaRefinesMessyDictation() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("live model test skipped (set SIDEWAVE_LIVE_MODELS=1 to run)")
        }
        let refiner = RefinerGemma()
        async let first: Void = refiner.prepare(variant: .e2b) { progress in
            print("[live-test] gemma setup \(Int(progress.fraction * 100))%: \(progress.detail)")
        }
        async let second: Void = refiner.prepare(variant: .e2b)
        _ = try await (first, second)
        await refiner.setSettings(RefineSettings(template: .standard))

        let raw = "so um the thing is we need to improve the performance by like thirty percent before next quarter"
        let refined = try await refiner.refine(raw, context: "")
        print("[live-test] Gemma refined: \"\(refined)\"")

        XCTAssertFalse(refined.isEmpty)
        XCTAssertTrue(refined.lowercased().split(whereSeparator: { !$0.isLetter }).contains("we"), "Keep the original speaker: \(refined)")
        let lowered = refined.lowercased()
        XCTAssertTrue(lowered.contains("performance"), "content must survive: \(refined)")
        XCTAssertFalse(lowered.split(whereSeparator: { !$0.isLetter }).contains("um"), "fillers must be cleaned: \(refined)")
    }

    func testUnloadDuringPreparationDoesNotRestoreTheModel() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Live model tests require SIDEWAVE_LIVE_MODELS=1")
        }
        let refiner = RefinerGemma()
        let preparing = Task { try await refiner.prepare(variant: .e2b) }
        try await Task.sleep(for: .milliseconds(100))
        await refiner.unload()
        do {
            try await preparing.value
            XCTFail("Unloading must invalidate the pending preparation")
        } catch { }
        let ready = await refiner.isReady
        XCTAssertFalse(ready)
    }
}
