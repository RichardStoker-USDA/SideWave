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
    // MARK: - Private: Model Loading

    /// Dispatches to the active backend's loader. Gemma downloads/caches
    /// weights via HuggingFace; Apple Intelligence is OS-owned so loading is
    /// just an availability check plus optional prewarm.
    func loadModel() async {
        // Wait for any running generation to finish before loading another model. A cancelled
        // generation still holds its MLX container, and loading on top would keep two
        // multi-gigabyte models in memory, enough to push a 16 GB Mac into swap.
        guard await drainGenerationBeforeLoad(), !Task.isCancelled else { return }
        switch activeBackend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            await loadGemmaModel()
        case .appleIntelligence, .appleIntelligenceLegacy:
            await loadAppleIntelligence()
        }
    }

    static let stoppingGenerationMessage = "The previous refinement is still stopping. Try again in a moment. If it remains stuck, restart SideWave. Your original text is kept."

    /// Retain ownership until the decoder actually stops, even after its caller returns.
    func retireGeneration(_ task: Task<String, Error>) {
        task.cancel()
        guard retiringGenerationTasks.insert(task).inserted else { return }
        Task { [weak self] in
            _ = try? await task.value
            self?.retiringGenerationTasks.remove(task)
        }
    }

    /// A stalled decoder must neither block the caller forever nor overlap a replacement.
    func drainGenerationBeforeLoad(deadlineNanos: UInt64 = 2_000_000_000) async -> Bool {
        while let prior = retiringGenerationTasks.first ?? currentGenerationTask {
            prior.cancel()
            if case .abandoned = await awaitRefineOrAbandon(prior, hardDeadlineNanos: deadlineNanos) {
                retireGeneration(prior)
                state = .error(Self.stoppingGenerationMessage)
                return false
            }
            retiringGenerationTasks.remove(prior)
            if currentGenerationTask == prior {
                currentGenerationTask = nil
            }
            if Task.isCancelled { return false }
        }
        return true
    }

    private func loadGemmaModel() async {
        // Bump the attempt ID. Any in-flight progress callbacks from a prior
        // load will see an older ID and exit without mutating state.
        currentLoadAttemptID &+= 1
        let attemptID = currentLoadAttemptID

        preparationDetail = "Checking model files and loading weights"
        state = .loading
        SWLog.note("[DictationFormatter] Loading \(activeBackend.displayName)... (attempt \(attemptID))")
        let seenPartialProgressBox = SeenPartialProgressBox()
        // Wrap the default Hugging Face downloader so every fetched file
        // is logged in NetworkActivityLog and surfaced in the Model Recovery
        // window with per-file progress.
        let interceptedDownloader = MLXDownloadInterceptor(
            upstream: #hubDownloader(),
            displayName: activeBackend.displayName
        )
        do {
            let container = try await ModelTokenizerLoader.loadContainer(
                from: interceptedDownloader,
                configuration: modelConfig
            ) { [weak self] progress in
                Task { @MainActor [weak self, attemptID] in
                    guard let self, self.currentLoadAttemptID == attemptID else { return }
                    let fraction = progress.fractionCompleted
                    if fraction < 1.0 {
                        seenPartialProgressBox.value = true
                    }
                    // Cached model: a single callback at 1.0 with no partial values before it. Stay
                    // in `.loading` briefly instead of showing download progress.
                    if fraction >= 1.0 && !seenPartialProgressBox.value {
                        return
                    }
                    switch self.state {
                    case .loading, .downloading:
                        self.state = fraction >= 1 ? .loading : .downloading(progress: fraction)
                    default:
                        break
                    }
                }
            }
            guard !Task.isCancelled, currentLoadAttemptID == attemptID else {
                SWLog.note("[DictationFormatter] Load cancelled or superseded")
                return
            }
            // Don't clobber a user-initiated teardown state with .ready
            switch state {
            case .disabled, .unloaded:
                SWLog.note("[DictationFormatter] Load finished but state is \(state); discarding container")
                return
            default:
                break
            }
            preparationDetail = "Preparing model for its first response"
            let warmup = Task.detached(priority: .userInitiated) {
                var params = GenerateParameters()
                params.maxTokens = 1
                params.temperature = 0
                let session = ChatSession(container, instructions: "Reply with OK.", generateParameters: params,
                                          additionalContext: ["enable_thinking": false])
                _ = try await session.respond(to: "ok")
            }
            try await withTaskCancellationHandler {
                try await warmup.value
            } onCancel: { warmup.cancel() }
            guard !Task.isCancelled, currentLoadAttemptID == attemptID else { return }
            self.modelContainer = container
            self.state = .ready
            SWLog.note("[DictationFormatter] Ready")
        } catch {
            if Task.isCancelled || currentLoadAttemptID != attemptID { return }
            // Don't overwrite a user-initiated teardown state with an error
            switch state {
            case .disabled, .unloaded:
                return
            default:
                break
            }
            SWLog.note("[DictationFormatter] Model load failed: \(error.localizedDescription)")
            self.state = .error(Self.userFacingErrorMessage(from: error))
        }
    }

    private enum IncompleteRefinement: Error { case tokenLimit }

    nonisolated static func checkCompletion(_ info: GenerateCompletionInfo) throws {
        if info.stopReason == .length { throw IncompleteRefinement.tokenLimit }
        if info.stopReason == .cancelled { throw CancellationError() }
    }

    // MARK: - Private: Memory Pressure

    func startMemoryPressureMonitoring() {
        // Watch .warning and .critical: .warning only logs, .critical drops the model before the
        // system starts swapping.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Move to the main actor before reading the source or changing state. Same thread, but
            // explicit isolation for Swift 6.
            Task { @MainActor [weak self] in
                guard let self, let src = self.memoryPressureSource else { return }
                let event = src.data
                if event.contains(.critical) {
                    self.handleCriticalMemoryPressure()
                } else if event.contains(.warning) {
                    SWLog.note("[DictationFormatter] Memory pressure warning (keeping model loaded)")
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func handleCriticalMemoryPressure() {
        guard modelContainer != nil else { return }
        if let task = currentGenerationTask { retireGeneration(task) }
        currentGenerationTask = nil
        modelContainer = nil
        resetGemmaTurnSession()
        resetAFMTurnSession()
        // Memory pressure unloads like the user did it: `.unloaded`, not `.error`, so the UI offers
        // to load the model again. `onAutoUnloaded` lets AppState explain with a toast.
        state = .unloaded
        onAutoUnloaded?()
        SWLog.note("[DictationFormatter] Dropped model due to critical memory pressure")
    }

    // No deinit to cancel memoryPressureSource: AppState owns this service for the app's lifetime
    // and the system releases the source at exit.

    // MARK: - Private: Utilities

    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    nonisolated private static func userFacingErrorMessage(from error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost:
                return "Can't reach the model server. Check your internet connection."
            default:
                return "Network error while downloading. Try again."
            }
        }
        if ns.code == NSFileWriteOutOfSpaceError {
            return "Not enough disk space. Free space for the selected model, then retry. Valid downloaded files will be reused."
        }
        return "Couldn't load the Refine model. Try again in a moment."
    }

    /// A model is cached only when its tokenizer, template, and all weight shards are intact.
    nonisolated static func isGemmaBackendCached(_ backend: Backend) -> Bool {
        guard let defaultRepoID = backend.huggingFaceRepoID else { return true }
        let repoID = ModelDownloadManager.resolveRepoID(defaultRepoID)
        guard let snapshot = ModelSnapshotValidation.cachedSnapshot(repoID: repoID) else { return false }
        return ModelSnapshotValidation.invalidFiles(at: snapshot).isEmpty
    }
}
