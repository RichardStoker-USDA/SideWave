// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Carbon
import Foundation
import os
import Synchronization

extension PasteEngine {
    // MARK: - App-Specific Relay Injection

    /// Inserts and submits text in the target with the most reliable method, for relay mode.
    /// Terminal and iTerm2 use AppleScript, which writes to the shell directly without focus.
    /// Returns false when the caller should use the normal paste and then Return.
    func injectAndSubmit(_ text: String, targetPID: pid_t?, windowTitle: String? = nil) async -> Bool {
        guard let pid = targetPID, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return false }

        let bundleID = app.bundleIdentifier ?? ""
        let capturedTitle = windowTitle

        switch bundleID {
        case "com.apple.Terminal":
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(returning: injectViaTerminal(text, windowTitle: capturedTitle))
                }
            }
        case "com.googlecode.iterm2":
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(returning: injectViaiTerm2(text, windowTitle: capturedTitle))
                }
            }
        default:
            return false  // Caller handles paste + Enter
        }
    }

    // MARK: - Terminal.app AppleScript

    /// Writes text to Terminal with AppleScript `do script`, which adds the newline and needs no
    /// focus. Targets the window named `windowTitle`, or the front window.
    private func injectViaTerminal(_ text: String, windowTitle: String? = nil) -> Bool {
        let escaped = escapeForAppleScript(text)

        // The named window if there is one, otherwise the front window.
        let windowTarget: String
        if let title = windowTitle {
            let escapedTitle = escapeForAppleScript(title)
            windowTarget = "window \"\(escapedTitle)\""
        } else {
            windowTarget = "front window"
        }

        let script = """
        tell application "Terminal"
            do script "\(escaped)" in \(windowTarget)
        end tell
        """

        // No retry in the front window on failure. Terminal titles change with the running command,
        // and a timed-out Apple event can still run later, so retrying could run the command in the
        // wrong window or twice. Return false and let the caller paste normally, which never
        // submits blindly.
        return executeAppleScript(script)
    }

    // MARK: - iTerm2 AppleScript

    /// Writes text to iTerm2 with AppleScript `write text`, which adds the newline and needs no
    /// focus. Targets the window named `windowTitle`, or the current window.
    private func injectViaiTerm2(_ text: String, windowTitle: String? = nil) -> Bool {
        let escaped = escapeForAppleScript(text)

        // The named window if there is one.
        let windowTarget: String
        if let title = windowTitle {
            let escapedTitle = escapeForAppleScript(title)
            windowTarget = "window \"\(escapedTitle)\""
        } else {
            windowTarget = "current window"
        }

        let script = """
        tell application "iTerm2"
            tell current session of \(windowTarget)
                write text "\(escaped)"
            end tell
        end tell
        """

        // No retry in the current window on failure, for the same reason as injectViaTerminal.
        return executeAppleScript(script)
    }

    /// Escapes text for an AppleScript string sent to a terminal. Newlines matter most: AppleScript turns
    /// `\n` back into a real newline, and a newline runs the next line as a separate command, so every
    /// newline becomes a space first. Then backslashes, then quotes, are escaped. Internal for tests.
    func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - AppleScript Executor

    /// Execute an AppleScript string. Returns true on success.
    /// Must be called from a background thread (not main) to avoid UI blocking.
    /// The caller (injectAndSubmit) handles dispatching off-main via async continuation.
    private func executeAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            print("[PasteEngine] AppleScript error: \(error)")
            return false
        }
        return true
    }
}
