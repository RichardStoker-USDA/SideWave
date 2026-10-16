// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Classifies the hotkey gesture, as in the original app, where
/// SmartPTTClassifierTests covers it: the
/// push-to-talk hold is measured from the moment recording went LIVE,
/// never from key-down, so time spent waiting on a slow engine start is
/// waiting, not intent. No engine confirmation means no PTT, ever.
public enum GestureClassifier {

    /// True when a release should fire as push-to-talk (stop and paste)
    /// rather than remain a toggle.
    public static func pttHoldSatisfied(
        now: TimeInterval,
        pressDown: TimeInterval,
        engineLiveAt: TimeInterval,
        threshold: TimeInterval
    ) -> Bool {
        guard pressDown > 0, engineLiveAt > 0 else { return false }
        return now - max(pressDown, engineLiveAt) >= threshold
    }

    /// Default hold threshold past engine-live. Matches Apple's long-press
    /// timing; relaxed toggle taps stay under it, and a spoken word cannot
    /// finish faster.
    public static let defaultThreshold: TimeInterval = 0.5
}
