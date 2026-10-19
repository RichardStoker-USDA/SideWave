// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Carbon
import Foundation
import os
import Synchronization

/// Result of a paste attempt, so callers can tell a real failure from an unconfirmed paste and decide
/// whether to auto-submit.
///
/// - verified: Accessibility confirmed the text is in the focused field.
/// - assumed: the event was sent but delivery couldn't be checked (no access, no readable value, or
///   web content). Treated as success to avoid pasting twice, but not trusted for an early Return.
/// - failed: every method ran and Accessibility reported nothing landed.
/// - blockedSecureInput: another process holds secure keyboard input, so synthetic key events are
///   dropped everywhere.
enum PasteOutcome: Sendable, Equatable {
    case verified
    case assumed
    case failed
    case blockedSecureInput

    /// True when the text is (probably) in the target. Drives the success
    /// chime + history vs. the error sound + failure toast in AppState.
    var landed: Bool {
        switch self {
        case .verified, .assumed: return true
        case .failed, .blockedSecureInput: return false
        }
    }

    /// Short label for the paste trace log.
    var traceLabel: String {
        switch self {
        case .verified: return "verified"
        case .assumed: return "assumed"
        case .failed: return "failed"
        case .blockedSecureInput: return "blocked-secure-input"
        }
    }
}

/// Result of a delivery check. Separate from PasteOutcome because "couldn't check" must not count
/// as "landed"; treating them the same hid real paste failures.
enum PasteVerification: Sendable, Equatable {
    case landed
    case notLanded
    case unverifiable
}

final class PasteEngine: @unchecked Sendable {
    /// Signposter for paste-path Instruments traces.
    nonisolated static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "com.sidewave.kit", category: "paste"))

    /// Shell hook: called when a paste is refused because Accessibility
    /// permission is missing, so the app can surface its own alert. The
    /// kit never presents UI.
    nonisolated(unsafe) static var onAccessibilityMissing: (@Sendable () -> Void)?

    private static let cgEventUnicodeLimit = 200

    /// The key code that types "v" on the current keyboard layout. Command-V is usually sent as key
    /// code 9, which is V only on QWERTY-style layouts; on Dvorak or AZERTY it's another letter and
    /// the paste never happens. Resolved once from the active layout and cached, with 9 as the
    /// fallback. Must resolve on the main thread: on macOS 27 the input-source API asserts its
    /// queue and crashes when first called from the paste queue. `warmUpKeyboardLayoutCache()`
    /// resolves it at launch. A first call off the main thread uses 9 rather than resolving inline
    /// or blocking on the main thread, which could deadlock.
    nonisolated(unsafe) private static var _vKeyCode: CGKeyCode?
    private static let vKeyCodeLock = NSLock()
    static var vKeyCode: CGKeyCode {
        vKeyCodeLock.lock()
        if let cached = _vKeyCode { vKeyCodeLock.unlock(); return cached }
        vKeyCodeLock.unlock()
        guard Thread.isMainThread else { return 9 }
        let resolved = resolveKeyCode(for: "v") ?? 9
        vKeyCodeLock.lock(); _vKeyCode = resolved; vKeyCodeLock.unlock()
        return resolved
    }

    /// Touch the layout-derived keycode cache from the main thread. Called at
    /// startup (AppState.startServices) so the TIS query runs where macOS 27
    /// requires it, long before any paste.
    static func warmUpKeyboardLayoutCache() {
        assert(Thread.isMainThread)
        _ = vKeyCode
    }

    /// How long the dictation stays on the clipboard before the user's clipboard is restored when
    /// delivery can't be confirmed. Electron apps can read the clipboard 100 to 300 ms after
    /// Command-V. The app can override it; 0 uses the default.
    nonisolated(unsafe) static var clipboardRestoreDelayOverrideMs: Int = 0
    static func clipboardRestoreDelayMs() -> Int {
        let v = clipboardRestoreDelayOverrideMs
        return v > 0 ? v : 600
    }

    // Thread-safe typing guard -- written from background queue, read from main thread
    private let isCurrentlyTyping = Mutex(false)

    struct TypingRequest: Sendable {
        let text: String
        let preferredTargetPID: pid_t?
        let appendTrailingSpace: Bool
        let completion: (@Sendable (PasteOutcome) -> Void)?
    }
    
    private let pendingRequests = Mutex<[TypingRequest]>([])

    /// Capture PID of the currently focused application.
    /// Tries the AX focused element first (most precise), then falls back to
    /// NSWorkspace.frontmostApplication if AX query fails (e.g., no text field focused).
    static func captureSystemFocusedPID() -> pid_t? {
        // Try AX focused element first
        if AXIsProcessTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedRef: CFTypeRef?

            let result = AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            )
            if result == .success, let focusedRef,
               CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
            {
                let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                if pid > 0 {
                    // Skip SideWave itself.
                    if let selfBundleID = Bundle.main.bundleIdentifier,
                       let app = NSRunningApplication(processIdentifier: pid),
                       app.bundleIdentifier == selfBundleID
                    {
                        // Fall through to frontmostApplication
                    } else {
                        return pid
                    }
                }
            }
        }

        // Fallback: use frontmost application from NSWorkspace
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let pid = frontmost.processIdentifier
            // Skip SideWave itself.
            if let selfBundleID = Bundle.main.bundleIdentifier,
               frontmost.bundleIdentifier == selfBundleID
            {
                return nil
            }
            return pid > 0 ? pid : nil
        }

        return nil
    }

    /// Activate an app by PID, unless it's SideWave itself.
    @discardableResult
    static func activateApp(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }

        if let selfBundleID = Bundle.main.bundleIdentifier,
           let targetBundleID = app.bundleIdentifier,
           selfBundleID == targetBundleID
        {
            return false
        }

        return app.activate()
    }

    /// Get the bundle name of the app owning the given PID.
    static func appName(for pid: pid_t?) -> String {
        guard let pid, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return "Unknown" }
        return app.localizedName ?? app.bundleIdentifier ?? "Unknown"
    }

    /// Check whether a process is still running and not terminated.
    static func isAppStillAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    /// Main entry: paste text into the active window.
    /// The caller must ensure the target app is already activated before calling.
    func typeTextInstantly(
        _ text: String,
        preferredTargetPID: pid_t?,
        appendTrailingSpace: Bool = false,
        completion: (@Sendable (PasteOutcome) -> Void)? = nil
    ) {
        guard !text.isEmpty else {
            completion?(.assumed)
            return
        }
        guard AXIsProcessTrusted() else {
            Logger(subsystem: "com.sidewave.kit", category: "paste").error("Accessibility permission required")
            Self.onAccessibilityMissing?()
            completion?(.failed)
            return
        }

        let request = TypingRequest(
            text: text,
            preferredTargetPID: preferredTargetPID,
            appendTrailingSpace: appendTrailingSpace,
            completion: completion
        )

        // Add to queue to prevent concurrent drops (P0-B #1)
        pendingRequests.withLock { $0.append(request) }

        // Process queue
        processQueue()
    }

    private func processQueue() {
        let hasWork = pendingRequests.withLock { !$0.isEmpty }
        guard hasWork else { return }
        
        let acquired = isCurrentlyTyping.withLock { isTyping -> Bool in
            if isTyping {
                return false
            }
            isTyping = true
            return true
        }
        
        guard acquired else { return }
        
        let nextRequest: TypingRequest? = pendingRequests.withLock { queue in
            if queue.isEmpty {
                return nil
            } else {
                return queue.removeFirst()
            }
        }
        
        guard let request = nextRequest else {
            isCurrentlyTyping.withLock { $0 = false }
            return
        }
        
        // Immutable so the background paste closure below captures a value, not
        // a mutable var (which the concurrency checker flags as a data race).
        // The trailing-space decision is made once, here, before dispatch.
        let textToInsert: String = (request.appendTrailingSpace && !request.text.hasSuffix(" "))
            ? request.text + " "
            : request.text
        
        let signpostID = Self.signposter.makeSignpostID()
        let signpostState = Self.signposter.beginInterval(
            "Paste",
            id: signpostID,
            "length=\(textToInsert.count)"
        )
        
        let traceTargetPID = request.preferredTargetPID ?? 0
        let traceTargetApp = Self.appName(for: request.preferredTargetPID)
        let traceLength = textToInsert.count
        
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var attempts: [String] = []
            var pasteOutcome: PasteOutcome = .failed
            defer {
                Self.signposter.endInterval("Paste", signpostState)
                PasteTracer.record(PasteTracer.Trace(
                    timestamp: Date(),
                    targetPID: traceTargetPID,
                    targetApp: traceTargetApp,
                    textLength: traceLength,
                    attempts: attempts,
                    outcome: attempts.last ?? "none",
                    verdict: pasteOutcome.traceLabel
                ))

                request.completion?(pasteOutcome)

                isCurrentlyTyping.withLock { $0 = false }

                // Process next in queue
                processQueue()
            }

            pasteOutcome = insertTextInstantly(textToInsert, preferredTargetPID: request.preferredTargetPID, attempts: &attempts)
        }
    }

    // MARK: - Private cascade

    private func insertTextInstantly(_ text: String, preferredTargetPID: pid_t?, attempts: inout [String]) -> PasteOutcome {
        guard let expectedPID = preferredTargetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
              Self.targetStillFocused(expectedPID) else {
            attempts.append("target-changed")
            return .failed
        }
        // Secure keyboard input held by another process (a password prompt or password manager)
        // makes the system drop every synthetic key event, so the key-based methods would appear to
        // work while nothing lands. Only setting the value through Accessibility still works, so
        // try that; if it can't (Electron and web content usually can't), fail so AppState shows a
        // toast.
        if IsSecureEventInputEnabled() {
            attempts.append("secure-input-ax-only")
            if insertTextViaAccessibility(text, expectedPID: expectedPID) { return .verified }
            attempts.append("secure-input-blocked")
            return .blockedSecureInput
        }

        // Long text goes straight to clipboard paste (PID-targeted when possible)
        if text.utf16.count > Self.cgEventUnicodeLimit {
            if let pid = preferredTargetPID, pid > 0 {
                attempts.append("clipboard-pid-long")
                let r = insertTextViaClipboard(text, targetPID: pid)
                if r != .failed { return r } // Landed or unverifiable; avoid fallback double-paste
            }
            attempts.append("clipboard-hid-long")
            let r = insertTextViaClipboard(text, targetPID: nil, expectedPID: expectedPID)
            if r != .failed { return r }
            attempts.append("char-by-char-long")
            return typeCharByCharAndVerify(text, expectedPID: expectedPID)
        }

        // Electron + browser fast path: skip CGEvent unicode insertion
        if let pid = preferredTargetPID, pid > 0, Self.requiresClipboardPaste(pid: pid) {
            attempts.append("clipboard-pid-electron")
            let r1 = insertTextViaClipboard(text, targetPID: pid)
            if r1 != .failed { return r1 }
            // PID-targeted Cmd+V positively did not land. Try the HID-tap
            // Cmd+V variant before giving up; some Electron builds accept the
            // global tap when the direct postToPid is dropped.
            attempts.append("clipboard-hid-electron")
            let r2 = insertTextViaClipboard(text, targetPID: nil, expectedPID: expectedPID)
            if r2 != .failed { return r2 }
            attempts.append("char-by-char-electron")
            return typeCharByCharAndVerify(text, expectedPID: expectedPID)
        }

        // Short text: try CGEvent cascade (PID-targeted first)
        let bulkTargetPID: pid_t? = (preferredTargetPID ?? 0) > 0 ? preferredTargetPID : nil
        var didTryBulk = false
        if let pid = bulkTargetPID {
            attempts.append("cgevent-bulk-pid")
            let baseline = Self.capturePasteBaseline(targetPID: pid)
            if insertTextBulk(text, targetPID: pid) {
                didTryBulk = true
                // Browsers accept the unicode event but don't reflect it in
                // kAXValueAttribute synchronously; verifying would false-fail
                // and trigger a double-paste via clipboard. Assume success.
                if Self.isWebBrowser(pid: pid) { return .assumed }
                switch Self.verifyPasteDelivery(expectedText: text, targetPID: pid, baseline: baseline) {
                case .landed: return .verified
                case .unverifiable:
                    // AXValue unreadable (native apps that don't expose it,
                    // custom controls). Falling through to Cmd+V would
                    // double-paste, so treat the posted event as delivered.
                    return .assumed
                case .notLanded:
                    // AX positively confirms nothing landed. Safe to fall
                    // through to the clipboard paste below; no double-paste.
                    break
                }
            }
        }

        // Try the focused element's process, but never send the same events again to a process just
        // targeted.
        if let focusedPID = Self.focusedElementPID(), focusedPID == expectedPID, focusedPID != bulkTargetPID {
            attempts.append("cgevent-bulk-focused")
            let baseline = Self.capturePasteBaseline(targetPID: focusedPID)
            if insertTextBulk(text, targetPID: focusedPID) {
                didTryBulk = true
                if Self.isWebBrowser(pid: focusedPID) { return .assumed }
                switch Self.verifyPasteDelivery(expectedText: text, targetPID: focusedPID, baseline: baseline) {
                case .landed: return .verified
                case .unverifiable: return .assumed
                case .notLanded: break
                }
            }
        }

        // Try Accessibility insertion; a successful set means the text is there.
        attempts.append("ax-insertion")
        if insertTextViaAccessibility(text, expectedPID: expectedPID) { return .verified }

        // System-wide key events only if nothing was already sent to a process, or the text would
        // be typed twice.
        if !didTryBulk {
            attempts.append("cgevent-bulk-hid")
            let baseline = Self.capturePasteBaseline()
            if insertTextBulkHID(text, expectedPID: expectedPID) {
                switch Self.verifyPasteDelivery(expectedText: text, baseline: baseline) {
                case .landed: return .verified
                case .unverifiable: return .assumed
                case .notLanded: break
                }
            }
        }

        // Clipboard fallback (PID-targeted when possible)
        if let pid = preferredTargetPID, pid > 0 {
            attempts.append("clipboard-pid")
            let r = insertTextViaClipboard(text, targetPID: pid)
            if r != .failed { return r }
        }
        attempts.append("clipboard-hid")
        let rHid = insertTextViaClipboard(text, targetPID: nil, expectedPID: expectedPID)
        if rHid != .failed { return rHid }

        // Last resort
        attempts.append("char-by-char-fallback")
        return typeCharByCharAndVerify(text, expectedPID: expectedPID)
    }

    /// Character-by-character HID typing followed by an AX delivery check.
    /// The last-resort layer still has to report a truthful verdict so a real
    /// failure reaches the user instead of a silent success chime.
    private func typeCharByCharAndVerify(_ text: String, expectedPID: pid_t) -> PasteOutcome {
        guard Self.targetStillFocused(expectedPID) else { return .failed }
        let baseline = Self.capturePasteBaseline()
        typeCharacterByCharacter(text, expectedPID: expectedPID)
        switch Self.verifyPasteDelivery(expectedText: text, baseline: baseline) {
        case .landed: return .verified
        case .unverifiable: return .assumed
        case .notLanded: return .failed
        }
    }

    /// Apps where synthetic text events are accepted but silently dropped: Electron apps such as
    /// Teams, Slack, Discord, VS Code, Linear, and Notion. Matched by bundle ID so they go straight
    /// to the clipboard. Chromium browsers aren't listed: their address bar and developer tools
    /// accept the events, and web content falls back through `insertTextViaAccessibility`.
    private static func requiresClipboardPaste(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier?.lowercased()
        else { return false }
        // Match by bundle-ID fragment rather than exact string so app
        // updates that bump the ID (e.g. teams → teams2 → teams3) keep
        // working without code changes.
        let electronFragments = [
            "com.microsoft.teams",
            "teams",
            "com.tinyspeck.slackmacgap",      // Slack
            "slack",
            "com.hnc.discord",                 // Discord
            "discord",
            "com.microsoft.vscode",
            "vscode",
            "com.todesktop.",                  // ToDesktop wrappers (Linear, Notion, etc.)
            "com.notion.id",
            "notion",
            "com.linear.linear",
            "linear",
            "com.figma.desktop",
            "figma",
            "com.github.electron",
            "electron",
            "org.whispersystems.signal",
            "signal",
            "whatsapp",
            "obsidian",
            "spotify",
            // TextEdit inserts the text but reports a normalized value (smart quotes, rich text),
            // so verification failed and the text was pasted twice. A single clipboard paste is
            // reliable there.
            "com.apple.textedit",
        ]
        for fragment in electronFragments {
            if bundleID.contains(fragment) { return true }
        }
        return false
    }

    /// Terminal apps. They accept typed text and Command-V reliably but usually don't expose the
    /// text through Accessibility, so delivery can't be confirmed. verifyPasteDelivery treats them
    /// as unverifiable rather than not landed, which would trigger a second method and paste the
    /// text twice. Exact bundle IDs only, so other apps aren't mistaken for terminals.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        "com.raphaelamorim.rio",
    ]

    static func isTerminal(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier?.lowercased()
        else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    private static func isWebBrowser(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier?.lowercased()
        else { return false }
        let browserFragments = [
            "com.apple.safari",
            "com.google.chrome",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.opera.software.opera",
            "com.brave.browser",
            "com.vivaldi.vivaldi",
            "company.thebrowser.browser", // Arc
            "com.orion.browser"
        ]
        for fragment in browserFragments {
            if bundleID.contains(fragment) { return true }
        }
        return false
    }

    /// CGEvent bulk insertion targeting a specific PID
    private func insertTextBulk(_ text: String, targetPID: pid_t) -> Bool {
        guard Self.targetStillFocused(targetPID) else { return false }
        guard targetPID > 0 else { return false }

        let utf16 = Array(text.utf16)
        guard utf16.count <= Self.cgEventUnicodeLimit else { return false }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return false }

        // Clear the flags. A new event inherits the current modifier state, which can still include
        // the hotkey's modifier or the Command from our own paste, turning typed characters into
        // shortcuts.
        keyDown.flags = []
        keyUp.flags = []

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        keyDown.postToPid(targetPID)
        usleep(2000)
        keyUp.postToPid(targetPID)

        return true
    }

    /// CGEvent bulk insertion via HID tap (no PID target)
    private func insertTextBulkHID(_ text: String, expectedPID: pid_t) -> Bool {
        guard Self.targetStillFocused(expectedPID) else { return false }
        let utf16 = Array(text.utf16)
        guard utf16.count <= Self.cgEventUnicodeLimit else { return false }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return false }

        // Explicit empty flags; same inherited-modifier hazard as
        // insertTextBulk above.
        keyDown.flags = []
        keyUp.flags = []

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        keyDown.post(tap: .cghidEventTap)
        usleep(2000)
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    /// Inserts text into the focused element through Accessibility. Sets kAXSelectedTextAttribute,
    /// which replaces the selection or inserts at the caret. Setting kAXValueAttribute would
    /// replace the whole field and erase a draft while still reporting success, so it's used only
    /// when selected text can't be set: then the current value is read and the text appended, or
    /// replaced if the field is empty. Secure fields read back as bullets, so they are replaced,
    /// never appended to.
    private func insertTextViaAccessibility(_ text: String, expectedPID: pid_t) -> Bool {
        guard Self.targetStillFocused(expectedPID) else { return false }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef else { return false }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == expectedPID else { return false }

        // Preferred path: insert at the selection/caret without touching the
        // rest of the field.
        let insertResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if insertResult == .success { return true }

        // Selected-text isn't settable here. For a secure field the value reads
        // back as bullets, so appending would corrupt it; keep the replace
        // behavior the secure-input path depends on.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           (roleRef as? String) == "AXSecureTextField" {
            return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
        }

        // Otherwise read the current value and append, so a half-typed draft or a
        // prior segment isn't wiped. Plain set (replace) only when it's empty.
        var existingRef: CFTypeRef?
        let existing: String
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &existingRef) == .success,
           let current = existingRef as? String {
            existing = current
        } else {
            existing = ""
        }
        let combined = existing.isEmpty ? text : existing + text
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, combined as CFTypeRef) == .success
    }

}
