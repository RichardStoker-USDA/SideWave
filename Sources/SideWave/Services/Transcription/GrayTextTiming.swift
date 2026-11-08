// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import os

/// Per-dictation timing of the gray text: when the streaming model was attached, when its first
/// words arrived and were shown, and how far its words trailed the audio. Logged once at stop in
/// the release-visible `recognition` category, as numbers only.
struct GrayTextTiming {
    private(set) var pressedAt: Double = 0
    private(set) var startedAt: Double = 0
    private(set) var firstAudioAt: Double?
    private(set) var mainThreadStallMs = 0
    private(set) var mainThreadStallAt: Double?
    private(set) var attachedAt: Double?
    private(set) var firstWordsAt: Double?
    private(set) var firstShownAt: Double?
    private(set) var behindMs: [Int] = []
    private(set) var heldUpdates = 0

    /// `pressedAt` is the hotkey press, `startedAt` when the speech pipeline began starting.
    init(pressedAt: Double? = nil, startedAt: Double = 0) {
        // A press from a start that was turned away doesn't belong to this one.
        if let pressedAt, pressedAt <= startedAt, startedAt - pressedAt < 30 {
            self.pressedAt = pressedAt
        } else {
            self.pressedAt = startedAt
        }
        self.startedAt = startedAt
    }

    mutating func attached(at time: Double) { if attachedAt == nil { attachedAt = time } }

    mutating func firstAudio(at time: Double) { if firstAudioAt == nil, time > 0 { firstAudioAt = time } }

    /// The main thread was busy for `seconds` from `time`; while it is, the preview can't change.
    mutating func mainThreadDelay(_ seconds: Double, at time: Double) {
        let ms = Int((seconds * 1000).rounded())
        if ms > mainThreadStallMs { mainThreadStallMs = ms; mainThreadStallAt = time }
    }

    /// One streaming update. `heardAt` is when the audio behind it was captured (0 if unknown);
    /// `shown` is whether any of its words reached the preview, `held` whether the ghost gate kept
    /// some back.
    mutating func update(at time: Double, heardAt: Double, hasWords: Bool, shown: Bool, held: Bool) {
        if hasWords, firstWordsAt == nil { firstWordsAt = time }
        if shown, firstShownAt == nil { firstShownAt = time }
        if heardAt > 0 { behindMs.append(max(0, Int(((time - heardAt) * 1000).rounded()))) }
        if held { heldUpdates += 1 }
    }

    var summary: String {
        func since(_ time: Double?) -> String { time.map { "\(Int((($0 - pressedAt) * 1000).rounded())) ms" } ?? "never" }
        let sorted = behindMs.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        return "Gray text after the hotkey: pipeline start \(since(startedAt)), first audio \(since(firstAudioAt)), model attached \(since(attachedAt)), first words \(since(firstWordsAt)), first shown \(since(firstShownAt)); behind the audio p95 \(p95) ms, max \(sorted.last ?? 0) ms over \(sorted.count) updates; \(heldUpdates) held by the ghost gate; main thread longest stall \(mainThreadStallMs) ms at \(since(mainThreadStallAt))"
    }

    func log() {
        GhostWordFilter.log.notice("\(summary, privacy: .public)")
    }
}
