// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

/// Keeps an asynchronous microphone start exclusive until it has unwound.
/// Cancellation invalidates callbacks without allowing another start to
/// reuse an engine that is still being prepared.
struct CaptureStartState {
    private(set) var isStarting = false
    private var generation: UInt64 = 0
    private var isCancelled = false

    mutating func begin() -> UInt64? {
        guard !isStarting else { return nil }
        generation &+= 1
        isStarting = true
        isCancelled = false
        return generation
    }

    func accepts(_ attempt: UInt64) -> Bool {
        generation == attempt && !isCancelled
    }

    mutating func cancel() {
        isCancelled = true
    }

    mutating func finish(_ attempt: UInt64) {
        guard generation == attempt else { return }
        isStarting = false
    }
}
