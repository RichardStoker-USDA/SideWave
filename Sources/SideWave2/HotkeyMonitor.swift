// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Carbon
import Foundation
import os

/// Global hotkey listening, carried tap mechanics only: session-level
/// CGEvent tap on the main run loop, timeout re-enable, 30s health check.
/// AppModel classifies gestures with the kit's GestureClassifier; this type reports raw
/// press, release, and abort of the configured chord, plus Escape while a session is active.
///
/// The tap source is added to the MAIN run loop, so the callback runs on
/// the main thread and can touch MainActor state directly.
@MainActor
final class HotkeyMonitor {

    /// The chord went down (and the session gesture should begin).
    var onPressDown: (() -> Void)?
    /// The chord released cleanly.
    var onPressUp: (() -> Void)?
    /// Another key was struck while the chord was held: the user typed a
    /// shortcut, not a dictation gesture.
    var onAborted: (() -> Void)?
    /// Escape / Ctrl+Escape while the model reports an active session.
    var onEscape: ((_ withControl: Bool) -> Bool)?
    /// Model-provided: whether a session is active (gates Escape capture).
    var isSessionActive: () -> Bool = { false }
    /// When set, the next chord is captured for the recorder instead of
    /// triggering a gesture. Return of the callback consumes the mode.
    var captureNext: ((HotkeyShortcut) -> Void)?

    private(set) var shortcut: HotkeyShortcut = AppSettings.hotkey
    private(set) var isInstalled = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTask: Task<Void, Never>?
    private var chordDown = false
    private var abortedThisHold = false
    private var lastFlagsKeyCode: UInt16 = 0
    private let log = Logger(subsystem: "com.sidewave2.app", category: "hotkey")

    func setShortcut(_ new: HotkeyShortcut) {
        shortcut = new
        AppSettings.hotkey = new
    }

    // MARK: Tap lifecycle

    @discardableResult
    func install() -> Bool {
        teardown()
        guard AXIsProcessTrusted() else {
            log.notice("hotkey tap deferred: accessibility not granted")
            return false
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                // The tap source lives on the main run loop; this callback
                // is main-thread by construction.
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
            },
            userInfo: refcon
        )
        guard let tap = eventTap else {
            log.error("CGEvent.tapCreate failed")
            return false
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = runLoopSource else {
            teardown()
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            teardown()
            return false
        }
        isInstalled = true
        startHealthCheck()
        log.notice("hotkey tap installed (\(self.shortcut.displayString, privacy: .public))")
        return true
    }

    func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isInstalled = false
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    /// macOS silently disables taps that stall or when the system flags
    /// input pressure; without recovery the hotkey "just stops working".
    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                if let tap = self.eventTap, !CGEvent.tapIsEnabled(tap: tap) {
                    self.log.notice("hotkey tap found disabled; re-enabling")
                    CGEvent.tapEnable(tap: tap, enable: true)
                    if !CGEvent.tapIsEnabled(tap: tap) {
                        _ = self.install()
                    }
                }
            }
        }
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // System re-enable requests come through the callback itself.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Recorder capture mode swallows the next chord.
        if let capture = captureNext {
            return handleCapture(capture, type: type, event: event, keyCode: keyCode)
        }

        // Escape handling while a session runs (cancel / park).
        if type == .keyDown, keyCode == 53, isSessionActive() {
            let withControl = event.flags.contains(.maskControl)
            if onEscape?(withControl) == true {
                return nil  // consumed
            }
            return Unmanaged.passUnretained(event)
        }

        if shortcut.isModifierOnly {
            return handleModifierOnly(type: type, event: event, keyCode: keyCode)
        }
        return handleCombo(type: type, event: event, keyCode: keyCode)
    }

    private func handleModifierOnly(
        type: CGEventType, event: CGEvent, keyCode: UInt16
    ) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged, keyCode == shortcut.keyCode {
            let isDown = Self.modifierIsDown(event.flags, forKeyCode: keyCode)
            if isDown, !chordDown {
                chordDown = true
                abortedThisHold = false
                onPressDown?()
            } else if !isDown, chordDown {
                chordDown = false
                if abortedThisHold {
                    abortedThisHold = false
                } else {
                    onPressUp?()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Another key while the modifier chord is held: the user typed a
        // shortcut (Option+letter). Abort the gesture, let the combo pass.
        if type == .keyDown, chordDown, !abortedThisHold {
            abortedThisHold = true
            onAborted?()
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleCombo(
        type: CGEventType, event: CGEvent, keyCode: UInt16
    ) -> Unmanaged<CGEvent>? {
        guard keyCode == shortcut.keyCode else {
            return Unmanaged.passUnretained(event)
        }
        let required = shortcut.modifierFlags
        let current = Self.nsFlags(from: event.flags)
        let matches = current.intersection([.command, .option, .control, .shift, .function]) == required

        if type == .keyDown, matches, !chordDown {
            chordDown = true
            abortedThisHold = false
            onPressDown?()
            return nil  // the chord belongs to us; don't type it
        }
        if type == .keyUp, chordDown {
            chordDown = false
            onPressUp?()
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleCapture(
        _ capture: (HotkeyShortcut) -> Void,
        type: CGEventType, event: CGEvent, keyCode: UInt16
    ) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            // Escape cancels the recorder.
            if keyCode == 53 {
                captureNext = nil
                return nil
            }
            let flags = Self.nsFlags(from: event.flags)
                .intersection([.command, .option, .control, .shift, .function])
            captureNext = nil
            capture(HotkeyShortcut(keyCode: keyCode, modifierFlags: flags))
            return nil
        }
        if type == .flagsChanged {
            if Self.modifierIsDown(event.flags, forKeyCode: keyCode) {
                lastFlagsKeyCode = keyCode
            } else if keyCode == lastFlagsKeyCode, HotkeyShortcut.isModifierKeyCode(keyCode) {
                // Modifier pressed and released alone: a modifier-only chord.
                captureNext = nil
                capture(HotkeyShortcut(keyCode: keyCode, modifierFlags: []))
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: Flag helpers

    private static func modifierIsDown(_ flags: CGEventFlags, forKeyCode keyCode: UInt16) -> Bool {
        switch keyCode {
        case 55, 54: return flags.contains(.maskCommand)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 56, 60: return flags.contains(.maskShift)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }

    private static func nsFlags(from cgFlags: CGEventFlags) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if cgFlags.contains(.maskCommand) { flags.insert(.command) }
        if cgFlags.contains(.maskAlternate) { flags.insert(.option) }
        if cgFlags.contains(.maskControl) { flags.insert(.control) }
        if cgFlags.contains(.maskShift) { flags.insert(.shift) }
        if cgFlags.contains(.maskSecondaryFn) { flags.insert(.function) }
        return flags
    }
}
