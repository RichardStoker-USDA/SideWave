// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Everything the shell needs to know about a session, in order, on one
/// stream. The controller emits these; the UI renders them. No other
/// channel exists between engine and shell.
public enum SessionSignal: Sendable, Equatable {
    /// The machine moved. Carries the event that moved it so logs and UI
    /// agree on why.
    case stateChanged(SessionState, trigger: SessionEvent)
    /// Capture bound to this device (human name, honest about fallback).
    case deviceResolved(name: String)
    /// Live transcript: settled text plus the still-settling tail.
    case transcript(settled: String, settling: String)
    /// An evidence gate dropped content and the user should know.
    case suppressed(reason: String)
    /// The session failed; reason is user-facing.
    case failed(reason: String)
    /// The session finished its pipeline. Terminal for that session.
    case completed(SessionOutcome)
}

/// What a finished session produced and where the text went.
public struct SessionOutcome: Sendable, Equatable {
    public enum Delivery: Sendable, Equatable {
        /// Ran the paste cascade; result says whether insertion verified.
        case pasted(PasteResult)
        /// Cancelled without saving (Ctrl+Escape).
        case discarded
        /// Cancelled but kept for history (Escape parks the transcript).
        case savedOnly
    }

    public let rawTranscript: String
    /// Refined text when refine ran, otherwise the raw transcript.
    public let finalText: String
    public let refined: Bool
    public let delivery: Delivery
    public let duration: Duration

    public init(
        rawTranscript: String,
        finalText: String,
        refined: Bool,
        delivery: Delivery,
        duration: Duration
    ) {
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.refined = refined
        self.delivery = delivery
        self.duration = duration
    }
}

/// Per-session knobs the shell passes at start. Everything else the
/// controller needs comes through its injected subsystems.
public struct SessionConfiguration: Sendable {
    /// Device UID to prefer; nil means system default. Resolved against
    /// the live device list at start, never cached across sessions.
    public var preferredDeviceUID: String?
    /// Run the refiner on the final transcript before pasting.
    public var refineEnabled: Bool
    /// Refiner context (active template guidance and vocabulary hints).
    public var refineContext: String
    /// App to paste into; nil pastes to the frontmost app.
    public var targetPID: pid_t?
    /// How long engine bring-up may take before the session fails honestly.
    public var startTimeout: Duration
    /// How long drain + refine + paste may take before the session fails.
    public var drainTimeout: Duration

    public init(
        preferredDeviceUID: String? = nil,
        refineEnabled: Bool = false,
        refineContext: String = "",
        targetPID: pid_t? = nil,
        startTimeout: Duration = .seconds(10),
        drainTimeout: Duration = .seconds(30)
    ) {
        self.preferredDeviceUID = preferredDeviceUID
        self.refineEnabled = refineEnabled
        self.refineContext = refineContext
        self.targetPID = targetPID
        self.startTimeout = startTimeout
        self.drainTimeout = drainTimeout
    }
}
