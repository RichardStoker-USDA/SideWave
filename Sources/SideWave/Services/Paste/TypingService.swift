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
/// - timedOut: nothing reached the target before the paste deadline, and the stalled attempt is
///   barred from pasting later.
enum PasteOutcome: Sendable, Equatable {
    case verified
    case assumed
    case failed
    case blockedSecureInput
    case timedOut

    /// True when the text is (probably) in the target. Drives the success
    /// chime + history vs. the error sound + failure toast in AppState.
    var landed: Bool {
        switch self {
        case .verified, .assumed: return true
        case .failed, .blockedSecureInput, .timedOut: return false
        }
    }

    /// Short label for the paste trace log.
    var traceLabel: String {
        switch self {
        case .verified: return "verified"
        case .assumed: return "assumed"
        case .failed: return "failed"
        case .blockedSecureInput: return "blocked-secure-input"
        case .timedOut: return "timed-out"
        }
    }
}

/// Delivery state of one paste request, shared by the paste worker and the deadline timer.
/// Whichever finishes first reports the outcome; the other is ignored.
final class PasteTicket: Sendable {
    private enum Stage { case waiting, sending, abandoned }
    private struct State {
        var stage: Stage = .waiting
        var completion: (@Sendable (PasteOutcome) -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>

    init(completion: (@Sendable (PasteOutcome) -> Void)?) {
        state = OSAllocatedUnfairLock(initialState: State(completion: completion))
    }

    /// Call right before anything reaches the target or the clipboard. Returns false once the
    /// deadline passed, so a late worker can't paste into whatever has focus then, and a paste
    /// that was already sending can't start a second method after the caller moved on.
    func beginSending() -> Bool {
        state.withLock { s in
            if s.stage == .abandoned { return false }
            s.stage = .sending
            return true
        }
    }

    var isAbandoned: Bool { state.withLock { $0.stage == .abandoned } }

    /// Reports `outcome` unless the ticket already reported.
    func report(_ outcome: PasteOutcome) {
        let completion = state.withLock { s -> (@Sendable (PasteOutcome) -> Void)? in
            defer { s.completion = nil }
            return s.completion
        }
        completion?(outcome)
    }

    /// The deadline passed before the worker reported. A paste that sent nothing is reported as
    /// timed out. One already sending is reported as assumed and its current method may finish,
    /// since its text is on the way. Either way no new method can start. Returns true when nothing
    /// had been sent, so the caller can free the typing slot.
    @discardableResult
    func expire() -> Bool {
        let (completion, abandoned) = state.withLock { s -> ((@Sendable (PasteOutcome) -> Void)?, Bool) in
            guard let completion = s.completion else { return (nil, false) }
            s.completion = nil
            let unsent = s.stage == .waiting
            s.stage = .abandoned
            return (completion, unsent)
        }
        completion?(abandoned ? .timedOut : .assumed)
        return abandoned
    }
}

/// Result of a delivery check. Separate from PasteOutcome because "couldn't check" must not count
/// as "landed"; treating them the same hid real paste failures.
enum PasteVerification: Sendable, Equatable {
    case landed
    case notLanded
    case unverifiable
}

final class TypingService: @unchecked Sendable {
    /// Signposter for paste-path Instruments traces.
    nonisolated static let signposter = OSSignposter(logHandle: SWLog.paste)

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
    /// Command-V, and restoring sooner makes them paste old data. Set with
    /// `clipboardRestoreDelayMs`; 0 or unset uses the default.
    static func clipboardRestoreDelayMs() -> Int {
        // At most 5 s, so a saved clipboard is put back well before its copy expires.
        let v = UserDefaults.standard.integer(forKey: "clipboardRestoreDelayMs")
        return v > 0 ? min(v, 5000) : 600
    }

    /// Settings key for restoring the clipboard after a clipboard paste. Off by default, and the
    /// clipboard is never read while it's off.
    static let restoreClipboardKey = "restoreClipboardAfterPaste"
    static var restoresClipboard: Bool { UserDefaults.standard.bool(forKey: restoreClipboardKey) }

    /// How long a caller waits for a paste to report, counted from the request. A normal paste
    /// reports within about 2 s, including the clipboard backup limit. A stall, such as a target
    /// app that stops answering Accessibility, reports `.timedOut` here instead of holding the
    /// session open.
    static let pasteDeadline: TimeInterval = 6

    /// The paste that owns the typing slot. One paste runs at a time so two can't interleave. A
    /// paste abandoned at its deadline gives up the slot; its worker can no longer send anything.
    private let activeTicket = Mutex<PasteTicket?>(nil)

    struct TypingRequest: Sendable {
        let text: String
        let preferredTargetPID: pid_t?
        let appendTrailingSpace: Bool
        let ticket: PasteTicket
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
            SWLog.note("[TypingService] Accessibility permissions required")
            AppDelegate.showAccessibilityAlert()
            completion?(.failed)
            return
        }

        let ticket = PasteTicket(completion: completion)
        let request = TypingRequest(
            text: text,
            preferredTargetPID: preferredTargetPID,
            appendTrailingSpace: appendTrailingSpace,
            ticket: ticket
        )

        // Queue so concurrent pastes run one at a time.
        pendingRequests.withLock { $0.append(request) }

        // Every paste reports by the deadline, including one queued behind a stalled paste.
        let targetApp = Self.appName(for: preferredTargetPID)
        let length = text.count
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.pasteDeadline) { [self] in
            guard ticket.expire() else { return }
            SWLog.note("[TypingService] Paste to \(targetApp) sent nothing within \(Int(Self.pasteDeadline)) s; abandoned")
            PasteTracer.record(PasteTracer.Trace(
                timestamp: Date(),
                targetPID: preferredTargetPID ?? 0,
                targetApp: targetApp,
                textLength: length,
                attempts: ["deadline"],
                outcome: "deadline",
                verdict: PasteOutcome.timedOut.traceLabel
            ))
            releaseSlot(ifHeldBy: ticket)
        }

        processQueue()
    }

    /// Frees the typing slot if `ticket` holds it, then starts the next queued paste.
    private func releaseSlot(ifHeldBy ticket: PasteTicket) {
        let released = activeTicket.withLock { active -> Bool in
            guard active === ticket else { return false }
            active = nil
            return true
        }
        if released { processQueue() }
    }

    private func processQueue() {
        // Claim the slot and take the next live request together. Requests that passed their
        // deadline while queued already reported and are skipped.
        let nextRequest: TypingRequest? = activeTicket.withLock { active in
            guard active == nil else { return nil }
            let next = pendingRequests.withLock { queue -> TypingRequest? in
                while !queue.isEmpty {
                    let candidate = queue.removeFirst()
                    if !candidate.ticket.isAbandoned { return candidate }
                }
                return nil
            }
            active = next?.ticket
            return next
        }
        guard let request = nextRequest else { return }

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

                request.ticket.report(pasteOutcome)
                releaseSlot(ifHeldBy: request.ticket)
            }

            pasteOutcome = insertTextInstantly(textToInsert, preferredTargetPID: request.preferredTargetPID,
                                               attempts: &attempts, ticket: request.ticket)
        }
    }

    // MARK: - Private cascade

    private func insertTextInstantly(
        _ text: String, preferredTargetPID: pid_t?, attempts: inout [String], ticket: PasteTicket
    ) -> PasteOutcome {
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
            switch insertTextViaAccessibility(text, expectedPID: expectedPID, ticket: ticket) {
            case .inserted: return .verified
            case .maybeSent: return .assumed
            case .notSent: break
            }
            attempts.append("secure-input-blocked")
            return .blockedSecureInput
        }

        // Terminal takes typed text byte for byte, so it never needs the clipboard.
        if let pid = preferredTargetPID, pid > 0, Self.isAppleTerminal(pid: pid) {
            attempts.append("terminal-typed")
            return typeIntoTerminal(text, pid: pid, ticket: ticket)
        }

        // Long text: too long for one key event, so it goes through Accessibility or the clipboard.
        if text.utf16.count > Self.cgEventUnicodeLimit {
            // Native apps take it at the caret through Accessibility, which leaves the clipboard
            // alone. Only a confirmed miss moves on to the clipboard, so nothing is pasted twice.
            if let pid = preferredTargetPID, pid > 0, Self.acceptsAccessibilityInsertion(pid: pid) {
                attempts.append("ax-insertion-long")
                let baseline = Self.capturePasteBaseline(targetPID: pid)
                switch insertTextViaAccessibility(text, expectedPID: expectedPID, ticket: ticket, caretOnly: true) {
                case .inserted:
                    switch Self.verifyPasteDelivery(expectedText: text, targetPID: pid, baseline: baseline) {
                    case .landed: return .verified
                    case .unverifiable: return .assumed
                    case .notLanded: break
                    }
                case .maybeSent:
                    // The app didn't answer in time and may still insert it; a clipboard paste
                    // now could put the text in twice.
                    return .assumed
                case .notSent:
                    break
                }
            }
            if let pid = preferredTargetPID, pid > 0 {
                attempts.append("clipboard-pid-long")
                let r = insertTextViaClipboard(text, targetPID: pid, ticket: ticket)
                if r != .failed { return r } // Landed or unverifiable; avoid fallback double-paste
            }
            attempts.append("clipboard-hid-long")
            let r = insertTextViaClipboard(text, targetPID: nil, expectedPID: expectedPID, ticket: ticket)
            if r != .failed { return r }
            attempts.append("char-by-char-long")
            return typeCharByCharAndVerify(text, expectedPID: expectedPID, ticket: ticket)
        }

        // Electron + browser fast path: skip CGEvent unicode insertion
        if let pid = preferredTargetPID, pid > 0, Self.requiresClipboardPaste(pid: pid) {
            attempts.append("clipboard-pid-electron")
            let r1 = insertTextViaClipboard(text, targetPID: pid, ticket: ticket)
            if r1 != .failed { return r1 }
            // PID-targeted Cmd+V positively did not land. Try the HID-tap
            // Cmd+V variant before giving up; some Electron builds accept the
            // global tap when the direct postToPid is dropped.
            attempts.append("clipboard-hid-electron")
            let r2 = insertTextViaClipboard(text, targetPID: nil, expectedPID: expectedPID, ticket: ticket)
            if r2 != .failed { return r2 }
            attempts.append("char-by-char-electron")
            return typeCharByCharAndVerify(text, expectedPID: expectedPID, ticket: ticket)
        }

        // Short text: try CGEvent cascade (PID-targeted first)
        let bulkTargetPID: pid_t? = (preferredTargetPID ?? 0) > 0 ? preferredTargetPID : nil
        var didTryBulk = false
        if let pid = bulkTargetPID {
            attempts.append("cgevent-bulk-pid")
            let baseline = Self.capturePasteBaseline(targetPID: pid)
            if insertTextBulk(text, targetPID: pid, ticket: ticket) {
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
            if insertTextBulk(text, targetPID: focusedPID, ticket: ticket) {
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
        switch insertTextViaAccessibility(text, expectedPID: expectedPID, ticket: ticket) {
        case .inserted: return .verified
        case .maybeSent: return .assumed
        case .notSent: break
        }

        // System-wide key events only if nothing was already sent to a process, or the text would
        // be typed twice.
        if !didTryBulk {
            attempts.append("cgevent-bulk-hid")
            let baseline = Self.capturePasteBaseline()
            if insertTextBulkHID(text, expectedPID: expectedPID, ticket: ticket) {
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
            let r = insertTextViaClipboard(text, targetPID: pid, ticket: ticket)
            if r != .failed { return r }
        }
        attempts.append("clipboard-hid")
        let rHid = insertTextViaClipboard(text, targetPID: nil, expectedPID: expectedPID, ticket: ticket)
        if rHid != .failed { return rHid }

        // Last resort
        attempts.append("char-by-char-fallback")
        return typeCharByCharAndVerify(text, expectedPID: expectedPID, ticket: ticket)
    }

    /// Character-by-character HID typing followed by an AX delivery check.
    /// The last-resort layer still has to report a truthful verdict so a real
    /// failure reaches the user instead of a silent success chime.
    private func typeCharByCharAndVerify(_ text: String, expectedPID: pid_t, ticket: PasteTicket) -> PasteOutcome {
        guard Self.targetStillFocused(expectedPID), ticket.beginSending() else { return .failed }
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
            "com.apple.textedit",
        ]
        for fragment in electronFragments {
            if bundleID.contains(fragment) { return true }
        }
        return false
    }

    /// Apps that can take text through Accessibility instead of the clipboard: native apps.
    /// Terminals don't accept it, Electron apps and TextEdit are known to need the clipboard, and
    /// web content (browsers, Electron) reports success for an Accessibility insert and ignores
    /// it, which tests on macOS 27 confirmed for WebKit.
    static func acceptsAccessibilityInsertion(pid: pid_t) -> Bool {
        !isTerminal(pid: pid) && !isWebBrowser(pid: pid) && !requiresClipboardPaste(pid: pid)
    }

    /// Apple's Terminal. Typed text there was confirmed byte for byte on macOS 27, including the
    /// escape characters of a bracketed paste. Other terminals keep the clipboard paste until tested.
    static func isAppleTerminal(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased() == "com.apple.terminal"
    }

    /// What Terminal should receive for `text`, split into key events of at most `chunkLimit`
    /// UTF-16 units. Control characters are removed, so dictated text can't end a bracketed paste
    /// early and run the rest as commands. Text with line breaks is wrapped in bracketed-paste
    /// markers with carriage returns, the bytes Terminal sends for a paste into a program that
    /// asked for bracketed paste (Claude Code, Codex, zsh, vim), which keeps the lines together.
    /// A program that didn't ask for it shows the markers as text and runs each line, as it would
    /// run each line of a Command-V paste. Single-line text is plain typing, safe in any program.
    static func terminalKeystrokes(for text: String, chunkLimit: Int = cgEventUnicodeLimit) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Keep line breaks, turn tabs into spaces (a typed tab completes in a shell), drop the rest.
        let cleaned = String(String.UnicodeScalarView(normalized.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar == "\n" { return scalar }
            if scalar == "\t" { return " " }
            return scalar.properties.generalCategory == .control ? nil : scalar
        }))
        let payload = cleaned.contains("\n")
            ? "\u{1b}[200~" + cleaned.replacingOccurrences(of: "\n", with: "\r") + "\u{1b}[201~"
            : cleaned
        var chunks: [String] = []
        var current = ""
        var units = 0
        func append(_ piece: String, size: Int) {
            if units + size > chunkLimit, !current.isEmpty {
                chunks.append(current)
                current = ""
                units = 0
            }
            current.append(piece)
            units += size
        }
        for character in payload {
            let size = character.utf16.count
            if size <= chunkLimit {
                append(String(character), size: size)
            } else {
                // A character built from many combining marks can exceed one key event. Split it
                // at scalar boundaries; the program rejoins the scalars it receives.
                for scalar in character.unicodeScalars {
                    append(String(scalar), size: String(scalar).utf16.count)
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Types text into Terminal's front tab with key events. Delivery can't be read back from a
    /// terminal, so a completed send reports `.assumed`.
    private func typeIntoTerminal(_ text: String, pid: pid_t, ticket: PasteTicket) -> PasteOutcome {
        guard Self.targetStillFocused(pid) else { return .failed }
        let chunks = Self.terminalKeystrokes(for: text)
        guard !chunks.isEmpty, ticket.beginSending() else { return .failed }
        for chunk in chunks {
            let utf16 = Array(chunk.utf16)
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return .failed }
            // No modifiers: a held hotkey modifier would turn the text into shortcuts.
            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyDown.postToPid(pid)
            usleep(1000)
            keyUp.postToPid(pid)
            usleep(1000)
        }
        return .assumed
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
    private func insertTextBulk(_ text: String, targetPID: pid_t, ticket: PasteTicket) -> Bool {
        guard Self.targetStillFocused(targetPID) else { return false }
        guard targetPID > 0 else { return false }

        let utf16 = Array(text.utf16)
        guard utf16.count <= Self.cgEventUnicodeLimit else { return false }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return false }
        guard ticket.beginSending() else { return false }

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
    private func insertTextBulkHID(_ text: String, expectedPID: pid_t, ticket: PasteTicket) -> Bool {
        guard Self.targetStillFocused(expectedPID) else { return false }
        let utf16 = Array(text.utf16)
        guard utf16.count <= Self.cgEventUnicodeLimit else { return false }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return false }
        guard ticket.beginSending() else { return false }

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
    /// With `caretOnly`, only the insert at the caret is tried, never the append to the field's end.
    /// A write the app didn't answer in time may still apply, so it stops there as `.maybeSent`.
    private func insertTextViaAccessibility(
        _ text: String, expectedPID: pid_t, ticket: PasteTicket, caretOnly: Bool = false
    ) -> AXInsertResult {
        guard Self.targetStillFocused(expectedPID) else { return .notSent }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef else { return .notSent }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return .notSent }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == expectedPID else { return .notSent }
        guard ticket.beginSending() else { return .notSent }

        // Preferred path: insert at the selection/caret without touching the
        // rest of the field.
        let insertResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if insertResult == .success { return .inserted }
        if Self.axWriteMayStillApply(insertResult) { return .maybeSent }
        if caretOnly { return .notSent }

        // Selected-text isn't settable here. For a secure field the value reads
        // back as bullets, so appending would corrupt it; keep the replace
        // behavior the secure-input path depends on.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           (roleRef as? String) == "AXSecureTextField" {
            return Self.axInsertResult(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef))
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
        return Self.axInsertResult(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, combined as CFTypeRef))
    }

    enum AXInsertResult { case inserted, notSent, maybeSent }

    /// Whether an Accessibility write that returned `error` could still be applied by the app.
    /// Only a timeout can: the app may process it once it answers. Other errors mean it rejected
    /// the write.
    static func axWriteMayStillApply(_ error: AXError) -> Bool { error == .cannotComplete }

    private static func axInsertResult(_ error: AXError) -> AXInsertResult {
        error == .success ? .inserted : axWriteMayStillApply(error) ? .maybeSent : .notSent
    }

}
