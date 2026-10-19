// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Pins the smart-PTT classification rule (HotkeyManager.smartPTTHoldSatisfied).
/// The rule: the hold is measured from the
/// moment recording went LIVE, never from key-down, and no amount of waiting
/// on a dead engine can fire PTT. Each case below is a real gesture.
final class SmartPTTClassifierTests: XCTestCase {

    private let threshold: CFTimeInterval = 0.5

    /// A snappy toggle tap on a warm engine. Stays a toggle.
    func testQuickTapIsNotPTT() {
        XCTAssertFalse(HotkeyManager.smartPTTHoldSatisfied(
            now: 10.18, pressDown: 10.0, engineLiveAt: 10.05, threshold: threshold))
    }

    /// A relaxed tap that lingers ~400ms while the user
    /// glances at the overlay. Press-anchored code fired PTT here, which
    /// stopped the session at release and pasted an empty take.
    func testRelaxedTapOnWarmEngineIsNotPTT() {
        XCTAssertFalse(HotkeyManager.smartPTTHoldSatisfied(
            now: 10.42, pressDown: 10.0, engineLiveAt: 10.06, threshold: threshold))
    }

    /// The docking-station bug: engine takes 2s to start after a dock swap,
    /// the user gives up waiting and releases right as it comes live. The
    /// old 1.5s no-confirmation fallback fired PTT and killed the session
    /// at birth. Now: toggle, session keeps recording.
    func testReleaseRightAfterSlowStartIsNotPTT() {
        XCTAssertFalse(HotkeyManager.smartPTTHoldSatisfied(
            now: 12.05, pressDown: 10.0, engineLiveAt: 12.0, threshold: threshold))
    }

    /// Holding through a slow start and KEEPING the hold once live is a
    /// deliberate PTT; the user is waiting to talk, then talking.
    func testHoldMaintainedPastSlowStartIsPTT() {
        XCTAssertTrue(HotkeyManager.smartPTTHoldSatisfied(
            now: 12.6, pressDown: 10.0, engineLiveAt: 12.0, threshold: threshold))
    }

    /// The walkie-talkie gesture on a warm engine: press, speak a sentence,
    /// release. Fires exactly as before.
    func testDeliberateHoldOnWarmEngineIsPTT() {
        XCTAssertTrue(HotkeyManager.smartPTTHoldSatisfied(
            now: 11.2, pressDown: 10.0, engineLiveAt: 10.05, threshold: threshold))
    }

    /// No amount of holding on an engine that never came live can fire PTT
    /// (the release must never stop-and-paste a session that never started).
    func testEngineNeverLiveNeverFiresPTT() {
        XCTAssertFalse(HotkeyManager.smartPTTHoldSatisfied(
            now: 20.0, pressDown: 10.0, engineLiveAt: 0, threshold: threshold))
    }

    /// Sentinel press value (no press tracked) never fires.
    func testNoPressNeverFiresPTT() {
        XCTAssertFalse(HotkeyManager.smartPTTHoldSatisfied(
            now: 20.0, pressDown: 0, engineLiveAt: 10.0, threshold: threshold))
    }

    /// Boundary: exactly threshold past live fires (>= contract).
    func testExactThresholdPastLiveFires() {
        XCTAssertTrue(HotkeyManager.smartPTTHoldSatisfied(
            now: 10.55, pressDown: 10.0, engineLiveAt: 10.05, threshold: threshold))
    }
}
