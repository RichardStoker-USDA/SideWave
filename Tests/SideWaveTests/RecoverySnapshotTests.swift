// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class RecoverySnapshotTests: XCTestCase {
    func testFirstSnapshotAndReplacementBothReachDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.volatile")
        for text in ["First partial phrase", "The complete phrase with its ending", "日本語 and 🌿"] {
            try TranscriptionService.writeRecoverySnapshot(text, to: url)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
}
