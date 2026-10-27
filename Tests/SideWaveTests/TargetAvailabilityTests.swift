// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// What happens to a chosen app or window that was minimized, closed, or quit, and to a VAD drain
/// that stops answering at stop.
@MainActor
final class TargetAvailabilityTests: XCTestCase {

    // MARK: - Chosen app or window

    private func check(running: Bool = true, window: CGWindowID? = 42, exists: Bool = true,
                       chosen: Bool = false, count: Int? = 1) -> AssignedTargetCheck {
        AssignedTargetCheck.evaluate(appRunning: running, windowID: window, windowExists: exists,
                                     windowChosen: chosen, windowCount: count)
    }

    func testAnOpenWindowIsReady() {
        // Minimized windows and windows on another Space still exist in the window server.
        XCTAssertEqual(check(), .ready)
        XCTAssertEqual(check(chosen: true), .ready)
    }

    func testAnAppThatQuitIsReported() {
        XCTAssertEqual(check(running: false), .appNotOpen)
        XCTAssertEqual(check(running: false, window: nil), .appNotOpen)
    }

    func testPickingTheAppFollowsItToANewWindow() {
        // Closing and reopening ChatGPT's window gives it a new ID.
        XCTAssertEqual(check(exists: false, chosen: false, count: 1), .followApp)
    }

    func testAChosenWindowThatClosedIsNotReplacedByAnother() {
        // Another Terminal window is another shell.
        XCTAssertEqual(check(exists: false, chosen: true, count: 3), .chosenWindowClosed)
    }

    func testAnAppWithNoWindowCantTakeText() {
        XCTAssertEqual(check(exists: false, chosen: false, count: 0), .noOpenWindow)
        XCTAssertEqual(check(window: nil, count: 0), .noOpenWindow)
    }

    func testAnAppThatDoesNotAnswerKeepsItsTarget() {
        XCTAssertEqual(check(window: nil, count: nil), .ready)
        XCTAssertEqual(check(exists: false, chosen: false, count: nil), .followApp)
    }

    func testMinimizedWindowsAreMarkedInTheMenu() {
        let open = WindowInfo(windowID: 1, pid: 1, title: "Notes", appName: "Notes", appIcon: nil, bounds: .zero)
        var minimized = open
        minimized.isMinimized = true
        XCTAssertEqual(open.menuTitle, "Notes")
        XCTAssertEqual(minimized.menuTitle, "Notes (minimized)")
    }

    // MARK: - VAD drain at stop

    func testADrainWaitsForTheOneInFlight() async {
        let service = TranscriptionService()
        service.vadDrainTask = Task { try? await Task.sleep(for: .milliseconds(300)) }
        let start = ContinuousClock.now
        await service.processVadChunks()
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(250))
        XCTAssertNil(service.vadDrainTask)
    }

    func testAStuckDrainIsAbandonedAndVadTurnsOff() async {
        let service = TranscriptionService()
        service.vadDrainTask = Task { try? await Task.sleep(for: .seconds(10)) }
        let epoch = service.vadDrainEpoch
        let start = ContinuousClock.now
        await service.drainVadWithinLimit(seconds: 0.2)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "the stop must not wait out a stuck drain")
        XCTAssertNotEqual(service.vadDrainEpoch, epoch, "a late result must see VAD was turned off")
        XCTAssertNil(service.vadDrainTask)
        XCTAssertNil(service.vadManager)
    }

    func testNoVadMeansNoWait() async {
        let service = TranscriptionService()
        let start = ContinuousClock.now
        await service.drainVadWithinLimit(seconds: 5)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
    }
}
