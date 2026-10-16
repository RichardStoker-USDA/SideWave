// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import os

/// Owns the session state machine and performs its effects. This is the
/// ONLY place a session starts, stops, or fails; the shell sends gestures
/// in, signals come out, and every transition is narrated to the unified
/// log with the event that caused it.
///
/// Subsystems are injected behind the four protocols, so the whole
/// controller is exercised by unit tests with mocks: effect ordering,
/// the queued-stop path, failure surfacing, cancellation overlap.
public actor SessionController {

    // MARK: State

    private var state: SessionState = .idle
    /// The one piece of transition context beyond the state itself:
    /// whether a stop request arrived while the engine was still starting.
    private var stopQueued = false

    // MARK: Subsystems

    private let audio: any AudioSource
    private let recognizer: any Recognizer
    private let refiner: (any Refiner)?
    private let paster: any Paster

    // MARK: Output

    /// Single-consumer stream of everything that happens. The shell owns
    /// the consuming task for the app's lifetime.
    public nonisolated let signals: AsyncStream<SessionSignal>
    private nonisolated let signalOut: AsyncStream<SessionSignal>.Continuation

    // MARK: Per-session working state

    private var config = SessionConfiguration()
    private var startedAt: ContinuousClock.Instant?
    private var sampleFeed: AsyncStream<[Float]>.Continuation?
    private var startTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var startWatchdog: Task<Void, Never>?
    private var drainWatchdog: Task<Void, Never>?

    private let clock = ContinuousClock()
    private let log = Logger(subsystem: "com.sidewave.kit", category: "session")

    // MARK: Init

    public init(
        audio: any AudioSource,
        recognizer: any Recognizer,
        refiner: (any Refiner)?,
        paster: any Paster
    ) {
        self.audio = audio
        self.recognizer = recognizer
        self.refiner = refiner
        self.paster = paster
        let (stream, continuation) = AsyncStream<SessionSignal>.makeStream(bufferingPolicy: .unbounded)
        self.signals = stream
        self.signalOut = continuation
    }

    // MARK: Shell entry points (gestures only)

    public func requestStart(_ configuration: SessionConfiguration = SessionConfiguration()) {
        if state.acceptsStart {
            config = configuration
        }
        dispatch(.startRequested)
    }

    public func requestStop() {
        dispatch(.stopRequested)
    }

    public func requestCancel(save: Bool) {
        dispatch(.cancelRequested(save: save))
    }

    /// For the shell's subsystem watchers (device-set changes, engine
    /// death). Tears capture down deterministically, then surfaces the
    /// failure. A session already draining is left to its own pipeline.
    public func reportSubsystemFailure(reason: String) async {
        switch state {
        case .idle, .stopping:
            return
        case .starting, .live:
            await settleCapture()
            await recognizer.abandon()
            dispatch(.failed(reason: reason))
        }
    }

    /// Snapshot for gesture classification and UI state checks.
    public var currentState: SessionState { state }

    // MARK: The machine

    private func dispatch(_ event: SessionEvent) {
        let result = SessionTransition.apply(event, to: state, stopQueued: stopQueued, now: clock.now)
        let moved = result.state != state
        if moved || !result.effects.isEmpty {
            log.notice("session: \(String(describing: self.state), privacy: .public) -> \(String(describing: result.state), privacy: .public) on \(String(describing: event), privacy: .public) effects=\(String(describing: result.effects), privacy: .public)")
        }
        state = result.state
        if moved {
            signalOut.yield(.stateChanged(result.state, trigger: event))
        }
        // Leaving .starting for any reason ends the start watchdog. The
        // drain watchdog is ended only by cleanup, so stray events during
        // .stopping cannot disarm it.
        if case .starting = result.state {} else {
            startWatchdog?.cancel()
            startWatchdog = nil
        }
        for effect in result.effects {
            perform(effect)
        }
    }

    private func perform(_ effect: SessionTransition.Effect) {
        switch effect {
        case .beginStart:
            stopQueued = false
            startedAt = clock.now
            armStartWatchdog(after: config.startTimeout)
            startTask = Task { await self.performStart() }

        case .queueStop:
            stopQueued = true

        case .beginStop:
            armDrainWatchdog(after: config.drainTimeout)
            pipelineTask = Task { await self.performStop() }

        case .beginStopForQueuedRequest:
            stopQueued = false
            armDrainWatchdog(after: config.drainTimeout)
            pipelineTask = Task { await self.performStop() }

        case .beginCancel(let save):
            armDrainWatchdog(after: config.drainTimeout)
            pipelineTask = Task { await self.performCancel(save: save) }

        case .surfaceFailure(let reason):
            log.error("session failed: \(reason, privacy: .public)")
            signalOut.yield(.failed(reason: reason))

        case .cleanup:
            cleanup()
        }
    }

    // MARK: Effects

    /// Bring the engine up: recognizer session, then capture. The first
    /// sample buffer through the feed is the evidence that makes the
    /// session live; nothing is announced on hope.
    private func performStart() async {
        do {
            let updates = try await recognizer.begin()
            guard !Task.isCancelled else {
                await recognizer.abandon()
                return
            }

            updatesTask = Task { await self.pumpRecognizerUpdates(updates) }

            let (samples, feedIn) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
            sampleFeed = feedIn
            feedTask = Task { await self.pumpSamples(samples) }

            let deviceName = try await audio.start(preferredDeviceUID: config.preferredDeviceUID) { chunk in
                feedIn.yield(chunk)
            }
            if Task.isCancelled {
                await audio.stop()
                return
            }
            signalOut.yield(.deviceResolved(name: deviceName))
        } catch {
            guard !Task.isCancelled else { return }
            await recognizer.abandon()
            dispatch(.failed(reason: Self.friendlyStartFailure(error)))
        }
    }

    /// Single consumer of capture buffers: preserves sample order and
    /// turns the first buffer into the engine-live event.
    private func pumpSamples(_ samples: AsyncStream<[Float]>) async {
        var first = true
        for await chunk in samples {
            if first {
                first = false
                dispatch(.engineLive)
            }
            await recognizer.feed(chunk)
        }
    }

    private func pumpRecognizerUpdates(_ updates: AsyncStream<RecognizerUpdate>) async {
        for await update in updates {
            switch update {
            case .transcript(let settled, let settling):
                signalOut.yield(.transcript(settled: settled, settling: settling))
            case .suppressed(let reason):
                signalOut.yield(.suppressed(reason: reason))
            }
        }
    }

    /// Drain -> finalize -> refine -> paste. Refine failure never loses
    /// words: the raw transcript pastes instead. Every stage is timed and
    /// the breakdown logged, so "the stop felt slow" reports name their
    /// slow stage instead of guessing.
    private func performStop() async {
        let stopStarted = clock.now
        await settleCapture()
        let raw = await recognizer.finish()
        let drainDone = clock.now
        guard !Task.isCancelled else { return }

        var finalText = raw
        var refined = false
        if config.refineEnabled, let refiner, !raw.isEmpty {
            do {
                let candidate = try await refiner.refine(raw, context: config.refineContext)
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    finalText = trimmed
                    refined = true
                }
            } catch {
                log.error("refine failed, pasting raw: \(String(describing: error), privacy: .public)")
            }
        }
        let refineDone = clock.now
        guard !Task.isCancelled else { return }

        let delivery: SessionOutcome.Delivery
        if finalText.isEmpty {
            // Gates dropped everything (silence, noise). Nothing to paste;
            // the suppression reason already went out on the stream.
            delivery = .discarded
        } else {
            delivery = .pasted(await paster.paste(finalText, targetPID: config.targetPID))
        }
        let pasteDone = clock.now
        guard !Task.isCancelled else { return }

        log.notice("stop pipeline: drain=\((drainDone - stopStarted).formatted(), privacy: .public) refine=\((refineDone - drainDone).formatted(), privacy: .public) paste=\((pasteDone - refineDone).formatted(), privacy: .public)")
        finishSession(raw: raw, finalText: finalText, refined: refined, delivery: delivery)
    }

    private func performCancel(save: Bool) async {
        await settleCapture()
        if save {
            let raw = await recognizer.finish()
            guard !Task.isCancelled else { return }
            finishSession(raw: raw, finalText: raw, refined: false, delivery: .savedOnly)
        } else {
            await recognizer.abandon()
            guard !Task.isCancelled else { return }
            finishSession(raw: "", finalText: "", refined: false, delivery: .discarded)
        }
    }

    /// Stop capture and make sure every buffered sample reached the
    /// recognizer before anyone calls finish. Also unwinds a still-running
    /// start so a cancel mid-bring-up cannot leave the mic open.
    private func settleCapture() async {
        startTask?.cancel()
        await startTask?.value
        startTask = nil
        await audio.stop()
        sampleFeed?.finish()
        sampleFeed = nil
        await feedTask?.value
        feedTask = nil
    }

    private func finishSession(
        raw: String,
        finalText: String,
        refined: Bool,
        delivery: SessionOutcome.Delivery
    ) {
        let duration = startedAt.map { clock.now - $0 } ?? .zero
        signalOut.yield(
            .completed(
                SessionOutcome(
                    rawTranscript: raw,
                    finalText: finalText,
                    refined: refined,
                    delivery: delivery,
                    duration: duration
                )))
        dispatch(.finished)
    }

    private func cleanup() {
        startWatchdog?.cancel()
        startWatchdog = nil
        drainWatchdog?.cancel()
        drainWatchdog = nil
        startTask?.cancel()
        startTask = nil
        sampleFeed?.finish()
        sampleFeed = nil
        feedTask?.cancel()
        feedTask = nil
        updatesTask?.cancel()
        updatesTask = nil
        pipelineTask = nil
        stopQueued = false
        startedAt = nil
    }

    // MARK: Watchdogs

    private func armStartWatchdog(after timeout: Duration) {
        startWatchdog?.cancel()
        startWatchdog = Task {
            try? await self.clock.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self.startWatchdogExpired()
        }
    }

    private func startWatchdogExpired() async {
        guard case .starting = state else { return }
        await settleCapture()
        await recognizer.abandon()
        // Re-check: a queued stop's engineLive may have raced the teardown.
        guard case .starting = state else { return }
        dispatch(.failed(reason: "The dictation engine did not start in time. Check the microphone and try again."))
    }

    private func armDrainWatchdog(after timeout: Duration) {
        drainWatchdog?.cancel()
        drainWatchdog = Task {
            try? await self.clock.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self.drainWatchdogExpired()
        }
    }

    private func drainWatchdogExpired() async {
        guard case .stopping = state else { return }
        pipelineTask?.cancel()
        await recognizer.abandon()
        guard case .stopping = state else { return }
        dispatch(.failed(reason: "Finishing the dictation took too long. The transcript may be incomplete."))
    }

    // MARK: Failure wording

    private static func friendlyStartFailure(_ error: any Error) -> String {
        "Could not start dictation: \(error.localizedDescription)"
    }
}
