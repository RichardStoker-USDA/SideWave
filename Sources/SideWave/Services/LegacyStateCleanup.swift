// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import Security

/// Removes state left by features that earlier versions had: the voice agent server's settings,
/// its old bearer-token keychain item, and its socket and log files. Runs once.
enum LegacyStateCleanup {
    static let doneKey = "legacyAgentStateRemoved"

    static let removedDefaultsKeys = [
        "mcpServerEnabled", "mcpAuthEnabled", "mcpAuthToken", "legacyMCPAuthCredentialPurged", "selectedTTSVoice",
    ]

    static let removedTemporaryFiles = ["sidewave-mcp.sock", "sidewave-mcp-dev.sock", "sidewave-mcp-debug.log"]

    static func run(
        defaults: UserDefaults = .standard,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
        removeKeychainItem: Bool = true
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for key in removedDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        for name in removedTemporaryFiles {
            try? FileManager.default.removeItem(at: temporaryDirectory.appendingPathComponent(name))
        }
        if removeKeychainItem {
            // errSecItemNotFound is the usual result; there is nothing to report either way.
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.sidewave.mcp-auth-token",
                kSecAttrAccount as String: "mcp-bearer-token",
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
        defaults.set(true, forKey: doneKey)
    }
}
