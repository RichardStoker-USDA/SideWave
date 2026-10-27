// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Synchronization
import XCTest
@testable import SideWaveKit

/// A paste must always report back, and a clipboard whose owner doesn't answer must not hold it.
/// Field case: Screen Sharing owned the clipboard as a promise from a remote Mac that stopped
/// answering. The clipboard backup waited 45 s per type, so the paste never ran and the session
/// stayed on Finishing until the app was quit.
final class PasteDeadlineTests: XCTestCase {

    private final class Outcomes: Sendable {
        private let list = Mutex<[PasteOutcome]>([])
        func append(_ outcome: PasteOutcome) { list.withLock { $0.append(outcome) } }
        var all: [PasteOutcome] { list.withLock { $0 } }
    }

    // MARK: - Ticket

    func testDeadlineBeforeAnythingIsSentReportsTimedOutAndBarsLaterSending() {
        let outcomes = Outcomes()
        let ticket = PasteTicket { outcomes.append($0) }

        XCTAssertTrue(ticket.expire())
        XCTAssertTrue(ticket.isAbandoned)
        XCTAssertFalse(ticket.beginSending(), "a stalled worker must not paste after the deadline")
        ticket.report(.verified)

        XCTAssertEqual(outcomes.all, [.timedOut])
    }

    func testDeadlineAfterSendingStartedReportsAssumedAndBarsAnotherMethod() {
        let outcomes = Outcomes()
        let ticket = PasteTicket { outcomes.append($0) }

        XCTAssertTrue(ticket.beginSending())
        XCTAssertFalse(ticket.expire(), "the method already sending keeps the typing slot until it ends")
        XCTAssertFalse(ticket.beginSending(),
                       "after the caller moved on, a fallback could paste late or into another window")
        ticket.report(.failed)

        XCTAssertEqual(outcomes.all, [.assumed])
    }

    func testWorkerOutcomeWinsWhenItReportsFirst() {
        let outcomes = Outcomes()
        let ticket = PasteTicket { outcomes.append($0) }

        XCTAssertTrue(ticket.beginSending())
        ticket.report(.verified)
        XCTAssertFalse(ticket.expire())

        XCTAssertEqual(outcomes.all, [.verified])
    }

    func testTimedOutPasteDoesNotCountAsLanded() {
        XCTAssertFalse(PasteOutcome.timedOut.landed)
    }

    func testOnlyATimedOutAccessibilityWriteMayStillLand() {
        // After a timeout the app may still insert the text, so a clipboard fallback could paste
        // it twice. Any other error means the app rejected it, and the fallback must run.
        XCTAssertTrue(PasteEngine.axWriteMayStillApply(.cannotComplete))
        XCTAssertFalse(PasteEngine.axWriteMayStillApply(.failure))
        XCTAssertFalse(PasteEngine.axWriteMayStillApply(.attributeUnsupported))
        XCTAssertFalse(PasteEngine.axWriteMayStillApply(.success))
    }

    // MARK: - Clipboard backup

    private final class SlowProvider: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            Thread.sleep(forTimeInterval: 1.5)
            item.setString("<b>late</b>", forType: type)
        }
    }

    private var pasteboard: NSPasteboard!
    private let provider = SlowProvider()

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.sidewave.kittests.paste-deadline.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testBackupGivesUpOnAClipboardOwnerThatDoesNotAnswer() {
        let item = NSPasteboardItem()
        item.setString("copied text", forType: .string)
        item.setDataProvider(provider, forTypes: [.html])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let start = CFAbsoluteTimeGetCurrent()
        let backup = PasteEngine.backupClipboard(named: pasteboard.name, timeout: 0.3, expiresAfter: 5)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertNil(backup)
        XCTAssertLessThan(elapsed, 1.0, "the backup must stop waiting at its timeout")
    }

    func testRestoreDelayStaysWithinTheCopyLifetime() {
        XCTAssertLessThanOrEqual(Double(PasteEngine.clipboardRestoreDelayMs()) / 1000 + 5, SealedClipboard.maxLifetime)
    }

    func testBackupCopiesEveryTypeFromAClipboardThatAnswers() throws {
        let item = NSPasteboardItem()
        item.setString("copied text", forType: .string)
        item.setString("<b>copied</b>", forType: .html)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let sealed = try XCTUnwrap(PasteEngine.backupClipboard(named: pasteboard.name, timeout: 1.0, expiresAfter: 5))
        let backup = try XCTUnwrap(sealed.open())

        XCTAssertEqual(backup.items.count, 1)
        let saved = try XCTUnwrap(backup.items.first)
        XCTAssertEqual(saved.dataMap[NSPasteboard.PasteboardType.string.rawValue], Data("copied text".utf8))
        XCTAssertEqual(saved.dataMap[NSPasteboard.PasteboardType.html.rawValue], Data("<b>copied</b>".utf8))
    }
}
