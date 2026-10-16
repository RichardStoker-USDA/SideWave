// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

extension DictationOverlayContent {
    // MARK: Token counter

    /// Shown only while dictating with Refine on and a usable backend. Hidden in cinematic mode,
    /// during the final pass, and while engines warm up.
    var shouldShowTokenCounter: Bool {
        guard !isCinematic, !appState.isCleaningUp, !isWarmingUp,
              appState.dictationCleanupEnabled else {
            return false
        }
        switch appState.dictationFormatter.state {
        case .ready, .generating, .unloaded:
            return refineBudget.ratio <= 0.25
        default:
            return false
        }
    }

    /// Estimated tokens from characters: about 3.8 characters per token for Gemma and 4.0 for Apple
    /// Intelligence, counting the template, vocabulary, and dictated text.
    private var estimatedTokenCount: Int {
        let bodyChars = appState.transcriptionService.confirmedText.count
            + appState.transcriptionService.volatileText.count
        let totalChars = approximateStaticPromptCharsCached() + bodyChars
        let ratio: Double = {
            switch appState.dictationFormatter.activeBackend {
            case .appleIntelligence, .appleIntelligenceLegacy:
                return 4.0
            case .gemma4E2B, .gemma4E4B, .gemma4_12B:
                return 3.8
            }
        }()
        return Int(ceil(Double(totalChars) / ratio))
    }

    /// Hash of the small values that change the static prompt, including the backend, without
    /// decoding the vocabulary.
    var staticPromptFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(appState.dictationFormatter.activeBackend)
        hasher.combine(appState.dictationCleanupInstructions)
        hasher.combine(appState.dictationCleanupTemplate)
        hasher.combine(appState.dictationOutputLanguage)
        hasher.combine(UserDefaults.standard.bool(forKey: "removeFillerWords"))
        hasher.combine(UserDefaults.standard.bool(forKey: "removeProfanity"))
        hasher.combine(UserDefaults.standard.bool(forKey: "replaceProfanity"))
        // Vocabulary entries update; hash the snapshot to catch changes
        hasher.combine(VocabularyStore.shared.makeSnapshot())
        return hasher.finalize()
    }

    /// Recomputes the cached prompt size. Called from task and onChange, never from a computed
    /// property.
    func refreshStaticPromptCache() {
        let fp = staticPromptFingerprint
        guard fp != cachedStaticPromptFingerprint || cachedStaticPromptChars == 0 else { return }
        let settings = DictationFormatterService.Settings.fromCurrentUserDefaults(
            customInstructions: appState.dictationCleanupInstructions
        )
        let prompt = DictationFormatterService.buildPrompt(rawText: "", settings: settings)
        
        let systemInstructionLength: Int
        switch appState.dictationFormatter.activeBackend {
        case .appleIntelligence, .appleIntelligenceLegacy:
            switch settings.template {
            case .standard: systemInstructionLength = 1200
            case .professional: systemInstructionLength = 1300
            case .concise: systemInstructionLength = 950
            case .emailReady: systemInstructionLength = 1600
            case .instructions: systemInstructionLength = 1800
            case .aiPrompt: systemInstructionLength = 2100
            case .custom: systemInstructionLength = 500
            }
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            let sys = DictationFormatterService.gemmaSystemPrompt(
                for: settings.template,
                removeFillers: settings.removeFillerWords,
                outputLanguage: settings.outputLanguage
            )
            systemInstructionLength = sys.count
        }
        
        cachedStaticPromptChars = prompt.count + systemInstructionLength
        cachedStaticPromptFingerprint = fp
    }

    private func approximateStaticPromptCharsCached() -> Int {
        cachedStaticPromptChars
    }

    /// Context size for the active backend: the cached Apple Intelligence value, or Gemma's fixed
    /// `Backend.contextCap`.
    private var contextCapForCurrentBackend: Int {
        switch appState.dictationFormatter.activeBackend {
        case .appleIntelligence, .appleIntelligenceLegacy:
            return cachedAFMContextCap
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            return appState.dictationFormatter.activeBackend.contextCap
        }
    }

    /// Output headroom reserved on top of the prompt budget. See Backend.
    private var outputHeadroomForCurrentBackend: Int {
        appState.dictationFormatter.activeBackend.outputHeadroomTokens
    }

    /// Remaining room in the refine model's input budget, from the same
    /// character-based estimate used at render time. Refinement checks the
    /// exact count itself before each pass.
    private var refineBudget: (remaining: Int, ratio: Double) {
        let inputBudget = max(contextCapForCurrentBackend - outputHeadroomForCurrentBackend, 1)
        let remaining = max(inputBudget - estimatedTokenCount, 0)
        return (remaining, Double(remaining) / Double(inputBudget))
    }

    /// Shown only once a long dictation has used most of Refine's room, in
    /// words rather than tokens.
    @ViewBuilder
    var tokenCounterBadge: some View {
        let budget = refineBudget
        let words = Int(Double(budget.remaining) * 0.75)
        let color: Color = budget.ratio <= 0.05 ? .red : budget.ratio <= 0.10 ? .warningAmber : .secondary
        Text("\(Self.countFormatter.string(from: NSNumber(value: words)) ?? "\(words)") words left for Refine")
            .font(.system(.caption2, design: .rounded).weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .help("This dictation is approaching the most text Refine can consider at once.")
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}
