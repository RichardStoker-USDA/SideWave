// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
import AppKit
@preconcurrency import AVFAudio
import CoreAudio
import FluidAudio
import Foundation
import os

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloadingAuxiliary(model: String)
    case verifying
    case compiling
    case loading
    case ready
    case error(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// True while setup is downloading, compiling, or loading, as opposed to not started, failed,
    /// or done. Chooses between "Setting up…" and "Finish setup" in the menu bar.
    var isSettingUp: Bool {
        switch self {
        case .downloading, .downloadingAuxiliary, .verifying, .compiling, .loading:
            return true
        case .notDownloaded, .ready, .error:
            return false
        }
    }
}

enum ModelVersion: String, CaseIterable, Identifiable, Sendable {
    case v2 = "v2"
    case v3 = "v3"
    case ultra = "ultra"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v2: return "Parakeet v2 (English)"
        case .v3: return "Parakeet v3 (Multilingual)"
        case .ultra: return "Parakeet Ultra (Multilingual)"
        }
    }

    /// Approximate download size shown before a fetch starts. The live
    /// download layer reports exact byte totals once transfer begins; this
    /// is the honest up-front estimate per version.
    var downloadSizeLabel: String {
        switch self {
        case .v2: return "~500 MB"
        case .v3: return "~480 MB"
        case .ultra: return "~630 MB"
        }
    }

    var asrVersion: AsrModelVersion {
        switch self {
        case .v2: return .v2
        case .v3: return .v3
        case .ultra: return .ultra
        }
    }

    var repoID: String {
        switch self {
        case .v2: return "richtext/parakeet-tdt-0.6b-v2-coreml"
        case .v3: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .ultra: return "FluidInference/parakeet-ultra-coreml"
        }
    }

    var folderName: String {
        switch self {
        case .v2: return "parakeet-tdt-0.6b-v2-coreml"
        case .v3: return "parakeet-tdt-0.6b-v3-coreml"
        case .ultra: return "parakeet-ultra-coreml"
        }
    }

    var runtimeRoots: Set<String> {
        let components: Set<String>
        switch self {
        case .v2: components = ModelNames.ASR.requiredModels
        case .v3: components = ModelNames.ASR.requiredModelsV3()
        case .ultra: components = ModelNames.ASR.requiredModelsV3()
        }
        return components.union([ModelNames.ASR.vocabularyFile, "config.json"])
    }

    func isCached(at directory: URL) -> Bool {
        ModelDownloadManager.runtimeFilesPresent(at: directory, roots: runtimeRoots.subtracting(["config.json"]))
    }

    func loadModels() async throws -> AsrModels {
        return try await AsrModels.loadFromCache(version: asrVersion)
    }

}

/// Status of CTC vocabulary boosting setup, providing richer feedback than a simple boolean.
/// The UI can map these to meaningful indicator states instead of just green/red.
enum CTCBoostStatus: Equatable {
    /// No CTC boost attempted (recording not active or not yet started)
    case inactive
    /// CTC model loading and vocabulary configuration in progress
    case loading
    /// Setup complete, vocabulary boosting active for finalization
    case ready
    /// Dictionary has entries but none passed the 3-char minimum filter
    case noValidTerms
    /// No dictionary entries configured, CTC boosting intentionally skipped
    case noDictionary
    /// Setup failed (model load error, configuration error, etc.)
    case failed(String)
}
