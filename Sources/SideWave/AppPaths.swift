// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Provides bundle-aware paths so Debug and Release builds don't share state.
///
/// Debug builds use bundle ID `com.sidewave.app.dev` and store their data under
/// `SideWave-Dev`. Release builds use `com.sidewave.app` and `SideWave`. This
/// keeps dev iteration from clobbering a user's real history/meetings/models
/// when both versions are installed side-by-side.
enum AppPaths {
    static var isTestHost: Bool {
        ProcessInfo.processInfo.arguments.contains("-XCTest")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    #if DEBUG
    /// Debug builds label windows with their size and build number. Capture runs turn the labels
    /// off with `-sideWaveCleanCapture YES` or the `SIDEWAVE_SITE_SCREENSHOTS` test variable, so
    /// screenshots look like a release build.
    static var showsDebugLabels: Bool {
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["sideWaveCleanCapture"]
        if (argument as? Bool) == true || (argument as? String)?.uppercased() == "YES" { return false }
        return ProcessInfo.processInfo.environment["SIDEWAVE_SITE_SCREENSHOTS"] == nil
    }
    #endif

    private static let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidewave_tests_" + UUID().uuidString, isDirectory: true)

    /// Directory name inside `~/Library/Application Support/` (or the temp
    /// fallback). Returns `SideWave-Dev` for Debug builds, `SideWave` for
    /// Release builds.
    static var supportDirectoryName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sidewave.app"
        return bundleID.hasSuffix(".dev") ? "SideWave-Dev" : "SideWave"
    }

    /// Returns `~/Library/Application Support/SideWave[-Dev]`, creating it
    /// if missing. Falls back to the temp directory if Application Support
    /// is unavailable.
    static func applicationSupportDirectory() -> URL {
        #if DEBUG
        // Launch-argument override for staged capture runs: point the whole
        // data directory (history, vocabulary, sessions) at a scratch folder
        // so screenshots and screen recordings never show real user data.
        // Argument-domain only, so it can't persist by accident:
        //   SideWave_Dev -sideWaveDataDirOverride /tmp/staged
        if let override = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["sideWaveDataDirOverride"] as? String,
           !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        if isTestHost {
            try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return testDirectory
        }
        let baseDir: URL
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            baseDir = appSupport
        } else {
            baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
        }
        let appDir = baseDir.appendingPathComponent(supportDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        // Restrict access to owner-only so other users cannot list files/sessions
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDir.path)
        return appDir
    }
}
