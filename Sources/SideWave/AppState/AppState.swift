// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import FluidAudio
import AVFAudio
import Foundation
import os
import Sparkle
import SwiftUI

// Hotkey state tracing, debug builds only; release builds use a disabled logger. Same subsystem and
// category as HotkeyManager's trace, so one predicate shows both sides.
let appStateTraceLog: Logger = {
    #if DEBUG
    return Logger(subsystem: "com.sidewave.dev", category: "hotkey-trace")
    #else
    return Logger(OSLog.disabled)
    #endif
}()

// MARK: - Dictation Target Mode

enum DictationTargetMode: String, CaseIterable {
    case focusedWindow = "focused"
    case assignedWindow = "assigned"
}

struct RunningAppInfo: Identifiable {
    let pid: pid_t
    let name: String
    let icon: NSImage?

    var id: pid_t { pid }
}

@Observable
@MainActor
final class AppState {
    var transcriptionService = TranscriptionService()
    var meetingService = MeetingTranscriptionService()
    var formatterService = MeetingFormatterService()
    /// Interrupted meetings found by the launch orphan scan (crash, force
    /// quit, or quit-with-keep). Drives the "continue this meeting?" sheet;
    /// resolved one at a time, front of the array first.
    var pendingMeetingRecovery: [OrphanedMeeting] = []

    /// One-shot routing. The global shortcut starts a new document; Add dictation continues it.
    enum NextDictationTarget { case auto, document, askBar }
    var nextDictationTarget: NextDictationTarget = .auto
    var documentRevision = 0
    var dictationFormatter = DictationFormatterService()
    var hotkeyManager = HotkeyManager()
    let audioDeviceManager = AudioDeviceManager()
    let typingService = TypingService()
    let historyStore = HistoryStore.shared
    let updaterController: SPUStandardUpdaterController
    var supportsAppUpdates: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }
    /// Strong ref so Sparkle's weak delegate reference doesn't get released
    /// the moment the init scope ends.
    private var sparkleActivityDelegate: SparkleActivityDelegate?

    /// True while the dictation formatter is processing text. The overlay
    /// switches to "cleanup mode" (streaming inference text + refining status).
    var isCleaningUp = false
    /// Accumulated inference output streamed from Gemma 4. The overlay displays
    /// this text in place of the dictated text during cleanup.
    var cleanupStatus = "Finishing text"
    var cleanupStreamingText = ""

    /// Signposter for the dictation domain. Use via `beginInterval` /
    /// `endInterval` at session boundaries. `nonisolated` so it's callable
    /// from any context.
    nonisolated let signposter = OSSignposter(logHandle: SWLog.dictation)

    /// Display name for the active cleanup backend, shown on the overlay header
    /// during cleanup.
    var cleanupBackendDisplayName: String {
        dictationFormatter.activeBackend.overlayLabel
    }

    var overlayPositionLocked = false
    var isOverlayVisible = false {
        didSet {
            if isOverlayVisible {
                overlayController.show(appState: self)
            } else {
                overlayController.hide()
            }
        }
    }
    var overlayMessage = ""
    var showMainWindow = false
    var isAccessibilityGranted: Bool = AXIsProcessTrusted()
    private(set) var microphonePermission = AVAudioApplication.shared.recordPermission
    private(set) var isRequestingMicrophoneAccess = false

    func refreshMicrophonePermission() {
        microphonePermission = AVAudioApplication.shared.recordPermission
    }

    /// Called by the permission explanation in setup, before capture starts.
    func requestMicrophoneAccess() async {
        guard !isRequestingMicrophoneAccess else { return }
        refreshMicrophonePermission()
        guard microphonePermission == .undetermined else {
            if microphonePermission != .granted { AppDelegate.openMicrophoneSettings() }
            return
        }
        isRequestingMicrophoneAccess = true
        defer { isRequestingMicrophoneAccess = false }
        _ = await AVAudioApplication.requestRecordPermission()
        refreshMicrophonePermission()
    }
    var lowMemoryMode = false

    /// Set by MenuBarView (or other non-ContentView UI) to request sidebar navigation.
    /// ContentView observes this and applies it to its local selectedItem, then nils it out.
    var requestedPage: SidebarItem? = nil

    /// Select a bundle or personal copy when opening Vocabulary from Settings.
    var requestedGlossaryID: UUID? = nil

    /// Set to navigate the Settings window to a specific tab when opened.
    var requestedSettingsTab: SidebarItem? = nil

    /// A contextual Help link selects its topic when the window opens.
    var requestedHelpSection: HelpSection? = nil

    /// Set to scroll to and pulse a specific setting row/card.
    var requestedSettingsSpotlight: String? = nil

    // Tutorial state
    var tutorialState = TutorialState.load()
    var showTutorial = false
    var currentPage: SidebarItem = .home

    // Recording session lifecycle (owned by AppState, set in handleStartRecording)
    var recordingStartTime: Date? = nil

    // Audio volume control during dictation.
    // Saves volume before dictation and restores it after.
    var savedVolume: Float32?
    var savedMuteState: Bool?

    // Computed from live text on transcriptionService
    var wordsTranscribedCount: Int {
        let allText = (transcriptionService.confirmedText + " " + transcriptionService.volatileText)
            .trimmingCharacters(in: .whitespaces)
        guard !allText.isEmpty else { return 0 }
        return allText.split(separator: " ").count
    }

    // Feature readiness indicators (forwarded from TranscriptionService)
    var isVadReady: Bool { transcriptionService.isVadReady }
    var isCtcBoosterReady: Bool { transcriptionService.isCtcBoosterReady }
    var ctcBoostStatus: CTCBoostStatus { transcriptionService.ctcBoostStatus }
    var auxiliaryModelErrors: [String] { transcriptionService.auxiliaryModelErrors }

    // Target app PID captured when dictation starts (or stops, in "finish window" mode)
    var targetPID: pid_t?
    var targetAppName: String = "Unknown"
    /// Fingerprint of the text field at recording start (or of the assigned target), used to find
    /// the field again at paste.
    var targetFieldFingerprint: TextFieldFingerprint?
    /// The focused text field at recording start. More reliable than the fingerprint; the
    /// fingerprint is the fallback if the element is gone (page navigation, app quit).
    var targetFocusedElement: AXUIElement?
    /// The window that held the target field at recording start (or the assigned window), so
    /// delivery brings back that window rather than whichever window of the app is in front.
    var targetWindowID: CGWindowID?
    /// The caret or selection in the target field at recording start. A background insert goes
    /// ahead only while the field still has a plain caret or this selection.
    var targetSelection: CFRange?
    /// Puts finished text into the target field. Stateless apart from the paste engine.
    @ObservationIgnored lazy var deliveryRouter = DeliveryRouter(typing: typingService)

    // Pending session: text from a soft-stopped recording awaiting resume or discard
    var pendingSessionText: String? = nil
    var accumulatedSessionNeedsRefinement = false
    var pendingSessionTimestamp: Date? = nil
    /// The paused text split into finished and unfinished parts, so Resume refines only the
    /// unfinished parts. Used only while its text and output language still match.
    var pendingSessionPass: ParkedFinalPass? = nil
    /// Text accumulated from a previous session being continued.
    var accumulatedSessionText: String? = nil
    var accumulatedSessionPass: ParkedFinalPass? = nil
    /// The stop pass's model call. Tests replace it to simulate declines and slow output.
    @ObservationIgnored
    var finalPassRefine: (@MainActor (_ chunk: String, _ context: String) async -> DictationFormatterService.RefinementResult)?

    // Guards against duplicate start/stop flow and duplicate startServices calls
    var captureStart = CaptureStartState()
    var isProcessingStart: Bool { captureStart.isStarting }
    var recordingStartTask: Task<Void, Never>?
    var isProcessingStop = false
    var refinementCountAtSessionStart: UInt64 = 0
    var sessionRefineBackendForHistory: String? {
        guard dictationFormatter.completedRefinementCount > refinementCountAtSessionStart else { return nil }
        return dictationFormatter.lastCompletedBackend?.rawValue
    }
    enum DictationFailure: Equatable {
        case capture(String), persistence(String), delivery(String), refinement(String)
        var message: String {
            switch self {
            case .capture(let message), .persistence(let message), .delivery(let message), .refinement(let message): message
            }
        }
    }
    var lastDictationFailure: DictationFailure?
    var lastDictationError: String? { lastDictationFailure?.message }

    func recordDictationFailure(_ failure: DictationFailure) {
        lastDictationFailure = failure
    }
    var didFinishDictation = false

    var dictationSessionPhase: DictationSessionPhase {
        if isProcessingStart { return .preparing }
        if isProcessingStop { return .finishing }
        if transcriptionService.isRecording { return .listening }
        if lastDictationError != nil { return .failed }
        return didFinishDictation ? .delivered : .idle
    }
    var isDictationBusy: Bool {
        isProcessingStart || isProcessingStop || transcriptionService.isRecording
    }
    var pendingStopAfterStart = false
    var pendingSoftStopAfterStart = false
    /// When the current start began. Tells a quick toggle-stop (defer the stop until the engine is
    /// live) from a press during a long first-run warm-up, where a queued stop would end the
    /// session as soon as it started.
    var startInFlightSince: Date? = nil
    var accessibilityPollTask: Task<Void, Never>?
    var halKeepAliveTask: Task<Void, Never>?

    /// Mic standby session, held while `keepMicOnStandby` is on. It discards every buffer; it only
    /// keeps the input device awake, avoiding a 1 to 3 s wake delay on the first press.
    var standbyMicSession: StandbyMicSession?

    /// When on, a capture session keeps the mic awake between dictations so starts are instant. The
    /// macOS mic indicator stays on while SideWave runs; no audio is kept outside dictation.
    var keepMicOnStandby: Bool = false {
        didSet {
            UserDefaults.standard.set(keepMicOnStandby, forKey: "keepMicOnStandby")
            audioDeviceManager.onInputSelectionChanged = { [weak self] in
                Task { @MainActor in self?.applyMicStandbyState() }
            }
            applyMicStandbyState()
        }
    }

    // UserDefaults-backed settings. @AppStorage can't coexist with @Observable,
    // so these use didSet to persist and init to load from UserDefaults.
    var storedActivationMode: String = ActivationMode.toggle.rawValue {
        didSet { UserDefaults.standard.set(storedActivationMode, forKey: "activationMode") }
    }
    var copyToClipboard: Bool = false {
        didSet { UserDefaults.standard.set(copyToClipboard, forKey: "copyToClipboard") }
    }
    var reduceAppMotion: Bool = false {
        didSet { UserDefaults.standard.set(reduceAppMotion, forKey: "reduceAppMotion") }
    }
    var appendTrailingSpace: Bool = false {
        didSet { UserDefaults.standard.set(appendTrailingSpace, forKey: "appendTrailingSpace") }
    }
    var dictationTargetMode: String = DictationTargetMode.focusedWindow.rawValue {
        didSet { UserDefaults.standard.set(dictationTargetMode, forKey: "dictationTargetMode") }
    }
    var relayModeEnabled: Bool = false {
        didSet { UserDefaults.standard.set(relayModeEnabled, forKey: "relayModeEnabled") }
    }
    /// "start" = paste to window focused at recording start; "finish" = at recording stop
    var pasteTargetTiming: String = "start" {
        didSet { UserDefaults.standard.set(pasteTargetTiming, forKey: "pasteTargetTiming") }
    }

    /// Push-to-talk option: refine every hold before pasting, like hold to refine. Off by default,
    /// since push-to-talk is for quick replies.
    var smartPTTAlwaysRefine: Bool = false {
        didSet { UserDefaults.standard.set(smartPTTAlwaysRefine, forKey: "smartPTTAlwaysRefine") }
    }

    /// Push-to-talk option: press Return (or Shift-Return) in the target after pasting, for chat
    /// and prompt boxes. Off by default.
    var smartPTTAutoSubmit: Bool = false {
        didSet { UserDefaults.standard.set(smartPTTAutoSubmit, forKey: "smartPTTAutoSubmit") }
    }

    /// Key for auto-submit: "return" (most chat apps and Terminal) or "shift-return" (composers
    /// where Return inserts a line break).
    var smartPTTAutoSubmitKey: String = "return" {
        didSet { UserDefaults.standard.set(smartPTTAutoSubmitKey, forKey: "smartPTTAutoSubmitKey") }
    }

    /// Final pass: "incremental" keeps refined text and refines recent sentences with whatever was
    /// never refined, "smart" refines a trailing section with prior context, and "full" refines
    /// everything again.
    var finalPassStrategy: String = "incremental" {
        didSet { UserDefaults.standard.set(finalPassStrategy, forKey: "finalPassStrategy") }
    }

    /// AI dictation cleanup: when on, dictated text is passed through a local
    /// Gemma 4 model before paste. Values mirror DictationFormatterService.
    var dictationCleanupEnabled: Bool = false {
        didSet {
            if lowMemoryMode && dictationCleanupEnabled {
                dictationCleanupEnabled = false
                return
            }
            UserDefaults.standard.set(dictationCleanupEnabled, forKey: "dictationCleanupEnabled")
            hotkeyManager.refinementAvailable = dictationCleanupEnabled
            if dictationCleanupEnabled {
                // Clear our automatic skipRefine (set below) when the model is turned back on. A
                // skipRefine the user chose in Experimental has no auto-forced marker and is kept.
                // Otherwise turning Refine off and on would leave live refine silently disabled.
                if UserDefaults.standard.bool(forKey: "skipRefineAutoForced") {
                    UserDefaults.standard.set(false, forKey: "skipRefine")
                    UserDefaults.standard.removeObject(forKey: "skipRefineAutoForced")
                }
                dictationFormatter.enable()
            } else {
                dictationFormatter.disable()
                // Live refine needs the model. When it unloads (turned off, memory pressure,
                // cancelled download), turn skipRefine on so the Dictation tab shows Refine as off
                // instead of on with nothing running.
                if !UserDefaults.standard.bool(forKey: "skipRefine") {
                    UserDefaults.standard.set(true, forKey: "skipRefine")
                    UserDefaults.standard.set(true, forKey: "skipRefineAutoForced")
                }
            }
        }
    }
    private func updateFormatterMinWords() {
        dictationFormatter.minimumWordCount = bypassRefineOnShortSessions ? dictationCleanupMinWords : 0
    }

    var dictationCleanupMinWords: Int = 10 {
        didSet {
            UserDefaults.standard.set(dictationCleanupMinWords, forKey: "dictationCleanupMinWords")
            updateFormatterMinWords()
        }
    }
    var bypassRefineOnShortSessions: Bool = false {
        didSet {
            UserDefaults.standard.set(bypassRefineOnShortSessions, forKey: "bypassRefineOnShortSessions")
            updateFormatterMinWords()
        }
    }
    var dictationCleanupInstructions: String = "" {
        didSet {
            // Cap to 1000 chars so a bad paste doesn't balloon UserDefaults
            // or bloat the prompt. Mirror the prompt-builder cap.
            if dictationCleanupInstructions.count > 1000 {
                dictationCleanupInstructions = String(dictationCleanupInstructions.prefix(1000))
                return
            }
            UserDefaults.standard.set(dictationCleanupInstructions, forKey: "dictationCleanupInstructions")
            dictationFormatter.customInstructions = dictationCleanupInstructions
        }
    }
    /// Cleanup prompt template (Standard, Professional, Concise, Light Touch).
    /// Stored as the enum's raw value so UserDefaults sees a plain String.
    @ObservationIgnored private var isRestoringDictationChoice = false
    var dictationCleanupTemplate: String = DictationFormatterService.Template.standard.rawValue {
        didSet {
            guard !isRestoringDictationChoice else { return }
            guard oldValue == dictationCleanupTemplate || (!isDictationBusy && !isProcessingAgenticEdit && pendingSessionText == nil) else {
                isRestoringDictationChoice = true
                dictationCleanupTemplate = oldValue
                isRestoringDictationChoice = false
                return
            }
            guard DictationFormatterService.Template(rawValue: dictationCleanupTemplate) != nil else {
                dictationCleanupTemplate = DictationFormatterService.Template.standard.rawValue
                return
            }
            if oldValue != dictationCleanupTemplate {
                if case .delivery = lastDictationFailure {
                    lastDictationFailure = nil
                    didFinishDictation = false
                }
                isSwitchingSpecialtyTemplate = true
                defer { isSwitchingSpecialtyTemplate = false }
                cancelAgenticEdit()
                if DictationFormatterService.Template(rawValue: oldValue)?.isSpecialty == true {
                    documentDrafts.save(specialtyEditedText, for: oldValue,
                                        additions: specialtyQueuedSegments.map(\.text), instruction: agenticEditInstruction)
                }
                isProgrammaticWrite = true
                let draft = documentDrafts.draft(for: dictationCleanupTemplate)
                specialtyEditedText = draft.text
                specialtyIsEdited = !specialtyEditedText.isEmpty
                specialtyFormattedText = specialtyEditedText
                specialtyQueuedSegments = draft.additions.map { SpecialtyQueuedSegment(text: $0) }
                agenticEditInstruction = draft.instruction
                documentEditNotice = nil
                if DictationFormatterService.Template(rawValue: dictationCleanupTemplate)?.isSpecialty != true {
                    isSpecialtyActive = false
                    nextDictationTarget = .auto
                }
                isProgrammaticWrite = false
            }
            UserDefaults.standard.set(dictationCleanupTemplate, forKey: "dictationCleanupTemplate")
            VocabularyStore.shared.reconcileForTemplate(dictationCleanupTemplate)
        }
    }
    /// Output language for Refine. "match" keeps the spoken language; any other code translates.
    /// Stored as the raw value; the formatter reads the same key.
    var dictationOutputLanguage: String = DictationFormatterService.OutputLanguage.matchInput.rawValue {
        didSet {
            UserDefaults.standard.set(dictationOutputLanguage, forKey: "dictationOutputLanguage")
        }
    }

    /// Language code for a history entry, or nil when the spoken language was kept or Refine didn't
    /// run. Translation happens only in Refine, so unrefined text never claims to be translated.
    func historyOutputLanguage(refined: Bool) -> String? {
        guard refined,
              DictationFormatterService.OutputLanguage.from(code: dictationOutputLanguage) != .matchInput
        else { return nil }
        return dictationOutputLanguage
    }
    /// Which local LLM backend runs dictation cleanup. Switching backends
    /// tears down the loaded one and loads the new one (if cleanup is enabled).
    var dictationCleanupBackend: String = DictationFormatterService.Backend.gemma4E2B.rawValue {
        didSet {
            guard !isRestoringDictationChoice else { return }
            guard dictationCleanupBackend != oldValue else { return }
            guard !isDictationBusy && !isProcessingAgenticEdit else {
                isRestoringDictationChoice = true
                dictationCleanupBackend = oldValue
                isRestoringDictationChoice = false
                return
            }
            UserDefaults.standard.set(dictationCleanupBackend, forKey: "dictationCleanupBackend")
            let newBackend = DictationFormatterService.Backend(rawValue: dictationCleanupBackend) ?? .gemma4E2B
            dictationFormatter.setBackend(newBackend)
            if dictationCleanupEnabled {
                dictationFormatter.enable()
            }
        }
    }

    /// Backend for meeting notes. The initial value is a placeholder: init chooses the device
    /// default (Gemma 4 E4B when downloaded, otherwise Apple Intelligence on macOS 26, or E2B), and
    /// a stored choice wins. Switching unloads any loaded model.
    private var isRestoringMeetingBackend = false
    var meetingFormatterBackend: String = MeetingFormatterBackend.gemma4E4B.rawValue {
        didSet {
            guard !isRestoringMeetingBackend else { return }
            guard meetingFormatterBackend != oldValue else { return }
            guard !formatterService.state.isBusy else {
                isRestoringMeetingBackend = true
                meetingFormatterBackend = oldValue
                isRestoringMeetingBackend = false
                return
            }
            UserDefaults.standard.set(meetingFormatterBackend, forKey: "meetingFormatterBackend")
            let newBackend = MeetingFormatterBackend(rawValue: meetingFormatterBackend) ?? .gemma4E4B
            formatterService.setBackend(newBackend)
        }
    }

    /// Set when system sleep interrupts a live meeting recording so the wake
    /// handler can surface a "stopped by sleep" toast once.
    var meetingStoppedBySleep = false

    // MARK: - Specialty Preview Window State
    var isSwitchingSpecialtyTemplate = false
    let documentDrafts = DocumentDraftStore(isPersistent: !AppPaths.isTestHost)
    var isSpecialtyActive: Bool = false
    var isCommandDictation: Bool = false
    var specialtyFormattedText: String = ""
    var specialtyEditedText: String = "" {
        didSet {
            if !isProgrammaticWrite && !specialtyEditedText.isEmpty {
                specialtyIsEdited = true
            }
            if !isProcessingAgenticEdit { saveSpecialtyDraft() }
        }
    }
    var specialtyIsEdited: Bool = false
    var showSpecialtyPreview: Bool = false
    /// One queued dictation segment waiting in the Pending Additions sidebar.
    /// Stable UUID identity so rows animate correctly and can be removed by id
    /// even while the background processor appends new segments concurrently.
    struct SpecialtyQueuedSegment: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }
    var specialtyQueuedSegments: [SpecialtyQueuedSegment] = [] {
        didSet { saveSpecialtyDraft() }
    }
    var autoAppendSpecialtyAdditions: Bool = true
    var isProgrammaticWrite: Bool = false
    var didAutoOpenSpecialtyEditor = false

    var assignedAppPID: pid_t? = nil
    var assignedAppName: String? = nil
    /// Finds the app again after it quits and reopens with a new process ID.
    var assignedBundleID: String? = nil
    var assignedWindowID: CGWindowID? = nil
    var assignedWindowTitle: String? = nil
    /// The user picked this window from the app's window list, rather than picking the app.
    var assignedWindowChosen = false
    /// Changes each time the user picks or clears a target, so the stop can tell a target picked
    /// in the overlay during the dictation from the one captured at start.
    @ObservationIgnored var assignmentRevision = 0
    @ObservationIgnored var targetAssignmentRevision = 0
    /// Fingerprint of the field that was focused when the target window was chosen, to find it
    /// again at paste.
    var assignedFieldFingerprint: TextFieldFingerprint? = nil
    let borderOverlay = BorderOverlayController()

    var overlayController: DictationOverlayController { .shared }

    var isProcessingAgenticEdit: Bool = false {
        didSet { if !isProcessingAgenticEdit { saveSpecialtyDraft() } }
    }

    var agenticEditInstruction: String = "" {
        didSet { saveSpecialtyDraft() }
    }

    var documentEditNotice: String?

    var agenticEditTask: Task<Void, Never>?

    /// Incremented on every submit, cancel, clear, and reset. An edit's stream and completion write
    /// back only if the value still matches, so a late edit can't change the document after Clear,
    /// cancel, or a new dictation.
    var agenticEditGeneration = 0

    /// The document when the edit was submitted. Cancel restores it right away instead of waiting
    /// for the cancelled task to return.
    var agenticEditOriginalText = ""

    /// Set by the dashboard in ContentView.onAppear. Opening the editor through a captured
    /// OpenWindowAction works even when no other window is open.
    var openSpecialtyWindowAction: (@MainActor () -> Void)?

    var hasShutdown = false

    var servicesStarted = false

    /// Forces this stop through Refine regardless of the Refine switch. Set by
    /// handleStopRefinedRecording and cleared early in handleStopRecording; doesn't change the
    /// setting or the model.
    var forceRefineThisCapture: Bool = false

    /// Set only by the deliberate hold past the threshold: a full pass over the whole dictation,
    /// with Gemma thinking when enabled. A push-to-talk release with "Always refine" also forces
    /// Refine but leaves this off and uses the saved strategy, so it stays fast.
    var thoroughRefineThisCapture: Bool = false

    /// Consecutive session starts where the audio engine took >450ms to come
    /// up with Mic standby off. Two in a row triggers the one-shot standby
    /// suggestion toast (slow-wake pro interfaces).
    var consecutiveSlowEngineStarts = 0

    /// Set when handleCancelRecording runs while handleStopRecording is awaiting
    /// the formatter. handleStopRecording checks this after its await and bails
    /// out of the paste path if set.
    var cancelRequestedDuringStop = false

    /// A hotkey press arrived while the previous stop was still finishing
    /// (refine drain / paste). Consumed at every handleStopRecording exit so
    /// the queued press starts the next session instead of being dropped.
    var pendingStartAfterStop = false

    /// Whether a cancel during refinement should keep the raw dictation as a pending session.
    /// Escape and the Stop button set it; Control-Escape doesn't.
    var preserveRawOnCleanupCancel = false

    init() {
        // Upstream debug/info messages can contain recognized or synthesized text.
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        // Load persisted settings from UserDefaults
        let defaults = UserDefaults.standard
        storedActivationMode = defaults.string(forKey: "activationMode") ?? ActivationMode.toggle.rawValue
        copyToClipboard = defaults.bool(forKey: "copyToClipboard")
        reduceAppMotion = defaults.bool(forKey: "reduceAppMotion")
        appendTrailingSpace = defaults.bool(forKey: "appendTrailingSpace")
        keepMicOnStandby = defaults.bool(forKey: "keepMicOnStandby")
        dictationTargetMode = defaults.string(forKey: "dictationTargetMode") ?? DictationTargetMode.focusedWindow.rawValue
        // With Experimental Features off, turn relay mode off at launch whatever was stored, since
        // its switch would be hidden and its auto-submit couldn't be turned off.
        let experimentalOn = defaults.bool(forKey: "experimentalFeatures")
        // One-time default for Advanced view: users who already had Experimental Features on start
        // in Advanced view. Everyone else starts in Simple view. Written only if the key was never
        // set.
        if defaults.object(forKey: "showAdvancedControls") == nil && experimentalOn {
            defaults.set(true, forKey: "showAdvancedControls")
        }
        if experimentalOn {
            relayModeEnabled = defaults.bool(forKey: "relayModeEnabled")
        } else {
            relayModeEnabled = false
            if defaults.bool(forKey: "relayModeEnabled") {
                defaults.set(false, forKey: "relayModeEnabled")
            }
        }
        pasteTargetTiming = defaults.string(forKey: "pasteTargetTiming") ?? "start"
        // Smart-PTT sub-options. Both default to off; the user opts into
        // them on the dashboard's Smart Push-to-Talk row.
        smartPTTAlwaysRefine = defaults.bool(forKey: "smartPTTAlwaysRefine")
        smartPTTAutoSubmit = defaults.bool(forKey: "smartPTTAutoSubmit")
        smartPTTAutoSubmitKey = defaults.string(forKey: "smartPTTAutoSubmitKey") ?? "return"
        finalPassStrategy = defaults.string(forKey: "finalPassStrategy") ?? "incremental"
        // Dictation cleanup settings (didSet wires to service; assign via storage
        // to avoid triggering didSet before the service exists)
        let storedCleanupEnabled = defaults.bool(forKey: "dictationCleanupEnabled")
        let storedCleanupMinWordsRaw = defaults.integer(forKey: "dictationCleanupMinWords")
        let storedBypassOnShort = defaults.object(forKey: "bypassRefineOnShortSessions") as? Bool ?? false
        let storedCleanupInstructions = defaults.string(forKey: "dictationCleanupInstructions") ?? ""
        let storedOutputLanguage = DictationFormatterService.OutputLanguage
            .from(code: defaults.string(forKey: "dictationOutputLanguage")).rawValue

        let rawCleanupTemplate = defaults.string(forKey: "dictationCleanupTemplate") ?? "standard"
        let storedCleanupTemplate = DictationFormatterService.Template(rawValue: rawCleanupTemplate)?.rawValue ?? "standard"
        let defaultCleanupBackend: String
        var defaultMeetingBackend: String
        // Don't default to Apple Intelligence on Macs that can never run it, or every refine would
        // fail. Temporary unavailability (still downloading, turned off) keeps the default.
        if case .unavailable(_, .deviceNotEligible) = DictationFormatterService.currentAFMAvailability() {
            defaultCleanupBackend = DictationFormatterService.Backend.gemma4E2B.rawValue
            defaultMeetingBackend = MeetingFormatterBackend.gemma4E4B.rawValue
        } else {
            defaultCleanupBackend = DictationFormatterService.Backend.appleIntelligence.rawValue
            defaultMeetingBackend = MeetingFormatterBackend.appleIntelligence.rawValue
        }
        // Default meeting notes to Gemma 4 E4B only when it's already downloaded and the Mac has
        // enough memory, so a first run doesn't start a 5 GB download. Otherwise Apple Intelligence
        // on macOS 26, where the format sheet offers Gemma for meetings too long for its window.
        if MeetingFormatterBackend.gemma4E4B.isDownloaded && HardwareCapability.current == .capable {
            defaultMeetingBackend = MeetingFormatterBackend.gemma4E4B.rawValue
        }
        var storedCleanupBackend = defaults.string(forKey: "dictationCleanupBackend") ?? defaultCleanupBackend
        // The legacy Apple Intelligence backend is no longer offered, so map a stored value to the
        // current one, or the picker would show nothing.
        if storedCleanupBackend == DictationFormatterService.Backend.appleIntelligenceLegacy.rawValue {
            storedCleanupBackend = DictationFormatterService.Backend.appleIntelligence.rawValue
            defaults.set(storedCleanupBackend, forKey: "dictationCleanupBackend")
        }
        var storedMeetingBackend = defaults.string(forKey: "meetingFormatterBackend") ?? defaultMeetingBackend
        // Gemma meeting backends need 16 GB, and smaller Macs only see Apple Intelligence. Map a
        // stored Gemma value there, or the picker would show nothing.
        if HardwareCapability.current != .capable,
           storedMeetingBackend != MeetingFormatterBackend.appleIntelligence.rawValue {
            storedMeetingBackend = MeetingFormatterBackend.appleIntelligence.rawValue
            defaults.set(storedMeetingBackend, forKey: "meetingFormatterBackend")
        }

        // The Sparkle delegate records update checks and downloads in NetworkActivityLog for Data
        // Transparency. The updater itself starts in startServices(), after setup.
        let sparkleDelegate = SparkleActivityDelegate()
        self.sparkleActivityDelegate = sparkleDelegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: sparkleDelegate,
            userDriverDelegate: nil
        )
        setupHotkeyCallbacks()
        loadHotkeySettings()

        // Wire audio device auto-switch notifications
        audioDeviceManager.onDeviceAutoSwitched = { [weak self] deviceName, reason in
            Task { @MainActor in
                switch reason {
                case "bluetooth_failover":
                    self?.showToast("Switched to \(deviceName) (Bluetooth detected)", icon: "airpodspro")
                case "reconnected":
                    self?.showToast("Switched to \(deviceName)", icon: "cable.connector")
                case "bt_default_override":
                    self?.showToast("macOS input: \(deviceName)", icon: "mic")
                default:
                    self?.showToast("Input: \(deviceName)", icon: "mic")
                }
            }
        }

        // Capture owns the route from the accepted hotkey through final HAL cleanup.
        // Priority switching must also yield to meetings and microphone diagnostics.
        audioDeviceManager.isDictationActive = { [weak self] in
            guard let self else { return false }
            return self.hotkeyManager.isRecording || self.isDictationBusy || self.meetingService.isCaptureActive
                || MicTestController.isCapturing || AudioSetupActivity.isActive
        }

        // Wire overlay Ctrl+Escape to hard cancel
        overlayController.onDismiss = { [weak self] in
            Task { @MainActor in
                await self?.handleCancelRecording()
            }
        }

        // Wire overlay plain Escape to soft stop (save text, don't paste)
        overlayController.onSoftStop = { [weak self] in
            Task { @MainActor in
                await self?.handleSoftStop()
            }
        }

        // Apply stored Refine settings. enable() waits for startServices() so init never starts a
        // download.
        dictationCleanupMinWords = storedCleanupMinWordsRaw > 0 ? storedCleanupMinWordsRaw : 10
        bypassRefineOnShortSessions = storedBypassOnShort
        dictationCleanupInstructions = storedCleanupInstructions
        dictationCleanupTemplate = storedCleanupTemplate
        let restoredDraft = documentDrafts.draft(for: storedCleanupTemplate)
        specialtyEditedText = restoredDraft.text
        specialtyQueuedSegments = restoredDraft.additions.map { SpecialtyQueuedSegment(text: $0) }
        agenticEditInstruction = restoredDraft.instruction
        specialtyFormattedText = specialtyEditedText
        specialtyIsEdited = !specialtyEditedText.isEmpty
        dictationOutputLanguage = storedOutputLanguage
        let resolvedBackend = storedCleanupBackend
        // Sync backend onto the service without firing didSet (service already
        // constructed; just align activeBackend to the persisted value).
        if let b = DictationFormatterService.Backend(rawValue: resolvedBackend) {
            dictationFormatter.activeBackend = b
        }
        dictationCleanupBackend = resolvedBackend
        _storedDictationCleanupEnabledAtLaunch = storedCleanupEnabled

        // Meeting formatter backend.
        let resolvedMeetingBackend = storedMeetingBackend
        if let b = MeetingFormatterBackend(rawValue: resolvedMeetingBackend) {
            formatterService.selectedBackend = b
        }
        meetingFormatterBackend = resolvedMeetingBackend
        updateFormatterMinWords()

        dictationFormatter.onSilentFallback = { [weak self] message in
            guard let self else { return }
            if DictationFormatterService.Template(rawValue: self.dictationCleanupTemplate)?.isSpecialty == true {
                self.documentEditNotice = message
            }
            self.showToast(message, icon: "text.badge.checkmark")
        }

        // Defer model warm-up to startServices() to avoid triggering AVFoundation/
        // FluidAudio initialization during AppState.init(). Early initialization can
        // cause TCC permission prompts on Sequoia/Tahoe for unrelated file providers.
    }

    /// Captured from UserDefaults during init; applied in startServices().
    var _storedDictationCleanupEnabledAtLaunch: Bool = false

    // MARK: - Toast

    func showToast(_ message: String, icon: String? = nil, duration: TimeInterval = 1.5) {
        guard !AppPaths.isTestHost else { return }
        ToastController.shared.show(message: message, icon: icon, duration: duration)
    }

}
