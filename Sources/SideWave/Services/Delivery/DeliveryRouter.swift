// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import ApplicationServices
import os

/// Puts finished text into its target field by the most precise route the target app supports.
///
/// 1. Straight into the saved field through Accessibility, for Mac apps whose text fields accept
///    it. Nothing comes to the front, the clipboard isn't used, and the field is read back to
///    confirm the text landed at the caret.
/// 2. Otherwise the target window comes forward, its field is focused again with its caret
///    restored, and the text is typed (Terminal, short text) or pasted (the rest). When the user
///    was working elsewhere, they're returned there afterward.
///
/// Deliveries run one at a time, from the first focus change to the return. Accessibility work
/// runs off the main thread, so a target app that stops answering can't freeze SideWave.
@MainActor
final class DeliveryRouter {
    enum Route: String, Sendable { case field, focused }
    enum SubmitKey: Sendable { case returnKey, shiftReturn }

    /// Why a delivery stopped before sending anything.
    enum Problem: Sendable, Equatable {
        /// The target app quit.
        case appQuit
        /// The recorded window closed. Another window of the app isn't where the user dictated.
        case windowClosed
        /// The field kept a selection the user didn't make, and typing would have replaced it.
        case unsafeSelection
        /// The target window couldn't be brought to the front, and typing would have gone to
        /// whatever window of the app was in front instead.
        case notInFront
    }

    struct Options: Sendable {
        var appendTrailingSpace = false
        /// Press Return after delivering. Needs the target in front, so it skips the field route.
        var submit: SubmitKey?
        var submitGraceMs = 400
        /// Bring back the app and window the user was in when delivery had to bring the target
        /// forward. Nothing happens when the user is already in the target window.
        var returnToUser = true
    }

    struct Report: Sendable {
        let outcome: PasteOutcome
        let route: Route
        var problem: Problem?
    }

    private let typing: TypingService
    private var lastDelivery: Task<Report, Never>?

    init(typing: TypingService) {
        self.typing = typing
    }

    /// `willSend` runs once, right before the text is delivered: hide the overlay, play the sound.
    /// It doesn't run when delivery stops before sending.
    func deliver(_ text: String, to target: DeliveryTarget, options: Options,
                 willSend: @escaping @MainActor () -> Void) async -> Report {
        let previous = lastDelivery
        let delivery = Task { @MainActor [typing] in
            _ = await previous?.value
            return await Self.perform(text, to: target, options: options, typing: typing, willSend: willSend)
        }
        lastDelivery = delivery
        return await delivery.value
    }

    private static func perform(_ text: String, to target: DeliveryTarget, options: Options,
                                typing: TypingService, willSend: @MainActor () -> Void) async -> Report {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            return Report(outcome: .failed, route: .focused, problem: .appQuit)
        }
        if let windowID = target.windowID, !WindowTargetingService.windowExists(windowID, pid: target.pid) {
            return Report(outcome: .failed, route: .focused, problem: .windowClosed)
        }

        if options.submit == nil, TypingService.acceptsAccessibilityInsertion(pid: target.pid),
           target.element != nil || target.fingerprint != nil {
            let fieldText = options.appendTrailingSpace && !text.hasSuffix(" ") ? text + " " : text
            switch await insertIntoField(fieldText, target: target) {
            case .landed:
                willSend()
                return Report(outcome: .verified, route: .field)
            case .changed:
                willSend()
                return Report(outcome: .assumed, route: .field)
            case .unchanged, .unavailable:
                break
            }
        }

        let user = options.returnToUser ? await FocusSnapshot.current(excluding: target) : nil
        // A minimized window can't take typing. It comes back for the delivery and goes back to the
        // Dock afterward, so the user's windows stay as they left them.
        let restored = await restoreIfMinimized(target)
        let window = target.windowID ?? restored
        if await !bringForward(pid: target.pid, windowID: window),
           await otherWindowInFront(pid: target.pid, windowID: window) {
            await putBack(restored, pid: target.pid, user: user, settleMs: 0)
            let closed = window.map { !WindowTargetingService.windowExists($0, pid: target.pid) } ?? false
            return Report(outcome: .failed, route: .focused, problem: closed ? .windowClosed : .notInFront)
        }
        guard await focusField(of: target) else {
            await putBack(restored, pid: target.pid, user: user, settleMs: 0)
            return Report(outcome: .failed, route: .focused, problem: .unsafeSelection)
        }
        willSend()

        // A mouse-moved event at the cursor makes the window server update focus tracking, which
        // can otherwise drop the paste while the cursor rests over a window. The cursor stays put.
        nudgeMouseTracking()
        try? await Task.sleep(for: .milliseconds(30))

        let outcome: PasteOutcome = await withCheckedContinuation { continuation in
            typing.typeTextInstantly(text, preferredTargetPID: target.pid,
                                     appendTrailingSpace: options.appendTrailingSpace) { continuation.resume(returning: $0) }
        }

        if outcome.landed, let submit = options.submit {
            // An unconfirmed paste in a slow Electron composer needs time before Return, or an empty
            // message is sent. A confirmed one doesn't.
            let graceMs = outcome == .verified ? 50 : max(50, options.submitGraceMs)
            TypingService.activateApp(pid: target.pid)
            try? await Task.sleep(for: .milliseconds(graceMs))
            let pid = target.pid
            let shift = submit == .shiftReturn
            _ = await blocking(seconds: 1) { TypingService.postReturnKey(targetPID: pid, withShift: shift) }
        }

        // Typed text and Return are posted to the target's event queue; give it time to take them
        // while it's still in front. Longer text means more key events.
        await putBack(restored, pid: target.pid, user: user, settleMs: 150 + min(450, text.utf16.count / 100))
        return Report(outcome: outcome, route: .focused)
    }

    /// After a focused delivery: minimizes the window again if delivery restored it, then returns
    /// the user to their app.
    private static func putBack(_ restored: CGWindowID?, pid: pid_t, user: FocusSnapshot?, settleMs: Int) async {
        guard restored != nil || user != nil else { return }
        if settleMs > 0 { try? await Task.sleep(for: .milliseconds(settleMs)) }
        if let restored { await minimize(restored, pid: pid) }
        if let user { await bringForward(pid: user.pid, windowID: user.windowID) }
    }

    /// Restores the target window when it's minimized; for a target without a window, the app's
    /// most recent window when all of them are minimized. Returns the restored window.
    nonisolated private static func restoreIfMinimized(_ target: DeliveryTarget) async -> CGWindowID? {
        let window: CGWindowID?
        if let windowID = target.windowID {
            window = WindowTargetingService.isMinimized(windowID: windowID, pid: target.pid) == true ? windowID : nil
        } else {
            window = WindowTargetingService.onlyMinimizedWindow(pid: target.pid)
        }
        guard let window, WindowTargetingService.setMinimized(false, windowID: window, pid: target.pid) else { return nil }
        return window
    }

    nonisolated private static func minimize(_ windowID: CGWindowID, pid: pid_t) async {
        WindowTargetingService.setMinimized(true, windowID: windowID, pid: pid)
    }

    // MARK: - Field route

    /// Finds the field (the saved element, or the one matching the fingerprint in the recorded
    /// window) and inserts into it, within a deadline. Past the deadline, work that hadn't sent yet
    /// is stopped before it can; work already sending may still land, so it counts as sent.
    nonisolated private static func insertIntoField(_ text: String, target: DeliveryTarget) async -> FieldInsertion.Result {
        let gate = PasteTicket { _ in }
        let result = await blocking(seconds: 3) { () -> FieldInsertion.Result in
            guard let element = target.element ?? target.fingerprint.flatMap({
                WindowTargetingService.findFieldByFingerprint($0, pid: target.pid, windowID: target.windowID)
            }) else { return FieldInsertion.skip("field not found") }
            return FieldInsertion.insert(text, into: element, pid: target.pid,
                                         captured: target.element == nil ? nil : target.selection, gate: gate)
        }
        if let result { return result }
        FieldInsertion.log.notice("Field route timed out")
        return gate.expire() ? .unavailable : .changed
    }

    // MARK: - Focus

    /// Brings an app, and the given window of it, to the front. Activation requested from a
    /// background app can be declined, so Accessibility's frontmost attribute is the second try.
    /// Returns whether the app ended up in front.
    @discardableResult
    nonisolated static func bringForward(pid: pid_t, windowID: CGWindowID?) async -> Bool {
        if await isFront(pid: pid, windowID: windowID) { return true }
        if let windowID {
            if !WindowTargetingService.raiseWindow(windowID: windowID, pid: pid) {
                await MainActor.run { _ = TypingService.activateApp(pid: pid) }
            }
        } else {
            await MainActor.run { _ = TypingService.activateApp(pid: pid) }
        }
        if await waitUntilFront(pid: pid, windowID: windowID, milliseconds: 250) { return true }

        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString,
                                     true as CFTypeRef)
        if let windowID { _ = WindowTargetingService.raiseWindow(windowID: windowID, pid: pid) }
        // Up to 2 s more for a busy or slower Mac, or a window coming back from the Dock. The wait
        // ends as soon as the window is in front.
        if await waitUntilFront(pid: pid, windowID: windowID, milliseconds: 2000) { return true }
        SWLog.note("[DeliveryRouter] Couldn't bring pid \(pid) to the front")
        return false
    }

    /// Focuses the target field again: the saved element, then the field matching the
    /// fingerprint, then the largest text field in the window. Without any of them the app's own
    /// focus is used. Returns false when the field ended up with a selection the user didn't make.
    ///
    /// Focusing a single-line field selects all its text, so typing would replace it. The saved
    /// field gets back the caret it had when captured; a field found another way gets a caret at
    /// the end.
    nonisolated private static func focusField(of target: DeliveryTarget) async -> Bool {
        try? await Task.sleep(for: .milliseconds(100))
        if let element = target.element, DeliveryTarget.elementPID(element) == target.pid,
           WindowTargetingService.refocusElement(element) {
            try? await Task.sleep(for: .milliseconds(80))
            return placeCaret(in: element, at: target.selection)
        }
        if let fingerprint = target.fingerprint,
           WindowTargetingService.focusFieldByFingerprint(fingerprint, pid: target.pid, windowID: target.windowID) {
            try? await Task.sleep(for: .milliseconds(80))
            return WindowTargetingService.captureSystemFocusedElement().map { placeCaret(in: $0, at: nil) } ?? true
        }
        if WindowTargetingService.ensureTextFieldFocused(pid: target.pid, windowID: target.windowID) {
            try? await Task.sleep(for: .milliseconds(80))
            return WindowTargetingService.captureSystemFocusedElement().map { placeCaret(in: $0, at: nil) } ?? true
        }
        SWLog.note("[DeliveryRouter] Field focus not confirmed for pid \(target.pid); using the app's own focus")
        return true
    }

    /// Restores `saved` when it still fits the field's text, or moves a selection the user didn't
    /// make to a caret at the end. Returns whether the field now has a plain caret or the saved
    /// selection. A field whose selection can't be read is left to the app.
    nonisolated static func placeCaret(in element: AXUIElement, at saved: CFRange?) -> Bool {
        guard let current = WindowTargetingService.selectedRange(of: element) else { return true }
        var countRef: CFTypeRef?
        let count = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success
            ? countRef as? Int : nil
        guard var wanted = caretTarget(current: current, saved: saved, characterCount: count) else {
            return FieldInsertion.maySend(current: current, captured: saved)
        }
        if let value = AXValueCreate(.cfRange, &wanted) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        // The field had a selection to correct. If it can't be read now, the correction can't be
        // confirmed, and typing could replace that selection.
        guard let after = WindowTargetingService.selectedRange(of: element) else { return false }
        return FieldInsertion.maySend(current: after, captured: saved)
    }

    /// The selection to set before typing, or nil to leave the field as it is. A saved range is
    /// used only while it still fits the text; otherwise a selection the user didn't make becomes
    /// a caret at the end.
    nonisolated static func caretTarget(current: CFRange, saved: CFRange?, characterCount: Int?) -> CFRange? {
        if let saved, let count = characterCount, saved.location >= 0, saved.length >= 0,
           saved.location + saved.length <= count {
            return saved.location == current.location && saved.length == current.length ? nil : saved
        }
        guard current.length > 0, let count = characterCount else { return nil }
        return CFRange(location: count, length: 0)
    }

    /// After bringing the target forward failed: true when another app, or a known other window of
    /// the target app, is in front. An app that doesn't report its focused window gets the benefit
    /// of the doubt, as before.
    nonisolated private static func otherWindowInFront(pid: pid_t, windowID: CGWindowID?) async -> Bool {
        let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard frontPID == pid else { return true }
        guard let windowID, let focused = WindowTargetingService.focusedWindowID(pid: pid) else { return false }
        return focused != windowID
    }

    nonisolated private static func isFront(pid: pid_t, windowID: CGWindowID?) async -> Bool {
        let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard frontPID == pid else { return false }
        guard let windowID else { return true }
        return WindowTargetingService.focusedWindowID(pid: pid) == windowID
    }

    nonisolated private static func waitUntilFront(pid: pid_t, windowID: CGWindowID?, milliseconds: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        while ContinuousClock.now < deadline {
            if await isFront(pid: pid, windowID: windowID) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await isFront(pid: pid, windowID: windowID)
    }

    private static func nudgeMouseTracking() {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: location.x, y: primaryHeight - location.y),
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Runs blocking work off the main thread. Nil when it passes the deadline; the work is left
    /// to finish and its result is dropped.
    nonisolated static func blocking<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T?) -> Void = { value in
                if resumed.withLock({ done in defer { done = true }; return !done }) {
                    continuation.resume(returning: value)
                }
            }
            DispatchQueue.global(qos: .userInitiated).async { finish(work()) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { finish(nil) }
        }
    }
}

/// The app and window the user was in before delivery brought the target forward.
struct FocusSnapshot: Sendable {
    let pid: pid_t
    let windowID: CGWindowID?

    /// Nil when the user is already in the target window, or in SideWave itself.
    static func current(excluding target: DeliveryTarget) async -> FocusSnapshot? {
        let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let pid = frontPID, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let windowID = WindowTargetingService.focusedWindowID(pid: pid)
        if pid == target.pid && (target.windowID == nil || windowID == target.windowID) { return nil }
        return FocusSnapshot(pid: pid, windowID: windowID)
    }
}

/// Inserting into a saved field through Accessibility, without focusing it.
enum FieldInsertion {
    enum Result: Sendable, Equatable {
        /// The field now reads as expected.
        case landed
        /// The text may have landed (the field changed unexpectedly, couldn't be read back, or the
        /// write timed out); trying another route could insert it twice.
        case changed
        /// The insert was accepted but the field didn't change, as web content does.
        case unchanged
        /// The field can't take a background insert safely; nothing was sent.
        case unavailable
    }

    private static let roles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String,
                                             kAXComboBoxRole as String]

    /// Why the field route was skipped or didn't confirm, without any text or app content, so a
    /// release build's log shows why delivery brought an app forward.
    static let log = Logger(subsystem: SWLog.subsystem, category: "delivery")

    static func skip(_ reason: String) -> Result {
        log.notice("Field route skipped: \(reason, privacy: .public)")
        return .unavailable
    }

    /// A background insert replaces the field's selection, so it's safe only at a plain caret or
    /// over the selection the user had when the target was captured. A field without keyboard
    /// focus can report its whole text as selected; inserting there would erase it.
    static func maySend(current: CFRange, captured: CFRange?) -> Bool {
        if current.length == 0 { return true }
        guard let captured else { return false }
        return captured.location == current.location && captured.length == current.length
    }

    /// The field's value after `text` replaces `range`, or nil when the range doesn't fit.
    static func expectedValue(_ value: String, inserting text: String, at range: CFRange) -> String? {
        let ns = value as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= ns.length else { return nil }
        return ns.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }

    /// Whether a failed write could still be applied by the app later: only after a timeout.
    static func writeMayStillApply(_ error: AXError) -> Bool { TypingService.axWriteMayStillApply(error) }

    /// Blocking; call off the main thread. `gate` is checked right before the write, so work that
    /// passed its deadline never sends.
    static func insert(_ text: String, into element: AXUIElement, pid: pid_t, captured: CFRange?,
                       gate: PasteTicket? = nil) -> Result {
        guard DeliveryTarget.elementPID(element) == pid else { return skip("field belongs to another app") }
        guard let role = string(element, kAXRoleAttribute), roles.contains(role) else { return skip("not a text field") }
        guard string(element, kAXSubroleAttribute) != (kAXSecureTextFieldSubrole as String) else { return skip("secure field") }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return skip("selected text not settable") }
        guard let before = string(element, kAXValueAttribute) else { return skip("value unreadable") }
        guard before.utf16.count <= TypingService.maxVerifiableFieldLength else { return skip("field too long to verify") }
        guard let range = WindowTargetingService.selectedRange(of: element) else { return skip("selection unreadable") }
        guard maySend(current: range, captured: captured) else { return skip("selection not made by the user") }
        guard let expected = expectedValue(before, inserting: text, at: range) else { return skip("selection outside the text") }
        guard gate?.beginSending() ?? true else { return skip("deadline passed") }

        let error = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if error != .success && !writeMayStillApply(error) { return skip("app rejected the insert") }
        if error != .success { log.notice("Field route write timed out; it may still apply") }
        let normalizedExpected = TypingService.normalizeForAXComparison(expected)
        var after: String?
        for _ in 0..<10 {
            after = string(element, kAXValueAttribute)
            if let after, after == expected || TypingService.normalizeForAXComparison(after) == normalizedExpected {
                return .landed
            }
            usleep(40_000)
        }
        // Unreadable afterward (the element may have been replaced) or a write that may still
        // apply both count as sent.
        guard let after, error == .success else {
            log.notice("Field route unconfirmed: not read back as expected")
            return .changed
        }
        if after == before {
            log.notice("Field route ignored: the field didn't change")
            return .unchanged
        }
        log.notice("Field route unconfirmed: the field changed differently")
        return .changed
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
