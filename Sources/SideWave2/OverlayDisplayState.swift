// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Everything the overlay draws, as one value. The view is a pure
/// function of this state, which is what lets the render harness draw
/// every overlay situation to a PNG without a live session.
struct OverlayDisplayState: Equatable {

    enum Phase: Equatable {
        case starting
        case live
        /// Draining and (optionally) refining before the paste.
        case finishing(refining: Bool)
        /// Terminal flash before the panel slips away.
        case done(Outcome)
    }

    enum Outcome: Equatable {
        case pasted
        case savedToHistory
        /// Gates dropped the session or something failed; message shows.
        case notice(String)
    }

    /// Which palette the wave strands wear while refining.
    enum RefinePalette: Equatable {
        case appleIntelligence
        case gemma
    }

    var phase: Phase = .starting
    var settledText: String = ""
    var settlingText: String = ""
    /// Bumps on every transcript update; the strands surge briefly.
    var activityPulse: Int = 0
    /// The hold crossed the live-anchored threshold: releasing sends.
    var pttEngaged: Bool = false
    /// Compact keycap glyph for the hint ("⌥").
    var hotkeyGlyph: String = "⌥"
    var refinePalette: RefinePalette = .appleIntelligence
    /// Set when capture bound somewhere unexpected ("MacBook Pro
    /// Microphone" while a Scarlett was preferred) so the session says so.
    var deviceNotice: String?

    var hasTranscript: Bool { !settledText.isEmpty || !settlingText.isEmpty }
}
