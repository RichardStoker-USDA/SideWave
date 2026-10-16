// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Turns the engine's running transcript into the overlay's two-part
/// stream: `settled` text that will not change, and the newest `settling`
/// tail styled as provisional for one beat.
///
/// Nemotron's cache-aware streaming never retracts an emitted token, so
/// this is presentation, not reconciliation: each partial is the previous
/// text plus a suffix, the suffix shows as settling, and the next partial
/// folds it into settled. The whole gray-draft/white-confirm apparatus of
/// the dual-engine design is gone by construction.
struct TranscriptAssembly: Sendable {

    private(set) var full: String = ""

    /// Ingest a running-transcript update. Returns nil when nothing
    /// changed (the engine re-reported the same text).
    mutating func ingest(_ newFull: String) -> (settled: String, settling: String)? {
        guard newFull != full else { return nil }
        let previous = full
        full = newFull
        if newFull.hasPrefix(previous) {
            return (previous, String(newFull.dropFirst(previous.count)))
        }
        // A non-append update should not happen with a never-retract
        // engine. If it ever does, present everything as settled rather
        // than claim stability the engine didn't give us.
        return (newFull, "")
    }

    /// Everything settles at session end.
    mutating func finalize(_ finalText: String) -> (settled: String, settling: String) {
        full = finalText
        return (finalText, "")
    }

    mutating func reset() {
        full = ""
    }
}
