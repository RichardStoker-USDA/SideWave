// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class DictationTracingTests: XCTestCase {
    func testClearingTraceDoesNotReenterHeldLock() async {
        let finished = expectation(description: "Trace cleared")
        DispatchQueue.global().async {
            DictationTracingService.shared.clear()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
    }

    func testTraceObserverCanReadEventsSynchronously() async {
        let finished = expectation(description: "Observer read trace")
        let service = DictationTracingService.shared
        let observer = NotificationCenter.default.addObserver(forName: .didReceiveDictationTrace, object: nil, queue: nil) { _ in
            _ = service.getEvents()
            finished.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        DispatchQueue.global().async {
            service.log(.engineState, .info, "Trace observation check")
        }
        await fulfillment(of: [finished], timeout: 2)
    }
}
