// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Carbon
import Foundation
import os
import Synchronization

extension TypingService {
    /// Character-by-character fallback
    func typeCharacterByCharacter(_ text: String, expectedPID: pid_t) {
        for char in text {
            guard Self.targetStillFocused(expectedPID) else { return }
            let utf16 = Array(String(char).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { continue }

            // Clear the flags so a leftover Command or hotkey modifier doesn't turn characters into
            // shortcuts.
            keyDown.flags = []
            keyUp.flags = []

            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

            keyDown.post(tap: .cghidEventTap)
            usleep(1000)
            keyUp.post(tap: .cghidEventTap)
            usleep(1000)
        }
    }

    static func targetMatches(expectedPID: pid_t, frontmostPID: pid_t?, focusedPID: pid_t?) -> Bool {
        expectedPID > 0 && frontmostPID == expectedPID && (focusedPID == nil || focusedPID == expectedPID)
    }

    static func targetStillFocused(_ expectedPID: pid_t) -> Bool {
        targetMatches(expectedPID: expectedPID,
                      frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                      focusedPID: focusedElementPID())
    }

    /// Get the PID of the system-focused element (used as intermediate fallback)
    static func focusedElementPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef else { return nil }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid > 0 ? pid : nil
    }

    /// The key code that types `character` without modifiers on the current layout, found by
    /// checking codes 0 to 127 with UCKeyTranslate. Nil if the layout can't be read or no key
    /// matches; the caller uses the ANSI code.
    static func resolveKeyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        let target = String(character).lowercased()

        return layoutData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            let kbdType = UInt32(LMGetKbdType())
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0

            for code in 0..<CGKeyCode(128) {
                // Reset per key so a dead key on an earlier code can't leak
                // state into this translation.
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(code),
                    UInt16(kUCKeyActionDown),
                    0, // no modifiers; we want the base character
                    kbdType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                if status == noErr, length > 0 {
                    let produced = String(utf16CodeUnits: chars, count: length).lowercased()
                    if produced == target { return code }
                }
            }
            return nil
        }
    }

    // MARK: - Key Press Helpers

    /// Send a Return/Enter key press to the target process (or globally if nil).
    /// Used as a fallback when app-specific injection isn't available.
    func sendReturnKey(targetPID: pid_t?) {
        sendReturnKey(targetPID: targetPID, withShift: false)
    }

    /// Sends Return to the target, optionally with Shift, for auto-submit in apps where Return
    /// inserts a line break and Shift-Return sends.
    func sendReturnKey(targetPID: pid_t?, withShift: Bool) {
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // keyCode 36 = Return
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)
            else { return }

            // Set flags on both paths; an unshifted Return sent right at hotkey release could
            // otherwise go out as Option-Return.
            keyDown.flags = withShift ? .maskShift : []
            keyUp.flags = withShift ? .maskShift : []

            if let pid = targetPID, pid > 0 {
                keyDown.postToPid(pid)
                usleep(10_000) // 10ms
                keyUp.postToPid(pid)
            } else {
                keyDown.post(tap: .cghidEventTap)
                usleep(10_000)
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }
}
