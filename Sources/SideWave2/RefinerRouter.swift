// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import SideWaveKit

/// One `Refiner` seam over both backends. The session controller holds
/// this; settings changes swap the active backend without touching the
/// engine.
actor RefinerRouter: Refiner {

    private let afm = RefinerAFM()
    private let gemma = RefinerGemma()
    private var backend: RefineBackendChoice = .appleIntelligence

    func configure(backend: RefineBackendChoice, settings: RefineSettings) async {
        self.backend = backend
        await afm.setSettings(settings)
        await gemma.setSettings(settings)
    }

    /// Load Gemma weights when a Gemma backend is chosen. AFM needs no
    /// preparation (the OS owns the model).
    func prepareIfNeeded(progress: (@Sendable (ModelSetupProgress) -> Void)? = nil) async throws {
        if let variant = backend.gemmaVariant {
            try await gemma.prepare(variant: variant, progress: progress)
        }
    }

    var isReady: Bool {
        get async {
            switch backend {
            case .appleIntelligence: return await afm.isReady
            case .gemmaE2B, .gemmaE4B: return await gemma.isReady
            }
        }
    }

    func refine(_ text: String, context: String) async throws -> String {
        switch backend {
        case .appleIntelligence:
            return try await afm.refine(text, context: context)
        case .gemmaE2B, .gemmaE4B:
            return try await gemma.refine(text, context: context)
        }
    }
}
