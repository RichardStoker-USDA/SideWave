// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import XCTest
@testable import SideWave

/// SideWave reads the clipboard only when the user turned on restore and macOS allows the read
/// without an alert. A copy it reads is sealed in memory and can't be opened after use or expiry.
final class ClipboardPrivacyTests: XCTestCase {

    // MARK: - When the clipboard may be read

    func testClipboardIsNeverReadWithRestoreOff() {
        for access: NSPasteboard.AccessBehavior in [.default, .ask, .alwaysAllow, .alwaysDeny] {
            XCTAssertFalse(TypingService.mayBackUpClipboard(restoreEnabled: false, access: access),
                           "read with restore off for access \(access.rawValue)")
        }
    }

    func testRestoreReadsOnlyWhenMacOSAlreadyAllowsIt() {
        XCTAssertTrue(TypingService.mayBackUpClipboard(restoreEnabled: true, access: .alwaysAllow))
        // `.default` asks on the first programmatic read; an alert in the middle of a paste could
        // take focus from the target.
        XCTAssertFalse(TypingService.mayBackUpClipboard(restoreEnabled: true, access: .default))
        XCTAssertFalse(TypingService.mayBackUpClipboard(restoreEnabled: true, access: .ask))
        XCTAssertFalse(TypingService.mayBackUpClipboard(restoreEnabled: true, access: .alwaysDeny))
    }

    // MARK: - Sealed copy

    private func sampleBackup() -> TypingService.ClipboardBackup {
        TypingService.ClipboardBackup(items: [
            .init(typeRawValues: [NSPasteboard.PasteboardType.string.rawValue],
                  dataMap: [NSPasteboard.PasteboardType.string.rawValue: Data("copied text".utf8)])
        ])
    }

    func testSealedCopyOpensOnceWithTheOriginalContents() throws {
        let sealed = try XCTUnwrap(SealedClipboard(sampleBackup(), expiresAfter: 60))
        XCTAssertFalse(sealed.isDestroyed)

        let opened = try XCTUnwrap(sealed.open())
        XCTAssertEqual(opened.items.first?.dataMap[NSPasteboard.PasteboardType.string.rawValue],
                       Data("copied text".utf8))
        XCTAssertTrue(sealed.isDestroyed)
        XCTAssertNil(sealed.open(), "a restored copy must not be readable again")
    }

    func testDestroyedCopyCannotBeOpened() throws {
        let sealed = try XCTUnwrap(SealedClipboard(sampleBackup(), expiresAfter: 60))
        sealed.destroy()
        XCTAssertNil(sealed.open())
    }

    func testLifetimeIsCappedWhateverTheRestoreDelay() throws {
        let sealed = try XCTUnwrap(SealedClipboard(sampleBackup(), expiresAfter: 3600))
        XCTAssertEqual(sealed.lifetime, 10)
        XCTAssertEqual(try XCTUnwrap(SealedClipboard(sampleBackup(), expiresAfter: 2)).lifetime, 2)
    }

    func testUnusedCopyIsDestroyedAtExpiry() throws {
        let sealed = try XCTUnwrap(SealedClipboard(sampleBackup(), expiresAfter: 0.1))
        let expired = expectation(description: "copy destroyed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if sealed.isDestroyed { expired.fulfill() }
        }
        wait(for: [expired], timeout: 2)
        XCTAssertNil(sealed.open())
    }
}
