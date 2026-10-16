// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWaveKit

/// Pins the session state machine's transition table. Each named field
/// failure from the original app is a row here, so the rebuild can never
/// re-grow the race that caused it.
final class SessionTransitionTests: XCTestCase {

    private let clock = ContinuousClock()

    private func apply(
        _ event: SessionEvent,
        to state: SessionState,
        stopQueued: Bool = false
    ) -> SessionTransition.Result {
        SessionTransition.apply(event, to: state, stopQueued: stopQueued, now: clock.now)
    }

    // MARK: The killed-at-birth class

    /// Releasing or tapping during a slow start must not end the session as
    /// soon as it starts. A stop during .starting queues.
    func testStopDuringStartingQueuesInsteadOfKilling() {
        let result = apply(.stopRequested, to: .starting(since: clock.now))
        guard case .starting = result.state else {
            return XCTFail("stop during starting must stay in starting, got \(result.state)")
        }
        XCTAssertEqual(result.effects, [.queueStop])
    }

    /// The queued stop is honored the moment the engine goes live: the
    /// user's buffered words still process, nothing is lost, and the
    /// session ends the way they asked.
    func testQueuedStopFiresAtEngineLive() {
        let result = apply(.engineLive, to: .starting(since: clock.now), stopQueued: true)
        guard case .stopping = result.state else {
            return XCTFail("queued stop must enter stopping at engine-live, got \(result.state)")
        }
        XCTAssertEqual(result.effects, [.beginStopForQueuedRequest])
    }

    // MARK: Normal paths

    func testStartFromIdleBeginsStart() {
        let result = apply(.startRequested, to: .idle)
        guard case .starting = result.state else { return XCTFail("\(result.state)") }
        XCTAssertEqual(result.effects, [.beginStart])
    }

    func testEngineLiveEntersLive() {
        let result = apply(.engineLive, to: .starting(since: clock.now))
        guard case .live = result.state else { return XCTFail("\(result.state)") }
        XCTAssertTrue(result.effects.isEmpty)
    }

    func testStopFromLiveBeginsStopPipeline() {
        let result = apply(.stopRequested, to: .live(since: clock.now))
        guard case .stopping = result.state else { return XCTFail("\(result.state)") }
        XCTAssertEqual(result.effects, [.beginStop])
    }

    func testFinishedReturnsToIdleWithCleanup() {
        let result = apply(.finished, to: .stopping(since: clock.now))
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.effects, [.cleanup])
    }

    // MARK: Failure honesty

    func testFailureDuringStartSurfacesAndCleans() {
        let result = apply(.failed(reason: "mic unavailable"), to: .starting(since: clock.now))
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.effects, [.surfaceFailure(reason: "mic unavailable"), .cleanup])
    }

    func testFailureWhileLiveEndsSessionVisibly() {
        let result = apply(.failed(reason: "audio stalled"), to: .live(since: clock.now))
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.effects, [.surfaceFailure(reason: "audio stalled"), .cleanup])
    }

    // MARK: Stray-event immunity

    /// Late engine callbacks after cleanup must be no-ops, not zombie
    /// sessions.
    func testLateEngineLiveAfterIdleIsNoOp() {
        let result = apply(.engineLive, to: .idle)
        XCTAssertEqual(result.state, .idle)
        XCTAssertTrue(result.effects.isEmpty)
    }

    /// Nothing interrupts a drain: a new start during stopping waits.
    func testStartDuringStoppingIsRefused() {
        let stopping = SessionState.stopping(since: clock.now)
        let result = apply(.startRequested, to: stopping)
        guard case .stopping = result.state else { return XCTFail("\(result.state)") }
        XCTAssertTrue(result.effects.isEmpty)
    }

    /// Double stop while stopping must not double-run the pipeline.
    func testDoubleStopWhileStoppingIsNoOp() {
        let result = apply(.stopRequested, to: .stopping(since: clock.now))
        XCTAssertTrue(result.effects.isEmpty)
    }

    // MARK: Carried gesture classifier

    func testCarriedClassifierStillLiveAnchored() {
        XCTAssertFalse(GestureClassifier.pttHoldSatisfied(
            now: 12.05, pressDown: 10.0, engineLiveAt: 12.0, threshold: 0.5))
        XCTAssertTrue(GestureClassifier.pttHoldSatisfied(
            now: 12.6, pressDown: 10.0, engineLiveAt: 12.0, threshold: 0.5))
        XCTAssertFalse(GestureClassifier.pttHoldSatisfied(
            now: 20.0, pressDown: 10.0, engineLiveAt: 0, threshold: 0.5))
    }
}
