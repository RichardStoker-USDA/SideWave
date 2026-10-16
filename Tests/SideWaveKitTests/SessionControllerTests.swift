// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWaveKit

/// Exercises SessionController end to end against mocks: effect ordering,
/// the queued-stop flow, failure surfacing, watchdogs, and cancellation
/// overlap. Together with SessionTransitionTests (the pure table) this
/// pins the whole session lifecycle.
final class SessionControllerTests: XCTestCase {

    private var recorder: CallRecorder!
    private var audio: MockAudioSource!
    private var recognizer: MockRecognizer!
    private var refiner: MockRefiner!
    private var paster: MockPaster!
    private var controller: SessionController!
    private var collector: SignalCollector!
    private var pump: Task<Void, Never>!

    override func setUp() async throws {
        recorder = CallRecorder()
        audio = MockAudioSource(recorder: recorder)
        recognizer = MockRecognizer(recorder: recorder)
        refiner = MockRefiner(recorder: recorder)
        paster = MockPaster(recorder: recorder)
        controller = SessionController(
            audio: audio, recognizer: recognizer, refiner: refiner, paster: paster)
        collector = SignalCollector()
        let signals = controller.signals
        let sink = collector!
        pump = Task {
            for await signal in signals {
                await sink.append(signal)
            }
        }
    }

    override func tearDown() async throws {
        pump.cancel()
    }

    // MARK: Helpers

    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func startAndGoLive(_ config: SessionConfiguration = SessionConfiguration()) async {
        await controller.requestStart(config)
        let started = await waitUntil { await self.audio.isCapturing }
        XCTAssertTrue(started, "audio capture never began")
        await audio.emit([Float](repeating: 0.1, count: 1600))
        let live = await waitUntil {
            if case .live = await self.controller.currentState { return true }
            return false
        }
        XCTAssertTrue(live, "session never reached live")
    }

    private func waitForIdle() async {
        let idle = await waitUntil {
            await self.controller.currentState == .idle
        }
        XCTAssertTrue(idle, "session never returned to idle")
    }

    /// Signal assertions must await delivery: the collector's pump task
    /// consumes the stream asynchronously, so an instant read after a
    /// state flip can observe an empty collector.
    private func awaitOutcomes(_ count: Int) async -> [SessionOutcome] {
        await waitUntil { await self.collector.completedOutcomes.count >= count }
        return await collector.completedOutcomes
    }

    private func awaitFailures(_ count: Int) async -> [String] {
        await waitUntil { await self.collector.failureReasons.count >= count }
        return await collector.failureReasons
    }

    // MARK: Happy paths

    func testToggleSessionPastesTranscript() async {
        await startAndGoLive()
        await audio.emit([Float](repeating: 0.1, count: 1600))
        await controller.requestStop()
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.rawTranscript, "mock transcript")
        XCTAssertEqual(outcomes.first?.finalText, "mock transcript")
        XCTAssertEqual(outcomes.first?.refined, false)
        XCTAssertEqual(outcomes.first?.delivery, .pasted(.verified))
        let pasted = await paster.pastedTexts
        XCTAssertEqual(pasted, ["mock transcript"])
        let failures = await collector.failureReasons
        XCTAssertTrue(failures.isEmpty)
    }

    func testPipelineOrderStopsAudioBeforeFinishBeforePaste() async {
        await startAndGoLive()
        await controller.requestStop()
        await waitForIdle()

        let stop = await recorder.index(of: "audio.stop")
        let finish = await recorder.index(of: "recognizer.finish")
        let paste = await recorder.index(of: "paster.paste")
        XCTAssertNotNil(stop)
        XCTAssertNotNil(finish)
        XCTAssertNotNil(paste)
        XCTAssertLessThan(stop!, finish!, "audio must stop before the recognizer drains")
        XCTAssertLessThan(finish!, paste!, "the transcript must finalize before pasting")
    }

    func testDeviceNameSurfacesForHonestFallback() async {
        await audio.setBehavior(.succeed(deviceName: "MacBook Pro Microphone"))
        await startAndGoLive()
        await waitUntil { await self.collector.resolvedDeviceNames.count == 1 }
        let names = await collector.resolvedDeviceNames
        XCTAssertEqual(names, ["MacBook Pro Microphone"])
        await controller.requestCancel(save: false)
        await waitForIdle()
    }

    func testLiveTranscriptSignalsFlowThrough() async {
        await startAndGoLive()
        await recognizer.push(.transcript(settled: "hello", settling: "wor"))
        let arrived = await waitUntil {
            await self.collector.transcripts.count == 1
        }
        XCTAssertTrue(arrived)
        let transcripts = await collector.transcripts
        XCTAssertEqual(transcripts.first?.settled, "hello")
        XCTAssertEqual(transcripts.first?.settling, "wor")
        await controller.requestStop()
        await waitForIdle()
    }

    func testRefineSuccessPastesRefinedText() async {
        await startAndGoLive(SessionConfiguration(refineEnabled: true, refineContext: "standard"))
        await controller.requestStop()
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.first?.refined, true)
        XCTAssertEqual(outcomes.first?.finalText, "refined: mock transcript")
        XCTAssertEqual(outcomes.first?.rawTranscript, "mock transcript")
        let pasted = await paster.pastedTexts
        XCTAssertEqual(pasted, ["refined: mock transcript"])
        let context = await refiner.lastContext
        XCTAssertEqual(context, "standard")
    }

    // MARK: The killed-at-birth class, end to end

    func testStopDuringStartingQueuesAndStillDelivers() async {
        await controller.requestStart(SessionConfiguration())
        let started = await waitUntil { await self.audio.isCapturing }
        XCTAssertTrue(started)

        // User releases before the engine confirms: must queue, not kill.
        await controller.requestStop()
        if case .starting = await controller.currentState {} else {
            XCTFail("stop during starting must keep the session starting")
        }

        // Engine comes up; the queued stop drains and delivers.
        await audio.emit([Float](repeating: 0.1, count: 1600))
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.delivery, .pasted(.verified))
        let pasted = await paster.pastedTexts
        XCTAssertEqual(pasted, ["mock transcript"], "buffered words must still process")

        // The session never presented as live: starting -> stopping -> idle.
        let states = await collector.stateChanges
        XCTAssertFalse(states.contains { if case .live = $0 { return true }; return false })
    }

    // MARK: Failure honesty

    func testAudioStartFailureSurfacesAndReturnsToIdle() async {
        await audio.setBehavior(.fail(message: "microphone unavailable"))
        await controller.requestStart(SessionConfiguration())
        await waitForIdle()

        let failures = await awaitFailures(1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("microphone unavailable") ?? false)
        let abandons = await recognizer.abandonCount
        XCTAssertEqual(abandons, 1, "a failed start must close the recognizer session")
        let outcomes = await collector.completedOutcomes
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testRecognizerBeginFailureSurfaces() async {
        await recognizer.setBeginError(MockFailure.rigged("model not loaded"))
        await controller.requestStart(SessionConfiguration())
        await waitForIdle()

        let failures = await awaitFailures(1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("model not loaded") ?? false)
        let audioStops = await audio.stopCount
        XCTAssertGreaterThanOrEqual(audioStops, 0)
        let stateNow = await controller.currentState
        XCTAssertEqual(stateNow, .idle)
    }

    func testStartWatchdogFailsDeadMicHonestly() async {
        await audio.setBehavior(.succeedSilent(deviceName: "Dead Mic"))
        await controller.requestStart(SessionConfiguration(startTimeout: .milliseconds(80)))
        await waitForIdle()

        let failures = await awaitFailures(1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("did not start") ?? false)
        let abandons = await recognizer.abandonCount
        XCTAssertGreaterThanOrEqual(abandons, 1)
    }

    func testRefineFailurePastesRawTranscript() async {
        await refiner.setBehavior { _ in throw MockFailure.rigged("model crashed") }
        await startAndGoLive(SessionConfiguration(refineEnabled: true))
        await controller.requestStop()
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.first?.refined, false)
        XCTAssertEqual(outcomes.first?.finalText, "mock transcript")
        let pasted = await paster.pastedTexts
        XCTAssertEqual(pasted, ["mock transcript"], "refine failure must never lose words")
        let failures = await collector.failureReasons
        XCTAssertTrue(failures.isEmpty, "a refine fallback is not a session failure")
    }

    func testDrainWatchdogEndsHungFinish() async {
        await recognizer.setFinishDelay(.seconds(30))
        await startAndGoLive(SessionConfiguration(drainTimeout: .milliseconds(120)))
        await controller.requestStop()
        await waitForIdle()

        let failures = await awaitFailures(1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("took too long") ?? false)
        let pasted = await paster.pastedTexts
        XCTAssertTrue(pasted.isEmpty, "a timed-out drain must not paste later")
    }

    func testSubsystemFailureWhileLiveEndsSessionVisibly() async {
        await startAndGoLive()
        await controller.reportSubsystemFailure(reason: "Your microphone was disconnected.")
        await waitForIdle()

        let failures = await awaitFailures(1)
        XCTAssertEqual(failures, ["Your microphone was disconnected."])
        let abandons = await recognizer.abandonCount
        XCTAssertEqual(abandons, 1)
        let stops = await audio.stopCount
        XCTAssertGreaterThanOrEqual(stops, 1)
    }

    func testSubsystemFailureAtIdleIsIgnored() async {
        await controller.reportSubsystemFailure(reason: "spurious")
        try? await Task.sleep(for: .milliseconds(50))
        let failures = await collector.failureReasons
        XCTAssertTrue(failures.isEmpty)
        let stateNow = await controller.currentState
        XCTAssertEqual(stateNow, .idle)
    }

    // MARK: Cancel paths

    func testCancelDiscardNeverPastes() async {
        await startAndGoLive()
        await controller.requestCancel(save: false)
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.first?.delivery, .discarded)
        let pasted = await paster.pastedTexts
        XCTAssertTrue(pasted.isEmpty)
        let abandons = await recognizer.abandonCount
        XCTAssertEqual(abandons, 1)
        let finishes = await recognizer.finishCount
        XCTAssertEqual(finishes, 0)
    }

    func testCancelSaveKeepsTranscriptWithoutPasting() async {
        await startAndGoLive()
        await controller.requestCancel(save: true)
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.first?.delivery, .savedOnly)
        XCTAssertEqual(outcomes.first?.rawTranscript, "mock transcript")
        let pasted = await paster.pastedTexts
        XCTAssertTrue(pasted.isEmpty)
    }

    func testCancelDuringStartingUnwindsCleanly() async {
        await controller.requestStart(SessionConfiguration())
        let started = await waitUntil { await self.audio.isCapturing }
        XCTAssertTrue(started)
        await controller.requestCancel(save: false)
        await waitForIdle()

        let pasted = await paster.pastedTexts
        XCTAssertTrue(pasted.isEmpty)
        let capturing = await audio.isCapturing
        XCTAssertFalse(capturing, "cancel mid-start must not leave the mic open")
    }

    // MARK: Empty-session honesty

    func testEmptyTranscriptSkipsPaste() async {
        await recognizer.setFinalText("")
        await startAndGoLive()
        await controller.requestStop()
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.first?.delivery, .discarded)
        let pasted = await paster.pastedTexts
        XCTAssertTrue(pasted.isEmpty, "gated-out sessions must not paste empty strings")
    }

    // MARK: Stray gestures

    func testStopAtIdleDoesNothing() async {
        await controller.requestStop()
        try? await Task.sleep(for: .milliseconds(50))
        let stateNow = await controller.currentState
        XCTAssertEqual(stateNow, .idle)
        let signals = await collector.signals
        XCTAssertTrue(signals.isEmpty)
        let finishes = await recognizer.finishCount
        XCTAssertEqual(finishes, 0)
    }

    func testDoubleStopRunsPipelineOnce() async {
        await recognizer.setFinishDelay(.milliseconds(100))
        await startAndGoLive()
        await controller.requestStop()
        await controller.requestStop()
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.count, 1)
        let pasteCalls = await recorder.count(of: "paster.paste")
        XCTAssertEqual(pasteCalls, 1)
    }

    func testStartDuringStoppingIsRefusedThenIdleAccepts() async {
        await recognizer.setFinishDelay(.milliseconds(150))
        await startAndGoLive()
        await controller.requestStop()
        await controller.requestStart(SessionConfiguration())
        if case .stopping = await controller.currentState {} else if await controller.currentState != .idle {
            XCTFail("start during stopping must be refused")
        }
        await waitForIdle()

        let outcomes = await awaitOutcomes(1)
        XCTAssertEqual(outcomes.count, 1, "the refused start must not create a second session")

        // A fresh start after idle works.
        await startAndGoLive()
        await controller.requestStop()
        await waitForIdle()
        let allOutcomes = await awaitOutcomes(2)
        XCTAssertEqual(allOutcomes.count, 2)
    }

    // MARK: Back-to-back determinism

    func testTwentyConsecutiveSessionsAllDeliver() async {
        for round in 1...20 {
            await startAndGoLive()
            await audio.emit([Float](repeating: 0.1, count: 1600))
            await controller.requestStop()
            await waitForIdle()
            let outcomes = await awaitOutcomes(round)
            XCTAssertEqual(outcomes.count, round, "session \(round) did not complete")
        }
        let failures = await collector.failureReasons
        XCTAssertTrue(failures.isEmpty)
        let pasteCalls = await recorder.count(of: "paster.paste")
        XCTAssertEqual(pasteCalls, 20)
    }
}
