// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
@preconcurrency import AVFAudio
import FluidAudio
import Foundation

// MARK: - Meeting Transcription Service

@Observable
@MainActor
final class MeetingTranscriptionService {
    var state: MeetingState = .idle
    var isStartingRecording = false
    var isCaptureActive: Bool {
        if isStartingRecording { return true }
        if case .recording = state { return true }
        return false
    }
    var recordingDuration: TimeInterval = 0
    var audioLevel: Double = 0
    var transcript: MeetingTranscript?
    var speakerCount: Int = 0

    /// Real fraction for the current processing stage (0...1), or nil for an
    /// indeterminate stage. The recording/processing view renders a real bar
    /// from this instead of the enum so progress ticks don't churn `state`.
    var processingProgress: Double?

    /// Provisional live transcript shown during recording. Empty unless the live
    /// streaming pipeline is active (16 GB+ and the streaming ASR model present).
    var liveSegments: [MeetingSegment] = []
    /// Whether the live streaming transcript is expected to run for this session.
    var liveTranscriptAvailable: Bool = false

    /// Download status for the meeting models (diarizer bundles + batch ASR).
    var meetingModelsState: MeetingModelsState = .notPrepared
    /// Description of the current preparation step, for example "Compiling speaker model". Nil when
    /// idle or ready.
    var modelPrepDetail: String?
    /// True while the current step has no byte feedback (Core ML compile,
    /// cache listing) so the provisioning card shows an indeterminate bar
    /// instead of a fraction that looks frozen.
    var modelPrepIndeterminate: Bool = false

    /// The unified download session for meeting preparation and its last real fraction.
    /// Lazily started on the first real download event so a warm cached load
    /// never pops a session. See updateModelDownloadActivity.
    @ObservationIgnored private var modelDLSession: UUID?
    @ObservationIgnored private var modelDLLastFraction: Double = 0
    /// Progress (0...1) of an explicit live-transcript model download, or nil
    /// when none is running. Separate from `meetingModelsState` so the ~600 MB
    /// optional fetch never disables the New Meeting button.
    var liveModelDownloadProgress: Double?
    private var prepareTask: Task<Void, Never>?

    /// Advisory warning set after recording stops if the audio looks unhealthy.
    /// Nil when the recording looked fine. Reset when a new recording starts.
    var postRecordingWarning: String?

    // User-configurable speaker names (defaults applied per transcript).
    var speakerNames: [String: String] = [:]
    /// Kept for the setup sheet. Nemotron 3 always uses up to 8 speakers and ignores a requested
    /// count, so this doesn't affect detection; the UI says it detects up to 8 speakers
    /// automatically.
    var expectedSpeakers: Int? = nil

    /// Cached after the first pass so rediarize can skip ASR.
    var cachedWords: [String] = []
    var cachedTokenTimings: [TokenTiming] = []
    var cachedDuration: TimeInterval = 0
    /// Detection can run again whenever the audio and transcript exist. A meeting transcribed live
    /// has no cached words, so it is fully reprocessed from its audio files.
    var canRediarize: Bool {
        transcript != nil && !(session?.partURLs().isEmpty ?? true)
    }

    // Crash-safe session backing the current/last meeting.
    var session: MeetingSession?
    var liveWasActive = false

    // Off-main engine (models cached for the app session).
    @ObservationIgnored
    lazy var engine: MeetingEngine = {
        let versionRaw = UserDefaults.standard.string(forKey: "selectedModelVersion") ?? "v3"
        let version = ModelVersion(rawValue: versionRaw) ?? .v3
        return MeetingEngine(asrVersion: version.asrVersion)
    }()

    var canChangeSpeechModel: Bool {
        guard !isCaptureActive, prepareTask == nil, liveModelDownloadProgress == nil else { return false }
        if case .processing = state { return false }
        return true
    }

    func speechModelChanged(_ version: ModelVersion) {
        guard canChangeSpeechModel else { return }
        engine = MeetingEngine(asrVersion: version.asrVersion)
        meetingModelsState = .notPrepared
    }

    // Recording infrastructure.
    var audioWriter: MeetingAudioWriter?
    var audioDiagnostics: MeetingAudioDiagnostics?
    var audioFileURL: URL?
    var recordingSampleRate: Double = 16000
    /// Seconds recorded in earlier parts of a resumed meeting. `recordingDuration` is this plus the
    /// current part; `finishCurrentPart` records only the current part's own time.
    var priorPartsDuration: TimeInterval = 0
    var capture: MeetingCapture?
    var durationTimer: Task<Void, Never>?
    var levelPollTask: Task<Void, Never>?
    var heartbeatTask: Task<Void, Never>?
    var recordingStartTime: Date?

    // Live pipeline plumbing.
    var liveContinuation: AsyncStream<MeetingAudioChunk>.Continuation?
    var liveConsumerTask: Task<Void, Never>?
    var liveDrainTask: Task<Void, Never>?

    // Processing.
    var processingTask: Task<Void, Never>?
    /// Incremented by cancelProcessing() and reset(). Progress updates hop to the main actor
    /// asynchronously, so one queued before a cancel could otherwise bring back `.processing` with
    /// nothing running. Each run records the value at start, and updates apply only while it
    /// matches.
    var processingEpoch: Int = 0

    // MARK: - Legacy cleanup

    /// Removes leftover audio from the old temporary meeting folder at launch. Only that legacy
    /// `sidewave-meetings` folder: in-progress recordings are handled by recovery, never deleted here.
    static func cleanupStaleAudioFiles() {
        let legacy = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidewave-meetings", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: nil
        ) else { return }
        var removed = 0
        for file in files where file.pathExtension == "caf" {
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        if removed > 0 {
            print("[MeetingTranscription] Cleaned up \(removed) legacy audio file(s)")
        }
    }

    // MARK: - Model preparation

    /// Progress handler shared by every caller of `engine.prepare`, so the display is the same
    /// whichever caller started it. `.downloading` updates the bar and detail; `.preparing` updates
    /// the words and never moves a running download bar backward.
    func makePrepHandler(driveRecoveryWindow: Bool = false) -> @Sendable (MeetingPrepProgress) -> Void {
        { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch p {
                case .downloading(let f, let detail):
                    let frac = max(0, min(1, f))
                    self.meetingModelsState = .downloading(progress: frac)
                    self.modelPrepDetail = detail
                    self.modelPrepIndeterminate = false
                    if driveRecoveryWindow { self.updateModelDownloadActivity(fraction: frac) }
                case .preparing(let detail):
                    self.modelPrepDetail = detail
                    self.modelPrepIndeterminate = true
                    if driveRecoveryWindow { self.updateModelDownloadActivity(fraction: nil) }
                    if case .downloading = self.meetingModelsState { return }
                    self.meetingModelsState = .notPrepared
                }
            }
        }
    }

    /// Reports meeting model downloads to the Downloads window. The session starts on the first
    /// real download event; cached loads never create one, because FluidAudio reports
    /// `.downloading` only when there are files to fetch. That makes `signalsRealDownload: true`
    /// safe, and meeting downloads open the window like other model downloads.
    private func updateModelDownloadActivity(fraction: Double?) {
        if let fraction {
            if modelDLSession == nil {
                modelDLSession = ModelDownloadActivity.shared.begin(
                    displayName: "Meeting models",
                    repoID: "on-device (FluidAudio)",
                    baselineBytes: 0)
            }
            modelDLLastFraction = fraction
        }
        guard let sid = modelDLSession else { return }
        let frac = fraction ?? modelDLLastFraction
        ModelDownloadActivity.shared.update(files: [], overall: frac, signalsRealDownload: true,
                                            sessionID: sid, detail: modelPrepDetail)
    }

    private func finishModelDownloadActivity(error: String?) {
        guard let sid = modelDLSession else { return }
        if let error {
            ModelDownloadActivity.shared.markError(error, sessionID: sid)
        } else {
            ModelDownloadActivity.shared.markComplete(sessionID: sid)
        }
        modelDLSession = nil
    }

    /// Loads the meeting models. Safe to call repeatedly; concurrent callers share one task. Shows
    /// a spinner for local loading and a bar for real downloads.
    func prepareMeetingModels() {
        if meetingModelsState.isReady { return }
        if case .downloading = meetingModelsState { return }
        if prepareTask != nil { return }

        // .notPrepared is the "preparing" spinner; clears any prior error on retry.
        meetingModelsState = .notPrepared
        // 16 GB+ Macs prepare the optional live transcript during this setup flow.
        let includeLive = HardwareDetector.physicalMemoryGB() >= 16
        let engine = self.engine
        let handler = makePrepHandler(driveRecoveryWindow: true)
        prepareTask = Task { [weak self] in
            do {
                try await engine.prepare(includeLive: includeLive, progress: handler)
                self?.finishModelDownloadActivity(error: nil)
                self?.meetingModelsState = .ready
                self?.modelPrepDetail = nil
                self?.modelPrepIndeterminate = false
                self?.refreshLiveAvailability()
            } catch {
                self?.finishModelDownloadActivity(error: error.localizedDescription)
                self?.meetingModelsState = .error(error.localizedDescription)
                self?.modelPrepDetail = nil
                self?.modelPrepIndeterminate = false
                print("[MeetingTranscription] Model prepare failed: \(error.localizedDescription)")
            }
            self?.prepareTask = nil
        }
    }

    /// Checks whether the live transcription model is already downloaded and updates
    /// `liveTranscriptAvailable`. Never downloads. Safe at launch or when the tab opens.
    func prepareLiveTranscriptModel() async {
        refreshLiveAvailability()
    }

    /// Downloads the live transcription model (about 600 MB, 16 GB Macs and up) when the user asks.
    /// Nothing at launch or meeting start may call this. Progress goes to
    /// `liveModelDownloadProgress`, separate from `meetingModelsState`, so it never blocks New
    /// Meeting.
    func downloadLiveTranscriptModel() async {
        guard HardwareDetector.physicalMemoryGB() >= 16 else { return }
        if MeetingEngine.liveASRModelPresent() { refreshLiveAvailability(); return }
        let engine = self.engine
        liveModelDownloadProgress = 0
        let handler: @Sendable (MeetingPrepProgress) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch p {
                case .downloading(let f, let detail):
                    self.liveModelDownloadProgress = max(0, min(1, f))
                    self.modelPrepDetail = detail
                case .preparing(let detail):
                    self.modelPrepDetail = detail
                }
            }
        }
        do {
            try await engine.downloadLiveASRModel(progress: handler)
        } catch {
            print("[MeetingTranscription] Live transcript model download failed: \(error.localizedDescription)")
        }
        liveModelDownloadProgress = nil
        modelPrepDetail = nil
        refreshLiveAvailability()
    }

    private func refreshLiveAvailability() {
        liveTranscriptAvailable = HardwareDetector.physicalMemoryGB() >= 16 && MeetingEngine.liveASRModelPresent()
    }

    /// Whether the live-transcript streaming model is already cached on disk.
    /// A cheap filesystem check (no load, no download) the UI can call to decide
    /// whether to offer the opt-in download.
    func isLiveASRModelPresent() -> Bool {
        MeetingEngine.liveASRModelPresent()
    }

    // MARK: - Cleanup

    func cancelProcessing() {
        processingEpoch += 1
        processingTask?.cancel()
        processingTask = nil
        Task { [engine] in await engine.abandonLive() }
        state = .idle
        processingProgress = nil
        modelPrepDetail = nil
    }

    func keepForLater() {
        // Re-detection can start from a completed transcript. Keep its audio too.
        session?.setStatus(.stopped)
        reset()
    }

    func reset(discardAudio: Bool = false) {
        stopRecordingIfActive()
        cancelProcessing()
        purgeAudioFile(discardUnprocessed: discardAudio)
        transcript = nil
        speakerCount = 0
        recordingDuration = 0
        priorPartsDuration = 0
        recordingStartTime = nil
        postRecordingWarning = nil
        liveSegments = []
        speakerNames = [:]
        cachedWords = []
        cachedTokenTimings = []
        cachedDuration = 0
        state = .idle
    }

    private func stopRecordingIfActive() {
        if case .recording = state {
            stopRecording()
        } else if capture != nil {
            stopRecording()
        }
    }

    /// Release the current session, retaining incomplete or unsaved audio.
    /// Only an explicit discard may remove unprocessed recordings.
    func purgeAudioFile(discardUnprocessed: Bool = false) {
        session?.release(discardUnprocessed: discardUnprocessed)
        session = nil
        audioFileURL = nil
    }
}

