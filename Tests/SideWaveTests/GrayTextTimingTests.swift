// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class GrayTextTimingTests: XCTestCase {
    func testSummaryReportsStartAndLagWithoutText() {
        var timing = GrayTextTiming(pressedAt: 99.8, startedAt: 100)
        timing.firstAudio(at: 100.25)
        timing.firstAudio(at: 100.9)
        timing.attached(at: 100.3)
        timing.update(at: 100.9, heardAt: 100.8, hasWords: false, shown: false, held: false)
        timing.update(at: 101.5, heardAt: 101.2, hasWords: true, shown: false, held: true)
        timing.update(at: 102.0, heardAt: 101.9, hasWords: true, shown: true, held: false)
        timing.mainThreadDelay(0.42, at: 100.5)
        timing.mainThreadDelay(0.1, at: 101)
        XCTAssertEqual(timing.summary,
                       "Gray text after the hotkey: pipeline start 200 ms, first audio 450 ms, model attached 500 ms, first words 1700 ms, first shown 2200 ms; behind the audio p95 100 ms, max 300 ms over 3 updates; 1 held by the ghost gate; main thread longest stall 420 ms at 700 ms")
    }

    func testIgnoresAStalePress() {
        XCTAssertEqual(GrayTextTiming(pressedAt: 10, startedAt: 100).pressedAt, 100)
        XCTAssertEqual(GrayTextTiming(pressedAt: 99.5, startedAt: 100).pressedAt, 99.5)
    }

    func testSummaryWhenTheModelNeverAttached() {
        let timing = GrayTextTiming(startedAt: 5)
        XCTAssertEqual(timing.summary,
                       "Gray text after the hotkey: pipeline start 0 ms, first audio never, model attached never, first words never, first shown never; behind the audio p95 0 ms, max 0 ms over 0 updates; 0 held by the ghost gate; main thread longest stall 0 ms at never")
    }
}
