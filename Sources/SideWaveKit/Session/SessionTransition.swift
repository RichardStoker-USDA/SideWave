// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// The pure transition function for the session state machine, separated
/// from SessionController so every case can be covered by a table test.
public enum SessionTransition {

    /// What the controller must do in response to an event, beyond moving
    /// to the new state. Effects are descriptions; the controller performs
    /// them. Keeping them as values makes the whole machine table-testable.
    public enum Effect: Equatable, Sendable {
        /// Begin audio capture + engine bring-up.
        case beginStart
        /// Note a stop for when the engine reaches live. A stop during
        /// .starting never tears anything down directly.
        case queueStop
        /// Run the drain -> finalize -> refine tail -> paste pipeline.
        case beginStop
        /// Tear down without pasting; save to history when asked.
        case beginCancel(save: Bool)
        /// Surface a failure to the user (toast + sound) and clean up.
        case surfaceFailure(reason: String)
        /// Release capture resources; session fully over.
        case cleanup
        /// A queued stop was waiting when the engine went live: enter
        /// live and immediately begin the stop pipeline (the user's
        /// early tap is honored, their buffered words still process).
        case beginStopForQueuedRequest
    }

    public struct Result: Equatable, Sendable {
        public let state: SessionState
        public let effects: [Effect]
        public init(_ state: SessionState, _ effects: [Effect] = []) {
            self.state = state
            self.effects = effects
        }
    }

    /// Total transition function. `stopQueued` is the one piece of context
    /// beyond the state itself (whether a stop request arrived during
    /// .starting); the controller owns that flag and passes it in.
    public static func apply(
        _ event: SessionEvent,
        to state: SessionState,
        stopQueued: Bool,
        now: ContinuousClock.Instant
    ) -> Result {
        switch (state, event) {

        // MARK: idle
        case (.idle, .startRequested):
            return Result(.starting(since: now), [.beginStart])
        case (.idle, _):
            // Stray events after cleanup (late engine callbacks, double
            // releases) are no-ops by design.
            return Result(.idle)

        // MARK: starting
        case (.starting, .engineLive) where stopQueued:
            return Result(.stopping(since: now), [.beginStopForQueuedRequest])
        case (.starting(let since), .engineLive):
            _ = since
            return Result(.live(since: now))
        case (.starting(let since), .stopRequested):
            // Queue it. The session that hasn't started cannot be stopped —
            // only remembered. This is what makes an early release or a
            // fast second tap non-destructive on slow starts.
            return Result(.starting(since: since), [.queueStop])
        case (.starting, .cancelRequested(let save)):
            return Result(.stopping(since: now), [.beginCancel(save: save)])
        case (.starting, .failed(let reason)):
            return Result(.idle, [.surfaceFailure(reason: reason), .cleanup])
        case (.starting(let since), .startRequested):
            // Repeat start while starting: ignore (the press that created
            // this session already owns it).
            return Result(.starting(since: since))
        case (.starting(let since), .finished):
            // Can't finish what never ran; log-worthy but harmless.
            return Result(.starting(since: since))

        // MARK: live
        case (.live, .stopRequested):
            return Result(.stopping(since: now), [.beginStop])
        case (.live, .cancelRequested(let save)):
            return Result(.stopping(since: now), [.beginCancel(save: save)])
        case (.live, .failed(let reason)):
            return Result(.idle, [.surfaceFailure(reason: reason), .cleanup])
        case (.live(let since), .startRequested):
            // A start on a live session is the toggle-stop gesture at the
            // AppShell layer; by the time it reaches the machine it must
            // already be a stopRequested. Reaching here is a shell bug;
            // stay live.
            return Result(.live(since: since))
        case (.live(let since), .engineLive):
            return Result(.live(since: since))
        case (.live(let since), .finished):
            return Result(.live(since: since))

        // MARK: stopping
        case (.stopping, .finished):
            return Result(.idle, [.cleanup])
        case (.stopping, .failed(let reason)):
            // Failure mid-drain still ends the session; the pipeline saves
            // what it had to history before surfacing.
            return Result(.idle, [.surfaceFailure(reason: reason), .cleanup])
        case (.stopping(let since), _):
            // Starts, stops, cancels, engine callbacks during teardown all
            // wait for idle. Nothing interrupts a drain.
            return Result(.stopping(since: since))
        }
    }
}
