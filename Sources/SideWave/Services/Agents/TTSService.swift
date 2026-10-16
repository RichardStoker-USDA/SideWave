// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

@preconcurrency import AVFAudio
import FluidAudio
import Foundation
import NaturalLanguage

// MARK: - TTS Service

/// State of the on-device PocketTTS model, so the UI and the MCP check_status tool can tell a local
/// load from a first-run download or a failure. `downloading` carries a real fraction and starts
/// only after a progress event below 1.0, so a cached load never looks like a download.
enum TTSModelPhase: Equatable, Sendable {
    case uninitialized
    case initializing
    case downloading(Double)
    case ready
    case failed(String)
}

/// Honest result of handing text to the speech pipeline. Callers (the MCP
/// tools) turn these into tool results so an agent is never told "speaking"
/// when nothing will play.
enum SpeechOutcome: Equatable, Sendable {
    /// Synthesis started; playback begins when the first audio frame arrives.
    case started
    /// Appended behind speech already playing; will play in turn.
    case queued
    /// Buffered while the voice model finishes initializing/downloading; it
    /// plays automatically once the model is ready.
    case queuedPendingModel
    /// Hit the 50-sentence queue cap. `accepted` sentences were queued and
    /// `dropped` were not, so the caller can tell full drops from partial ones
    /// and only re-send what didn't fit.
    case droppedQueueFull(accepted: Int, dropped: Int)
    /// Nothing speakable after cleanup.
    case empty
    /// Not spoken for the given reason (e.g. model init failed).
    case notSpoken(String)
}

/// A queued sentence with the connection that sent it and the voice chosen when it was queued, so
/// playback never assigns a new voice for a connection that has since closed.
struct QueuedSentence {
    let text: String
    /// Socket fd of the MCP connection that sent this sentence.
    /// 0 means local (voice preview, draft response, non-MCP speak).
    let connectionID: Int32
    /// Voice assigned to this sentence's connection when it was enqueued.
    let voice: String
}

/// Text-to-speech with FluidAudio's PocketTTS. Each voice keeps a `PocketTtsSession`, so voice
/// setup happens once per burst of speech rather than per sentence and sentences play without
/// gaps. The session generates ahead and AVAudioPlayerNode buffers the audio.
@Observable
@MainActor
final class TTSService {
    var isInitialized = false
    var isSpeaking = false
    var hasPendingSpeech: Bool { playbackTask != nil || !pendingSentences.isEmpty || isSpeaking }
    var isPreparingSpeech: Bool { hasPendingSpeech && !isSpeaking }
    /// Model lifecycle for the UI and check_status. Never regresses to
    /// `.uninitialized` once `.ready`.
    private(set) var modelPhase: TTSModelPhase = .uninitialized
    var selectedVoice: String = "jane" {
        didSet { UserDefaults.standard.set(selectedVoice, forKey: "selectedTTSVoice") }
    }

    /// True while an initialization attempt is actually running. Lets
    /// check_status report "initializing" only when it's true, never as a
    /// permanent lie.
    var initializationInFlight: Bool { initTask != nil }

    /// Whether agent speech is suppressed because the user is recording. Checked when audio is
    /// about to play, not only when queued, so speech buffered before the model loaded can't play
    /// into a dictation or meeting. Set by MCPServerManager.
    var isSuppressed: (@MainActor () -> Bool)?
    private var suppressed: Bool { isSuppressed?() ?? false }

    /// Sentences that failed to play since the last read (session build or
    /// synthesis errors), surfaced through get_playback_status so an agent that
    /// was told a sentence was queued can detect it never made sound.
    private(set) var droppedSentenceCount: Int = 0
    private(set) var lastPlaybackError: String?

    /// Read and clear the dropped-sentence counter.
    func consumeDroppedCount() -> Int {
        let count = droppedSentenceCount
        droppedSentenceCount = 0
        return count
    }

    /// The voice a connection would speak with, without creating or mutating an
    /// assignment. For check_status so it reports the caller's voice, not the
    /// user's selectedVoice.
    func peekVoice(for connectionID: Int32) -> String {
        if connectionID == 0 { return selectedVoice }
        return voiceAssignments[connectionID] ?? selectedVoice
    }

    // MARK: - Playback State (observable for UI and MCP status)

    /// Text of the sentence currently being played to the user.
    private(set) var currentlyPlayingText: String = ""
    /// Text of the next sentence with audio already scheduled for playback.
    private(set) var preBufferedText: String = ""
    /// Sentences waiting as text -- fully editable by the agent at any time.
    private(set) var pendingSentences: [QueuedSentence] = []

    private var playbackTimeline = SpeechPlaybackTimeline()

    // MARK: - Multi-Agent Voice Assignment

    /// Maps MCP connection fd → assigned voice name.
    /// First agent gets the user's primary voice. Subsequent agents get voices
    /// from the fallback order, ensuring each agent sounds distinct.
    private var voiceAssignments: [Int32: String] = [:]

    /// Voice order for additional agents: the first agent gets the selected voice, later agents get
    /// these in order, skipping the selected one. Alternates female and male so neighbors sound
    /// different.
    static let voiceFallbackOrder: [String] = [
        "jane",           // female
        "george",         // male
        "eve",            // female
        "bill_boerst",    // male
        "vera",           // female
        "peter_yearsley", // male
        "anna",           // female
        "michael",        // male
        "mary",           // female
        "paul",           // male
        "azelma",         // female
        "caro_davy",      // female
    ]

    // MARK: - Internal State

    private var ttsManager: PocketTtsManager?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    /// 24kHz mono float32 output format, created once with the engine.
    private var outputFormat: AVAudioFormat?

    /// Warm PocketTTS session per voice, alive for a speaking burst. Reused
    /// across every sentence of that burst, then finished when the burst
    /// drains (so a fresh burst starts a clean session).
    private var sessionsByVoice: [String: PocketTtsSession] = [:]

    /// The task draining the queue into sessions and scheduling audio.
    private var playbackTask: Task<Void, Never>?
    /// Bumped by stopSpeaking() to make any in-flight playback/scheduling bail.
    private var playbackEpoch = 0

    /// The single in-flight model initialization, if any. Shared so concurrent
    /// speak/preview calls don't start duplicate downloads.
    private var initTask: Task<Void, Never>?
    private var initializationGeneration = UUID()
    private var isFetchingVoiceAssets = false

    // Bound output lookahead without holding back the first 80 ms frame.
    private static let maximumBufferedSamples = 28_800
    static let maximumSentenceCharacters = 480

    /// Maximum pending sentences to prevent unbounded queue growth.
    private static let maxPendingSentences = 50

    // PocketTTS voices in order of preference from listening tests, alternating female and male
    // so agents sound different.
    static let availableVoices = [
        // Top tier (alternating f/m)
        "jane", "george", "eve", "bill_boerst",
        "vera", "peter_yearsley", "anna",
        // Usable
        "mary", "michael", "paul",
        "azelma", "caro_davy",
    ]

    init() {
        if let saved = UserDefaults.standard.string(forKey: "selectedTTSVoice"),
           Self.availableVoices.contains(saved) {
            selectedVoice = saved
        }
    }

    nonisolated static func computeUnits(chipBrand: String) -> PocketTtsComputeUnits {
        // FluidAudio issue 881: M1 Max on macOS 26 aborts in the Neural Engine flow decoder.
        // Keep M1 hardware on the supported CPU/GPU route until requalified.
        let words = chipBrand.lowercased().split(whereSeparator: \.isWhitespace)
        return words.contains("m1") ? .avoidNeuralEngine : .default
    }

    // MARK: - Voice Assignment

    /// Get or assign a voice for a connection. If the primary voice (selectedVoice)
    /// is available (no other connection using it), the new connection gets it.
    /// Otherwise, the next voice from the fallback order is assigned.
    func voiceForConnection(_ connectionID: Int32) -> String {
        // Local/non-MCP calls always use primary voice
        if connectionID == 0 { return selectedVoice }

        // Already assigned
        if let voice = voiceAssignments[connectionID] { return voice }

        let usedVoices = Set(voiceAssignments.values)

        // If the primary voice is available, assign it to this connection
        if !usedVoices.contains(selectedVoice) {
            voiceAssignments[connectionID] = selectedVoice
            print("[TTS] Assigned primary voice '\(selectedVoice)' to connection \(connectionID)")
            return selectedVoice
        }

        // Primary is taken -- find next available from fallback order
        let fallbacks = Self.voiceFallbackOrder.filter { $0 != selectedVoice }
        let nextVoice = fallbacks.first { !usedVoices.contains($0) } ?? fallbacks.last ?? selectedVoice
        voiceAssignments[connectionID] = nextVoice
        print("[TTS] Assigned voice '\(nextVoice)' to connection \(connectionID)")
        return nextVoice
    }

    /// Releases a closed connection's voice and drops its sentences that haven't started. Sentences
    /// already given to a session finish.
    func releaseConnection(_ connectionID: Int32) {
        if let voice = voiceAssignments.removeValue(forKey: connectionID) {
            print("[TTS] Released voice '\(voice)' from connection \(connectionID)")
        }
        pendingSentences.removeAll { $0.connectionID == connectionID }
    }

    // MARK: - Initialization

    /// Loads the voice model. Safe to call repeatedly or concurrently: the first call does the work
    /// and the rest wait. Failures are reported through `modelPhase`.
    func initialize() async {
        if isInitialized { return }
        let task = initTask ?? beginInitialization()
        await task.value
    }

    private func ensureInitializing() {
        guard !isInitialized, initTask == nil else { return }
        _ = beginInitialization()
    }

    private func beginInitialization() -> Task<Void, Never> {
        let generation = UUID()
        initializationGeneration = generation
        let task = Task { [weak self] in
            await self?.performInitialize(generation: generation)
            guard let self, self.initializationGeneration == generation else { return }
            self.initTask = nil
            if self.isInitialized { self.ensurePlaybackLoop() }
        }
        initTask = task
        return task
    }

    private func performInitialize(generation: UUID) async {
        guard !isInitialized, initializationGeneration == generation, !Task.isCancelled else { return }
        modelPhase = .initializing
        isFetchingVoiceAssets = true
        do {
            // Fetch the language pack with a progress handler so a first run shows a real download
            // bar. A cached pack reports no progress. The parameters match PocketTtsManager's
            // defaults, so its own load finds everything present.
            _ = try await PocketTtsResourceDownloader.ensureModels(
                language: .english,
                progressHandler: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    // Cached assets return without transfer progress.
                    guard fraction > 0, fraction < 1 else { return }
                    Task { @MainActor [weak self] in self?.applyDownloadFraction(fraction, generation: generation) }
                }
            )
            guard initializationGeneration == generation, !Task.isCancelled else { return }
            isFetchingVoiceAssets = false
            // Models are on disk now; loading/compiling into the manager is a
            // local step, not a download.
            modelPhase = .initializing
            let manager = PocketTtsManager(defaultVoice: selectedVoice,
                computeUnits: Self.computeUnits(chipBrand: HardwareDetector.chipBrand))
            try await manager.initialize()
            guard initializationGeneration == generation, !Task.isCancelled else {
                await manager.cleanup()
                return
            }
            self.ttsManager = manager
            try setupAudioEngine()
            isInitialized = true
            modelPhase = .ready
            print("[TTS] PocketTTS initialized with voice: \(selectedVoice)")
        } catch {
            guard initializationGeneration == generation, !Task.isCancelled else { return }
            isFetchingVoiceAssets = false
            droppedSentenceCount += pendingSentences.count
            stopSpeaking()
            if let manager = ttsManager {
                ttsManager = nil
                await manager.cleanup()
            }
            guard initializationGeneration == generation, !Task.isCancelled else { return }
            modelPhase = .failed(error.localizedDescription)
            print("[TTS] Failed to initialize PocketTTS: \(error)")
        }
    }

    private func applyDownloadFraction(_ fraction: Double, generation: UUID) {
        guard initializationGeneration == generation, isFetchingVoiceAssets,
              !isInitialized, initializationInFlight else { return }
        switch modelPhase {
        case .initializing, .downloading: break
        default: return
        }
        var current = 0.0
        if case .downloading(let value) = modelPhase { current = value }
        modelPhase = .downloading(max(current, fraction))
    }

    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SideWave.TTS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The speech output format is unavailable."])
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            engine.prepare()
            try engine.start()
            self.audioEngine = engine
            self.playerNode = player
            self.outputFormat = format
            print("[TTS] Audio engine started")
        } catch {
            engine.stop()
            throw error
        }
    }

    // MARK: - Public API

    /// Speak text immediately: stops current playback, clears queue, speaks this text.
    /// connectionID 0 = local/non-MCP (voice preview, draft response).
    @discardableResult
    func speak(_ text: String, connectionID: Int32 = 0) -> SpeechOutcome {
        stopSpeaking()
        return queueSpeech(text, connectionID: connectionID)
    }

    /// Splits text into sentences and queues them; plays immediately if nothing is playing.
    /// Connection 0 is local, not MCP.
    @discardableResult
    func queueSpeech(_ text: String, connectionID: Int32 = 0) -> SpeechOutcome {
        guard !suppressed else { return .notSpoken("Speech is paused while recording.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }

        // If the model already failed, don't pretend the text is queued. Retry
        // init in the background so a later call can succeed.
        if !isInitialized, case .failed(let reason) = modelPhase {
            ensureInitializing()
            return .notSpoken("Voice model failed to initialize (\(reason)). Retrying now; call check_status, then speak again.")
        }

        let sentences = Self.splitIntoSentences(text)
        guard !sentences.isEmpty else { return .empty }

        let voice = voiceForConnection(connectionID)
        let room = max(0, Self.maxPendingSentences - pendingSentences.count)
        let accepted = Array(sentences.prefix(room))
        let droppedCount = sentences.count - accepted.count

        guard !accepted.isEmpty else {
            print("[TTS] Queue full (\(Self.maxPendingSentences)); dropped \(droppedCount) sentence(s)")
            return .droppedQueueFull(accepted: 0, dropped: droppedCount)
        }

        pendingSentences.append(contentsOf: accepted.map {
            QueuedSentence(text: $0, connectionID: connectionID, voice: voice)
        })

        let started = startOrBuffer()
        if droppedCount > 0 { return .droppedQueueFull(accepted: accepted.count, dropped: droppedCount) }
        return started
    }

    /// Replaces this connection's unplayed sentences with new text. The current sentence finishes,
    /// and audio already buffered may play briefly. Connection 0 is local, not MCP.
    @discardableResult
    func replacePending(with text: String, connectionID: Int32 = 0) -> SpeechOutcome {
        guard !suppressed else { return .notSpoken("Speech is paused while recording.") }
        // Same honesty checks as queueSpeech: a hard init failure isn't a queue,
        // and a past-cap truncation is reported, not silent.
        if !isInitialized, case .failed(let reason) = modelPhase {
            ensureInitializing()
            return .notSpoken("Voice model failed to initialize (\(reason)). Retrying now; call check_status, then speak again.")
        }

        pendingSentences.removeAll()

        let sentences = Self.splitIntoSentences(text)
        guard !sentences.isEmpty else {
            return .empty
        }
        let voice = voiceForConnection(connectionID)
        let accepted = Array(sentences.prefix(Self.maxPendingSentences))
        let droppedCount = sentences.count - accepted.count
        pendingSentences.append(contentsOf: accepted.map {
            QueuedSentence(text: $0, connectionID: connectionID, voice: voice)
        })

        let started = startOrBuffer()
        if droppedCount > 0 { return .droppedQueueFull(accepted: accepted.count, dropped: droppedCount) }
        return started
    }

    /// Start playback (or buffer for a later model init) for freshly queued
    /// sentences and report which happened. Shared by queueSpeech/replacePending.
    private func startOrBuffer() -> SpeechOutcome {
        if isInitialized {
            do {
                try ensureAudioOutput()
            } catch {
                failPlayback("Audio output is unavailable. Check the selected sound output and try again.")
                return .notSpoken(lastPlaybackError ?? "Audio output is unavailable.")
            }
            let wasIdle = (playbackTask == nil)
            ensurePlaybackLoop()
            return wasIdle ? .started : .queued
        } else {
            ensureInitializing()
            return .queuedPendingModel
        }
    }

    /// Stop all speech immediately: cancel playback, clear queue, tear down
    /// warm sessions so nothing keeps generating.
    func stopSpeaking() {
        playbackEpoch &+= 1
        playbackTask?.cancel()
        playbackTask = nil

        let toCancel = Array(sessionsByVoice.values)
        sessionsByVoice.removeAll()
        for session in toCancel {
            Task { await session.cancel() }
        }

        pendingSentences.removeAll()
        playerNode?.stop()
        playerNode?.reset()
        isSpeaking = false
        currentlyPlayingText = ""
        preBufferedText = ""
        playbackTimeline.reset()
    }

    // MARK: - Session-Based Playback

    /// Start the playback loop if there's work and none is running.
    private func ensurePlaybackLoop() {
        guard isInitialized, playbackTask == nil, !pendingSentences.isEmpty else { return }
        do {
            try ensureAudioOutput()
        } catch {
            failPlayback("Audio output is unavailable. Check the selected sound output and try again.")
            return
        }
        let epoch = playbackEpoch
        playbackTask = Task { [weak self] in
            await self?.runPlayback(epoch: epoch)
        }
    }

    /// Drain the pending queue run by run (a run = consecutive same-voice
    /// sentences), playing each run through that voice's warm session.
    private func runPlayback(epoch: Int) async {
        while playbackEpoch == epoch {
            // While the user is recording, drop queued speech instead of playing it into the mic,
            // including text buffered before the model loaded.
            if suppressed { pendingSentences.removeAll() }
            while playbackEpoch == epoch, let head = pendingSentences.first {
                if suppressed { pendingSentences.removeAll(); break }
                let voice = head.voice
                let prepared = await sessionFor(voice: voice, epoch: epoch)
                guard playbackEpoch == epoch, !Task.isCancelled else { break }
                guard let session = prepared else {
                    // No session could be made for this voice: drop the sentence so the loop
                    // doesn't spin, and count it for get_playback_status.
                    if !pendingSentences.isEmpty { pendingSentences.removeFirst() }
                    droppedSentenceCount += 1
                    continue
                }
                guard playbackEpoch == epoch else { break }
                await playRun(voice: voice, session: session, epoch: epoch)
            }
            // Queue is drained; wait for the audio tail to finish. Text may
            // arrive during that wait -- if it does, loop and play it rather
            // than stranding it.
            await waitForPlayerDrain(epoch: epoch)
            if playbackEpoch != epoch { break }
            if pendingSentences.isEmpty { break }
        }

        // No await between the empty check and this cleanup, so a concurrent queueSpeech either ran
        // before the check or starts a new loop afterward.
        if playbackEpoch == epoch {
            isSpeaking = false
            currentlyPlayingText = ""
            preBufferedText = ""
            playbackTimeline.reset()
            playbackTask = nil
        }
    }

    /// Plays consecutive sentences with the same voice through one session, keeping the next
    /// sentence generating while the current one plays, and finishes the session when no more text
    /// for that voice is waiting.
    private func playRun(voice: String, session: PocketTtsSession, epoch: Int) async {
        var enqueuedTexts: [(id: UUID, text: String)] = []
        var finished = false

        // Queues the next sentence if it uses this run's voice and returns true. Uses the voice
        // chosen at enqueue time.
        func enqueueNextSameVoice() -> Bool {
            guard let head = pendingSentences.first, head.voice == voice else { return false }
            pendingSentences.removeFirst()
            session.enqueue(head.text)
            enqueuedTexts.append((UUID(), head.text))
            return true
        }

        guard enqueueNextSameVoice() else { return }

        guard let format = outputFormat, let player = playerNode else {
            session.finish()
            sessionsByVoice[voice] = nil
            droppedSentenceCount += enqueuedTexts.count
            lastPlaybackError = "Audio output is unavailable. Try speaking again."
            return
        }

        var sealedThrough = -1
        var aborted = false

        do {
            for try await frame in session.frames {
                if playbackEpoch != epoch || Task.isCancelled { aborted = true; break }
                guard audioEngine?.isRunning == true else {
                    failPlayback("The sound output changed during speech. Check the output device and try again.")
                    aborted = true
                    break
                }
                // The user started recording: stop the audio now instead of finishing the sentence
                // into the mic.
                if suppressed {
                    stopSpeaking()
                    aborted = true
                    break
                }

                guard await waitForPlaybackCapacity(epoch: epoch) else { aborted = true; break }
                guard playbackEpoch == epoch, !Task.isCancelled, !suppressed else { aborted = true; break }
                let index = min(max(0, frame.utteranceIndex ?? 0), enqueuedTexts.count - 1)
                let utterance = enqueuedTexts[index]
                try scheduleSamples(frame.samples, format: format, player: player,
                                    utteranceID: utterance.id, text: utterance.text)
                if !player.isPlaying { player.play() }
                isSpeaking = true

                // A new utterance index means the previous one is fully generated: queue the next
                // sentence or seal the session. A frame without an index also seals it, so playback
                // can't wait forever.
                if let utterance = frame.utteranceIndex {
                    if utterance > sealedThrough {
                        sealedThrough = utterance
                        if !finished {
                            if !enqueueNextSameVoice() {
                                session.finish()
                                finished = true
                            }
                        }
                    }
                } else if !finished {
                    session.finish()
                    finished = true
                }
            }
        } catch {
            if playbackEpoch == epoch {
                print("[TTS] Session synthesis error for voice \(voice): \(error)")
                lastPlaybackError = "Speech synthesis failed. Try speaking again."
                droppedSentenceCount += max(1, enqueuedTexts.count - max(0, sealedThrough))
            }
            // The utterance being generated plus any enqueued-but-unstarted
            // ones didn't play; count them so the drop is observable.
        }

        if aborted { await session.cancel() }
        else if !finished { session.finish() }
        if sessionsByVoice[voice] === session { sessionsByVoice[voice] = nil }
    }

    /// Get or create a warm session for a voice. Creating one pays the voice
    /// conditioning cost once for the whole run.
    private func sessionFor(voice: String, epoch: Int) async -> PocketTtsSession? {
        if let existing = sessionsByVoice[voice] { return existing }
        guard let manager = ttsManager else { return nil }
        do {
            let session = try await manager.makeSession(voice: voice)
            guard playbackEpoch == epoch, !Task.isCancelled else {
                await session.cancel()
                return nil
            }
            sessionsByVoice[voice] = session
            return session
        } catch {
            if playbackEpoch == epoch, !Task.isCancelled {
                lastPlaybackError = "The selected voice could not prepare speech. Try another voice or retry."
            }
            print("[TTS] makeSession failed for voice \(voice): \(error)")
            return nil
        }
    }

    private func scheduleSamples(_ samples: [Float], format: AVAudioFormat, player: AVAudioPlayerNode,
                                 utteranceID: UUID, text: String) throws {
        guard let buffer = Self.makeBuffer(samples: samples, format: format) else {
            throw NSError(domain: "SideWave.TTS", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Speech synthesis returned invalid audio."])
        }
        let bufferID = playbackTimeline.schedule(samples: samples.count, utteranceID: utteranceID, text: text)
        updatePlaybackText()
        let epoch = playbackEpoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackEpoch == epoch else { return }
                self.playbackTimeline.didPlay(bufferID)
                self.updatePlaybackText()
            }
        })
    }

    private func updatePlaybackText() {
        currentlyPlayingText = playbackTimeline.playingText
        preBufferedText = playbackTimeline.nextText
        if playbackTimeline.isEmpty { isSpeaking = false }
    }

    private func waitForPlaybackCapacity(epoch: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while playbackTimeline.bufferedSamples >= Self.maximumBufferedSamples {
            guard playbackEpoch == epoch, !Task.isCancelled else { return false }
            if suppressed { stopSpeaking(); return false }
            guard audioEngine?.isRunning == true, playerNode?.isPlaying == true,
                  ContinuousClock.now < deadline else {
                failPlayback("Speech playback stopped before it finished. Check the output device and try again.")
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return playbackEpoch == epoch && !Task.isCancelled
    }

    /// Waits until scheduled audio has played or playback is interrupted. Polls instead of waiting
    /// on a continuation, so reset() can't leave one hanging.
    private func waitForPlayerDrain(epoch: Int) async {
        let duration = Double(playbackTimeline.bufferedSamples) / 24_000
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(2, duration + 2)))
        while playbackEpoch == epoch, !playbackTimeline.isEmpty, !Task.isCancelled {
            guard audioEngine?.isRunning == true, playerNode?.isPlaying == true,
                  ContinuousClock.now < deadline else {
                failPlayback("Speech playback stopped before it finished. Check the output device and try again.")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func ensureAudioOutput() throws {
        if let engine = audioEngine {
            if !engine.isRunning { try engine.start() }
        } else {
            try setupAudioEngine()
        }
        lastPlaybackError = nil
    }

    private func failPlayback(_ message: String) {
        droppedSentenceCount += pendingSentences.count + (currentlyPlayingText.isEmpty ? 0 : 1)
        stopSpeaking()
        lastPlaybackError = message
    }

    static func makeBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, samples.count <= Int(UInt32.max), samples.allSatisfy(\.isFinite),
              format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    channelData[0].update(from: base, count: samples.count)
                }
            }
        }
        return buffer
    }

    // MARK: - Sentence Splitting

    /// Split text into sentences using Apple's NLTokenizer.
    static func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english)
        tokenizer.string = text

        var raw: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                raw.append(sentence)
            }
            return true
        }

        raw = raw.flatMap { boundedChunks($0) }
        guard raw.count > 1 else { return raw }

        // Merge short fragments with neighbors: PocketTTS synthesizes each sentence separately, and
        // fragments under about 5 words sound unnatural alone. Merge backward if the result stays
        // under 120 characters (about 25 words, within PocketTTS's 50-token chunks); otherwise the
        // second pass may merge it forward.
        var merged: [String] = []
        for sentence in raw {
            let isShort = sentence.count < 30
            if isShort, let last = merged.last, (last.count + sentence.count + 1) < 120 {
                // Short fragment + previous is still reasonable length -- merge back
                merged[merged.count - 1] = last + " " + sentence
            } else {
                merged.append(sentence)
            }
        }

        // Second pass: merge any remaining short orphans forward into the next sentence.
        // This catches fragments that couldn't merge backward (previous was too long).
        guard merged.count > 1 else { return merged }
        var final: [String] = []
        var i = 0
        while i < merged.count {
            let current = merged[i]
            if current.count < 30, i + 1 < merged.count, (current.count + merged[i + 1].count + 1) < 120 {
                // Merge this short fragment forward into the next sentence
                final.append(current + " " + merged[i + 1])
                i += 2
            } else {
                final.append(current)
                i += 1
            }
        }

        return final
    }

    /// Bound the upstream stream's lookahead even for text without punctuation.
    private static func boundedChunks(_ text: String) -> [String] {
        var remaining = text[...]
        var result: [String] = []
        while remaining.count > maximumSentenceCharacters {
            let limit = remaining.index(remaining.startIndex, offsetBy: maximumSentenceCharacters)
            let candidate = remaining[..<limit]
            let split = candidate.lastIndex(where: \.isWhitespace) ?? limit
            let chunk = remaining[..<split].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            remaining = remaining[split...].drop(while: \.isWhitespace)
        }
        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    // MARK: - Voice Management

    func updateVoice(_ voice: String) async {
        guard Self.availableVoices.contains(voice) else { return }
        selectedVoice = voice
        await ttsManager?.setDefaultVoice(voice)
    }

    func cleanup() {
        initializationGeneration = UUID()
        isFetchingVoiceAssets = false
        initTask?.cancel()
        initTask = nil
        stopSpeaking()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        outputFormat = nil
        let manager = ttsManager
        ttsManager = nil
        isInitialized = false
        modelPhase = .uninitialized
        lastPlaybackError = nil
        if let manager {
            Task { await manager.cleanup() }
        }
    }
}
