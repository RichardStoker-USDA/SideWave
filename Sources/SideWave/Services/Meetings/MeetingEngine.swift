// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
@preconcurrency import AVFAudio
import FluidAudio
import Foundation

// MARK: - Off-main engine

/// Owns speech and eight-speaker diarization away from the main actor.
/// Live uses 2.56-second chunks; the final pass uses 10.24-second chunks.
actor MeetingEngine {
    private var fastModels: Nemotron3Models?
    private var balancedModels: Nemotron3Models?
    private var asrModels: AsrModels?

    // Single in-flight preparation tasks. Concurrent callers await the same
    // task instead of starting a parallel DownloadUtils fetch of the same dir.
    private var prepareInFlight: Task<Void, Error>?
    private var liveDownloadInFlight: Task<Void, Error>?

    // Live streaming state (created per recording).
    private var liveDiarizer: MeetingSpeakerDiarizer?
    private var liveASR: StreamingUnifiedAsrManager?
    private weak var liveSession: MeetingSession?
    private let liveConverter = AudioConverter(sampleRate: 16000)
    private var liveTimings: [TokenTiming] = []
    private var liveJournaledCount = 0
    private var liveDropped = false

    private let asrVersion: AsrModelVersion

    init(asrVersion: AsrModelVersion) {
        self.asrVersion = asrVersion
    }

    // MARK: Cache paths

    private static func fluidModelsDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static func unifiedCacheDir() -> URL {
        fluidModelsDir().appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    /// Whether the live transcription model is already downloaded. Checks only: the live pipeline
    /// never downloads this 600 MB model on its own. `downloadLiveASRModel` is the explicit
    /// download.
    static func liveASRModelPresent() -> Bool {
        ModelDownloadManager.runtimeFilesPresent(at: unifiedCacheDir(), roots: [
            ModelNames.ParakeetUnified.streamingEncoderInt8File,
            ModelNames.ParakeetUnified.decoderFile,
            ModelNames.ParakeetUnified.jointDecisionFile,
            ModelNames.ParakeetUnified.vocab
        ])
    }

    // MARK: Preparation

    /// Loads the speaker detection bundles and the transcription model, downloading what's missing.
    /// Reports `.preparing` for local loading and `.downloading` only for real fetches. All callers
    /// share one task: FluidAudio downloads into a shared cache folder, and two loads of the same
    /// bundle would corrupt each other's files.
    func prepare(includeLive: Bool, progress: @escaping @Sendable (MeetingPrepProgress) -> Void) async throws {
        if let existing = prepareInFlight {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [progress] in
            try await self.runPrepare(includeLive: includeLive, progress: progress)
        }
        prepareInFlight = task
        defer { prepareInFlight = nil }
        try await task.value
    }

    private func runPrepare(includeLive: Bool, progress: @escaping @Sendable (MeetingPrepProgress) -> Void) async throws {
        if includeLive {
            // Macs with 16 GB or more also prepare the live transcription model in the same setup.
            // The weights add up to 1 across the four loads so the bar goes from 0 to 100% once;
            // the live model is the largest.
            try await loadFastModels(base: 0.0, weight: 0.15, label: "Nemotron 3 live speakers", progress: progress)
            try await loadBalancedModels(base: 0.15, weight: 0.15, label: "Nemotron 3 final speakers", progress: progress)
            try await loadASRModels(base: 0.30, weight: 0.10, label: "Speech model", progress: progress)
            // Live is an enhancement, not required for batch meetings — a failed
            // live fetch must never block New Meeting. Swallow its error and let
            // the caller's refreshLiveAvailability reflect that live isn't ready.
            do {
                try await loadLiveModel(base: 0.40, weight: 0.60, label: "Live transcript model", progress: progress)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                progress(.preparing(detail: "Live transcript unavailable. Recorded audio can still be transcribed when you stop."))
            }
        } else {
            // Weights sum to 1 for a smooth overall bar across the three loads.
            try await loadFastModels(base: 0.0, weight: 0.35, label: "Nemotron 3 live speakers", progress: progress)
            try await loadBalancedModels(base: 0.35, weight: 0.35, label: "Nemotron 3 final speakers", progress: progress)
            try await loadASRModels(base: 0.70, weight: 0.30, label: "Speech model", progress: progress)
        }
    }

    private func loadFastModels(
        base: Double, weight: Double, label: String,
        progress: @escaping @Sendable (MeetingPrepProgress) -> Void
    ) async throws {
        if fastModels != nil { return }
        progress(.preparing(detail: "Loading \(label)…"))
        fastModels = try await Nemotron3Models.loadFromHuggingFace(
            config: .fast32,
            computeUnits: .cpuAndNeuralEngine,
            progressHandler: Self.progressBridge(base: base, weight: weight, label: label, forward: progress))
    }

    private func loadBalancedModels(
        base: Double, weight: Double, label: String,
        progress: @escaping @Sendable (MeetingPrepProgress) -> Void
    ) async throws {
        if balancedModels != nil { return }
        progress(.preparing(detail: "Loading \(label)…"))
        balancedModels = try await Nemotron3Models.loadFromHuggingFace(
            config: .fast128,
            computeUnits: .cpuAndNeuralEngine,
            progressHandler: Self.progressBridge(base: base, weight: weight, label: label, forward: progress))
    }

    private func loadASRModels(
        base: Double, weight: Double, label: String,
        progress: @escaping @Sendable (MeetingPrepProgress) -> Void
    ) async throws {
        if asrModels != nil { return }
        progress(.preparing(detail: "Loading \(label)…"))
        asrModels = try await AsrModels.loadFromCache(
            version: asrVersion,
            progressHandler: Self.progressBridge(base: base, weight: weight, label: label, forward: progress))
    }

    /// Turns FluidAudio progress into a meeting preparation update. Only a download phase with
    /// files to fetch is shown as downloading (bar and "N of T files"); cached loads, listing, and
    /// compiling show a spinner and words. Compiling is named because it can take a while.
    private static func progressBridge(
        base: Double, weight: Double, label: String,
        forward: @escaping @Sendable (MeetingPrepProgress) -> Void
    ) -> ProgressHandler {
        { dp in
            switch dp.phase {
            case .downloading(let completedFiles, let totalFiles) where totalFiles > 0:
                // Use the larger of byte progress and file count. FluidAudio's byte fraction stays
                // at 0 when Hugging Face doesn't report file sizes, and only spans half its range
                // otherwise; the file count always moves.
                let fileFrac = Double(completedFiles) / Double(totalFiles)
                let local = max(max(0, dp.fractionCompleted), fileFrac)
                let f = base + weight * min(1, local)
                let n = max(1, min(completedFiles + 1, totalFiles))
                forward(.downloading(fraction: f, detail: "\(label): \(n) of \(totalFiles) files"))
            case .compiling:
                // Local Core ML compile — no byte feedback, can take seconds. Call
                // it out by name so an indeterminate bar never reads as frozen.
                forward(.preparing(detail: "Compiling \(label). This takes a moment."))
            case .listing, .downloading:
                forward(.preparing(detail: "\(label): checking"))
            }
        }
    }

    /// Whether the live streaming ASR model is loadable from cache right now.
    /// Actor-side mirror of the service's filesystem check.
    func isLiveASRModelPresent() -> Bool { MeetingEngine.liveASRModelPresent() }

    /// Downloads the live transcription model (about 600 MB). Only reachable through
    /// `downloadLiveTranscriptModel()`, never at launch or meeting start. Serialized so a double click
    /// can't start two downloads.
    func downloadLiveASRModel(progress: @escaping @Sendable (MeetingPrepProgress) -> Void) async throws {
        try await loadLiveModel(base: 0, weight: 1, label: "Live transcript model", progress: progress)
    }

    /// Downloads the live model, reporting progress within [base, base + weight] of the overall bar.
    /// `liveDownloadInFlight` ensures only one download of that folder runs.
    private func loadLiveModel(
        base: Double, weight: Double, label: String,
        progress: @escaping @Sendable (MeetingPrepProgress) -> Void
    ) async throws {
        if let existing = liveDownloadInFlight {
            try await existing.value
            return
        }
        progress(.preparing(detail: "Loading \(label)…"))
        let bridged = Self.progressBridge(base: base, weight: weight, label: label, forward: progress)
        let task = Task<Void, Error> {
            let asr = StreamingUnifiedAsrManager()
            try await asr.loadModels(progressHandler: bridged)
            await asr.cleanup()
        }
        liveDownloadInFlight = task
        defer { liveDownloadInFlight = nil }
        try await task.value
    }

    // MARK: Batch pipeline

    /// Detects speakers (up to eight, streamed) and transcribes (from disk) all parts as one
    /// timeline, then assigns words by overlap. Memory stays bounded: detection works through 10.24
    /// s windows and transcription reads from disk. Speaker slots carry across parts, and each
    /// part's timings are offset by the length of the parts before it.
    func batchProcess(
        partURLs: [URL],
        progress: @escaping @Sendable (MeetingState.ProcessingStage, Double) -> Void
    ) async throws -> MeetingBatchResult {
        let usable = try Self.validatedAudioParts(partURLs)
        guard !usable.isEmpty else { throw MeetingError.noAudio }
        let totalDuration = usable.reduce(0.0) { $0 + $1.duration }

        // 1. Diarize, streamed across all parts.
        let diarizer = MeetingSpeakerDiarizer(config: .fast128, models: try ensureBalanced())
        var processedSeconds = 0.0
        for part in usable {
            try streamCAF(part.url) { window in
                try diarizer.append(window)
                processedSeconds += Double(window.count) / 16000.0
                let frac = totalDuration > 0 ? min(0.5, 0.5 * processedSeconds / totalDuration) : 0
                progress(.diarizing(method: ""), frac)
            }
        }
        try diarizer.finish()
        let diarSegs = diarizer.segments

        // 2. Transcribe each part disk-backed; offset timings by prior duration.
        //    Subscribe to the per-chunk progress stream so a long ASR pass shows
        //    a moving bar instead of freezing at 50% for minutes on 1hr audio.
        progress(.transcribing, 0.5)
        let asr = AsrManager(config: ASRConfig.default)
        try await asr.loadModels(try ensureASR())
        var allTimings: [TokenTiming] = []
        var textParts: [String] = []
        var cumulative = 0.0
        for (i, part) in usable.enumerated() {
            let base = 0.5 + 0.5 * Double(i) / Double(usable.count)
            let span = 0.5 / Double(usable.count)
            let progressTask = Task { [progress] in
                let stream = await asr.transcriptionProgressStream
                do {
                    for try await p in stream {
                        progress(.transcribing, base + span * max(0, min(1, p)))
                    }
                } catch {}
            }
            defer { progressTask.cancel() }
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(part.url, decoderState: &decoderState)
            progressTask.cancel()
            textParts.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let timings = result.tokenTimings {
                let shift = cumulative
                allTimings.append(contentsOf: timings.map {
                    TokenTiming(token: $0.token, tokenId: $0.tokenId,
                                startTime: $0.startTime + shift, endTime: $0.endTime + shift,
                                confidence: $0.confidence)
                })
            }
            cumulative += part.duration
            progress(.transcribing, base + span)
        }
        let fullText = textParts.filter { !$0.isEmpty }.joined(separator: " ")

        return makeResult(diarSegs: diarSegs, timings: allTimings, fullText: fullText, duration: totalDuration)
    }

    /// Re-run only the balanced diarizer over the audio and re-attribute the
    /// cached words. ASR is skipped (its timings are reused).
    func rediarize(
        partURLs: [URL],
        words: [String],
        tokenTimings: [TokenTiming],
        duration: Double,
        progress: @escaping @Sendable (MeetingState.ProcessingStage, Double) -> Void
    ) async throws -> MeetingBatchResult {
        let parts = try Self.validatedAudioParts(partURLs)
        let usableParts = parts.map(\.url)
        guard !usableParts.isEmpty else { throw MeetingError.noAudio }
        let derivedTotal = parts.reduce(0.0) { $0 + $1.duration }
        let totalDuration = duration > 0 ? duration : derivedTotal

        let diarizer = MeetingSpeakerDiarizer(config: .fast128, models: try ensureBalanced())
        var processedSeconds = 0.0
        for url in usableParts {
            try streamCAF(url) { window in
                try diarizer.append(window)
                processedSeconds += Double(window.count) / 16000.0
                let frac = totalDuration > 0 ? min(1.0, processedSeconds / totalDuration) : 0
                progress(.diarizing(method: ""), frac)
            }
        }
        try diarizer.finish()
        let diarSegs = diarizer.segments

        let fullText = words.joined(separator: " ")
        return makeResult(diarSegs: diarSegs, timings: tokenTimings, fullText: fullText, duration: totalDuration)
    }

    /// An empty failed start is harmless. Missing or corrupt recorded audio is not a complete transcript.
    nonisolated static func validatedAudioParts(_ urls: [URL]) throws -> [(url: URL, duration: Double)] {
        try urls.compactMap { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let bytes = attributes[.size] as? NSNumber else { throw MeetingError.invalidAudio }
            if bytes.int64Value == 0 { return nil }
            guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
                throw MeetingError.invalidAudio
            }
            guard file.length > 0 else { return nil }
            return (url, Double(file.length) / file.fileFormat.sampleRate)
        }
    }

    private func makeResult(
        diarSegs: [MeetingDiarSeg], timings: [TokenTiming], fullText: String, duration: Double
    ) -> MeetingBatchResult {
        let raw = MeetingMerge.buildRawSegments(
            diarSegs: diarSegs, timings: timings, fullText: fullText, totalDuration: duration)
        let words = fullText.split(separator: " ").map(String.init)
        return MeetingBatchResult(
            rawSegments: raw,
            speakerCount: Set(raw.map(\.speakerId)).count,
            duration: duration,
            words: words,
            tokenTimings: timings)
    }

    // MARK: Live pipeline

    /// Start the live diarizer (+ streaming ASR if its model is present). Throws
    /// only on a hard model-load failure; the caller treats any throw as "live
    /// off, recording continues on the CAF, batch at stop".
    func beginLive(session: MeetingSession) async throws {
        liveSession = session
        liveTimings = []
        liveJournaledCount = 0
        liveDropped = false

        let diarizer = MeetingSpeakerDiarizer(config: .fast32, models: try ensureFast())
        liveDiarizer = diarizer

        // Cached-only: never download the unified model mid-meeting.
        if Self.liveASRModelPresent() {
            let asr = StreamingUnifiedAsrManager()
            try await asr.loadModels(from: Self.unifiedCacheDir())
            liveASR = asr
        }
    }

    var isLiveActive: Bool { liveDiarizer != nil }

    /// Feed one tap window (native sample rate) into the live pipeline.
    func ingestLive(_ samples: [Float], sampleRate: Double) async {
        guard let diarizer = liveDiarizer, !liveDropped else { return }
        let s16: [Float]
        if sampleRate == 16000 {
            s16 = samples
        } else {
            do {
                s16 = try liveConverter.resample(samples, from: sampleRate)
            } catch {
                liveDropped = true
                return
            }
        }
        guard !s16.isEmpty else { return }
        do {
            try diarizer.append(s16)
        } catch {
            liveDropped = true
            return
        }

        if let asr = liveASR, let buffer = Self.makeBuffer16k(s16) {
            do {
                try await asr.appendAudio(buffer)
                try await asr.processBufferedAudio()
                liveTimings.append(contentsOf: await asr.consumeTokenTimings())
            } catch {
                // A live-ASR hiccup disables live text; the diarizer keeps
                // streaming and batch fills text at stop.
                liveDropped = true
            }
        }
    }

    /// Rebuild the provisional live transcript and journal any newly-stable
    /// segments. Returns the full current list for the recording view. Provisional
    /// text is raw ASR output; the authoritative transcript is built at stop.
    func drainLive() -> [MeetingSegment] {
        guard let diarizer = liveDiarizer, liveASR != nil else { return [] }
        let diarSegs = diarizer.segments
        guard !diarSegs.isEmpty, !liveTimings.isEmpty else { return [] }

        let duration = diarizer.duration
        let raw = MeetingMerge.buildRawSegments(
            diarSegs: diarSegs, timings: liveTimings, fullText: "", totalDuration: duration)
        let segments = raw.map {
            MeetingSegment(speakerId: $0.speakerId, speakerLabel: $0.speakerId,
                           text: $0.rawText, startTime: $0.start, endTime: $0.end)
        }
        // Journal all but the last segment (the last one may still grow as more
        // audio arrives); a crash mid-append is tolerated by the reader.
        if segments.count > liveJournaledCount + 1 {
            for i in liveJournaledCount..<(segments.count - 1) {
                liveSession?.appendLiveSegment(segments[i])
            }
            liveJournaledCount = segments.count - 1
        }
        return segments
    }

    /// Finalize the live diarizer + ASR and return the authoritative result, or
    /// nil to signal the caller should run the batch pipeline instead (live ASR
    /// was off, dropped audio, or produced nothing usable).
    func finishLive() async -> MeetingBatchResult? {
        defer {
            liveDiarizer = nil
            Task { [liveASR] in await liveASR?.cleanup() }
            liveASR = nil
            liveSession = nil
        }
        guard let diarizer = liveDiarizer, let asr = liveASR, !liveDropped else { return nil }

        do {
            try diarizer.finish()
            _ = try await asr.finish()
            liveTimings.append(contentsOf: await asr.consumeTokenTimings())
        } catch {
            return nil
        }
        let diarSegs = diarizer.segments
        guard !diarSegs.isEmpty, !liveTimings.isEmpty else { return nil }

        let duration = diarizer.duration
        return makeResult(diarSegs: diarSegs, timings: liveTimings, fullText: "", duration: duration)
    }

    /// Discard live state without producing a result (cancel path).
    func abandonLive() async {
        liveDiarizer = nil
        await liveASR?.cleanup()
        liveASR = nil
        liveSession = nil
        liveTimings = []
    }

    // MARK: Model accessors

    private func ensureFast() throws -> Nemotron3Models {
        guard let m = fastModels else { throw MeetingError.modelsNotReady }
        return m
    }
    private func ensureBalanced() throws -> Nemotron3Models {
        guard let m = balancedModels else { throw MeetingError.modelsNotReady }
        return m
    }
    private func ensureASR() throws -> AsrModels {
        guard let m = asrModels else { throw MeetingError.modelsNotReady }
        return m
    }

    // MARK: Audio helpers

    /// Read a CAF in native format and hand ~8 s windows of 16 kHz mono to the
    /// closure. One window is resident at a time, so memory is bounded regardless
    /// of file length (no whole-file load, no native-rate copy chain).
    func streamCAF(_ url: URL, onWindow: ([Float]) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= 384_000,
              format.channelCount > 0 else { throw MeetingError.invalidAudio }
        let windowFrames = AVAudioFrameCount(max(Int(format.sampleRate) * 8, 16000))
        let converter = AudioConverter(sampleRate: 16000)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let toRead = AVAudioFrameCount(min(Int64(windowFrames), file.length - file.framePosition))
            guard toRead > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toRead) else {
                throw MeetingError.invalidAudio
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw MeetingError.invalidAudio }
            let window = try converter.resampleBuffer(buffer)
            guard !window.isEmpty else { throw MeetingError.invalidAudio }
            try onWindow(window)
        }
    }

    private static func makeBuffer16k(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channel[0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}

/// A tap window handed to the live pipeline. Copied out of the render buffer so
/// nothing borrowed from CoreAudio crosses a task boundary.
struct MeetingAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
}
