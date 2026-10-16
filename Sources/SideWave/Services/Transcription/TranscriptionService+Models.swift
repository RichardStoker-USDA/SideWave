// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
import AppKit
@preconcurrency import AVFAudio
import CoreAudio
import FluidAudio
import Foundation
import os

@MainActor
extension TranscriptionService {
    // MARK: - Model Management

    func checkModelCache() {
        let version: ModelVersion = storedModelVersion()
        checkModelCache(for: version)
    }

    /// Check if a specific model version is cached and update modelState accordingly.
    /// Called when the user switches versions in the engine picker.
    func checkModelCache(for version: ModelVersion) {
        // Never rewrite live pipeline state. Settings calls this on appear; during a download the
        // disk check sees partial files, and turning `.downloading` back into `.notDownloaded`
        // would allow a second download of the same model.
        switch modelState {
        case .downloading, .downloadingAuxiliary, .verifying, .compiling, .loading:
            return
        default:
            break
        }
        let cacheDir = AsrModels.defaultCacheDirectory(for: version.asrVersion)
        guard version.isCached(at: cacheDir) else {
            hasInstalledSpeechModels = false
            modelState = .notDownloaded
            return
        }

        // Perform size and file integrity check (P1 #5)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            hasInstalledSpeechModels = false
            modelState = .notDownloaded
            return
        }

        var totalSize: Int64 = 0
        var fileCount = 0

        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                fileCount += 1
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int64 {
                    if size == 0 {
                        hasInstalledSpeechModels = false
                        modelState = .notDownloaded
                        return
                    }
                    totalSize += size
                }
            }
        }

        guard fileCount > 0, totalSize > 10 * 1024 * 1024 else {
            hasInstalledSpeechModels = false
            modelState = .notDownloaded
            return
        }

        hasInstalledSpeechModels = true
        let prepared = speechModelsPrepared && cachedModelVersion == version.rawValue
        modelState = prepared ? .ready : .loading
        if !prepared, NSClassFromString("XCTestCase") == nil {
            Task { await warmUpModelsIfNeeded() }
        }
    }

    func downloadModel(version: ModelVersion) async {
        guard !modelState.isSettingUp, !isRecording else { return }
        let generation = UUID()
        modelPreparationGeneration = generation

        let cacheDir = AsrModels.defaultCacheDirectory(for: version.asrVersion)
        if version.isCached(at: cacheDir), speechModelsPrepared, cachedModelVersion == version.rawValue {
            UserDefaults.standard.set(version.rawValue, forKey: "selectedModelVersion")
            hasInstalledSpeechModels = true
            modelState = .ready
            return
        }

        modelState = .downloading(progress: 0)
        auxiliaryModelErrors = []

        do {
            // Download from richtext/ HuggingFace mirrors first.
            // This pre-populates the FluidAudio cache directory so AsrModels.download()
            // sees the files and skips its own download from FluidInference/ repos.
            try await ModelDownloadManager.download(version: version, verifyCachedFiles: true) { progress in
                Task { @MainActor in
                    guard self.modelPreparationGeneration == generation,
                          case .downloading = self.modelState else { return }
                    self.modelState = .downloading(progress: progress)
                }
            }
            modelState = .verifying

            // Fallback: run FluidAudio's built-in download in case any files were missed.
            // If everything is already cached this returns immediately.
            try await AsrModels.download(version: version.asrVersion)
            try Task.checkCancellation()

            // Pre-cache auxiliary models from richtext/ mirrors, then let FluidAudio
            // verify they're present. Non-fatal: the app works without them.
            modelState = .downloadingAuxiliary(model: "CTC vocabulary model")
            do {
                // Pre-populate from richtext/ repo so FluidAudio skips its own download
                try await ModelDownloadManager.downloadCTC(verifyCachedFiles: true)
                // FluidAudio verification (sees files exist, returns immediately)
                try await CtcModels.download(variant: .ctc110m)
                print("[TranscriptionService] CTC 110M model cached (from richtext/)")
            } catch {
                let msg = "CTC vocabulary model: \(error.localizedDescription)"
                auxiliaryModelErrors.append(msg)
                print("[TranscriptionService] CTC model download failed (non-fatal): \(error.localizedDescription)")
            }

            modelState = .downloadingAuxiliary(model: "Voice activity detection")
            do {
                // Pre-populate from richtext/ repo so FluidAudio skips its own download
                try await ModelDownloadManager.downloadVAD()
                // FluidAudio verification (sees files exist, returns immediately)
                let _ = try await VadManager()
                print("[TranscriptionService] VAD model cached (from richtext/)")
            } catch {
                let msg = "Voice activity detection: \(error.localizedDescription)"
                auxiliaryModelErrors.append(msg)
                print("[TranscriptionService] VAD model download failed (non-fatal): \(error.localizedDescription)")
            }

            UserDefaults.standard.set(version.rawValue, forKey: "selectedModelVersion")
            try await prepareSpeechModels(version: version)
            try Task.checkCancellation()
            hasInstalledSpeechModels = true
            modelState = .ready
        } catch {
            modelState = .error(error.localizedDescription)
            print("[TranscriptionService] Model download failed: \(error)")
        }
    }

    /// Retry downloading CTC and VAD auxiliary models that failed during initial setup.
    func retryAuxiliaryDownloads() async {
        guard !modelState.isSettingUp, !isRecording else { return }
        var newErrors: [String] = []

        modelState = .downloadingAuxiliary(model: "CTC vocabulary model")
        do {
            try await ModelDownloadManager.downloadCTC(verifyCachedFiles: true)
            try await CtcModels.download(variant: .ctc110m)
            print("[TranscriptionService] CTC 110M model cached (retry from richtext/)")
        } catch {
            let msg = "CTC vocabulary model: \(error.localizedDescription)"
            newErrors.append(msg)
            print("[TranscriptionService] CTC model retry failed: \(error.localizedDescription)")
        }

        modelState = .downloadingAuxiliary(model: "Voice activity detection")
        do {
            try await ModelDownloadManager.downloadVAD()
            let _ = try await VadManager()
            print("[TranscriptionService] VAD model cached (retry from richtext/)")
        } catch {
            let msg = "Voice activity detection: \(error.localizedDescription)"
            newErrors.append(msg)
            print("[TranscriptionService] VAD model retry failed: \(error.localizedDescription)")
        }

        auxiliaryModelErrors = newErrors
        do {
            try await prepareSpeechModels(version: storedModelVersion())
            hasInstalledSpeechModels = true
            modelState = .ready
        } catch {
            modelState = .error("Speech preparation failed. Retry in Settings > Speech Recognition. " + error.localizedDescription)
        }
    }

    func storedModelVersion() -> ModelVersion {
        let raw = UserDefaults.standard.string(forKey: "selectedModelVersion") ?? "v3"
        return ModelVersion(rawValue: raw) ?? .v3
    }

    /// Prepare the selected engines before Home reports that dictation is ready.
    /// This runs silent inference only; it never opens the microphone.
    func warmUpModelsIfNeeded() async {
        guard !isRecording else { return }
        let version = storedModelVersion()
        guard version.isCached(at: AsrModels.defaultCacheDirectory(for: version.asrVersion)) else { return }
        // An explicit download owns preparation until it reaches the loading stage.
        switch modelState {
        case .downloading, .downloadingAuxiliary, .verifying: return
        default: break
        }
        Task.detached(priority: .utility) { AudioDeviceManager.warmAllInputDevicesHAL() }
        do {
            try await prepareSpeechModels(version: version)
            while !speechModelsPrepared {
                try Task.checkCancellation()
                try await prepareSpeechModels(version: storedModelVersion())
            }
            hasInstalledSpeechModels = true
            modelState = .ready
        } catch {
            modelState = .error("Speech preparation failed. Retry in Settings > Speech Recognition. " + error.localizedDescription)
        }
    }

    private func prepareSpeechModels(version: ModelVersion) async throws {
        if let task = speechWarmupTask { try await task.value }
        let needsStreaming = UserDefaults.standard.bool(forKey: "useDualEngineSmartPTT")
        if !needsStreaming, let unused = cachedEouAsr {
            cachedEouAsr = nil
            if let reset = eouResetTask { await reset.value }
            await unused.cleanup()
        }
        guard cachedModels == nil || cachedModelVersion != version.rawValue || (needsStreaming && cachedEouAsr == nil) else { return }
        let generation = UUID()
        speechWarmupGeneration = generation
        modelState = .loading
        let task = Task { @MainActor [self] in
            defer { self.speechWarmupGeneration = UUID() }
            if self.cachedModels == nil || self.cachedModelVersion != version.rawValue {
                self.modelState = UserDefaults.standard.bool(forKey: "modelLoaded_\(version.rawValue)") ? .loading : .compiling
                let models = try await version.loadModels()
                try Task.checkCancellation()
                try await self.runTdtWarmupDecode(models, context: "preparation")
                self.cachedModels = models
                self.cachedModelVersion = version.rawValue
                UserDefaults.standard.set(true, forKey: "modelLoaded_\(version.rawValue)")
            }
            if needsStreaming, self.cachedEouAsr == nil {
                let eou = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
                self.modelState = .loading
                try await eou.loadModels(to: nil, configuration: nil) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.speechWarmupGeneration == generation else { return }
                        switch progress.phase {
                        case .downloading(let completed, let total):
                            self.modelState = .downloadingAuxiliary(model: "Streaming speech (\(completed) of \(total) files)")
                        case .compiling: self.modelState = .compiling
                        case .listing: self.modelState = .downloadingAuxiliary(model: "Streaming speech")
                        }
                    }
                }
                try Task.checkCancellation()
                self.modelState = .loading
                try await self.runEouWarmupDecode(eou, context: "preparation")
                self.cachedEouAsr = eou
            }
        }
        speechWarmupTask = task
        defer {
            if speechWarmupTask == task {
                speechWarmupTask = nil
                speechWarmupGeneration = UUID()
            }
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    // MARK: - Cold-inference warm-up decode

    /// Two seconds of silence at 16kHz mono. Silence is a supported input —
    /// the EOU actor's own finish() pads with zeros — and enough samples to
    /// push several full chunks through the encoder.
    nonisolated private static var silentWarmupSamples: [Float] {
        Array(repeating: 0, count: 32_000)
    }

    /// Exercise the engine on silence, then reset it before recording. A failed
    /// warm-up keeps preparation from reporting Ready.
    func runEouWarmupDecode(_ eou: StreamingEouAsrManager, context: String) async throws {
        guard let buffer = Self.makePCMBuffer16k(samples: Self.silentWarmupSamples) else { return }
        let started = Date()
        do {
            _ = try await eou.process(audioBuffer: buffer)
            let ghost = try await eou.finish()
            let ms = Date().timeIntervalSince(started) * 1000
            if ghost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dictationTraceLog.notice("eou warmup decode clean context=\(context, privacy: .public) durationMs=\(Int(ms), privacy: .public)")
            } else {
                // The trap caught the cold-start ghost. This text would have
                // been the user's first gray words.
                dictationTraceLog.warning("eou warmup decode consumed ghost context=\(context, privacy: .public) durationMs=\(Int(ms), privacy: .public) chars=\(ghost.count, privacy: .public)")
            }
        } catch {
            await eou.reset()
            throw error
        }
        await eou.reset()
    }

    /// One silent transcribe with the freshly loaded TDT models, so the first real segment isn't
    /// the cold inference. The warmed CoreML models are shared with every session through
    /// `AsrModels`.
    func runTdtWarmupDecode(_ models: AsrModels, context: String) async throws {
        let started = Date()
        do {
            let manager = AsrManager(config: ASRConfig.default)
            try await manager.loadModels(models)
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(Self.silentWarmupSamples, decoderState: &decoderState)
            let ms = Date().timeIntervalSince(started) * 1000
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                dictationTraceLog.notice("tdt warmup decode clean context=\(context, privacy: .public) durationMs=\(Int(ms), privacy: .public)")
            } else {
                dictationTraceLog.warning("tdt warmup decode consumed ghost context=\(context, privacy: .public) durationMs=\(Int(ms), privacy: .public) chars=\(text.count, privacy: .public)")
            }
        } catch {
            throw error
        }
    }
}
