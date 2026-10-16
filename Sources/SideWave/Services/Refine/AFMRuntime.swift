// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Single answer to "what Apple Foundation Model do we have, and how do we
/// build it." Before this existed, the generation split (#available(macOS 27))
/// and the `SystemLanguageModel(guardrails:)` construction were copy-pasted
/// across ~10 sites, which is how the guardrail policy drifted (some sites
/// used `.default`) and how the "legacy" backend leaked into the picker on the
/// wrong OS. Everything AFM-capability-shaped funnels through here now.
///
/// AFM inference runs out-of-process in a shared OS daemon, so the model
/// weights are NOT charged to SideWave's memory — near-zero in-app footprint,
/// vs. ~2-3 GB for an in-process MLX Gemma model. That's why the AFM Backend
/// cases report 0 GB disk / 0 GB RAM.
///
/// `gen1`/`gen2` are internal ordinals only; user-facing copy says
/// "Apple Intelligence" / "AFM 3" (third generation) — never "gen 2".
enum AFMRuntime {
    /// Which on-device Apple Foundation Model generation the running OS ships.
    /// - `none`: pre-Tahoe (macOS 25 and earlier) — no on-device AFM at all.
    /// - `gen1`: macOS 26 Tahoe — first-gen model, weaker instruction following,
    ///   needs the shorter prompt profiles and the plain-prompt refusal retry.
    ///   4096-token context window (8192 on macOS 27-capable devices).
    /// - `gen2`: macOS 27+ — the third-generation model, marketed "AFM 3",
    ///   much stronger instruction following. Capability is still probed at
    ///   runtime (contextSize / availability), never assumed from the OS: the
    ///   larger "Core Advanced" model is hardware-gated and may not be handed
    ///   to third parties, so prompts are tuned for the base 3B case.
    enum Generation: Sendable, Equatable {
        case none
        case gen1
        case gen2
    }

    /// Resolved once at first access. macOS 26 is the deployment floor, so the
    /// only split left is gen-2 (macOS 27+) vs gen-1 (macOS 26).
    static let generation: Generation = {
        if #available(macOS 27, *) { return .gen2 }
        return .gen1
    }()

    /// Documented conservative AFM context window, used when the live
    /// `contextSize` API is unavailable (pre-26.4) and as the static cap in
    /// `Backend.contextCap`. One literal, one place.
    static let fallbackContextWindow = 4_096

    #if canImport(FoundationModels)
    /// The one place a `SystemLanguageModel` is built. Permissive guardrails
    /// because every SideWave AFM surface transforms user-owned content
    /// (dictation, meeting transcripts, the user's own vocabulary
    /// descriptions) rather than generating new content — Apple's recommended
    /// posture for transformation use cases (developer forum thread 787736).
    static func makeModel() -> SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }
    #endif
}
