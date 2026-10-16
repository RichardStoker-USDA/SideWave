// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWaveKit

final class RefineDeadlineTests: XCTestCase {
    private static func uncooperativeWork() async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                continuation.resume(returning: "late output")
            }
        }
    }

    func testDeadlineDoesNotWaitForUncooperativeModel() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await RefineDeadline.run(timeout: .milliseconds(20)) { await Self.uncooperativeWork() }
            XCTFail("Expected a timeout")
        } catch RefinerFailure.timedOut {
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        }
    }

    func testCancellationDoesNotWaitForUncooperativeModel() async throws {
        let task = Task { try await RefineDeadline.run(timeout: .seconds(5)) { await Self.uncooperativeWork() } }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        }
    }

    func testCompletedOutputWinsAndCancelsTimer() async throws {
        let output = try await RefineDeadline.run(timeout: .seconds(1)) { "Ready." }
        XCTAssertEqual(output, "Ready.")
    }
}
