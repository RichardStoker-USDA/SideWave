// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import FluidAudio
import AVFAudio
import Foundation
import os
import Sparkle
import SwiftUI

@MainActor
extension AppState {
    // MARK: - Debug Reset

    #if DEBUG
    /// Reset all user-facing app settings to compiled defaults.
    func resetAppSettingsToDefaults() {
        let keys = [
            // UI
            "appearance", "overlaySize", "customOverlayWidth", "textDisplayMode",
            "visualizerColorMode", "liquidGlassMode", "audioSensitivity", "waveFrameRate",
            // Text processing
            "selectedModelVersion", "removeFillerWords", "removeProfanity", "replaceProfanity",

            // Audio
            "dictationAudioControl", "dictationVolumeReduction",
            "soundEffectsEnabled", "soundEffectsVolume",
            "soundEffect_recordingStart", "soundEffect_recordingStop", "soundEffect_promptConfirmed", "soundEffect_error",
            // Dictation behavior
            "activationMode", "copyToClipboard", "appendTrailingSpace",
            "dictationTargetMode", "pasteTargetTiming",
            // History
            "historyRetentionDays",
            // Experimental
            "experimentalFeatures", "meetingTranscriptionEnabled", "enableSpecialtyTemplates",
            // AI Dictation Cleanup
            "dictationCleanupEnabled", "dictationCleanupMinWords", "bypassRefineOnShortSessions",
            "dictationCleanupInstructions", "dictationCleanupTemplate",
            "dictationCleanupBackend",
            // Meeting formatter
            "meetingFormatterBackend",
            // Relay
            "relayModeEnabled",
            "mainWindowMode",
        ]

        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Sync in-memory properties that aren't backed by @AppStorage
        storedActivationMode = ActivationMode.toggle.rawValue
        copyToClipboard = false
        appendTrailingSpace = false
        dictationTargetMode = DictationTargetMode.focusedWindow.rawValue
        relayModeEnabled = false
        pasteTargetTiming = "start"
        // AI Dictation Cleanup in-memory sync (paired with the keys cleared above)
        dictationCleanupEnabled = false
        dictationCleanupMinWords = 10
        bypassRefineOnShortSessions = false
        dictationCleanupInstructions = ""
        dictationCleanupTemplate = DictationFormatterService.Template.standard.rawValue
        dictationCleanupBackend = DictationFormatterService.Backend.gemma4E2B.rawValue
        dictationFormatter.disable()
        // Meeting formatter backend in-memory sync (paired with the key above).
        meetingFormatterBackend = MeetingFormatterBackend.gemma4E4B.rawValue
    }
    #endif
}
