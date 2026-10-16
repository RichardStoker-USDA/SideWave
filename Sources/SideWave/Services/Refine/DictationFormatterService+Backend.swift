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

@MainActor
extension DictationFormatterService {
    // MARK: - Backend

    /// Which local language model powers dictation cleanup. The user picks
    /// one in Settings; the service loads/unloads on switch.
    enum Backend: String, CaseIterable, Sendable, Identifiable {
        case gemma4E2B = "gemma4-e2b"
        case gemma4E4B = "gemma4-e4b"
        case gemma4_12B = "gemma4-12b"
        case appleIntelligence = "apple-intelligence"
        case appleIntelligenceLegacy = "apple-intelligence-legacy"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gemma4E2B: return "Gemma 4 E2B"
            case .gemma4E4B: return "Gemma 4 E4B"
            case .gemma4_12B: return "Gemma 4 12B"
            case .appleIntelligence:
                return AFMRuntime.generation == .gen2 ? "Apple Intelligence (AFM 3)" : "Apple Intelligence"
            case .appleIntelligenceLegacy: return "Apple Intelligence (Legacy)"
            }
        }

        /// Short label used in the overlay header.
        var overlayLabel: String {
            switch self {
            case .gemma4E2B: return "Gemma 4 E2B"
            case .gemma4E4B: return "Gemma 4 E4B"
            case .gemma4_12B: return "Gemma 4 12B"
            case .appleIntelligence:
                return AFMRuntime.generation == .gen2 ? "Apple Intelligence (AFM 3)" : "Apple Intelligence"
            case .appleIntelligenceLegacy: return "Apple Intelligence (Legacy)"
            }
        }

        /// Approximate on-disk size for the user-facing download description.
        var diskSize: String {
            switch self {
            case .gemma4E2B: return "~3 GB"
            case .gemma4E4B: return "~5.2 GB"
            case .gemma4_12B: return "~6.8 GB"
            case .appleIntelligence, .appleIntelligenceLegacy: return "0 GB"
            }
        }

        /// Approximate memory use while loaded, for the hardware check and the warning before a
        /// large download.
        var ramRequiredGB: Int {
            switch self {
            case .gemma4E2B: return 4
            case .gemma4E4B: return 6
            case .gemma4_12B: return 10
            case .appleIntelligence, .appleIntelligenceLegacy: return 0
            }
        }

        /// Short tagline displayed in the picker.
        var description: String {
            switch self {
            case .gemma4E2B: return "Lighter model. Faster on most Macs."
            case .gemma4E4B: return "Balanced speed and document editing. 16 GB+ recommended."
            case .gemma4_12B: return "Larger model for complex edits. Slower; 24 GB+ recommended."
            case .appleIntelligence:
                return AFMRuntime.generation == .gen2
                    ? "Third-gen AFM 3 on-device model. Faster and highly precise."
                    : "Free, ships with macOS. Faster but less consistent."
            case .appleIntelligenceLegacy: return "Legacy Tahoe on-device model with fallback workaround."
            }
        }

        /// HuggingFace repository the backend pulls weights from. Returns nil
        /// for backends that don't have a HF source (Apple Intelligence is
        /// OS-owned, not a downloaded model).
        var huggingFaceRepoID: String? {
            switch self {
            case .gemma4E2B: return "mlx-community/gemma-4-e2b-it-4bit"
            case .gemma4E4B: return "mlx-community/gemma-4-e4b-it-4bit"
            case .gemma4_12B: return "mlx-community/gemma-4-12B-it-4bit"
            case .appleIntelligence, .appleIntelligenceLegacy: return nil
            }
        }

        /// Marks the backend as a core requirement vs optional. The recovery
        /// window uses this to phrase the surface ("required for refine" vs
        /// "you turned on the bigger model").
        var isRequired: Bool {
            switch self {
            case .gemma4E2B: return true
            case .gemma4E4B, .gemma4_12B, .appleIntelligence, .appleIntelligenceLegacy: return false
            }
        }

        /// Context window in tokens. Apple Intelligence is queried at runtime on macOS 26.4 and
        /// later (4096 today). Gemma's window is much larger, but each refine's budget is bounded
        /// to keep latency reasonable. The preview's remaining-room estimate uses this value minus
        /// the output headroom.
        var contextCap: Int {
            switch self {
            case .gemma4E2B, .gemma4E4B, .gemma4_12B:
                // The Gemma 4 E2B and E4B model cards list 128K, but at 4-bit on Apple Silicon a
                // 16K working budget keeps time to first token bounded, and long dictations stay
                // well under it.
                return 16_384
            case .appleIntelligence, .appleIntelligenceLegacy:
                // The live value comes from SystemLanguageModel.contextSize (macOS 26.4 and later,
                // 4096 today) through afmContextSize(); this fallback matches Apple's documented
                // size.
                return AFMRuntime.fallbackContextWindow
            }
        }

        /// Tokens reserved for the refined output, subtracted from `contextCap` to get the input
        /// budget. Apple Intelligence shares one window for input and output, so it needs more.
        var outputHeadroomTokens: Int {
            switch self {
            case .gemma4E2B, .gemma4E4B, .gemma4_12B: return 1_024
            case .appleIntelligence, .appleIntelligenceLegacy: return 512
            }
        }

        /// Backends the user can choose. `.appleIntelligenceLegacy` isn't offered: on macOS 26 the first
        /// generation model is `.appleIntelligence` (generation differences key off
        /// `AFMRuntime.generation`), and macOS 27 can't select it. The case remains so a stored value still
        /// decodes; AppState maps it to `.appleIntelligence` on load.
        static var availableBackends: [Backend] {
            [.gemma4E2B, .gemma4E4B, .gemma4_12B, .appleIntelligence]
        }
    }
}
