// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

/// Pointer animator for the gray-to-white effect. `advance(targetWords:at:)` adds
/// `dt / wordDuration` to `displayedPointer` and clamps it to the target, so fast speech leaves a
/// few gray words at the edge, a pause lets it catch up, and new speech restarts the chase.
///
/// Deliberately not `@Observable`: TimelineView drives redraws, and pointer updates must not
/// trigger extra SwiftUI updates. Held in `@State`, so the instance survives view rebuilds.
@MainActor
final class TdtTrailAnimator {
    /// Seconds per word of pointer movement, about 133 words a minute: slower than TDT's streaming,
    /// so the throttled CTC rescoring (every 1.5 s) usually lands before the pointer reaches a
    /// word. The pointer also stops at the TDT-confirmed edge.
    let wordDuration: TimeInterval = 0.450

    /// Current pointer position, in words. Words within `Animate.tdtTrailFadeWindow` of it are
    /// fading.

    private(set) var displayedPointer: Double = 0
    private var prevTickAt: TimeInterval = 0
    /// Last target, to detect a new session (target back to 0) and reset the pointer.
    private var lastTarget: Int = 0

    /// Moves the pointer one tick toward `targetWords`, the TDT-confirmed edge. `floorWords`, the
    /// confirmed word count, positions the pointer only on the first tick; later commits don't pull
    /// the pointer forward, so the rest of the text doesn't turn solid at once.
    func advance(targetWords: Int, floorWords: Int, at now: TimeInterval) -> Double {
        // Detect session reset: total word count fell from non-zero to
        // zero (StagedTranscript.reset() between sessions).
        if lastTarget > 0 && targetWords == 0 && floorWords == 0 {
            displayedPointer = 0
            prevTickAt = now
            lastTarget = 0
            return 0
        }
        lastTarget = targetWords

        let target = Double(max(0, targetWords))
        let floor = Double(max(0, floorWords))

        // First tick: start the clock and put the pointer at the confirmed count, so a view
        // recreated mid-session (resize, mode change) shows confirmed words white instead of
        // sweeping them again.
        if prevTickAt == 0 {
            prevTickAt = now
            displayedPointer = Self.nextPointer(
                current: displayedPointer,
                target: target,
                floor: floor,
                dt: 0,
                wordDuration: wordDuration,
                isFirstTick: true
            )
            return displayedPointer
        }
        let dt = max(0, now - prevTickAt)
        prevTickAt = now
        displayedPointer = Self.nextPointer(
            current: displayedPointer,
            target: target,
            floor: floor,
            dt: dt,
            wordDuration: wordDuration,
            isFirstTick: false
        )
        return displayedPointer
    }

    /// Pointer math, separate so `OverlayAlignmentTests` can check:
    /// - Constant pace: `dt / wordDuration` words per tick below the target; the floor never pulls it
    ///   forward.
    /// - Frame-rate independence: the same speed at 30 and 60 fps.
    /// - No retreat: if the target drops below the pointer, it holds instead of graying a white word.
    /// - The first tick starts at the floor, capped by the target.
    static func nextPointer(
        current: Double,
        target: Double,
        floor: Double,
        dt: Double,
        wordDuration: Double,
        isFirstTick: Bool
    ) -> Double {
        if isFirstTick {
            let anchor = max(current, floor)
            // Never seat past the TDT-confident edge. `target` is >=
            // `floor` in normal operation; the max guards the degenerate
            // case so the anchor can't fall below the confirmed floor.
            return min(anchor, max(target, floor))
        }
        let step = wordDuration > 0 ? max(0, dt) / wordDuration : 0
        let proposed = current + step
        // Cap at the TDT-confident edge on the way up; hold (never
        // retreat) if the edge sits behind us.
        let capped = min(proposed, target)
        return max(capped, current)
    }
}

/// Keeps the text of in-progress words the pointer has already passed, so the leading edge stops
/// jumping. Streaming revisions and re-alignment then change only the gray words ahead of the
/// pointer, never words the user already saw turn white.
///
/// Keyed by absolute word index. When a commit grows the confirmed zone, the frozen words become
/// confirmed words, so the freeze is dropped and re-keyed. The frozen indices are always contiguous.
///
/// Held in `@State` and updated inside TimelineView like `TdtTrailAnimator`; not `@Observable`.
@MainActor
final class InProgressTextLock {
    private var locked: [Int: String] = [:]
    private var epoch: Int = -1

    func reset() {
        locked.removeAll(keepingCapacity: true)
        epoch = -1
    }

    func apply(
        words: [DictationOverlayContent.DisplayWord],
        confirmedTdtCount: Int,
        pointer: Double,
        fadeWindow: Double
    ) -> [DictationOverlayContent.DisplayWord] {
        // Session reset: everything cleared and the pointer back at 0. Drop all freezes so the next
        // session starts clean. A brief empty moment mid-segment, with the pointer still advanced,
        // keeps them.
        if confirmedTdtCount == 0 && words.isEmpty && pointer <= 0 {
            locked.removeAll(keepingCapacity: true)
            epoch = 0
            return words
        }

        // A commit rebuilt the confirmed zone and the frozen words are now confirmed, so drop the
        // freeze and re-key to the new count.
        if confirmedTdtCount != epoch {
            locked.removeAll(keepingCapacity: true)
            epoch = confirmedTdtCount
        }

        var out = words

        // Freeze / restore the engaged prefix of the in-progress zone.
        var i = confirmedTdtCount
        while i < out.count {
            let progress = DictationOverlayContent.wordProgress(wordIndex: i, pointer: pointer, fadeWindow: fadeWindow)
            if progress > 0 {
                if let frozen = locked[i] {
                    out[i] = DictationOverlayContent.DisplayWord(
                        text: frozen,
                        tdtText: nil,
                        isRefined: out[i].isRefined,
                        trailingSpace: out[i].trailingSpace,
                        refinedAt: out[i].refinedAt,
                        wordIndexInSpan: out[i].wordIndexInSpan
                    )
                } else {
                    locked[i] = DictationOverlayContent.displayText(out[i], progress: progress)
                }
            }
            i += 1
        }

        // Put back any passed word the latest layout dropped, so a white word never disappears. The
        // highest index comes from the stored freezes, because the dropped word isn't in this
        // frame's list. The indices are contiguous, so appending the range is safe.
        let maxLockedIdx = locked.keys.max() ?? (confirmedTdtCount - 1)
        if maxLockedIdx >= out.count {
            var k = out.count
            while k <= maxLockedIdx {
                // Only restore frozen words the pointer still covers.
                if let frozen = locked[k], Double(k) < pointer {
                    out.append(DictationOverlayContent.DisplayWord(
                        text: frozen,
                        tdtText: nil,
                        isRefined: false,
                        trailingSpace: true,
                        refinedAt: nil,
                        wordIndexInSpan: k - confirmedTdtCount
                    ))
                }
                k += 1
            }
        }

        // Trailing space belongs to every word except the last.
        if !out.isEmpty {
            for idx in out.indices {
                let shouldHaveSpace = idx != out.count - 1
                if out[idx].trailingSpace != shouldHaveSpace {
                    out[idx] = DictationOverlayContent.DisplayWord(
                        text: out[idx].text,
                        tdtText: out[idx].tdtText,
                        isRefined: out[idx].isRefined,
                        trailingSpace: shouldHaveSpace,
                        refinedAt: out[idx].refinedAt,
                        wordIndexInSpan: out[idx].wordIndexInSpan
                    )
                }
            }
        }
        return out
    }
}
