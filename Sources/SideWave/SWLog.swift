// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import os

/// Centralised OSLog handles for SideWave. Use with `OSSignposter(logHandle:)`
/// from each service so Instruments traces group by domain.
///
/// Signposts are always live (≤5ns compare-and-branch when no tool is attached)
/// so there's no `#if DEBUG` gating. Placement rules:
/// - No signposts in the audio tap callback
/// - No signposts in `convertToMono16k` or per-sample loops
/// - No signposts in the per-cycle polling loop body (only its contained calls)
/// - Sample high-frequency point events (e.g. streaming chunks) 1-in-10
enum SWLog {
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.sidewave.app"
    static let dictation: OSLog = OSLog(subsystem: subsystem, category: "dictation")
    static let transcription: OSLog = OSLog(subsystem: subsystem, category: "transcription")
    static let cleanup: OSLog = OSLog(subsystem: subsystem, category: "cleanup")
    static let paste: OSLog = OSLog(subsystem: subsystem, category: "paste")
}
