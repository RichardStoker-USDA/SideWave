// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class AudioSetupOperationTests: XCTestCase {
    @MainActor
    func testPriorityRoutingYieldsToMeetingsAndPendingHALWork() {
        let state = AppState()
        XCTAssertFalse(state.audioDeviceManager.isDictationActive?() ?? true)
        state.meetingService.state = .recording(duration: 0)
        XCTAssertTrue(state.audioDeviceManager.isDictationActive?() ?? false)
        state.meetingService.state = .idle
        XCTAssertTrue(AudioSetupActivity.begin())
        defer { AudioSetupActivity.end() }
        XCTAssertTrue(state.audioDeviceManager.isDictationActive?() ?? false)
    }

    func testRequestWaitsForClosingInputWithinItsDeadline() async throws {
        XCTAssertTrue(AudioSetupActivity.begin())
        let released = Task {
            try await Task.sleep(for: .milliseconds(50))
            AudioSetupActivity.end()
        }
        let value = try await AudioSetupOperation<Int>.run(timeout: 1) { _ in 7 } dispose: { _ in
            XCTFail("The replacement resource must be adopted")
        }
        try await released.value
        XCTAssertEqual(value, 7)
        XCTAssertFalse(AudioSetupActivity.isActive)
    }

    func testDeadlineReturnsWithoutWaitingForBlockedHALAndDisposesLateResult() async throws {
        let release = DispatchSemaphore(value: 0)
        let disposed = expectation(description: "Late resource disposed")
        let finished = expectation(description: "Worker finished after disposal")
        let disposalState = DisposalState()
        let start = Date()
        do {
            _ = try await AudioSetupOperation<Int>.run(timeout: 0.05) { operation in
                release.wait()
                XCTAssertTrue(operation.isAbandoned)
                return 42
            } dispose: { value in
                XCTAssertEqual(value, 42)
                disposalState.markDisposed()
                disposed.fulfill()
            } workFinished: {
                XCTAssertTrue(disposalState.isDisposed)
                finished.fulfill()
            }
            XCTFail("A blocked setup must time out")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
        release.signal()
        await fulfillment(of: [disposed, finished], timeout: 2, enforceOrder: true)
    }

    func testSuccessfulResourceIsTransferredOnce() async throws {
        let value = try await AudioSetupOperation<Int>.run(timeout: 0.1) { _ in 7 } dispose: { _ in
            XCTFail("An adopted resource must not be disposed")
        }
        XCTAssertEqual(value, 7)
    }

    func testCancellationReleasesCallerBeforeWorkerReturns() async throws {
        let started = expectation(description: "Worker started")
        let disposed = expectation(description: "Cancelled resource disposed")
        let finished = expectation(description: "Cancelled worker finished")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await AudioSetupOperation<Int>.run(timeout: 5) { _ in
                started.fulfill()
                release.wait()
                return 1
            } dispose: { _ in disposed.fulfill() } workFinished: { finished.fulfill() }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        release.signal()
        await fulfillment(of: [disposed, finished], timeout: 2, enforceOrder: true)
    }

    func testTimedOutWorkerKeepsRouteUntilLateResourceCloses() async throws {
        let release = DispatchSemaphore(value: 0)
        let cleanupRelease = DispatchSemaphore(value: 0)
        let started = expectation(description: "Setup started")
        let closing = expectation(description: "Late resource closing")
        let finished = expectation(description: "Cleanup finished")
        let rejected = expectation(description: "Rejected request reports worker completion")
        let task = Task {
            try await AudioSetupOperation<Int>.run(timeout: 0.05) { _ in
                started.fulfill()
                release.wait()
                return 1
            } dispose: { _ in
                closing.fulfill()
                cleanupRelease.wait()
            } workFinished: { finished.fulfill() }
        }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected timeout") } catch {}
        XCTAssertTrue(AudioSetupActivity.isActive)
        do {
            _ = try await AudioSetupOperation<Int>.run(timeout: 1) { _ in
                XCTFail("A replacement must not enter HAL during abandoned setup")
                return 2
            } dispose: { _ in } workFinished: { rejected.fulfill() }
            XCTFail("Expected a busy route")
        } catch { XCTAssertEqual((error as NSError).code, AudioSetupActivity.busyError.code) }
        await fulfillment(of: [rejected], timeout: 1)
        release.signal()
        await fulfillment(of: [closing], timeout: 2)
        XCTAssertFalse(AudioSetupActivity.begin(), "Closing still owns the input route")
        cleanupRelease.signal()
        await fulfillment(of: [finished], timeout: 2)
        let replacement = try await AudioSetupOperation<Int>.run(timeout: 1) { _ in 3 } dispose: { _ in }
        XCTAssertEqual(replacement, 3)
        XCTAssertFalse(AudioSetupActivity.isActive)
    }
}

private final class DisposalState: @unchecked Sendable {
    private let lock = NSLock()
    private var disposed = false
    var isDisposed: Bool { lock.withLock { disposed } }
    func markDisposed() { lock.withLock { disposed = true } }
}
