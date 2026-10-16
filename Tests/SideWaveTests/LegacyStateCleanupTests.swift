// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class LegacyStateCleanupTests: XCTestCase {
    func testRemovesVoiceAgentStateOnceAndKeepsRelay() throws {
        let suite = "sidewave_tests.legacy_\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidewave_legacy_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for key in LegacyStateCleanup.removedDefaultsKeys { defaults.set(true, forKey: key) }
        defaults.set(true, forKey: "relayModeEnabled")
        let socket = folder.appendingPathComponent("sidewave-mcp.sock")
        try Data().write(to: socket)

        LegacyStateCleanup.run(defaults: defaults, temporaryDirectory: folder, removeKeychainItem: false)

        for key in LegacyStateCleanup.removedDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertTrue(defaults.bool(forKey: "relayModeEnabled"), "Relay is a separate feature and stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))

        // Runs once: a later launch leaves settings alone.
        defaults.set(true, forKey: "mcpServerEnabled")
        LegacyStateCleanup.run(defaults: defaults, temporaryDirectory: folder, removeKeychainItem: false)
        XCTAssertTrue(defaults.bool(forKey: "mcpServerEnabled"))
    }
}
