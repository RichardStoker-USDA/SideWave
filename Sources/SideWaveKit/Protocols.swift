// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

// The four seams of the engine. Each subsystem lives behind one of these;
// SessionController talks to nothing else. Implementations get replaced,
// not patched around.

/// Delivers 16kHz mono float samples from an input device, chosen fresh at
/// every session start against the CURRENT device list (no cached binding
/// survives a dock change).
public protocol AudioSource: Sendable {
    /// Begin capture. Returns the resolved device's human name so the
    /// session can narrate an honest fallback ("Scarlett isn't connected.
    /// Using MacBook Pro Microphone"). `onSamples` is called from the
    /// capture thread in stream order.
    func start(preferredDeviceUID: String?, onSamples: @escaping @Sendable ([Float]) -> Void) async throws -> String
    /// End capture and release the device. Must be safe to call at any
    /// time, including before a successful start and more than once.
    func stop() async
}

/// Speech-to-text over a live sample stream. One long-lived object holding
/// loaded models; begin/finish bracket each session.
public protocol Recognizer: Sendable {
    /// Start a session. Returns the update stream for THIS session; the
    /// stream finishes when the session does.
    func begin() async throws -> AsyncStream<RecognizerUpdate>
    /// Feed 16kHz mono samples, in order.
    func feed(_ samples: [Float]) async
    /// Drain buffered audio, apply the evidence gates, and return the final
    /// transcript. Empty string when the gates dropped the session.
    func finish() async -> String
    /// Discard the session without a transcript. Must be safe to call at
    /// any time, including mid-begin and more than once.
    func abandon() async
}

/// One session's transcript, single confident stream. `settled` text never
/// retracts; `settling` is the newest chunk still styled as provisional.
public enum RecognizerUpdate: Sendable, Equatable {
    case transcript(settled: String, settling: String)
    /// An evidence gate suppressed content (VAD saw no speech, phantom
    /// token filtered). Surfaced so the session can narrate honestly.
    case suppressed(reason: String)
}

/// Text cleanup. One protocol over Apple Intelligence and Gemma; prompts
/// are the verified library carried from the original app.
public protocol Refiner: Sendable {
    var isReady: Bool { get async }
    func refine(_ text: String, context: String) async throws -> String
}

/// Puts text into the target app. The carried cascade with explicit-flags
/// hygiene on every synthesized event.
public protocol Paster: Sendable {
    func paste(_ text: String, targetPID: pid_t?) async -> PasteResult
}

public enum PasteResult: Sendable, Equatable {
    case verified
    case assumed
    case failed(reason: String)
}
