// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Shared engine presets for Dictation and Home's advanced controls.
enum ExperiencePreset {
    static let experienceKey = "sideWaveExperience"

    static func isRecognitionOnly(_ defaults: UserDefaults = .standard) -> Bool {
        ["standard", "speedy"].contains(defaults.string(forKey: experienceKey) ?? "full")
            && defaults.bool(forKey: "skipRefine")
    }

    static func description(for experience: String, refinementEnabled: Bool) -> String {
        switch experience {
        case "standard":
            return refinementEnabled
                ? "Two speech engines for a live preview, with refinement enabled."
                : "Two speech engines for a live preview and confirmed text. No AI refinement."
        case "speedy":
            return refinementEnabled
                ? "Parakeet only, with refinement when you finish."
                : "Parakeet only. Text updates in short batches. No AI refinement."
        default:
            return refinementEnabled
                ? "Live speech preview with on-device text refinement."
                : "Two speech engines for a live preview. Refinement is turned off."
        }
    }

    /// Valid values: "full" (Complete), "standard" (Basic), "speedy"
    /// (Minimalistic). Unknown strings are ignored.
    @MainActor
    static func apply(_ experience: String, appState: AppState) {
        guard ["full", "standard", "speedy"].contains(experience),
              !appState.isDictationBusy, !appState.isProcessingAgenticEdit,
              appState.pendingSessionText == nil else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "skipRefineAutoForced")
        if experience != "full" {
            appState.selectDictationOutput(nil)
            appState.dictationCleanupEnabled = false
        }
        switch experience {
        case "full":
            defaults.set(true, forKey: "useDualEngineSmartPTT")
            defaults.set(true, forKey: "useMultiStageRendering")
            defaults.set(true, forKey: "useRealTimeRefine")
            defaults.set(false, forKey: "skipRefine")
            defaults.set(true, forKey: "tdtHiddenRefineSweep")
            defaults.set(false, forKey: "useEouToRefineDirect")
            defaults.set(true, forKey: "showLiveGhostText")
            defaults.set(true, forKey: "performFinalRefinePass")
            // Live refine is meaningless without the model loaded. Enable it
            // last so skipRefine = false above stands on capable machines; on
            // <8 GB Macs the didSet bounces this back off and re-pins
            // skipRefine, leaving the preset coherent either way.
            appState.dictationCleanupEnabled = true
        case "standard":
            // Basic: the live dual-engine preview (TDT + EOU streaming) with
            // the heavy MLX refine pass turned off. Middle tier (lighter than
            // Complete, no GPU polishing) but still the fast, fluid live
            // transcript, not a single-engine fallback.
            defaults.set(true, forKey: "useDualEngineSmartPTT")
            defaults.set(true, forKey: "useMultiStageRendering")
            defaults.set(false, forKey: "useRealTimeRefine")
            defaults.set(true, forKey: "skipRefine")
            defaults.set(false, forKey: "tdtHiddenRefineSweep")
            defaults.set(false, forKey: "useEouToRefineDirect")
            defaults.set(true, forKey: "showLiveGhostText")
            defaults.set(false, forKey: "performFinalRefinePass")
        case "speedy":
            // Minimalistic: single-engine Parakeet TDT only. Drops the
            // parallel EOU stream and all refinement for the smallest
            // footprint.
            defaults.set(false, forKey: "useDualEngineSmartPTT")
            defaults.set(false, forKey: "useMultiStageRendering")
            defaults.set(false, forKey: "useRealTimeRefine")
            defaults.set(true, forKey: "skipRefine")
            defaults.set(false, forKey: "tdtHiddenRefineSweep")
            defaults.set(false, forKey: "useEouToRefineDirect")
            defaults.set(false, forKey: "showLiveGhostText")
            defaults.set(false, forKey: "performFinalRefinePass")
        default:
            return
        }
        defaults.set(experience, forKey: experienceKey)
        appState.transcriptionService.prepareSelectedMode()
    }
}
