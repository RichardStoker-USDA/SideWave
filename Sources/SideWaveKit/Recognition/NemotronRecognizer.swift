// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

@preconcurrency import CoreML
import FluidAudio
import Foundation
import os

public enum RecognizerError: LocalizedError, Equatable {
    case modelsNotReady
    case sessionAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .modelsNotReady:
            return "The speech models are not ready yet."
        case .sessionAlreadyRunning:
            return "A recognition session is already running."
        }
    }
}

/// Download / load progress for onboarding, kit-typed so the shell never
/// sees FluidAudio types.
public struct ModelSetupProgress: Sendable, Equatable {
    public let fraction: Double
    public let detail: String
}

/// The one speech engine: NVIDIA Nemotron Speech Streaming 0.6B
/// (multilingual 3.5 line) through FluidAudio's CoreML pipeline.
/// Cache-aware true streaming — an emitted token never retracts — at
/// roughly one quarter the word error rate of the chunked design it
/// replaces, so the dual-engine draft/confirm reconciliation layer is
/// gone entirely.
///
/// Decisions that live here:
/// - Models preload once (`prepare`) into shared, ANE-resident instances;
///   each session gets a fresh manager from the shared models with zero
///   cold start. Compute units are pinned to CPU+ANE: the int8 encoder
///   routed to GPU runs an order of magnitude slower.
/// - The default chunk is the trained 1120ms tier. The 560ms tier is
///   documented (FluidAudio issue 687) to thin out punctuation on long
///   sessions, and dictation lives on punctuation.
/// - Silero VAD runs alongside on the CPU (never fighting the encoder for
///   the ANE) purely as EVIDENCE: its speech stamps feed the carried
///   silence-window guard and phantom-token filter at finish. Every gate
///   fails open when evidence is missing.
public actor NemotronRecognizer: Recognizer {

    public struct Options: Sendable {
        /// Language hint: "auto" or a BCP-47-ish code ("en-US", "de-DE",
        /// "zh-CN"). Latin-script hints load the pruned faster variant.
        public var languageCode: String
        /// Streaming chunk tier in ms: 560, 1120, 2240, 4480.
        public var chunkMs: Int
        /// Capitalize + close the raw transcript when the engine didn't.
        public var tidyFinalTranscript: Bool
        /// Model cache root; nil uses FluidAudio's Application Support dir.
        public var modelsDirectory: URL?
        /// Silero speech probability threshold (carried tuning).
        public var vadThreshold: Float

        public init(
            languageCode: String = "auto",
            chunkMs: Int = 1120,
            tidyFinalTranscript: Bool = true,
            modelsDirectory: URL? = nil,
            vadThreshold: Float = 0.75
        ) {
            self.languageCode = languageCode
            self.chunkMs = chunkMs
            self.tidyFinalTranscript = tidyFinalTranscript
            self.modelsDirectory = modelsDirectory
            self.vadThreshold = vadThreshold
        }
    }

    // MARK: Long-lived state

    private var options: Options
    private var shared: SharedNemotronMultilingualModels?
    private var vad: VadManager?
    private let log = Logger(subsystem: "com.sidewave.kit", category: "recognizer")

    // MARK: Per-session state

    private var manager: StreamingNemotronMultilingualAsrManager?
    private var updateOut: AsyncStream<RecognizerUpdate>.Continuation?
    private var assembly = TranscriptAssembly()
    private var vadState: VadStreamState?
    private var vadPending: [Float] = []
    private var totalFedSamples = 0
    private var vadProcessedThrough = 0
    private var lastVadSpeechSample = -1
    private var lastSpeechEndSample: Int?
    private var consecutiveDecodeErrors = 0

    /// VAD consumes fixed 4096-sample chunks (carried size).
    private static let vadChunkSamples = 4_096
    /// Evidence-only segmentation config: nothing here triggers
    /// finalization, the durations just shape the speech-end events.
    private static let vadSegmentation = VadSegmentationConfig(
        minSpeechDuration: 0.25,
        minSilenceDuration: 3.0,
        maxSpeechDuration: 14.0,
        speechPadding: 0.1
    )

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Preparation (onboarding + app start)

    public var isReady: Bool { shared != nil && vad != nil }

    /// Download (if needed) and preload everything the engine needs. Safe
    /// to call again; cached models load without network.
    public func prepare(progress: (@Sendable (ModelSetupProgress) -> Void)? = nil) async throws {
        let aneConfig = MLModelConfiguration()
        aneConfig.computeUnits = .cpuAndNeuralEngine

        if shared == nil {
            progress?(ModelSetupProgress(fraction: 0, detail: "Checking speech model"))
            let bridged: ProgressHandler = { dp in
                guard let progress else { return }
                switch dp.phase {
                case .downloading(let completed, let total) where total > 0:
                    // Byte fraction is 0 whenever the host didn't report
                    // sizes; file count is the signal that always moves.
                    let fileFraction = Double(completed) / Double(total)
                    let fraction = max(max(0, dp.fractionCompleted), fileFraction) * 0.9
                    progress(
                        ModelSetupProgress(
                            fraction: fraction,
                            detail: "Downloading speech model: \(min(completed + 1, total)) of \(total) files"))
                case .compiling:
                    progress(ModelSetupProgress(fraction: 0.92, detail: "Preparing speech model"))
                case .listing, .downloading:
                    progress(ModelSetupProgress(fraction: 0.02, detail: "Checking speech model"))
                }
            }
            shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
                languageCode: options.languageCode,
                chunkMs: options.chunkMs,
                to: options.modelsDirectory,
                configuration: aneConfig,
                progressHandler: bridged
            )
            log.notice("Nemotron shared models ready (\(self.options.languageCode, privacy: .public), \(self.options.chunkMs, privacy: .public)ms)")
        }

        if vad == nil {
            progress?(ModelSetupProgress(fraction: 0.95, detail: "Preparing voice detector"))
            // CPU only: evidence must never contend with the encoder for
            // the ANE.
            vad = try await VadManager(
                config: VadConfig(defaultThreshold: options.vadThreshold, computeUnits: .cpuOnly))
            log.notice("VAD ready")
        }

        progress?(ModelSetupProgress(fraction: 1, detail: "Ready"))
    }

    /// Change the language hint. Latin-script codes share one model
    /// variant, so switching inside that group needs no new download; a
    /// switch across variants makes `prepare` fetch the other model.
    public func setLanguage(_ code: String) async {
        let oldDirectory = StreamingNemotronMultilingualAsrManager.languageDirectory(for: options.languageCode)
        let newDirectory = StreamingNemotronMultilingualAsrManager.languageDirectory(for: code)
        options.languageCode = code
        if oldDirectory != newDirectory {
            shared = nil
        }
    }

    // MARK: Recognizer

    public func begin() async throws -> AsyncStream<RecognizerUpdate> {
        guard let shared, let vad else { throw RecognizerError.modelsNotReady }
        if manager != nil {
            // Defensive: the controller's state machine never double-
            // begins, but a stale session must not poison a new one.
            await abandon()
        }

        let aneConfig = MLModelConfiguration()
        aneConfig.computeUnits = .cpuAndNeuralEngine
        let fresh = StreamingNemotronMultilingualAsrManager(configuration: aneConfig)
        try await fresh.loadFromShared(shared)
        await fresh.setLanguage(options.languageCode == "auto" ? nil : options.languageCode)

        let (stream, continuation) = AsyncStream<RecognizerUpdate>.makeStream(bufferingPolicy: .unbounded)
        updateOut = continuation
        assembly.reset()

        // The partial callback fires inside the manager during process();
        // it carries the RUNNING transcript. Assembly happens back on this
        // actor so ordering follows the feed order.
        let box = PartialBox()
        await fresh.setPartialCallback { [weak self] running in
            guard box.noteIfChanged(running) else { return }
            Task { await self?.ingestPartial(running) }
        }

        manager = fresh
        vadState = await vad.makeStreamState()
        vadPending = []
        totalFedSamples = 0
        vadProcessedThrough = 0
        lastVadSpeechSample = -1
        lastSpeechEndSample = nil
        consecutiveDecodeErrors = 0
        return stream
    }

    private func ingestPartial(_ running: String) {
        guard let updateOut else { return }
        if let (settled, settling) = assembly.ingest(running) {
            updateOut.yield(.transcript(settled: settled, settling: settling))
        }
    }

    public func feed(_ samples: [Float]) async {
        guard let manager else { return }
        totalFedSamples += samples.count

        do {
            _ = try await manager.process(samples: samples)
            consecutiveDecodeErrors = 0
        } catch {
            consecutiveDecodeErrors += 1
            if consecutiveDecodeErrors <= 3 {
                log.error("decode error (\(self.consecutiveDecodeErrors, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
        }

        await runVad(on: samples)
    }

    /// Feed the evidence VAD in fixed chunks, tracking the consumed
    /// frontier and speech stamps in session-absolute sample indexes.
    private func runVad(on samples: [Float]) async {
        guard let vad, var state = vadState else { return }
        vadPending.append(contentsOf: samples)

        var consumed = 0
        while vadPending.count - consumed >= Self.vadChunkSamples {
            let chunk = Array(vadPending[consumed..<consumed + Self.vadChunkSamples])
            consumed += Self.vadChunkSamples
            do {
                let result = try await vad.processStreamingChunk(
                    chunk, state: state, config: Self.vadSegmentation)
                state = result.state
                let frontier = totalFedSamples - (vadPending.count - consumed)
                vadProcessedThrough = frontier
                if state.triggered {
                    lastVadSpeechSample = frontier
                }
                if let event = result.event, event.kind == .speechEnd {
                    lastSpeechEndSample = frontier
                }
            } catch {
                log.error("vad error: \(String(describing: error), privacy: .public)")
                break
            }
        }
        if consumed > 0 {
            vadPending.removeFirst(consumed)
        }
        vadState = state
    }

    public func finish() async -> String {
        guard let manager else {
            closeStream()
            return ""
        }
        defer {
            self.manager = nil
            closeStream()
        }

        var text: String
        var timings: [TokenTiming]?
        do {
            let result = try await manager.finishWithTokenTimings()
            text = result.text
            timings = result.timings
        } catch {
            // Salvage what accumulated rather than lose the session.
            log.error("finish failed, salvaging partial: \(String(describing: error), privacy: .public)")
            text = await manager.getPartialTranscript()
            timings = await manager.getTokenTimings()
        }
        let detectedLanguage = await manager.detectedLanguage()
        await manager.cleanup()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Gate 1: the whole session was silence or steady noise as far as
        // VAD could see — the text is hallucination, not speech.
        if EvidenceGates.silenceWindowShouldDrop(
            vadProcessedThrough: vadProcessedThrough,
            lastVadSpeechSample: lastVadSpeechSample,
            segmentStart: 0,
            segmentEnd: totalFedSamples
        ) {
            log.notice("noise guard dropped session: no VAD speech in \(self.totalFedSamples, privacy: .public) samples")
            updateOut?.yield(.suppressed(reason: "No speech detected, so nothing was typed."))
            return ""
        }

        // Gate 2: strip tokens the decoder predicted into trailing silence.
        let vadWasSpeaking = vadState?.triggered ?? true
        var final = EvidenceGates.applyPhantomWordFilter(
            text: trimmed,
            tokenTimings: timings,
            vadWasSpeaking: vadWasSpeaking,
            speechEndSample: lastSpeechEndSample,
            frozenSampleCount: 0
        )
        if final.isEmpty {
            updateOut?.yield(.suppressed(reason: "Only trailing noise was heard, so nothing was typed."))
            return ""
        }

        // ITN is paused here: running NeMo over
        // the WHOLE session transcript over-groups plain counting into
        // times/phone numbers ("ten twenty six nine ten" -> "10 26
        // 09:10"). The original app avoids this by normalizing per ~14s
        // segment. Re-enable only with segment-scoped spans plus a tuned
        // maxSpanTokens; the library stays linked and the ordinal revert
        // stays ready.
        // final = ProseOrdinalReverter.revert(TextNormalizer.shared.normalizeSentence(final))

        if options.tidyFinalTranscript {
            final = EvidenceGates.tidyFinalTranscript(final, detectedLanguage: detectedLanguage)
        }
        return final
    }

    public func abandon() async {
        if let manager {
            await manager.cleanup()
        }
        manager = nil
        closeStream()
    }

    private func closeStream() {
        updateOut?.finish()
        updateOut = nil
        assembly.reset()
        vadState = nil
        vadPending = []
    }
}

/// Dedupe box for the partial callback: the engine re-reports the running
/// transcript on chunks that added nothing.
private final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""
    func noteIfChanged(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard text != last else { return false }
        last = text
        return true
    }
}
