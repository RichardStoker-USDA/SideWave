// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

@MainActor
extension MeetingFormatterService {
    func runAFMFormatting(
        transcript: MeetingTranscript,
        transcriptText: String,
        vocabSection: String,
        format: MeetingFormat
    ) async throws {
        // A new Apple Intelligence session for every run. A session keeps every turn, and each run
        // sends the whole transcript, so reuse would grow the context until a transcript that fit
        // before reports as too long. There's no KV cache to keep, unlike Gemma.
        afmSessionHolder = nil
        try await loadAppleIntelligence()

        guard let session = afmSessionHolder as? LanguageModelSession else {
            throw FormatterError.backendNotReady
        }

        guard !Task.isCancelled else { return }

        let base = """
        Here is the meeting transcript:

        \(transcriptText)

        Format this as: \(format.rawValue)

        \(resolvedSystemPrompt(for: format))
        """
        let userMessage = withVocabulary(base, vocabSection)
        print("[MeetingFormatter] AFM processing \(transcriptText.count) chars")

        state = .generating(output: "", note: nil)
        var fullOutput = ""

        do {
            // AFM streams partial content via the `partial.content` string on
            // each iteration. Matches DictationFormatterService's AFM path.
            let stream = session.streamResponse(to: userMessage)
            for try await partial in stream {
                guard !Task.isCancelled else { return }
                fullOutput = partial.content
                guard !Task.isCancelled else { return }
                state = .generating(output: fullOutput, note: nil)
            }
        } catch let error as LanguageModelSession.GenerationError {
            // Apple Intelligence errors get user-facing text; context overflow suggests Gemma.
            switch error {
            case .exceededContextWindowSize:
                throw FormatterError.afmTooLong
            case .guardrailViolation, .refusal:
                throw FormatterError.afmGuardrail
            case .assetsUnavailable, .unsupportedLanguageOrLocale:
                throw FormatterError.backendNotReady
            default:
                throw FormatterError.afmGeneration(error.localizedDescription)
            }
        }

        guard !Task.isCancelled else { return }

        if fullOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only suggest Gemma when it's actually reachable (16 GB+); below
            // that it isn't in the picker.
            state = .error(HardwareCapability.current == .capable
                ? "No output generated. Try a different format or switch to Gemma 4."
                : "No output generated. Try a different format.")
        } else {
            state = .complete(output: fullOutput)
            MeetingHistoryStore.shared.saveFormattedOutput(
                meetingID: transcript.id,
                format: format.rawValue,
                output: fullOutput
            )
        }
        print("[MeetingFormatter] AFM generation complete (\(fullOutput.count) chars)")
    }

    private func loadAppleIntelligence() async throws {
        state = .loading
        // The same permissive guardrails as dictation Refine (AFMRuntime builds the model). The
        // defaults refused ordinary workplace and research transcripts.
        let model = AFMRuntime.makeModel()
        switch model.availability {
        case .available:
            let session = LanguageModelSession(
                model: model,
                instructions: "You are a professional meeting transcript processor. Follow the user's formatting instructions precisely. Be concise, accurate, and well-organized. Only use information from the provided transcript."
            )
            session.prewarm()
            afmSessionHolder = session
            print("[MeetingFormatter] Apple Intelligence session ready")
        case .unavailable(let reason):
            throw FormatterError.afmUnavailable(Self.afmUnavailableMessage(for: reason))
        @unknown default:
            throw FormatterError.afmUnavailable("Apple Intelligence is unavailable on this device.")
        }
    }

    private static func afmUnavailableMessage(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        // Gemma is only a real fallback on 16 GB+ Macs (below that it isn't in
        // the picker), so only point users at it when it's actually reachable.
        let capable = HardwareCapability.current == .capable
        switch reason {
        case .deviceNotEligible:
            return capable
                ? "This Mac doesn't support Apple Intelligence. Pick Gemma 4 to format meetings on this device."
                : "This Mac doesn't support Apple Intelligence, and it's under the 16 GB the on-device Gemma models need. Meeting formatting isn't available on this Mac."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Turn it on in System Settings to use it here."
        case .modelNotReady:
            return "Apple Intelligence is still downloading. Try again in a few minutes."
        @unknown default:
            return capable
                ? "Apple Intelligence is unavailable right now. Pick Gemma 4 to continue."
                : "Apple Intelligence is unavailable right now. Turn it on in System Settings, or use a 16 GB+ Mac for the Gemma models."
        }
    }

    func loadModel() async throws {
        let backend = selectedBackend
        guard let config = backend.registryConfig else {
            // Apple Intelligence shouldn't reach loadModel — runFormatting
            // routes it to loadAppleIntelligence instead. Defensive throw.
            throw FormatterError.modelNotLoaded
        }
        if let pending = currentLoadTask {
            let attempt = loadGeneration
            let loaded = try await pending.value
            try Task.checkCancellation()
            guard loadGeneration == attempt else { throw CancellationError() }
            modelContainer = loaded
            return
        }
        let attempt = UUID()
        loadGeneration = attempt
        state = .loading
        print("[MeetingFormatter] Loading \(backend.displayName)...")

        // Recognize a cached load so the UI doesn't flash a download card at 100%: MLX sends a
        // single progress update at 1.0 when the files are already present, as in
        // DictationFormatterService.
        let seenPartialProgressBox = MeetingFormatterSeenPartialProgressBox()

        // Wrap the default HF downloader so every fetched file is logged in
        // NetworkActivityLog and surfaced in the Model Recovery window.
        let interceptedDownloader = MLXDownloadInterceptor(
            upstream: #hubDownloader(),
            displayName: backend.displayName
        )

        // Wrap the download in a tracked Task so `cancelDownload()` can
        // propagate cancellation, and so the progress-callback's
        // `currentLoadTask != nil` guard is actually meaningful.
        let loadTask = Task { [weak self] () throws -> ModelContainer in
            try await ModelTokenizerLoader.loadContainer(
                from: interceptedDownloader,
                configuration: config
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.currentLoadTask != nil, self.loadGeneration == attempt else { return }
                    let fraction = progress.fractionCompleted
                    if fraction < 1.0 {
                        seenPartialProgressBox.value = true
                    }
                    // Cached-path fingerprint: single 1.0 callback with no
                    // prior partials. Stay in .loading so the progress card
                    // never mounts for a model that's already on disk.
                    if fraction >= 1.0 && !seenPartialProgressBox.value {
                        return
                    }
                    // Only emit .downloading once a real sub-1.0 sample
                    // has been observed.
                    guard seenPartialProgressBox.value else { return }
                    self.state = .downloading(
                        completedBytes: progress.completedUnitCount,
                        totalBytes: progress.totalUnitCount,
                        progress: progress
                    )
                }
            }
        }
        currentLoadTask = loadTask
        defer { if loadGeneration == attempt { currentLoadTask = nil } }

        do {
            let container = try await loadTask.value
            try Task.checkCancellation()
            guard loadGeneration == attempt else { throw CancellationError() }
            self.modelContainer = container
            print("[MeetingFormatter] Model loaded: \(backend.displayName)")
        } catch {
            print("[MeetingFormatter] Model load failed: \(error)")
            throw error
        }
    }

    enum FormatterError: LocalizedError {
        case modelNotLoaded
        case insufficientMemory
        case backendNotReady
        case afmTooLong
        case afmUnavailable(String)
        case afmGuardrail
        case afmGeneration(String)
        case incompleteNotes

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "Formatting model failed to load. Try again."
            case .insufficientMemory: return "Not enough memory for the selected model."
            case .backendNotReady: return "Model not ready yet. Try again in a moment."
            case .afmTooLong: return "Meeting too long for Apple Intelligence. Pick Gemma 4 E2B or E4B."
            case .afmUnavailable(let message): return message
            case .afmGuardrail: return "Apple Intelligence declined to format this transcript. Try a different format or switch to Gemma 4."
            case .afmGeneration(let message): return message
            case .incompleteNotes: return "A section could not be summarized within the model's limits. Your original transcript is available. Try another model or format."
            }
        }
    }
}
