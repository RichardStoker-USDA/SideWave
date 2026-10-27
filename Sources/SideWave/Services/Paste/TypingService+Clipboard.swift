// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Carbon
import CryptoKit
import Foundation
import os
import Synchronization

/// The user's clipboard while a paste is in flight, encrypted in memory with a key made for this
/// copy alone. Each type is encrypted as soon as it's read. Opening the copy, destroying it, or
/// reaching its expiry discards the key and the ciphertext, so a copy left behind can't be
/// decrypted. It is never written to disk.
final class SealedClipboard: Sendable {
    struct Item: Sendable {
        let types: [String]
        let sealed: [String: Data]
    }
    private struct Contents: Sendable {
        var key: SymmetricKey?
        var items: [Item] = []
    }
    private let contents: OSAllocatedUnfairLock<Contents>

    /// Longest time a copy is kept, whatever the restore delay.
    static let maxLifetime: TimeInterval = 10

    /// Seconds from creation until the copy destroys itself.
    let lifetime: TimeInterval

    init(key: SymmetricKey, items: [Item], expiresAfter requested: TimeInterval) {
        contents = OSAllocatedUnfairLock(initialState: Contents(key: key, items: items))
        lifetime = min(requested, Self.maxLifetime)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lifetime) { [weak self] in
            self?.destroy()
        }
    }

    /// Seals an already-read backup. Nil when encryption fails.
    convenience init?(_ backup: TypingService.ClipboardBackup, expiresAfter lifetime: TimeInterval) {
        let key = SymmetricKey(size: .bits256)
        var items: [Item] = []
        for item in backup.items {
            var sealed: [String: Data] = [:]
            for type in item.typeRawValues {
                guard let data = item.dataMap[type], let box = Self.seal(data, with: key) else { return nil }
                sealed[type] = box
            }
            items.append(Item(types: item.typeRawValues, sealed: sealed))
        }
        self.init(key: key, items: items, expiresAfter: lifetime)
    }

    static func seal(_ data: Data, with key: SymmetricKey) -> Data? {
        try? AES.GCM.seal(data, using: key).combined
    }

    /// Decrypts the copy once and destroys it. Nil after the first call or after expiry.
    func open() -> TypingService.ClipboardBackup? {
        let (key, items) = contents.withLock { c -> (SymmetricKey?, [Item]) in
            defer { c = Contents() }
            return (c.key, c.items)
        }
        guard let key else { return nil }
        var opened: [TypingService.ClipboardBackup.Item] = []
        for item in items {
            var dataMap: [String: Data] = [:]
            for type in item.types {
                guard let box = item.sealed[type].flatMap({ try? AES.GCM.SealedBox(combined: $0) }),
                      let data = try? AES.GCM.open(box, using: key) else { return nil }
                dataMap[type] = data
            }
            opened.append(TypingService.ClipboardBackup.Item(typeRawValues: item.types, dataMap: dataMap))
        }
        return TypingService.ClipboardBackup(items: opened)
    }

    var isDestroyed: Bool { contents.withLock { $0.key == nil } }

    func destroy() { contents.withLock { $0 = Contents() } }
}

extension TypingService {
    /// Writes a sensitive string to the pasteboard, clearing it, setting the
    /// local-only host restriction, and marking it as concealed/transient.
    static func writeSensitiveString(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: [.currentHostOnly])
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    /// A decrypted clipboard copy, as it's written back.
    struct ClipboardBackup: Sendable {
        struct Item: Sendable {
            let typeRawValues: [String]
            let dataMap: [String: Data]
        }
        let items: [Item]
    }

    /// Whether a paste may read the clipboard so it can restore it afterward: only when the user
    /// turned restore on and macOS already allows SideWave to read it. In any other state a read
    /// can raise a macOS permission alert, which in the middle of a paste could take focus from
    /// the target.
    static func mayBackUpClipboard(restoreEnabled: Bool, access: NSPasteboard.AccessBehavior) -> Bool {
        restoreEnabled && access == .alwaysAllow
    }

    /// Reads one type from the clipboard and discards it, so that macOS asks about clipboard
    /// access when the user turns restore on rather than during a paste. Call it off the main
    /// thread; the read waits while macOS shows its alert.
    static func requestClipboardAccess() {
        let pasteboard = NSPasteboard.general
        guard let item = pasteboard.pasteboardItems?.first, let type = item.types.first else { return }
        _ = item.data(forType: type)
    }

    /// Longest wait for the clipboard backup before a paste. Clipboard data can be a promise
    /// that another process fills on request, such as Screen Sharing or Universal Clipboard
    /// fetching it from another Mac or device. When that device doesn't answer, each read waits
    /// about 45 s, so the paste goes ahead without a backup instead.
    static let clipboardBackupTimeout: TimeInterval = 1.0

    /// Largest field value, in UTF-16 units, read back to confirm a paste. Larger fields cost
    /// more to copy over Accessibility and compare than the check is worth.
    static let maxVerifiableFieldLength = 100_000

    /// Pasteboard change count right after our last writeSensitiveString. The count only increases,
    /// so while the pasteboard still reports this value, our dictation text is what's on it rather
    /// than the user's clipboard.
    private static let lastSensitiveWriteChangeCount = Mutex<Int?>(nil)

    /// The user's clipboard saved before the first of several quick pastes, so a later paste that
    /// finds our own text still there restores the user's copy instead of saving ours.
    private static let pendingClipboardBackup = Mutex<SealedClipboard?>(nil)

    /// Copies every item and type on the pasteboard, encrypting each type as soon as it's read.
    /// The reads run on their own thread because one can wait on another process; returns nil
    /// when they don't finish within `timeout`. The abandoned thread stops before its next read
    /// and drops what it holds, which is encrypted.
    static func backupClipboard(named name: NSPasteboard.Name, timeout: TimeInterval,
                                expiresAfter lifetime: TimeInterval) -> SealedClipboard? {
        struct Read: Sendable {
            var abandoned = false
            var items: [SealedClipboard.Item]?
        }
        let key = SymmetricKey(size: .bits256)
        let read = OSAllocatedUnfairLock(initialState: Read())
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            let pasteboard = NSPasteboard(name: name)
            let startCount = pasteboard.changeCount
            var items: [SealedClipboard.Item] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var types: [String] = []
                var sealed: [String: Data] = [:]
                for type in item.types {
                    guard !read.withLock({ $0.abandoned }), pasteboard.changeCount == startCount else { return }
                    guard let data = item.data(forType: type) else { continue }
                    guard let box = SealedClipboard.seal(data, with: key) else { return }
                    types.append(type.rawValue)
                    sealed[type.rawValue] = box
                }
                if !types.isEmpty { items.append(SealedClipboard.Item(types: types, sealed: sealed)) }
            }
            let done = items
            read.withLock { $0.items = done }
            finished.signal()
        }
        reader.name = "SideWave clipboard backup"
        reader.qualityOfService = .userInitiated
        reader.start()
        guard finished.wait(timeout: .now() + timeout) == .success,
              let items = read.withLock({ $0.items }) else {
            read.withLock { $0.abandoned = true }
            return nil
        }
        return SealedClipboard(key: key, items: items, expiresAfter: lifetime)
    }

    /// Writes a saved clipboard back, local to this Mac, so restoring never offers it to
    /// Universal Clipboard when the original was kept local.
    private static func restoreClipboard(_ backup: ClipboardBackup, to pb: NSPasteboard) {
        pb.prepareForNewContents(with: [.currentHostOnly])
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

    /// Pastes through the clipboard. Sends Command-V to `targetPID` when given, otherwise
    /// system-wide. Returns a PasteOutcome so the caller can try another method after a confirmed
    /// failure.
    ///
    /// By default the clipboard is never read: the dictation replaces what was there and stays on
    /// it. With restore turned on (`restoresClipboard`) and allowed by macOS, the previous
    /// contents are read, sealed in memory, and put back after the paste.
    func insertTextViaClipboard(
        _ text: String, targetPID: pid_t? = nil, expectedPID: pid_t? = nil, ticket: PasteTicket? = nil
    ) -> PasteOutcome {
        guard let expectedPID = expectedPID ?? targetPID, Self.targetStillFocused(expectedPID) else { return .failed }
        let baseline = Self.capturePasteBaseline(targetPID: targetPID)
        let pasteboard = NSPasteboard.general

        let backup: SealedClipboard?
        if Self.mayBackUpClipboard(restoreEnabled: Self.restoresClipboard, access: pasteboard.accessBehavior) {
            // Don't save our own text as the user's clipboard. After quick consecutive pastes, the
            // previous dictation can still be on the pasteboard while its restore waits; saving it
            // would later restore our text and lose the user's copy. If the change count still
            // matches our last write, reuse the backup from the first paste.
            let ourStringStillPresent = Self.lastSensitiveWriteChangeCount.withLock { $0 } == pasteboard.changeCount
            if ourStringStillPresent, let pending = Self.pendingClipboardBackup.withLock({ $0 }), !pending.isDestroyed {
                backup = pending
            } else {
                // Nil when the clipboard owner didn't answer in time. That clipboard can't be
                // pasted anywhere until its owner answers, so the paste goes ahead without it.
                backup = Self.backupClipboard(named: pasteboard.name, timeout: Self.clipboardBackupTimeout,
                                              expiresAfter: Double(Self.clipboardRestoreDelayMs()) / 1000 + 5)
                Self.pendingClipboardBackup.withLock { $0 = backup }
                if backup == nil {
                    SWLog.note("[TypingService] Clipboard not saved within \(Self.clipboardBackupTimeout) s; pasting without restoring it")
                }
            }
        } else {
            backup = nil
        }
        func restore(to pb: NSPasteboard) {
            if let saved = backup?.open() { Self.restoreClipboard(saved, to: pb) }
        }

        // The clipboard write is the first change the user would see.
        guard Self.targetStillFocused(expectedPID), ticket?.beginSending() ?? true else { return .failed }
        Self.writeSensitiveString(text, to: pasteboard)
        let ourChangeCount = pasteboard.changeCount
        Self.lastSensitiveWriteChangeCount.withLock { $0 = ourChangeCount }

        // Cmd+V using the layout-resolved keycode for 'V' (see vKeyCode).
        guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.vKeyCode, keyDown: true),
              let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.vKeyCode, keyDown: false)
        else {
            restore(to: pasteboard)
            return .failed
        }

        guard Self.targetStillFocused(expectedPID) else {
            if pasteboard.changeCount == ourChangeCount { restore(to: pasteboard) }
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
            guard let backup else { return }
            DispatchQueue.global(qos: .utility).async {
                if delayMs > 0 {
                    // Thread.sleep, not usleep: the delay is user-tunable and
                    // can exceed usleep's ~1s ceiling, which would silently no-op.
                    Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
                }
                let pb = NSPasteboard.general
                guard pb.changeCount == ourChangeCount && pb.string(forType: .string) == text,
                      let saved = backup.open() else { return }
                Self.restoreClipboard(saved, to: pb)
                // The user's clipboard is restored and the sealed copy is destroyed.
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
            if backup != nil, pb.changeCount == ourChangeCount, pb.string(forType: .string) == text {
                restore(to: pb)
                Self.pendingClipboardBackup.withLock { $0 = nil }
            }
            return .failed
        }
    }

    /// Normalizes text for tolerant comparison in verifyPasteDelivery. Lowercases,
    /// standardizes punctuation/quotes/dashes, and collapses all whitespace sequences.
    static func normalizeForAXComparison(_ str: String) -> String {
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
        // A terminal's value is its whole scrollback, often megabytes, and verification treats
        // terminals as unconfirmable anyway. Reading and comparing it added seconds to each paste.
        if isTerminal(pid: pid) { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              value.utf16.count <= maxVerifiableFieldLength else { return nil }
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
