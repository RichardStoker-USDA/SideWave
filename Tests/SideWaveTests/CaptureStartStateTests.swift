// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class CaptureStartStateTests: XCTestCase {
    func testRepeatedStartIsRejectedUntilPreparationFinishes() throws {
        var state = CaptureStartState()
        let attempt = try XCTUnwrap(state.begin())
        XCTAssertNil(state.begin())
        XCTAssertTrue(state.accepts(attempt))
        state.finish(attempt)
        XCTAssertFalse(state.isStarting)
        XCTAssertTrue(state.accepts(attempt))
    }

    func testCancelDoesNotAllowOverlappingEngineSetup() throws {
        var state = CaptureStartState()
        let attempt = try XCTUnwrap(state.begin())
        state.cancel()
        XCTAssertFalse(state.accepts(attempt))
        XCTAssertTrue(state.isStarting)
        XCTAssertNil(state.begin())
        state.finish(attempt)
        XCTAssertFalse(state.isStarting)
        XCTAssertNotNil(state.begin())
    }

    func testOldCallbacksCannotChangeTheNextStart() throws {
        var state = CaptureStartState()
        let first = try XCTUnwrap(state.begin())
        state.finish(first)
        let second = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.accepts(first))
        state.finish(first)
        XCTAssertTrue(state.isStarting)
        XCTAssertTrue(state.accepts(second))
    }

    func testCancellationInvalidatesDeferredEffectsAfterStartCompletes() throws {
        var state = CaptureStartState()
        let attempt = try XCTUnwrap(state.begin())
        state.finish(attempt)
        state.cancel()
        XCTAssertFalse(state.accepts(attempt))
    }
    func testStopHoldRequestsRewriteOnlyWhenEnabledAndPastThreshold() {
        XCTAssertFalse(HotkeyManager.shouldRewriteOnStop(enabled: false, heldFor: 5))
        XCTAssertFalse(HotkeyManager.shouldRewriteOnStop(enabled: true, heldFor: 0.49))
        XCTAssertTrue(HotkeyManager.shouldRewriteOnStop(enabled: true, heldFor: 0.5))
        XCTAssertFalse(HotkeyManager.shouldRewriteOnStop(enabled: true, heldFor: .nan))
    }

}
