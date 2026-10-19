// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import os

/// Records every paste attempt to a JSON-lines log file so failures can be
/// diagnosed after the fact. The intermittent "dictation finished but the
/// text never reached my target window" symptom is hard to debug without a
/// per-attempt record of which fallback layer ran and whether the system
/// reported success at each step.
///
/// File: ~/Library/Application Support/SideWave/paste_trace.jsonl
/// Owner read/write only (0600), capped at 200 entries (oldest dropped). Surfaced via a "Show Paste Log" button in Settings →
/// Audio → Advanced → Diagnostics.
enum PasteTracer {
    private static let maxEntries: Int = 200
    private static let queue = DispatchQueue(label: "com.sidewave.paste-tracer", qos: .utility)
    private static let logger = Logger(subsystem: "com.sidewave.dev", category: "paste-trace")

    /// UserDefaults key. Default is OFF (privacy-respecting). User opts
    /// in through Settings → Audio & Speech → Advanced when they need to
    /// diagnose a paste failure.
    static let enabledKey = "pasteLogEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        // Off → also wipe any existing log so disabling actually clears
        // the user's history of paste activity, not just stops new
        // entries from being added.
        if !enabled {
            clear()
        }
    }

    /// One paste attempt: the lifetime of `typeTextInstantly` plus the
    /// cascade of fallback layers it dispatches into.
    struct Trace: Codable, Sendable {
        let timestamp: Date
        let targetPID: Int32
        let targetApp: String
        let textLength: Int
        /// Ordered list of methods tried, one per attempt. The last one is
        /// the path the cascade settled on.
        let attempts: [String]
        /// The last attempt method that ran (e.g. "clipboard-pid-electron").
        let outcome: String
        /// Final tri-state verdict from paste verification: "verified",
        /// "assumed", "failed", or "blocked-secure-input". This is the field
        /// to read when diagnosing a silent-fail: "assumed" means we couldn't
        /// confirm the text landed, "failed" means AX said it didn't.
        let verdict: String

        enum CodingKeys: String, CodingKey {
            case timestamp, targetPID, targetApp, textLength
            case attempts, outcome, verdict
        }
    }

    /// Append one trace entry. Thread-safe; the JSON encode + file append
    /// runs on a serial utility queue so the calling thread isn't blocked.
    /// No-op when the user hasn't opted in via Settings.
    static func record(_ trace: Trace) {
        guard isEnabled else { return }
        queue.async {
            do {
                let dir = applicationSupportDir()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("paste_trace.jsonl")
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(trace)
                guard var line = String(data: data, encoding: .utf8) else { return }
                line += "\n"

                let existed = FileManager.default.fileExists(atPath: url.path)
                if !existed {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()

                trimIfNeeded(url: url)
                logger.info("paste outcome=\(trace.outcome, privacy: .public) verdict=\(trace.verdict, privacy: .public) target=\(trace.targetApp, privacy: .public)")
            } catch {
                SWLog.note("[PasteTracer] Failed to write trace: \(error.localizedDescription)")
            }
        }
    }

    /// Path to the trace file, even if it doesn't exist yet. Used by the
    /// Settings UI to reveal the file in Finder.
    static func traceFileURL() -> URL {
        applicationSupportDir().appendingPathComponent("paste_trace.jsonl")
    }

    /// Erase the trace log on demand. Useful when reproducing a specific
    /// failure; clear, repro, share.
    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: traceFileURL())
        }
    }

    private static func applicationSupportDir() -> URL {
        AppPaths.applicationSupportDirectory()
    }

    /// Cap the file at maxEntries lines by reading and rewriting.
    /// Performance: only runs after a write; reads at most ~200 lines of
    /// JSON per write. Negligible disk overhead.
    private static func trimIfNeeded(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxEntries else { return }
        let kept = lines.suffix(maxEntries).joined(separator: "\n") + "\n"
        // Write in-place without atomic umask reset, maintaining owner-only permissions.
        try? kept.write(to: url, atomically: false, encoding: .utf8)
    }
}
