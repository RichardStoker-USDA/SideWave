// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Carbon
import Foundation
import os
import Synchronization

extension PasteEngine {
    /// Writes a sensitive string to the pasteboard, clearing it, setting the
    /// local-only host restriction, and marking it as concealed/transient.
    static func writeSensitiveString(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }



    private struct ClipboardBackup: Sendable {
        struct Item: Sendable {
            let typeRawValues: [String]
            let dataMap: [String: Data]
        }
        let items: [Item]
    }

    /// Pasteboard change count right after our last writeSensitiveString. The count only increases,
    /// so while the pasteboard still reports this value, our dictation text is what's on it rather
    /// than the user's clipboard.
    private static let lastSensitiveWriteChangeCount = Mutex<Int?>(nil)

    /// The user's clipboard saved before the first of several quick pastes, so a later paste that
    /// finds our own text still there restores the user's copy instead of saving ours.
    private static let pendingClipboardBackup = Mutex<ClipboardBackup?>(nil)

    private static func backupClipboard(pasteboard: NSPasteboard) -> ClipboardBackup {
        var backupItems: [ClipboardBackup.Item] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                var typeRawValues: [String] = []
                var dataMap: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        let raw = type.rawValue
                        typeRawValues.append(raw)
                        dataMap[raw] = data
                    }
                }
                if !typeRawValues.isEmpty {
                    backupItems.append(ClipboardBackup.Item(typeRawValues: typeRawValues, dataMap: dataMap))
                }
            }
        }
        return ClipboardBackup(items: backupItems)
    }

    private static func restoreClipboard(_ backup: ClipboardBackup, to pb: NSPasteboard) {
        pb.clearContents()
        if backup.items.isEmpty {
            return
        }
        var writeItems: [NSPasteboardItem] = []
        for backupItem in backup.items {
            let newItem = NSPasteboardItem()
            for rawType in backupItem.typeRawValues {
                if let data = backupItem.dataMap[rawType] {
                    newItem.setData(data, forType: NSPasteboard.PasteboardType(rawType))
                }
            }
            writeItems.append(newItem)
        }
        pb.writeObjects(writeItems)
    }

    /// Pastes through the clipboard and restores the previous contents. Sends Command-V to
    /// `targetPID` when given, otherwise system-wide. Returns a PasteOutcome so the caller can try
    /// another method after a confirmed failure.
    func insertTextViaClipboard(_ text: String, targetPID: pid_t? = nil, expectedPID: pid_t? = nil) -> PasteOutcome {
        guard let expectedPID = expectedPID ?? targetPID, Self.targetStillFocused(expectedPID) else { return .failed }
        let baseline = Self.capturePasteBaseline(targetPID: targetPID)
        let pasteboard = NSPasteboard.general

        // Don't save our own text as the user's clipboard. After quick consecutive pastes, the
        // previous dictation can still be on the pasteboard while its restore waits; saving it
        // would later restore our text and lose the user's copy. If the change count still matches
        // our last write, reuse the backup from the first paste.
        let ourStringStillPresent = Self.lastSensitiveWriteChangeCount.withLock { $0 } == pasteboard.changeCount
        let backup: ClipboardBackup
        if ourStringStillPresent, let pending = Self.pendingClipboardBackup.withLock({ $0 }) {
            backup = pending
        } else {
            backup = Self.backupClipboard(pasteboard: pasteboard)
            Self.pendingClipboardBackup.withLock { $0 = backup }
        }

        Self.writeSensitiveString(text, to: pasteboard)
        let ourChangeCount = pasteboard.changeCount
        Self.lastSensitiveWriteChangeCount.withLock { $0 = ourChangeCount }

        // Cmd+V using the layout-resolved keycode for 'V' (see vKeyCode).
        guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.vKeyCode, keyDown: true),
              let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.vKeyCode, keyDown: false)
        else {
            Self.restoreClipboard(backup, to: pasteboard)
            return .failed
        }

        guard Self.targetStillFocused(expectedPID) else {
            if pasteboard.changeCount == ourChangeCount { Self.restoreClipboard(backup, to: pasteboard) }
            return .failed
        }
        cmdVDown.flags = .maskCommand
        cmdVUp.flags = .maskCommand

        if let pid = targetPID, pid > 0 {
            cmdVDown.postToPid(pid)
            usleep(10_000) // 10ms
            cmdVUp.postToPid(pid)
        } else {
            cmdVDown.post(tap: .cghidEventTap)
            usleep(10_000) // 10ms
            cmdVUp.post(tap: .cghidEventTap)
        }

        // Verify synchronously on this background queue so both the return
        // value and the restore timing use the same verdict.
        let verification = Self.verifyPasteDelivery(expectedText: text, targetPID: targetPID, baseline: baseline, timeoutMs: 400)

        // Never overwrite a clipboard that changed in the meantime (a user copy, or a later paste's
        // write): restore only if the change count and the string still match.
        func restoreIfUnchanged(after delayMs: Int) {
            DispatchQueue.global(qos: .utility).async {
                if delayMs > 0 {
                    // Thread.sleep, not usleep: the delay is user-tunable and
                    // can exceed usleep's ~1s ceiling, which would silently no-op.
                    Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
                }
                let pb = NSPasteboard.general
                guard pb.changeCount == ourChangeCount && pb.string(forType: .string) == text else { return }
                Self.restoreClipboard(backup, to: pb)
                // The user's clipboard is restored; drop the saved copy so it isn't kept longer
                // than needed.
                Self.pendingClipboardBackup.withLock { $0 = nil }
            }
        }

        switch verification {
        case .landed:
            // Confirmed in the field; restore the user's clipboard now.
            restoreIfUnchanged(after: 0)
            return .verified
        case .unverifiable:
            // Delivery can't be confirmed (Electron or web content). Leave the text on the
            // clipboard for the grace period so a slow app still reads it. No later method runs
            // after `.assumed`, so the delayed restore can't race one.
            restoreIfUnchanged(after: Self.clipboardRestoreDelayMs())
            return .assumed
        case .notLanded:
            // Accessibility says nothing landed and another method will run, so restore now: a
            // pending delayed restore would race it, and our text left on the clipboard would be
            // saved as the user's.
            let pb = NSPasteboard.general
            if pb.changeCount == ourChangeCount && pb.string(forType: .string) == text {
                Self.restoreClipboard(backup, to: pb)
                Self.pendingClipboardBackup.withLock { $0 = nil }
            }
            return .failed
        }
    }

    /// Normalizes text for tolerant comparison in verifyPasteDelivery. Lowercases,
    /// standardizes punctuation/quotes/dashes, and collapses all whitespace sequences.
    private static func normalizeForAXComparison(_ str: String) -> String {
        return str.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "…", with: "...")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    struct PasteBaseline {
        let element: AXUIElement
        let value: String
        let selectedText: String?
    }

    /// Snapshot before posting an event. A snapshot taken afterwards can
    /// mistake a fast, successful paste for an unchanged field and paste twice.
    static func capturePasteBaseline(targetPID: pid_t? = nil) -> PasteBaseline? {
        guard AXIsProcessTrusted() else { return nil }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let targetPID, targetPID > 0, pid != targetPID { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return nil }
        var selectedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef)
        return PasteBaseline(element: element, value: value, selectedText: selectedRef as? String)
    }

    static func comparePasteValues(
        before: String?, after: String?, expected: String, selectedText: String? = nil
    ) -> PasteVerification {
        guard let before, let after else { return .unverifiable }
        let expected = normalizeForAXComparison(expected)
        guard !expected.isEmpty else { return .unverifiable }
        let normalizedBefore = normalizeForAXComparison(before)
        let normalizedAfter = normalizeForAXComparison(after)
        if normalizedBefore != normalizedAfter {
            return normalizedAfter.contains(expected) ? .landed : .unverifiable
        }
        if let selectedText,
           normalizeForAXComparison(selectedText) == expected {
            // Replacing selected text with itself need not change AXValue.
            return .unverifiable
        }
        return .notLanded
    }

    static func verifyPasteDelivery(
        expectedText: String, targetPID: pid_t? = nil,
        baseline: PasteBaseline?, timeoutMs: Int = 500
    ) -> PasteVerification {
        guard let baseline, AXIsProcessTrusted() else { return .unverifiable }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var verdict: PasteVerification = .unverifiable
        repeat {
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedRef
            ) == .success, let focusedRef,
                  CFGetTypeID(focusedRef) == AXUIElementGetTypeID(),
                  CFEqual(baseline.element, focusedRef) else { return .unverifiable }
            var pid: pid_t = 0
            AXUIElementGetPid(baseline.element, &pid)
            if let targetPID, targetPID > 0, pid != targetPID { return .unverifiable }
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                baseline.element, kAXValueAttribute as CFString, &valueRef
            ) == .success, let value = valueRef as? String else { return .unverifiable }
            verdict = comparePasteValues(
                before: baseline.value, after: value, expected: expectedText,
                selectedText: baseline.selectedText
            )
            if verdict != .notLanded { return verdict }
            if Date() >= deadline { break }
            usleep(50_000)
        } while true
        var pid: pid_t = 0
        AXUIElementGetPid(baseline.element, &pid)
        return pid > 0 && isTerminal(pid: pid) ? .unverifiable : verdict
    }
}
