// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import ApplicationServices

/// What a dictation does with the "specific app or window" choice when it starts.
enum AssignedTargetCheck: Equatable {
    case ready
    /// The window the choice was tied to is gone, but the user picked the app rather than that
    /// window (closing and reopening a window gives it a new ID): use the app's current window.
    case followApp
    /// The user picked a specific window and it closed. Another window of the app could be a
    /// different conversation or shell, so nothing goes there.
    case chosenWindowClosed
    case appNotOpen
    case noOpenWindow

    /// `windowCount` is nil when the app didn't answer; that counts as having windows.
    static func evaluate(appRunning: Bool, windowID: CGWindowID?, windowExists: Bool, windowChosen: Bool,
                         windowCount: Int?) -> AssignedTargetCheck {
        guard appRunning else { return .appNotOpen }
        if windowID != nil, windowExists { return .ready }
        if windowID != nil, windowChosen { return .chosenWindowClosed }
        if windowCount == 0 { return .noOpenWindow }
        return windowID == nil ? .ready : .followApp
    }
}

/// Where a dictation goes: the app, the window, and the exact text field, fixed when captured.
/// Captured at the shortcut press for "where I started", at the stop for "where I finish", or
/// from the assignment for "always this window". Sendable because the element is an immutable
/// Accessibility reference, which the router uses from background threads.
struct DeliveryTarget: @unchecked Sendable {
    let pid: pid_t
    let appName: String
    /// The window that held the field. Delivery brings back this window, not whichever window of
    /// the app happens to be in front.
    let windowID: CGWindowID?
    /// The field itself, when it was a readable text input.
    let element: AXUIElement?
    /// A description of the field, for finding it again if the element is gone.
    let fingerprint: TextFieldFingerprint?
    /// The caret or selection in the field when captured. A background insert only goes ahead
    /// while the field still has a plain caret or this same selection, so it never replaces text
    /// the user didn't select.
    let selection: CFRange?

    /// The text field with keyboard focus now, outside SideWave. Nil when nothing outside SideWave
    /// has focus.
    static func captureFocused() -> DeliveryTarget? {
        guard let pid = TypingService.captureSystemFocusedPID() else { return nil }
        var element = WindowTargetingService.captureSystemFocusedElement()
        if let candidate = element, elementPID(candidate) != pid { element = nil }
        let windowID = element.flatMap(WindowTargetingService.containingWindowID(of:))
            ?? WindowTargetingService.focusedWindowID(pid: pid)
        return DeliveryTarget(
            pid: pid,
            appName: TypingService.appName(for: pid),
            windowID: windowID,
            element: element,
            fingerprint: WindowTargetingService.captureFocusedFieldFingerprint(pid: pid, windowID: windowID),
            selection: element.flatMap(WindowTargetingService.selectedRange(of:))
        )
    }

    static func elementPID(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }
}
