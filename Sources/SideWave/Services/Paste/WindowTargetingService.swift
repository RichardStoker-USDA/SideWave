// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import ApplicationServices
import AppKit

// MARK: - Window Info

struct WindowInfo: Identifiable, Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let appIcon: NSImage?
    let bounds: CGRect

    var id: CGWindowID { windowID }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

// MARK: - Text Field Fingerprint

/// Enough to find a text field in a window again: its role, description, and relative position.
/// Element references don't last, so at paste time the window is searched for the best match.
struct TextFieldFingerprint: Codable, Hashable {
    let role: String
    let roleDescription: String?
    let identifier: String?
    /// Vertical position within the window (0 top, 1 bottom). Compose fields are usually low,
    /// search and address bars at the top, which separates fields with the same role.
    let relativeY: CGFloat
    let area: CGFloat
}

// MARK: - Window Targeting Service

/// Provides window-level targeting via macOS Accessibility API.
/// Enumerates windows per app, brings specific windows to front,
/// and tracks window position for border overlay.
enum WindowTargetingService {

    // Private macOS API for getting CGWindowID from AXUIElement
    @_silgen_name("_AXUIElementGetWindow")
    static func _AXUIElementGetWindow(
        _ element: AXUIElement,
        _ windowID: UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    /// List all visible windows for a specific app PID.
    static func windows(for pid: pid_t) -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
        let appIcon = NSRunningApplication(processIdentifier: pid)?.icon

        return axWindows.compactMap { axWindow in
            // Get title
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            // Skip windows without titles (utility panels, popovers)
            guard !title.isEmpty else { return nil }

            // Get CGWindowID via private API
            var cgWindowID: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &cgWindowID) == .success else { return nil }

            // Get bounds
            let bounds = windowFrame(for: axWindow) ?? .zero

            // Skip minimized windows
            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
            if (minimizedRef as? Bool) == true { return nil }

            return WindowInfo(
                windowID: cgWindowID,
                pid: pid,
                title: title,
                appName: appName,
                appIcon: appIcon,
                bounds: bounds
            )
        }
    }

    /// Brings a window to the front by window ID and process ID. Returns true only if the app
    /// activated and AXRaise succeeded; pasting into a window still behind another loses the text.
    /// The caller falls back to activating the app and polling.
    static func raiseWindow(windowID: CGWindowID, pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let axWindows = windowsRef as? [AXUIElement] else {
            return false
        }

        for axWindow in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &wid) == .success, wid == windowID {
                // Activate the app FIRST. Raising via AX and then activating
                // lets the activation reshuffle window order, undoing the
                // raise; activate then raise keeps the target on top.
                let activateOK = NSRunningApplication(processIdentifier: pid)?.activate() ?? false
                let raiseErr = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                // Make keyboard focus follow the raised window. Both sets are
                // best-effort; apps that expose these read-only just ignore
                // them, which is harmless.
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
                AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, axWindow as CFTypeRef)
                return activateOK && raiseErr == .success
            }
        }
        return false
    }

    /// After raising a window, make sure a text field has focus; if not, focus the largest text
    /// field in the window (only the given window when `windowID` is set).
    static func ensureTextFieldFocused(pid: pid_t, windowID: CGWindowID? = nil) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?

        // If something has focus, leave it: focusing another element can take focus from the field
        // the user was in. With a specific window requested, accept existing focus only inside that
        // window, since focus in another window of the same app would send the paste there.
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            if let targetWID = windowID {
                let focusedElement = unsafeBitCast(focused, to: AXUIElement.self)
                if containingWindowID(of: focusedElement) == targetWID {
                    return true
                }
                // else: focus is in another window; fall through to search.
            } else {
                return true
            }
        }

        // Scope the search to the targeted window when possible
        var candidates: [(element: AXUIElement, area: CGFloat)] = []

        if let targetWID = windowID,
           let axWindow = axWindowForID(targetWID, pid: pid) {
            // User locked onto a specific window; search only that one
            var nc1 = 0; collectTextFields(in: axWindow, depth: 0, results: &candidates, nodeCount: &nc1)
        } else {
            // No specific window; use the focused window, then fall back to app
            var mainWindowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                &mainWindowRef
            ) == .success, let windowVal = mainWindowRef, CFGetTypeID(windowVal) == AXUIElementGetTypeID() {
                let focusedWindow = unsafeBitCast(windowVal, to: AXUIElement.self)
                var nc2 = 0; collectTextFields(in: focusedWindow, depth: 0, results: &candidates, nodeCount: &nc2)
            }
            if candidates.isEmpty {
                var nc3 = 0; collectTextFields(in: appElement, depth: 0, results: &candidates, nodeCount: &nc3)
            }
        }

        // Pick the largest text field, so a browser's chat box wins over its address bar.
        guard let best = candidates.max(by: { $0.area < $1.area }) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            best.element,
            kAXFocusedAttribute as CFString,
            true as CFTypeRef
        )
        return result == .success
    }

    /// Capture a fingerprint of the currently focused text field in an app.
    /// Returns nil if no text field is focused.
    static func captureFocusedFieldFingerprint(pid: pid_t, windowID: CGWindowID? = nil) -> TextFieldFingerprint? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }

        let element = unsafeBitCast(focused, to: AXUIElement.self)
        guard isTextInputElement(element) else { return nil }

        return buildFingerprint(for: element, pid: pid, windowID: windowID)
    }

    /// Turns on the accessibility tree in Electron apps (Teams, Slack, Discord, VS Code), which
    /// expose it only after AXManualAccessibility or AXEnhancedUserInterface is set. No effect on
    /// other apps.
    static func unlockElectronAXTree(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            true as CFTypeRef
        )
        AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
    }

    /// The focused element, if it's a text input, kept so it can be focused again at paste. Nil
    /// otherwise.
    static func captureSystemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }

        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if textInputRoles.contains(role) { return element }

        // Browser/Electron apps may have focus on a group or web area
        // that contains the actual text input. Accept any element that
        // reports it can accept keyboard input.
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            "AXInsertionPointLineNumber" as CFString,
            &editableRef
        ) == .success {
            return element
        }

        return nil
    }

    /// Focuses a saved element again through Accessibility, or clicks its center when that fails,
    /// as it often does for web content.
    static func refocusElement(_ element: AXUIElement) -> Bool {
        // Try the clean accessibility approach first
        let axResult = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            true as CFTypeRef
        )
        if axResult == .success { return true }

        // Accessibility set-focus failed (browsers often reject this for
        // web content). Fall back to clicking the element's center point.
        return clickElement(element)
    }

    /// Send a CGEvent mouse click at the center of an AXUIElement's bounds.
    /// Browsers respond to click events for focus even when they reject
    /// accessibility focus commands.
    static func clickElement(_ element: AXUIElement) -> Bool {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posRef
        ) == .success,
              AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeRef
        ) == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return false }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return false }

        // Click the center of the element
        let clickPoint = CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2
        )

        let src = CGEventSource(stateID: .hidSystemState)
        guard let mouseDown = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseDown,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ),
              let mouseUp = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseUp,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ) else { return false }

        mouseDown.post(tap: .cgSessionEventTap)
        mouseUp.post(tap: .cgSessionEventTap)
        return true
    }

    /// Build a fingerprint for a given AX element.
    private static func buildFingerprint(
        for element: AXUIElement,
        pid: pid_t,
        windowID: CGWindowID?
    ) -> TextFieldFingerprint {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &descRef)
        let roleDesc = descRef as? String

        var idRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &idRef)
        let identifier = idRef as? String

        // Get the element's position relative to its window
        var relY: CGFloat = 0.5
        var posRef: CFTypeRef?
        var pos = CGPoint.zero
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
           AXValueGetValue(unsafeBitCast(posVal, to: AXValue.self), .cgPoint, &pos),
           pos.x.isFinite, pos.y.isFinite {

            // Get the window frame for relative positioning
            var resolved = false
            if let wid = windowID, let axWin = axWindowForID(wid, pid: pid) {
                if let wFrame = windowFrame(for: axWin), wFrame.height > 0 {
                    relY = (pos.y - wFrame.origin.y) / wFrame.height
                    resolved = true
                }
            }
            // Fallback: use the app's focused window when no windowID
            if !resolved {
                let appEl = AXUIElementCreateApplication(pid)
                var fwRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &fwRef) == .success,
                   let fwVal = fwRef, CFGetTypeID(fwVal) == AXUIElementGetTypeID() {
                    let fw = unsafeBitCast(fwVal, to: AXUIElement.self)
                    if let wFrame = windowFrame(for: fw), wFrame.height > 0 {
                        relY = (pos.y - wFrame.origin.y) / wFrame.height
                    }
                }
            }
        }

        let area = elementArea(element)

        return TextFieldFingerprint(
            role: role,
            roleDescription: roleDesc,
            identifier: identifier,
            relativeY: relY,
            area: area
        )
    }

    /// Re-find and focus a text field matching a saved fingerprint.
    /// Searches the targeted window's element tree and picks the
    /// best match by identifier, role description, then relative position.
    static func focusFieldByFingerprint(
        _ fingerprint: TextFieldFingerprint,
        pid: pid_t,
        windowID: CGWindowID? = nil
    ) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        // First check if the currently focused element already matches
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let el = unsafeBitCast(focused, to: AXUIElement.self)
            if isTextInputElement(el) {
                let currentFP = buildFingerprint(for: el, pid: pid, windowID: windowID)
                if fingerprintMatch(currentFP, fingerprint) {
                    return true
                }
            }
        }

        // Collect all text fields in the target window
        var candidates: [(element: AXUIElement, fingerprint: TextFieldFingerprint)] = []

        let searchRoot: AXUIElement
        if let wid = windowID, let axWin = axWindowForID(wid, pid: pid) {
            searchRoot = axWin
        } else {
            var mainWindowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                &mainWindowRef
            ) == .success, let wVal = mainWindowRef, CFGetTypeID(wVal) == AXUIElementGetTypeID() {
                searchRoot = unsafeBitCast(wVal, to: AXUIElement.self)
            } else {
                searchRoot = appElement
            }
        }

        var allFields: [(element: AXUIElement, area: CGFloat)] = []
        var nc4 = 0; collectTextFields(in: searchRoot, depth: 0, results: &allFields, nodeCount: &nc4)

        for (el, _) in allFields {
            let fp = buildFingerprint(for: el, pid: pid, windowID: windowID)
            candidates.append((el, fp))
        }

        // Score each candidate against the fingerprint
        var bestElement: AXUIElement?
        var bestScore: Int = -1

        for (el, fp) in candidates {
            var score = 0

            // Exact identifier match is strongest signal
            if let savedID = fingerprint.identifier, let candidateID = fp.identifier,
               savedID == candidateID {
                score += 100
            }

            // Role description match
            if let savedDesc = fingerprint.roleDescription, let candidateDesc = fp.roleDescription,
               savedDesc == candidateDesc {
                score += 10
            }

            // Role match
            if fp.role == fingerprint.role {
                score += 5
            }

            // Relative Y position similarity (within 15% = good match)
            let yDiff = abs(fp.relativeY - fingerprint.relativeY)
            if yDiff < 0.15 {
                score += 20
            } else if yDiff < 0.3 {
                score += 5
            }

            // Similar size
            if fingerprint.area > 0 {
                let sizeRatio = min(fp.area, fingerprint.area) / max(fp.area, fingerprint.area)
                if sizeRatio > 0.5 { score += 5 }
            }

            if score > bestScore {
                bestScore = score
                bestElement = el
            }
        }

        // Require at least a position or identifier match (score >= 20)
        // to avoid focusing a random field that only matches on role
        guard let target = bestElement, bestScore >= 20 else {
            return false
        }

        let focusResult = AXUIElementSetAttributeValue(
            target,
            kAXFocusedAttribute as CFString,
            true as CFTypeRef
        )
        return focusResult == .success
    }

    /// Check if two fingerprints likely refer to the same field.
    private static func fingerprintMatch(
        _ a: TextFieldFingerprint,
        _ b: TextFieldFingerprint
    ) -> Bool {
        // Identifier match is definitive
        if let idA = a.identifier, let idB = b.identifier, idA == idB {
            return true
        }
        // Same role + similar position
        if a.role == b.role && abs(a.relativeY - b.relativeY) < 0.15 {
            return true
        }
        return false
    }

    /// ID of the window containing an element, from kAXWindowAttribute. Nil for elements without a
    /// window (menu bar items, some web content) or when the lookup fails.
    private static func containingWindowID(of element: AXUIElement) -> CGWindowID? {
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXWindowAttribute as CFString, &winRef
        ) == .success,
              let winVal = winRef,
              CFGetTypeID(winVal) == AXUIElementGetTypeID()
        else { return nil }

        let axWindow = unsafeBitCast(winVal, to: AXUIElement.self)
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(axWindow, &wid) == .success else { return nil }
        return wid
    }

    /// Look up the AXUIElement for a specific CGWindowID in an app's window list.
    private static func axWindowForID(_ windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
        let axWindows = windowsRef as? [AXUIElement] else {
            return nil
        }
        for axWindow in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &wid) == .success, wid == windowID {
                return axWindow
            }
        }
        return nil
    }

    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXWebArea"
    ]

    private static func isTextInputElement(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        guard let role = roleRef as? String else { return false }
        return textInputRoles.contains(role)
    }

    /// Get the pixel area of an AX element (width * height). Returns 0
    /// if the size can't be read or the element is hidden/zero-size.
    private static func elementArea(_ element: AXUIElement) -> CGFloat {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeRef
        ) == .success,
              let sizeVal = sizeRef,
              CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return 0 }

        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(sizeVal, to: AXValue.self), .cgSize, &size),
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return 0 }
        return size.width * size.height
    }

    /// Walk the element tree and collect all text input fields with
    /// their pixel area. Depth-limited and node-counted to prevent
    /// runaway on deep Electron/web-content AX trees.
    private static func collectTextFields(
        in element: AXUIElement,
        depth: Int,
        results: inout [(element: AXUIElement, area: CGFloat)],
        nodeCount: inout Int
    ) {
        guard depth < 18, nodeCount < 800 else { return }
        nodeCount += 1

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if textInputRoles.contains(role) {
            var enabledRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef)
            if (enabledRef as? Bool) != false {
                let area = elementArea(element)
                if area > 0 {
                    results.append((element, area))
                }
            }
            // Don't recurse into AXWebArea children; they're HTML
            // elements, not independent paste targets. The web area
            // itself is the target for browser-based apps.
            if role == "AXWebArea" { return }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        ) == .success, let children = childrenRef as? [AXUIElement] else {
            return
        }

        for child in children {
            collectTextFields(in: child, depth: depth + 1, results: &results, nodeCount: &nodeCount)
        }
    }

    /// Get the current frame of a window by its AXUIElement.
    static func windowFrame(for window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        // Accessibility values aren't type-checked, so an app could return something else. Casting
        // conditionally returns nil instead of crashing.
        guard let rawPos = posRef, let rawSize = sizeRef,
              CFGetTypeID(rawPos) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }
        let posValue = rawPos as! AXValue
        let sizeValue = rawSize as! AXValue
        guard AXValueGetValue(posValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }

        return CGRect(origin: position, size: size)
    }

    /// Get the frame of a window by CGWindowID (uses CGWindowListCopyWindowInfo).
    static func windowFrame(for windowID: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        return CGRect(
            x: bounds["X"] ?? 0,
            y: bounds["Y"] ?? 0,
            width: bounds["Width"] ?? 0,
            height: bounds["Height"] ?? 0
        )
    }

    /// Check if a window is still visible on screen.
    static func isWindowOnScreen(_ windowID: CGWindowID) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return infoList.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }
}
