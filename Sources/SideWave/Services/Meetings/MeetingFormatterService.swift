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

// MARK: - Meeting Formatter Service

@Observable
@MainActor
final class MeetingFormatterService {
    var state: FormatterState = .idle
    var selectedFormat: MeetingFormat = .minutes
    /// Active backend. `setBackend(_:)` unloads the current model so the next format loads the new
    /// one; direct assignment stays plain for SwiftUI bindings.
    var selectedBackend: MeetingFormatterBackend = .gemma4E4B

    var modelContainer: ModelContainer?
    var chatSession: ChatSession?
    /// Apple Intelligence session, type-erased to `Any?`; cast to
    /// `LanguageModelSession` at the AFM use sites.
    var afmSessionHolder: Any?
    private var generationTask: Task<Void, Never>?
    var currentLoadTask: Task<ModelContainer, Error>?
    var loadGeneration = UUID()

    /// Hash of the transcript loaded into the chat session. While it matches, formatting again is
    /// almost instant because the KV cache already holds the transcript. Gemma only.
    var cachedTranscriptHash: Int?
    private var cachedTokenCount = 0

    /// True only when formatting the same transcript again would reuse Gemma's KV cache (single
    /// pass, transcript still loaded). False for Apple Intelligence and map-reduce, so the UI
    /// doesn't promise a near-instant result there.
    var reformatIsCached: Bool {
        chatSession != nil && cachedTranscriptHash != nil
            && Self.canReuseContext(cachedTokens: cachedTokenCount, promptTokens: 1_024,
                                    contextCap: selectedBackend.contextTokenCap)
    }

    // MARK: - Public API

    /// Format a meeting transcript. If the transcript is already cached in the
    /// ChatSession's KV cache, only the new format instruction is processed.
    func format(transcript: MeetingTranscript, as format: MeetingFormat) {
        selectedFormat = format
        guard transcript.hasSpeech else {
            cancel()
            state = .error("No speech was recognized in this recording. Check the microphone or process the saved audio again before generating notes.")
            return
        }
        if generationTask != nil {
            generationTask?.cancel()
            chatSession = nil
            cachedTranscriptHash = nil
        }
        state = .loading
        
        let box = TaskBox<Void, Never>()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runFormatting(transcript: transcript, format: format)
            } catch {
                if !Task.isCancelled {
                    self.state = .error(error.localizedDescription)
                }
            }
            if self.generationTask == box.task {
                self.generationTask = nil
            }
        }
        box.task = task
        generationTask = task
    }

    func cancel() {
        loadGeneration = UUID()
        generationTask?.cancel()
        generationTask = nil
        // Cancel a running download too, or the next progress update would set `.downloading` again and a
        // finished load would keep the 6 GB model in memory. Progress updates stop once
        // `currentLoadTask` is nil.
        currentLoadTask?.cancel()
        currentLoadTask = nil
        // Drop the chat session and its KV cache but keep the model container, which is costly to
        // reload, until unloadModel().
        chatSession = nil
        cachedTranscriptHash = nil
        state = .idle
    }

    /// Cancel an in-flight weight download. Partial files stay in the HF cache
    /// so the next attempt resumes. State returns to `.idle`.
    func cancelDownload() {
        cancel()
    }

    /// Release the LLM from memory. Call when leaving the meeting tab
    /// or when the user is done formatting. Drops both MLX containers and
    /// any Apple Intelligence session.
    func unloadModel() {
        loadGeneration = UUID()
        // Cancel a download-in-progress so closing the sheet mid-download
        // doesn't leave the fetch + load running detached and re-pinning the
        // container after dismiss.
        currentLoadTask?.cancel()
        currentLoadTask = nil
        generationTask?.cancel()
        generationTask = nil
        chatSession = nil
        modelContainer = nil
        afmSessionHolder = nil
        cachedTranscriptHash = nil
        state = .idle
        print("[MeetingFormatter] Model unloaded")
    }

    /// Swap the active backend. Drops both models so the next `format(...)`
    /// loads the newly-selected backend from scratch. Safe to call when a
    /// generation is in flight — the running task is cancelled first.
    func setBackend(_ newBackend: MeetingFormatterBackend) {
        guard newBackend != selectedBackend else { return }
        loadGeneration = UUID()
        generationTask?.cancel()
        generationTask = nil
        currentLoadTask?.cancel()
        currentLoadTask = nil
        chatSession = nil
        modelContainer = nil
        afmSessionHolder = nil
        cachedTranscriptHash = nil
        selectedBackend = newBackend
        state = .idle
    }

    /// Probe Apple Intelligence availability again. Call when the app returns
    /// to foreground so a user who just toggled AI on in System Settings sees
    /// the AFM option unblock without restarting SideWave.
    func refreshAFMAvailability() {
        guard selectedBackend == .appleIntelligence else { return }
        if case .error = state {
            state = .idle
        }
    }

    // MARK: - Private

    /// Resolved system prompt for a format. `.custom` folds in the user's
    /// stored instructions as the primary directive; every other format uses
    /// its fixed prompt. Both append the shared speaker-label rule.
    func resolvedSystemPrompt(for format: MeetingFormat) -> String {
        switch format {
        case .custom:
            return MeetingFormat.customFullSystemPrompt(instructions: Self.customFormatInstructions())
        default:
            return format.fullSystemPrompt
        }
    }

    /// The persisted `.custom` format instructions, trimmed and length-capped
    /// (matching the UI's cap so preflight and generation agree).
    static func customFormatInstructions() -> String {
        let raw = UserDefaults.standard.string(forKey: MeetingFormat.customInstructionsKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(MeetingFormat.customInstructionsCharLimit))
    }

    private func runFormatting(transcript: MeetingTranscript, format: MeetingFormat) async throws {
        let backend = selectedBackend

        // Gemma loads multi-GB weights into SideWave's own memory; refuse it on
        // Macs under the 16 GB floor rather than thrash into swap. AFM stays
        // available (out-of-process, near-zero app footprint).
        if backend != .appleIntelligence, HardwareCapability.current == .insufficient {
            throw FormatterError.insufficientMemory
        }

        let transcriptText = transcript.formattingSource

        // The user's vocabulary goes in the user message so the model prefers those spellings, as
        // in dictation Refine. Meeting transcription doesn't use CTC boosting yet.
        let vocabSection = VocabularyStore.shared.makeSnapshot().buildPromptSection(for: transcriptText)

        // Apple Intelligence check: refuse transcripts that won't fit its window before loading a
        // session, and name the Gemma backend to use instead. The vocabulary section counts too,
        // since it's in the same message.
        if backend == .appleIntelligence,
           transcriptText.count + vocabSection.count > MeetingFormatterBackend.afmTranscriptCharLimit {
            throw FormatterError.afmTooLong
        }

        // Route to the right backend's generation path. Gemma paths share the
        // MLX ChatSession implementation; AFM uses FoundationModels on Tahoe.
        switch backend {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            try await runGemmaFormatting(transcript: transcript, transcriptText: transcriptText, vocabSection: vocabSection, format: format)
        case .appleIntelligence:
            try await runAFMFormatting(transcript: transcript, transcriptText: transcriptText, vocabSection: vocabSection, format: format)
        }
    }

    /// Append the reference-vocabulary section to a user message, if any.
    func withVocabulary(_ message: String, _ section: String) -> String {
        guard !section.isEmpty else { return message }
        return message + "\n\n" + section
    }

    private func runGemmaFormatting(
        transcript: MeetingTranscript,
        transcriptText: String,
        vocabSection: String,
        format: MeetingFormat
    ) async throws {
        // Step 1: Ensure model is loaded
        if modelContainer == nil {
            try await loadModel()
        }

        guard let container = modelContainer else {
            throw FormatterError.modelNotLoaded
        }

        guard !Task.isCancelled else { return }

        // Past about 70% of the usable window (vocabulary included), use map-reduce: notes per
        // section, then one combining pass. A whole long transcript would overflow, and default
        // parameters don't bound the output.
        let inputTokens = await container.encode(transcriptText + "\n\n" + vocabSection).count
        try Task.checkCancellation()
        let mapReduceThreshold = Int(Double(selectedBackend.contextTokenCap) * 0.7)
        if inputTokens > mapReduceThreshold {
            try await runGemmaMapReduce(
                container: container,
                transcript: transcript,
                vocabSection: vocabSection,
                format: format
            )
            return
        }

        // Step 2: Build the user message
        let systemPrompt = resolvedSystemPrompt(for: format)
        let transcriptHash = (transcriptText + "\n\n" + vocabSection).hashValue
        let reformatMessage = """
        Now format the transcript as: \(format.rawValue)

        \(systemPrompt)
        """
        let reformatTokens = await container.encode(reformatMessage).count
        try Task.checkCancellation()

        let userMessage: String
        if cachedTranscriptHash == transcriptHash, chatSession != nil,
           Self.canReuseContext(cachedTokens: cachedTokenCount, promptTokens: reformatTokens,
                                contextCap: selectedBackend.contextTokenCap) {
            // Transcript already in KV cache -- just send the new format instruction.
            // This is the fast path (~1-2 seconds instead of 20-30).
            // The system prompt is neutral so switching between formats works cleanly.
            userMessage = reformatMessage
            print("[MeetingFormatter] KV cache hit -- reformat only")
        } else {
            // First time or different transcript -- send the full text. Vocab
            // rides along with the transcript so it stays in the KV cache for
            // subsequent reformat-only calls.
            let base = """
            Here is the meeting transcript:

            \(transcriptText)

            Format this as: \(format.rawValue)

            \(systemPrompt)
            """
            userMessage = withVocabulary(base, vocabSection)
            // Reset session for new transcript
            chatSession = nil
            print("[MeetingFormatter] Processing full transcript (\(transcriptText.count) chars)")
        }

        // Create or reuse the chat session with a neutral system prompt so different formats don't
        // conflict. Explicit parameters bound the output length.
        if chatSession == nil {
            cachedTokenCount = 128
            chatSession = ChatSession(
                container,
                instructions: "You are a professional meeting transcript processor. Follow the user's formatting instructions precisely. Be concise, accurate, and well-organized. Only use information from the provided transcript.",
                generateParameters: Self.gemmaParameters(maxTokens: Self.maxOutputTokens),
            additionalContext: ["enable_thinking": false]
            )
            cachedTranscriptHash = transcriptHash
        }

        guard let session = chatSession else { return }
        let promptTokens = await container.encode(userMessage).count
        try Task.checkCancellation()

        // Step 4: Stream the response
        state = .generating(output: "", note: nil)
        var fullOutput = ""

        for try await chunk in session.streamResponse(to: userMessage) {
            guard !Task.isCancelled else { return }
            fullOutput += chunk
            // Second cancel check immediately before the state write so a
            // cancel that lands between `guard` above and this assignment
            // doesn't stamp `.generating` over an `.idle` the user asked for.
            guard !Task.isCancelled else { return }
            state = .generating(output: fullOutput, note: nil)
        }

        guard !Task.isCancelled else { return }

        let outputTokens = await container.encode(fullOutput).count
        try Task.checkCancellation()
        cachedTokenCount += promptTokens + outputTokens + 32

        if fullOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .error("No output generated. Try a different format or a longer transcript.")
        } else {
            state = .complete(output: fullOutput)
            // Save the generated output to the meeting's history
            MeetingHistoryStore.shared.saveFormattedOutput(
                meetingID: transcript.id,
                format: format.rawValue,
                output: fullOutput
            )
        }
        print("[MeetingFormatter] Gemma generation complete (\(fullOutput.count) chars)")
    }

}

/// File-scoped twin of `DictationFormatterService`'s `SeenPartialProgressBox`.
/// Kept separate so each service owns its own load fingerprint without
/// reaching across internal boundaries. All access is main-thread-serialized.
final class MeetingFormatterSeenPartialProgressBox: @unchecked Sendable {
    var value: Bool = false
}
