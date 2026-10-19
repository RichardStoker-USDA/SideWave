// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
import AppKit
@preconcurrency import AVFAudio
import CoreAudio
import FluidAudio
import Foundation
import os

/// Per-engine dictation tracing. Active in DEBUG only; release binary's
/// logger is the disabled handle so log output is fully elided. Filter via
/// Console.app: `subsystem == "com.sidewave.dev" AND category == "dictation-trace"`.
let dictationTraceLog: Logger = {
    #if DEBUG
    return Logger(subsystem: "com.sidewave.dev", category: "dictation-trace")
    #else
    return Logger(OSLog.disabled)
    #endif
}()

/// Word count helper; splits on whitespace and counts non-empty pieces.
/// Cheap; called only on a delta path so allocation pressure is minimal.
func wordCount(_ s: String) -> Int {
    s.split(whereSeparator: \.isWhitespace).count
}

/// Content-free transcript diagnostics.
func transcriptMetrics(_ text: String) -> String {
    "chars=\(text.count) words=\(wordCount(text))"
}

@Observable
@MainActor
final class TranscriptionService {
    var modelState: ModelState = .notDownloaded
    var hasInstalledSpeechModels = false
    var modelPreparationGeneration = UUID()
    var auxiliaryModelErrors: [String] = []
    var isRecording = false
    
    /// Tracks if the EOU dual engine streaming manager has fully loaded its models and is ready.
    /// Prevents the AppState decision-task race on first cold load.
    var isDualEngineReady: Bool {
        if !dualEngineActive { return true }
        return eouAsr != nil
    }
    /// True while stop drains EOU's last chunks during `eou.finish()`. The EOU callback accepts
    /// partials while `isRecording || isStoppingDrain`; without it the last 100 to 300 ms of speech
    /// (often the final words) would miss `stagedTranscript.liveEouTail` and the saved text.
    /// Cleared after `stagedTranscript.finalText()` reads the tail.
    var isStoppingDrain = false
    /// True while any segment refine is running or queued. Shifts the wave to the refine palette.
    var isRefining: Bool = false
    var specialtyLiveStatus: SpecialtyLiveStatus? = nil
    // Separated confirmed/volatile for overlay rolling window display.
    var confirmedText = ""
    var volatileText = ""
    /// Time of the latest EOU partial this session, reset at start. The overlay uses it to show a
    /// quiet listening state when EOU has been silent for more than 3 s, since the streaming model
    /// can lag 2 to 3 s after a long pause.
    var lastEouEmitAt: Date?

    // RMS audio level (0.0 to 1.0) for equalizer visualization.
    // Written from the audio tap thread via thread-safe store, published at ~20Hz.
    var audioLevel: Double = 0

    // Peak amplitude of the most recent buffer (0.0 to 1.0+). Used for
    // clipping detection; RMS averages out brief peaks but the peak
    // catches them. Published at ~20Hz alongside audioLevel.
    var audioPeak: Double = 0

    /// Input level as a state the dashboard can show (Quiet, Balanced, Hot, Clipping) instead of a
    /// percentage. Balanced is typical speech, -30 to -12 dBFS.
    enum AudioInputStatus {
        /// Not recording, or the engine just started. Shows neutral chrome rather than "silent".
        case idle
        /// Engine is running, no real signal (RMS < -45 dB FS).
        /// Background noise floor or muted mic.
        case silent
        /// Real speech but too quiet for reliable recognition
        /// (RMS between -45 and -30 dB FS).
        case quiet
        /// Healthy speech level (RMS between -30 and -12 dB FS).
        /// This is the "you're doing it right" state.
        case balanced
        /// Loud but not clipping (RMS > -12 dB FS, peak < 0.95).
        /// Recognition still works but headroom is shrinking.
        case loud
        /// Peak samples within 5% of full scale (peak >= 0.95).
        /// Audio is clipping or about to clip; recognition degrades.
        case clipping
    }

    var audioInputStatus: AudioInputStatus {
        guard isRecording else { return .idle }
        // Peak-based clipping check first; a brief transient peak should
        // turn the indicator red even if RMS is still in the balanced
        // range, because clipped samples are unrecoverable.
        if audioPeak >= 0.95 { return .clipping }
        // RMS thresholds (linear scale corresponding to dB FS):
        //   -45 dB FS ≈ 0.0056
        //   -30 dB FS ≈ 0.0316
        //   -12 dB FS ≈ 0.2512
        if audioLevel < 0.0056 { return .silent }
        if audioLevel < 0.0316 { return .quiet }
        if audioLevel < 0.2512 { return .balanced }
        return .loud
    }

    /// Level for the dashboard, scaled so typical speech reads around 80% instead of 20 to 30%.
    /// `audioLevel` keeps the raw RMS for the wave.
    var audioInputDisplayPercent: Int {
        guard isRecording, audioLevel.isFinite else { return 0 }
        // Map RMS → 0-100% with the sweet spot at -15 dB FS (0.178).
        // Below -50 dB FS clamps to 0; above -3 dB FS (0.708) clamps to 100.
        // Logarithmic so the visual response feels even across the range.
        let rms = max(audioLevel, 0.001)
        let dB = 20.0 * log10(rms)            // -60 (silent) ... 0 (full scale)
        let normalized = (dB + 50) / 47        // -50 dBFS -> 0,  -3 dBFS -> 1
        return Int((max(0.0, min(1.0, normalized)) * 100).rounded())
    }

    /// Serial queue for segment persistence to prevent concurrent writes to the same .jsonl file.
    nonisolated let persistQueue = DispatchQueue(label: "com.sidewave.segment-persist", qos: .utility)

    // Recording session stats, directly observable by views through @Observable.
    var currentConfidence: Double = 0
    var currentSegmentCount: Int = 0
    var currentRtfx: Double = 0
    var isVadReady: Bool = false
    var isCtcBoosterReady: Bool = false
    var ctcBoostStatus: CTCBoostStatus = .inactive
    var fillerWordsRemovedCount: Int = 0
    var dictionaryReplacementsCount: Int = 0
    var vadTriggeredSegments: Int = 0
    /// Word replacements made by CTC vocabulary boosting this session. Separate from
    /// `dictionaryReplacementsCount`, which counts text substitutions after recognition.
    var ctcBoostsApplied: Int = 0

    /// Segment refines that applied this session (skips and rejections excluded). Shown as the
    /// dashboard's Refines stat.
    var refinesCompletedCount: Int = 0

    /// Set when a translate session kept a segment in the spoken language because every refine
    /// attempt for it failed, for example a timeout under load. AppState shows a toast after stop.
    /// Reset at session start.
    var translateRefineKeptSourceLanguage: Bool = false
    /// Count of segments that ended a translate session in the source language.
    var translateHeldSegmentCount: Int = 0

    /// Occurrences of vocabulary terms in this session's output, however they got there: CTC boost,
    /// text replacement, or Refine. Recomputed from the confirmed text at segment and refine
    /// cadence.
    var vocabTermsInOutputCount: Int = 0

    /// Word-boundary, case-insensitive count of each active vocabulary term in the confirmed text.
    /// Runs at segment cadence, never per buffer.
    func recomputeVocabOutputStat() {
        let text = confirmedText
        guard !text.isEmpty else {
            if vocabTermsInOutputCount != 0 { vocabTermsInOutputCount = 0 }
            return
        }
        let terms = VocabularyStore.shared.makeSnapshot().terms.map(\.canonical)
        guard !terms.isEmpty else { return }
        let lowered = text.lowercased()
        var count = 0
        for term in terms {
            let t = term.lowercased()
            guard t.count >= 2 else { continue }
            var searchStart = lowered.startIndex
            while let r = lowered.range(of: t, range: searchStart..<lowered.endIndex) {
                // Word-boundary check on both sides so "sign" doesn't count
                // inside "design".
                let beforeOK = r.lowerBound == lowered.startIndex
                    || !(lowered[lowered.index(before: r.lowerBound)].isLetter
                         || lowered[lowered.index(before: r.lowerBound)].isNumber)
                let afterOK = r.upperBound == lowered.endIndex
                    || !(lowered[r.upperBound].isLetter || lowered[r.upperBound].isNumber)
                if beforeOK && afterOK { count += 1 }
                searchStart = r.upperBound
            }
        }
        if vocabTermsInOutputCount != count { vocabTermsInOutputCount = count }
    }

    var pollingAsrManager: AsrManager?
    var pollingTask: Task<Void, Never>?
    var audioLevelTask: Task<Void, Never>?
    var liveTailPollingTask: Task<Void, Never>?
    var healthCheckTask: Task<Void, Never>?

    /// Which engine owns the preview in a dual-engine session. AppState's press-mode decision moves
    /// it from `.undecided` to `.eou` (push-to-talk hold) or `.tdt` (toggle). Neither engine writes
    /// to the overlay while undecided.
    enum DualEngineOverlayChoice {
        case undecided
        case eou
        case tdt
    }

    /// Read from `useDualEngineSmartPTT` at start and fixed for the session. Dual-engine is the
    /// default path; this flag keeps single-engine sessions on their own code path.
    internal var dualEngineActive: Bool = false

    /// Set by AppState's press-mode-decision Task. Default `.undecided`.
    /// Read by the EOU partial callback and the polling pipeline to decide
    /// whether to write the overlay.
    var currentEngineForOverlay: DualEngineOverlayChoice = .undecided

    /// Latest EOU partial transcript (post-processed). Updated unconditionally
    /// by the EOU callback so a Smart PTT release stop has the latest text
    /// regardless of which engine was driving the overlay at the moment.
    var eouPartialAccumulated: String = ""

    /// Highest EOU word count backed by speech energy. While the mic is silent the ghost gate
    /// freezes the visible tail here, so words the streaming model invents from silence or room
    /// noise don't reach the preview or the paste. Reset with the EOU accumulator.
    var eouSpeechBackedWordCount: Int = 0
    /// Ghost-gate release window: when the freeze began and the word count then. Four or more new
    /// words within 3 s is a rate silence hallucinations don't sustain but quiet speech does. The
    /// window re-arms when it expires.
    var ghostFreezeBeganAt: Double = 0
    var ghostFrozenWordsAtStart: Int = 0

    /// How long after the last speech buffer EOU growth is still trusted. Covers gaps between words
    /// and fading syllables; only longer silence freezes the tail.
    static let eouGhostHangoverSeconds: Double = 0.7

    /// First `n` words of a string. The ghost gate passes the staged transcript a prefix of the EOU
    /// text, never a shorter one. Nonisolated so tests and the audio path can call it.
    nonisolated static func prefixWords(_ text: String, _ n: Int) -> String {
        guard n >= 0 else { return "" }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > n else { return text }
        return words.prefix(n).joined(separator: " ")
    }

    /// Last input and output of `dualEngineProcessLive`. During silence the EOU actor re-sends the
    /// same text about every 160 ms, and the cleanup chain (fillers, profanity, substitutions)
    /// would re-run over all of it. The chain is a pure function of the text and the filter
    /// settings, so reusing the result is safe. Reset at session start.
    var lastEouRawInput: String?
    var lastEouProcessedOutput: String = ""

    /// Stamps each EOU partial in the order the streaming actor delivers it.
    /// `nonisolated` so the (non-MainActor) actor callback can advance it
    /// before hopping to the MainActor body.
    nonisolated let eouPartialSeqGen = MonotonicSeq()

    /// Highest EOU partial sequence applied on the main actor. Lower sequences are dropped, so the
    /// gray preview only moves forward. Set to the generator's current value at each session start.
    var lastAppliedEouPartialSeq: UInt64 = 0

    /// Owned by the dual-engine path. Drained by `eouFeederTask`.
    @ObservationIgnored nonisolated(unsafe) var streamingAudioQueue: StreamingAudioQueue?

    /// EOU streaming actor for the dual-engine path. Held alongside
    /// `pollingAsrManager` for the life of a dual-engine session.
    var eouAsr: StreamingEouAsrManager?

    /// Loaded EOU actor kept between sessions, so later sessions skip the 120 MB download and
    /// Neural Engine warm-up. `reset()` clears it between uses; `cleanup()` runs only when
    /// dual-engine is turned off or the app quits.
    var cachedEouAsr: StreamingEouAsrManager?
    var speechWarmupTask: Task<Void, Error>?
    var speechWarmupGeneration = UUID()

    var speechModelsPrepared: Bool {
        cachedModels != nil && cachedModelVersion == storedModelVersion().rawValue
            && (!UserDefaults.standard.bool(forKey: "useDualEngineSmartPTT") || cachedEouAsr != nil)
    }

    var hasPreparedStreamingModel: Bool { cachedEouAsr != nil }

    /// A failed streaming-engine start must show the working TDT fallback.
    var usesStagedPreview: Bool {
        multiStageActive || (!isRecording && (!stagedTranscript.confirmedSpans.isEmpty || !stagedTranscript.liveEouTail.isEmpty))
    }

    func prepareSelectedMode() {
        guard !isRecording, !AppPaths.isTestHost else { return }
        if hasInstalledSpeechModels && !speechModelsPrepared { modelState = .loading }
        Task { await warmUpModelsIfNeeded() }
    }

    /// Live preview model. EOU partials are the leading edge, TDT segments commit spans, and
    /// segment refines upgrade spans to `.refined`. Fed only while `multiStageActive` is true.
    let stagedTranscript = StagedTranscript()

    /// Read at start from `useMultiStageRendering` and `useDualEngineSmartPTT`. Needs dual-engine,
    /// because EOU provides the first stage.
    var multiStageActive: Bool = false

    /// Sampled once at startRecording. When true, each TDT-confirmed span
    /// triggers a background Refine task that replaces the span's text
    /// with the polished version once the LLM finishes.
    var refineRealTimeActive: Bool = false

    /// Read at start. When true, the pipeline skips TDT segments: VAD speech-end events commit EOU
    /// text since the last boundary and send it straight to Refine. Faster, but without TDT
    /// vocabulary boosting or the multilingual TDT model. Experimental.
    var directEouRefineActive: Bool = false

    /// Read at start from `eouGhostSuppression` (default on), so the partial callback, about 12
    /// times a second, doesn't read UserDefaults.
    var eouGhostSuppressionActive: Bool = true

    /// In direct mode, tracks how many EOU words have already been committed
    /// to a span. Next VAD speech-end commits everything beyond this offset.
    /// Reset per session and each commit.
    var lastCommittedEouWordCount: Int = 0

    /// `stagedTranscript.originalText()` saved in the stop path before cleanup resets the model.
    /// AppState stores it as the entry's unrefined text. Empty when multi-stage was off.
    var lastSessionOriginalText: String = ""

    /// `stagedTranscript.eouRawText()` saved in the stop path: the streaming draft before TDT
    /// correction and Refine, shown in History's earlier stages. Empty when multi-stage was off.
    var lastSessionEouRawText: String = ""

    /// The paste text split at stop, before cleanup resets the transcript. The body is what live
    /// refine already polished; the tail is what it never reached. AppState's stop pass refines
    /// only the tail, with the body as context, so no text is refined twice. Both empty when
    /// multi-stage was off.
    var lastSessionRefinedBody: String = ""
    var lastSessionUnrefinedTail: String = ""

    /// Serial worker that owns the per-segment refine queue. Refine tasks
    /// run sequentially so two segments don't fight `DictationFormatter`'s
    /// "cancel prior generation" behavior. Reset per session.
    var refineWorkerTask: Task<Void, Never>?
    /// Monotonic id per worker start. Lets a worker that exits on its own
    /// clear `refineWorkerTask` without clobbering a newer worker's handle.
    var refineWorkerGeneration: Int = 0

    /// Pending span IDs queued for refinement. The worker pops from the
    /// front, awaits the formatter, then writes the result back into
    /// `stagedTranscript`. A continuation wakes the worker on enqueue.
    var refineQueue: [UUID] = []
    var refineQueueContinuation: CheckedContinuation<UUID?, Never>?
    /// True from when the worker takes a span until that span is resolved. Set together with the
    /// dequeue so the span is always either queued or in flight, which keeps `awaitPendingRefines`
    /// from seeing a false idle moment.
    var refineInFlight = false

    /// Reference held so the refine worker can call into it. Set by
    /// AppState via `attachDictationFormatter` on launch.
    weak var dictationFormatter: DictationFormatterService?

    /// Single-feeder Task. Drains `streamingAudioQueue` and forwards buffers
    /// to `eouAsr` sequentially so chronological order is preserved at the
    /// actor's mailbox.
    var eouFeederTask: Task<Void, Never>?

    /// The teardown `eou.reset()`, which the next session awaits before reusing the cached actor.
    /// Otherwise a slow teardown reset could land after the next session wired its callback and
    /// wipe its gray tail.
    var eouResetTask: Task<Void, Never>?

    /// Per-session channel selector, built at start from the saved channel mode for the device. Nil
    /// between sessions.
    @ObservationIgnored var channelSelector: ChannelSelector?

    /// Per-session resampler, high quality or linear per `useHighQualityResampling`. Built at start
    /// so converter state never carries into a new session.
    @ObservationIgnored var resampler: AudioResampler?

    /// Incremented at every start. Stop and cancel skip their global cleanup when a newer session
    /// began while they were waiting, so a quick second dictation doesn't lose its recognizer, VAD,
    /// or CTC state.
    var sessionGeneration: Int = 0
    // Cross-thread audio buffers shared between MainActor and audio tap callback.
    // nonisolated(unsafe) allows capture in nonisolated closures; NSLock provides thread safety.
    let audioBuffers = AudioBufferStore()
    var hasAttemptedRecovery = false
    // System-default redirect. The input unit follows the system default input, so when the
    // selected mic differs from the default (for example a Bluetooth headset), the default is
    // switched to the selected mic for the whole session and restored at teardown. Restoring before
    // `engine.start()` can bind the tap to the wrong device, and it never fires.
    var redirectedSystemDefaultFromID: AudioDeviceID = 0
    var redirectedSystemDefaultToID: AudioDeviceID = 0
    var didRedirectSystemDefault: Bool = false
    var isPollingInProgress = false
    /// True while `finalizeCurrentSegment` runs. The stop path waits for it so it can't commit a
    /// segment the polling loop is already finalizing; cancelling `pollingTask` doesn't interrupt a
    /// finalize suspended in transcribe.
    private var isFinalizeInProgress = false
    private var isStopping = false
    var isReinitializingAsrManager = false
    var consecutivePollingErrors: Int = 0
    let minSamplesForTranscription = 16_000 // 1 second at 16kHz

    // CTC vocabulary boosting: after transcription, the 110M CTC encoder scores the same audio and
    // replaces a word when the acoustic evidence favors a vocabulary term. Adds about 200 to 300
    // MB.
    var ctcBooster: CtcVocabBooster?
    var boostSetupTask: Task<Void, Never>?

    // VAD Smart Segment Boundaries: detects natural speech pauses to finalize segments
    // at sentence boundaries instead of only at the fixed 14.8s ceiling.
    var vadManager: VadManager?
    var vadStreamState: VadStreamState?
    /// Set the first time Silero VAD detects speech this session. Until then, with VAD running, any
    /// transcribed segment is the recognizer reacting to noise (for example "Mm-hmm." from a fan),
    /// so commits and TDT preview updates are suppressed. Fails open when VAD isn't available.
    var vadSawSpeechThisSession = false
    /// Sample index (same space as frozenSampleCount) of the latest audio VAD classified as speech,
    /// -1 before any. A finalizing segment with no speech inside it is a pause, and its transcript
    /// is dropped as a hallucination.
    var lastVadSpeechSampleIndex: Int = -1
    /// How far VAD has processed, in the same sample space. The per-window guard acts only when VAD
    /// has covered the whole window, so a lagging VAD never drops real words.
    var vadConsumedFrontierSampleIndex: Int = 0
    var vadAccumulationBuffer: [Float] = []
    var vadTotalSamplesProcessed: Int = 0
    var lastSpeechEndSampleIndex: Int?
    /// Time of the latest TDT segment finalize, for the experimental fixed-interval cadence: once
    /// the interval has passed and the segment has enough audio, polling finalizes without waiting
    /// for a pause. Reset at session start.
    var lastFinalizeWallTime: TimeInterval = 0
    var vadSetupTask: Task<Void, Never>?
    var consecutiveVadErrors: Int = 0
    static let maxVadErrors = 10
    static let maxVadAccumulationSamples = 160_000 // 10 seconds at 16kHz
    static let vadChunkSize = 4096 // 256ms at 16kHz
    static let minSamplesForVadFinalization = 48_000 // 3s minimum before VAD-triggered split

    // MARK: - Segment Architecture
    struct FrozenSegment: Codable {
        let index: Int
        let text: String
        let sampleStart: Int
        let sampleEnd: Int
        let timestamp: Date
    }

    var frozenSegments: [FrozenSegment] = []
    var frozenSampleCount: Int = 0
    var totalDroppedSamples: Int = 0
    let segmentDurationSamples: Int = 236_800  // ~14.8s, max safe single encoder pass (185 frames * 1280)
    static let maxFrozenSegmentsKept = 100
    static let defaultFillers: Set<String> = [
        "um", "uh", "er", "ah", "eh", "umm", "uhh", "err", "ahh", "ehh",
        "hmm", "hm", "mm", "mmm", "erm", "urm", "ugh",
    ]

    // MARK: - Profanity Filter

    static let profanityWords: Set<String> = [
        // f-word family
        "fuck", "fucking", "fucked", "fucker", "fucks", "fuckface", "fuckhead",
        "fuckwit", "fuckboy", "fuckers", "fuckoff",
        "motherfuck", "motherfucker", "motherfucking", "motherfuckers",
        // s-word family
        "shit", "shitting", "shitty", "shits", "shithead", "shitface",
        "shithole", "shitstorm", "bullshit", "bullshitting", "horseshit",
        "dipshit", "batshit", "apeshit",
        // a-word family
        "ass", "asses", "asshole", "assholes", "asshat", "assface",
        "badass", "dumbass", "fatass", "jackass", "kickass", "smartass",
        "hardass", "lardass",
        // b-word family
        "bitch", "bitches", "bitching", "bitchy", "bitchass",
        "sonofabitch",
        // d-words
        "damn", "damned", "damning", "dammit", "goddamn", "goddamned", "goddammit",
        "dick", "dicks", "dickhead", "dickheads", "dickwad",
        // p-words
        "piss", "pissed", "pissing", "pisses", "pissoff",
        // c-words
        "crap", "crappy", "crapping",
        "cock", "cocks", "cocksucker", "cocksuckers", "cocky",
        "cunt", "cunts",
        // other
        "hell", "hellhole",
        "bastard", "bastards",
        "whore", "whores",
        "slut", "sluts", "slutty",
        "wanker", "wankers",
        "twat", "twats",
        "tit", "tits",
        "arse", "arses", "arsehole", "arseholes",
        "bollocks",
        "bugger", "buggers",
        "douche", "douchebag", "douchebags",
        "skank", "skanky",
        "screw", "screwed", "screwing",
        "frigging", "freaking",
        "wtf", "stfu", "lmfao",
        // additional missing common words
        "prick", "pricks",
        "suck", "sucks", "sucked", "sucker", "suckers",
        "retard", "retarded", "retards",
        "pisshead",
        "asswipe",
    ]

    static let profanityReplacements: [String: String] = [
        // f-word family
        "fuck": "frick",
        "fucking": "fricking",
        "fucked": "fricked",
        "fucker": "fricker",
        "fucks": "fricks",
        "fuckface": "silly goose",
        "fuckhead": "blockhead",
        "fuckwit": "nitwit",
        "fuckboy": "fool",
        "fuckers": "frickers",
        "fuckoff": "buzz off",
        "motherfuck": "mother fudge",
        "motherfucker": "mother trucker",
        "motherfucking": "mother trucking",
        "motherfuckers": "mother truckers",
        // s-word family
        "shit": "crap",
        "shitting": "crapping",
        "shitty": "crappy",
        "shits": "craps",
        "shithead": "bonehead",
        "shitface": "goofball",
        "shithole": "dump",
        "shitstorm": "trainwreck",
        "bullshit": "baloney",
        "bullshitting": "fibbing",
        "horseshit": "hogwash",
        "dipshit": "dimwit",
        "batshit": "bonkers",
        "apeshit": "bananas",
        // a-word family
        "ass": "butt",
        "asses": "butts",
        "asshole": "fool",
        "assholes": "fools",
        "asshat": "clown",
        "assface": "doofus",
        "badass": "tough",
        "dumbass": "dummy",
        "fatass": "lump",
        "jackass": "donkey",
        "kickass": "rad",
        "smartass": "wise guy",
        "hardass": "tough cookie",
        "lardass": "couch potato",
        // b-word family
        "bitch": "meanie",
        "bitches": "meanies",
        "bitching": "griping",
        "bitchy": "cranky",
        "bitchass": "wimp",
        "sonofabitch": "son of a gun",
        // d-words
        "damn": "dang",
        "damned": "danged",
        "damning": "danging",
        "dammit": "dang it",
        "goddamn": "gosh darn",
        "goddamned": "gosh darned",
        "goddammit": "gosh darn it",
        "dick": "turkey",
        "dicks": "turkeys",
        "dickhead": "blockhead",
        "dickheads": "blockheads",
        "dickwad": "doofus",
        // p-words
        "piss": "ticked",
        "pissed": "ticked",
        "pissing": "ticking",
        "pisses": "ticks",
        "pissoff": "buzz off",
        // c-words
        "crap": "crud",
        "crappy": "cruddy",
        "crapping": "crudding",
        "cock": "rooster",
        "cocks": "roosters",
        "cocksucker": "scoundrel",
        "cocksuckers": "scoundrels",
        "cocky": "smug",
        "cunt": "villain",
        "cunts": "villains",
        // other
        "hell": "heck",
        "hellhole": "dump",
        "bastard": "scoundrel",
        "bastards": "scoundrels",
        "whore": "rascal",
        "whores": "rascals",
        "slut": "troublemaker",
        "sluts": "troublemakers",
        "slutty": "tacky",
        "wanker": "fool",
        "wankers": "fools",
        "twat": "twit",
        "twats": "twits",
        "tit": "fool",
        "tits": "fools",
        "arse": "butt",
        "arses": "butts",
        "arsehole": "fool",
        "arseholes": "fools",
        "bollocks": "nonsense",
        "bugger": "rascal",
        "buggers": "rascals",
        "douche": "loser",
        "douchebag": "clown",
        "douchebags": "clowns",
        "skank": "creep",
        "skanky": "gross",
        "screw": "forget",
        "screwed": "messed up",
        "screwing": "messing",
        "frigging": "flipping",
        "freaking": "flipping",
        "wtf": "what the heck",
        "stfu": "shush",
        "lmfao": "ha ha",
        // additional
        "prick": "thorn",
        "pricks": "thorns",
        "suck": "stink",
        "sucks": "stinks",
        "sucked": "stank",
        "sucker": "chump",
        "suckers": "chumps",
        "retard": "goofball",
        "retarded": "goofy",
        "retards": "goofballs",
        "pisshead": "numbskull",
        "asswipe": "dolt",
    ]
    var totalFrozenSegmentsCount: Int = 0
    var cachedFrozenText: String = ""
    var lastVolatileSnapshot: String = ""
    var segmentFinalizationFailures: Int = 0
    var sessionDirectory: URL?
    var sessionID: String?
    var completedRecoveryFiles: [URL] = []

    // Cached CoreML models to avoid expensive reloads across sessions
    var cachedModels: AsrModels?
    var cachedModelVersion: String?

    // AVAudioEngine stored as AnyObject to avoid SwiftUI AttributeGraph crash.
    // @Observable macro reflection can trigger ObjC class lookup for AVFoundation types
    // during AttributeGraph's early metadata processing, causing launch-time crashes.
    var engineStorage: AnyObject?
    var engine: AVAudioEngine {
        if let existing = engineStorage as? AVAudioEngine {
            return existing
        }
        let created = AVAudioEngine()
        engineStorage = created
        return created
    }
    /// Background work that currently holds the kept engine: the keep-warm teardown or the launch
    /// prewarm. startRecording waits for it, with a limit, and builds a new engine if it is stuck.
    var engineQuiesceTask: Task<Void, Never>?

    /// Live capture for the current session; nil unless the opt-in default is
    /// set. Written from the tap thread (internally locked), closed in
    /// cleanupRecordingState.
    @ObservationIgnored nonisolated(unsafe) var sessionAudioCapture: SessionAudioCapture?

    /// Throttled sidecar write: at most once per 1.5 s.
    var lastVolatilePersistTime: Date = .distantPast

    /// Throttle for live CTC boosting. Each pass costs 50 to 300 ms, so once per 1.5 s keeps
    /// polling fast while terms still show up promptly.
    var lastLiveCtcBoostTime: Date = .distantPast

    init() {
        UserDefaults.standard.register(defaults: [
            "removeFillerWords": true,
            "dictationCleanupEnabled": true,
            // The two-stage preview (gray streaming draft, hidden TDT, refined text) is the
            // default: dual-engine push-to-talk, multi-stage rendering, real-time refine, and the
            // hidden TDT sweep are on. These are independent of `experimentalFeatures`, which stays
            // off by default and only shows opt-in surfaces such as the Experimental settings pane.
            // `register` fills only missing keys, so existing choices are kept.
            "experimentalFeatures": false,
            "useDualEngineSmartPTT": true,
            "useMultiStageRendering": true,
            "useRealTimeRefine": true,
            "tdtHiddenRefineSweep": true,
            "showLiveGhostText": true,
            "perWordTransitionAnimation": false,
            "useEouToRefineDirect": false,
            // When on, the refine worker never starts: the text is TDT output only, with a
            // word-by-word transition in place of refinement. For slow hardware or speed. Default
            // off.
            "skipRefine": false,
            "bypassRefineOnShortSessions": false,
            // Holds back streaming tokens that grow the live tail while the mic is silent. Affects
            // the gray preview and the paste only; TDT is unaffected. Default on.
            "eouGhostSuppression": true,
            // Paste tunables, read in TypingService and AppState: how long the clipboard keeps the
            // dictation before it is restored when delivery can't be verified (Electron and web
            // content), and how long auto-submit waits before pressing Return after an unverified
            // paste.
            "clipboardRestoreDelayMs": 600,
            "autoSubmitDeliveryGraceMs": 400,
            // How readily polling finalizes a segment at a pause. With multi-stage rendering,
            // "standard" never finalizes at a pause (segments split at the 14.8 s limit or the
            // fixed-interval timer); "faster" finalizes after 3 s of silence and "aggressive" after
            // 2 s. Without multi-stage, "standard" uses 3 s. Pause splits punctuate better because
            // Parakeet punctuates each segment on its own; the cost is more inference.
            "refineCadence": "standard",
            // Finalizes segments on a timer even while the user keeps talking. Off by default. The
            // interval stays below the 14.8 s Parakeet limit so the two never coincide.
            "refineFixedIntervalEnabled": false,
            "refineFixedIntervalSeconds": 8,
            // Gemma keeps one KV cache per dictation and each segment refine feeds only its new
            // turn. Measured on an M4 Max with E2B: time to first token 1213 ms to 109 ms, total
            // 1786 ms to 928 ms, prefill flat at about 70 tokens. Full-text passes, thinking mode,
            // and fallbacks still start fresh. Default on; turning it off restores fresh prompts
            // everywhere.
            "gemmaSessionTurns": true,
            // Turns all VAD-based hallucination guards on or off (session noise guard, pause guard,
            // preview gate). If a quiet voice or unusual mic loses words to a guard, turning this
            // off restores the unguarded behavior; the trace log records every suppression.
            "phantomNoiseGuardsEnabled": true,
            // Smart Push-to-Talk is on for new installs. HotkeyManager also treats a missing key as
            // on, but registering it keeps a fresh install off that fallback.
            "smartPushToTalkEnabled": true,
            // How the stop pass refines. "incremental" (default) keeps what real-time refine
            // produced and refines only the unrefined tail. "smart" refines a trailing window
            // again; "full" refines the whole dictation again.
            "finalPassStrategy": "incremental",
            // "afmSessionTurns" is not registered: its default depends on the Apple Intelligence
            // generation and is resolved where it's used with an object(forKey:) nil check, which a
            // registered value would defeat.
        ])
        // Applies hardware-appropriate defaults on first launch only; a stored flag prevents
        // overwriting the user's values. Runs after register(), and writes only keys that are
        // absent.
        let afmAvailable: Bool = {
            if case .available = DictationFormatterService.currentAFMAvailability() {
                return true
            }
            return false
        }()
        HardwareDetector.detectIfNeeded(afmAvailable: afmAvailable)
        checkModelCache()

        // The kept engine's binding can go stale across sleep, because devices re-enumerate on
        // wake. Discard the idle engine on wake; the next press builds a new one. Live sessions are
        // handled by attemptAudioRecovery.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRecording else { return }
                self.teardownEngine(destroyEngine: true)
            }
        }

        // Same rebuild when the set of audio devices changes without a sleep, for example a dock
        // that enumerates its USB devices seconds after wake.
        NotificationCenter.default.addObserver(
            forName: .sideWaveAudioDeviceSetChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRecording else { return }
                self.teardownEngine(destroyEngine: true)
            }
        }
    }
}
