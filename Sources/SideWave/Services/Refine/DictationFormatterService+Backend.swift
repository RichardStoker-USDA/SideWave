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
    /// Memory SideWave's loaded Gemma model and MLX's buffer cache hold now; 0 without one. Fit
    /// checks count it as free, since switching models releases it.
    var loadedModelMemoryBytes: UInt64 {
        guard modelContainer != nil else { return 0 }
        return UInt64(max(0, MLX.Memory.activeMemory + MLX.Memory.cacheMemory))
    }

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

        /// Download size of the model repository, from its file listing on Hugging Face. Nil for
        /// Apple Intelligence, which macOS provides.
        var downloadBytes: UInt64? {
            switch self {
            case .gemma4E2B: return 3_580_000_000
            case .gemma4E4B: return 5_180_000_000
            case .gemma4_12B: return 6_770_000_000
            case .appleIntelligence, .appleIntelligenceLegacy: return nil
            }
        }

        /// Memory the model holds while refining, for the fit shown in Settings > Refine. Measured
        /// with MLX on an M4 Max (macOS 27.3, November 2026): the peak over twelve session turns
        /// of a long dictation and over a long document pass, plus 0.5 GB for MLX's buffer cache,
        /// rounded up to a half binary gigabyte. Peaks in decimal GB: E2B 3.5 (2.6 of weights), E4B
        /// 5.1 (4.2), 12B 8.4 (6.7). Nil for Apple
        /// Intelligence, which runs in macOS outside SideWave's memory.
        var workingBytes: UInt64? {
            switch self {
            case .gemma4E2B: return 4 * 1_073_741_824
            case .gemma4E4B: return 11 * 536_870_912
            case .gemma4_12B: return 17 * 536_870_912
            case .appleIntelligence, .appleIntelligenceLegacy: return nil
            }
        }

        /// Download size for user-facing text, such as "3.6 GB".
        var diskSize: String {
            downloadBytes.map { RefineModelFit.gigabytes($0) } ?? "0 GB"
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
