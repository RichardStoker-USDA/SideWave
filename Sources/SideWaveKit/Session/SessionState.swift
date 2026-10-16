// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// The dictation session state machine. Everything reads session state from here; nothing keeps its
/// own recording flags. The original app spread this across flags in three types, and races between
/// them ended sessions as they started or applied a stop to the wrong session. Here a transition
/// either exists below or can't happen.
public enum SessionState: Equatable, Sendable {
    /// No session. The only state that accepts a start.
    case idle

    /// Start accepted: capture began on the press while engines bind and load. A stop request now
    /// is queued (SessionPhaseTransition.queuedStop), so it can't end a session before its first
    /// live frame.
    case starting(since: ContinuousClock.Instant)

    /// Engines live, audio flowing, transcript assembling.
    case live(since: ContinuousClock.Instant)

    /// Stop accepted: draining audio, finalizing segments, refining the
    /// tail, pasting. New starts are refused until idle.
    case stopping(since: ContinuousClock.Instant)

    public var isActive: Bool {
        switch self {
        case .idle: return false
        case .starting, .live, .stopping: return true
        }
    }

    public var acceptsStart: Bool { self == .idle }

    /// Whether a stop request acts now (live) or queues (starting).
    public var acceptsImmediateStop: Bool {
        if case .live = self { return true }
        return false
    }
}

/// The complete transition table. SessionController applies these and logs
/// each with its trigger; anything not representable here is a programmer
/// error surfaced in DEBUG, a no-op in release.
public enum SessionEvent: Equatable, Sendable {
    /// User gesture asked for a session (tap or PTT press).
    case startRequested
    /// Engines reported live (first audio frame through the recognizer).
    case engineLive
    /// User gesture asked to finish and paste (tap again / PTT release).
    case stopRequested
    /// User asked to discard (Ctrl+Escape) or park (Escape).
    case cancelRequested(save: Bool)
    /// Engine failure or audio loss; carries a user-facing reason.
    case failed(reason: String)
    /// Drain/refine/paste finished; back to idle.
    case finished
}
