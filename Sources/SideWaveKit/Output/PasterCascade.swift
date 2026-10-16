// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Foundation

/// The `Paster` seam over the carried paste engine. The engine's cascade
/// (activate target -> AX insertion -> clipboard Cmd+V with layout-aware
/// keycode -> HID typing), its clipboard backup/restore, its delivery
/// verification, and the explicit-flags hygiene on every synthesized
/// event all ride along unchanged; this adapter only bridges the async
/// seam and maps the outcome.
public actor PasterCascade: Paster {

    private let engine = PasteEngine()

    public init() {}

    /// Must run once on the main thread at app startup: macOS 27 asserts
    /// the calling queue inside the TIS keyboard-layout query this warms.
    @MainActor
    public static func warmUpKeyboardLayout() {
        PasteEngine.warmUpKeyboardLayoutCache()
    }

    /// Shell hook for the missing-Accessibility alert.
    public static func setAccessibilityMissingHandler(_ handler: @escaping @Sendable () -> Void) {
        PasteEngine.onAccessibilityMissing = handler
    }

    /// AX-based capture of the app that owns keyboard focus right now.
    /// Call at gesture time, BEFORE any UI of ours could steal focus, so
    /// the paste lands where the user was typing.
    public static func captureSystemFocusedPID() -> pid_t? {
        PasteEngine.captureSystemFocusedPID()
    }

    public func paste(_ text: String, targetPID: pid_t?) async -> PasteResult {
        // Activate the target first, the way the proven call path did:
        // the engine expects the destination app frontmost.
        if let pid = targetPID, PasteEngine.isAppStillAlive(pid: pid) {
            _ = PasteEngine.activateApp(pid: pid)
            try? await Task.sleep(for: .milliseconds(60))
        }

        let outcome: PasteOutcome = await withCheckedContinuation { continuation in
            engine.typeTextInstantly(text, preferredTargetPID: targetPID) { result in
                continuation.resume(returning: result)
            }
        }

        switch outcome {
        case .verified:
            return .verified
        case .assumed:
            return .assumed
        case .failed:
            return .failed(reason: "The text could not be inserted. It is on your clipboard — press Cmd+V to paste it.")
        case .blockedSecureInput:
            return .failed(reason: "Another app is blocking keyboard input (secure input). The text is on your clipboard.")
        }
    }
}
