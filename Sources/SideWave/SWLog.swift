// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import os

/// Centralised OSLog handles for SideWave. Use with `OSSignposter(logHandle:)`
/// from each service so Instruments traces group by domain.
///
/// Signposts stay on in release builds; they cost almost nothing without Instruments attached.
/// Placement rules:
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

    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")

    /// A diagnostic line in the unified log. The text is private, so release logs redact it unless
    /// private data is enabled for the subsystem.
    static func note(_ message: String) {
        diagnostics.notice("\(message, privacy: .private)")
    }
}
