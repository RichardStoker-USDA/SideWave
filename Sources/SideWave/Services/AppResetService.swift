// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import Foundation

/// Two reset paths surfaced in Settings > Advanced.
///
/// `restoreDefaultSettings` is NON-destructive: it clears the app's tuning
/// UserDefaults so registration defaults win again, keeping history, glossaries,
/// downloaded models, and onboarding state. It relaunches so the in-memory
/// mirrors (AppState, HotkeyManager) re-read the defaults cleanly.
///
/// `performFactoryReset` is destructive: it deletes every piece of app data and
/// known SideWave model caches, purges the UserDefaults domain, and quits so the next
/// launch starts from onboarding.
@MainActor
enum AppResetService {

    // MARK: - Settings Restore

    /// Tuning keys cleared by "Restore Default Settings". Sourced from
    /// TranscriptionService.registerDefaults, HistoryStore.register, the
    /// hardware-tier overrides, and every @AppStorage / direct-UserDefaults
    /// setting in the app. removeObject lets the registration domain (or the
    /// @AppStorage-declared default) win again.
    ///
    /// Deliberately EXCLUDED (see `preservedKeys`): history retention (resetting
    /// it could prune existing history), the selected model version (keeps the
    /// user on the model they downloaded), the SideWave experience preset and
    /// perf-recommendation flag (onboarding state), all vocabulary keys, and the
    /// one-shot migration / hardware-detection sentinels (re-running them can
    /// duplicate data or re-trigger first-launch logic).
    static let settingsKeysToReset: [String] = [
        // UI / overlay / window
        "appearance", "overlaySize", "customOverlayWidth", "overlayExpanded",
        "textDisplayMode", "visualizerColorMode", "liquidGlassMode",
        "audioSensitivity", "waveFrameRate", "refineAnimationStyle",
        "showLiveGhostText", "perWordTransitionAnimation",
        "lastSelectedSettingsTab", "dictationOpenSection",
        "dictationRefineAdvancedOpen", "showAdvancedControls", "mainWindowMode",
        // Text processing
        "removeFillerWords", "removeProfanity", "replaceProfanity",
        "performFinalRefinePass", "finalPassStrategy",

        // Audio / output
        "dictationAudioControl", "dictationVolumeReduction",
        "soundEffectsEnabled", "soundEffectsVolume",
        "soundEffect_recordingStart", "soundEffect_recordingStop",
        "soundEffect_promptConfirmed",
        // Dictation behavior
        "activationMode", "copyToClipboard", "appendTrailingSpace", "holdToRewriteEnabled",
        "dictationTargetMode", "pasteTargetTiming",
        // Refine pipeline
        "skipRefine", "useRealTimeRefine", "useMultiStageRendering",
        "useDualEngineSmartPTT", "tdtHiddenRefineSweep", "useEouToRefineDirect",
        "eouGhostSuppression", "refineCadence", "refineFixedIntervalEnabled",
        "refineFixedIntervalSeconds", "gemmaSessionTurns",
        "clipboardRestoreDelayMs", "autoSubmitDeliveryGraceMs",
        // Smart Push-to-Talk
        "smartPushToTalkEnabled", "smartPTTAlwaysRefine", "smartPTTAutoSubmit",
        "smartPTTAutoSubmitKey",
        // Cleanup / formatter
        "dictationCleanupEnabled", "dictationCleanupMinWords",
        "bypassRefineOnShortSessions", "dictationCleanupInstructions",
        "dictationCleanupTemplate", "dictationCleanupBackend",
        "meetingFormatterBackend",
        // Experimental
        "experimentalFeatures", "meetingTranscriptionEnabled",
        "enableSpecialtyTemplates", "relayModeEnabled", "mcpServerEnabled",
        "devForceAFMGen1Profile",
        // History (the AI-title setting, NOT retention or the data)
        "historyAITitlesEnabled",
        // Voice
        "selectedTTSVoice",
    ]

    /// Keys the settings restore never touches, for the report and as a guard.
    static let preservedKeys: Set<String> = [
        "selectedModelVersion", "historyRetentionDays", "sideWaveExperience",
        "perfRecommendationShown", "customDictionaryEntries",
        "vocabEnabledBuiltInPackIDs", "vocabBuiltInLinkedTemplates",
        "vocabCorrectionsMigratedV1", "hardwareTier", "hardwareTierDetectedAt",
        "tierCadenceResetMigration1", "legacyMCPAuthCredentialPurged",
    ]

    /// Clear the tuning keys and relaunch so every in-memory mirror re-reads
    /// the defaults. History, glossaries, models, and onboarding are untouched.
    static func restoreDefaultSettings() {
        let defaults = UserDefaults.standard
        for key in settingsKeysToReset where !preservedKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
        relaunch()
    }

    // MARK: - Factory Reset

    /// Every directory factory reset deletes. Computed (not created) so the
    /// confirmation copy can list them and nothing is materialized just to
    /// delete it. Missing paths are skipped at delete time.
    static let fluidModelDirectoryNames = [
        "parakeet-tdt-0.6b-v2", "parakeet-tdt-0.6b-v2-coreml", "parakeet-tdt-0.6b-v3",
        "parakeet-ultra", "parakeet-ultra-coreml", "parakeet-ctc-110m-coreml", "parakeet-eou-streaming",
        "parakeet-unified-en-0.6b", "nemotron-multilingual", "nemotron-3-diarization",
        "silero-vad", "silero-vad-coreml", "sortformer"
    ]

    static func modelResetPaths(home: URL, appSupport: URL, hubRoot: URL,
                                repositoryIDs: [String]) -> [URL] {
        let models = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        var paths = fluidModelDirectoryNames.map { models.appendingPathComponent($0, isDirectory: true) }
        paths.append(home.appendingPathComponent(".cache/fluidaudio/Models/pocket-tts", isDirectory: true))
        paths += repositoryIDs.compactMap { id -> URL? in
            let components = id.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2,
                  components.allSatisfy({ $0.range(of: "^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil && !$0.contains("..") }) else { return nil }
            return hubRoot.appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        }
        return paths
    }

    static func factoryResetPaths() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var paths = modelResetPaths(home: home, appSupport: support, hubRoot: ModelCacheInventory.hubRoot,
                                    repositoryIDs: ModelCacheInventory.knownRepositoryIDs)
        if let id = Bundle.main.bundleIdentifier {
            paths.append(home.appendingPathComponent("Library/Caches").appendingPathComponent(id))
        }
        // Delete personal data last. A model-cache failure must leave settings and history available.
        paths.append(support.appendingPathComponent(AppPaths.supportDirectoryName))
        return paths
    }

    struct ResetFailure: LocalizedError {
        var errorDescription: String? {
            "Reset could not finish. Some downloaded files may have been removed, but settings have not been reset. Check storage access and try again."
        }
    }

    /// Delete all app data + model caches, purge the UserDefaults domain, and
    /// quit. The next launch starts clean at onboarding.
    static func performFactoryReset() throws {
        guard !AppPaths.isTestHost else { throw ResetFailure() }
        let fm = FileManager.default
        for url in factoryResetPaths() where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                throw ResetFailure()
            }
        }

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }

        // Hard exit rather than NSApp.terminate: the terminate handlers flush
        // history to disk (recreating the folder we just deleted) and the
        // quit guard can pop a "meeting in progress" dialog. exit(0) skips
        // both so the wipe actually sticks. Nothing runs between the deletion
        // above and here, so there's no re-save window.
        exit(0)
    }

    // MARK: - Relaunch

    /// Relaunch the app. `sleep 1` lets this process fully exit before `open`
    /// runs, so a single-instance app relaunches cleanly. App sandbox is off,
    /// so spawning the helper is allowed.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "sidewave-relaunch", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
