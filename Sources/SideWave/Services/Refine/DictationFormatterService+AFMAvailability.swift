// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

#if canImport(FoundationModels)

extension DictationFormatterService {
    /// Re-checks availability when the app is brought back to foreground
    /// (user may have just enabled Apple Intelligence in System Settings).
    func refreshAFMAvailability() {
        guard activeBackend == .appleIntelligence || activeBackend == .appleIntelligenceLegacy else { return }
        // Refresh only when unavailable; leave ready or generating alone.
        if case .unavailable = state {
            Task { [weak self] in
                await self?.loadAppleIntelligence()
            }
        }
    }

    nonisolated static func afmUnavailableMessage(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence. Switch to Gemma 4 to use Refine on this device."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri."
        case .modelNotReady:
            return "Apple Intelligence is still downloading. Check back in a few minutes."
        @unknown default:
            return "Apple Intelligence is unavailable."
        }
    }

    /// Apple Intelligence availability for onboarding, launch checks, and dictation. Checked on
    /// every call because the user can turn Apple Intelligence off in System Settings at any time.
    enum AFMAvailability: Equatable {
        case available
        case unavailable(reason: String, kind: AFMUnavailabilityKind)
    }

    enum AFMUnavailabilityKind: Equatable {
        case appleIntelligenceNotEnabled  // user-fixable, deep-link to Settings
        case deviceNotEligible            // permanent, route to Gemma silently
        case modelNotReady                // transient, retry later
        case unknown                      // future-proof @unknown default
    }

    nonisolated static func currentAFMAvailability() -> AFMAvailability {
        let model = AFMRuntime.makeModel()
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .unavailable(
                    reason: afmUnavailableMessage(for: reason),
                    kind: .appleIntelligenceNotEnabled
                )
            case .deviceNotEligible:
                return .unavailable(
                    reason: afmUnavailableMessage(for: reason),
                    kind: .deviceNotEligible
                )
            case .modelNotReady:
                return .unavailable(
                    reason: afmUnavailableMessage(for: reason),
                    kind: .modelNotReady
                )
            @unknown default:
                return .unavailable(
                    reason: "Apple Intelligence is unavailable.",
                    kind: .unknown
                )
            }
        @unknown default:
            return .unavailable(
                reason: "Apple Intelligence is unavailable on this device.",
                kind: .unknown
            )
        }
    }

    /// The context window, queried at runtime because Apple may enlarge it. `contextSize` exists on
    /// macOS 26.4 and later; earlier versions return the documented fallback from AFMRuntime.
    nonisolated static func afmContextSize() -> Int {
        if #available(macOS 26.4, *) {
            return AFMRuntime.makeModel().contextSize
        }
        return AFMRuntime.fallbackContextWindow
    }

    /// Token usage of a refine prompt against the live window: (used, cap, ratio). Lets generation
    /// fall back before `.exceededContextWindowSize` is thrown mid-stream. macOS 26.4 and later.
    @available(macOS 26.4, *)
    nonisolated static func afmTokenUsage(forPrompt prompt: String, template: Template) async -> (used: Int, cap: Int, ratio: Double)? {
        let model = AFMRuntime.makeModel()
        guard case .available = model.availability else { return nil }
        let promptObj = Prompt(prompt)
        guard let used = try? await model.tokenCount(for: promptObj) else { return nil }
        let cap = model.contextSize
        let ratio = cap > 0 ? Double(used) / Double(cap) : 0
        return (used: used, cap: cap, ratio: ratio)
    }
}
#endif
