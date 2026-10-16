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

    /// Called from the overlay's Stop button and from Escape during refinement: stops generation
    /// and keeps the raw dictation as a pending session. Does nothing when not refining, and never
    /// turns a hard cancel already in progress into a soft one.
    @MainActor
    func requestCleanupCancel() {
        guard isCleaningUp, isProcessingStop else { return }
        guard !cancelRequestedDuringStop else { return }
        preserveRawOnCleanupCancel = true
        cancelRequestedDuringStop = true
        dictationFormatter.cancelGeneration()
    }

    func cancelSpecialtyFinishingIfRequested(rawText: String) -> Bool {
        guard cancelRequestedDuringStop else { return false }
        documentEditNotice = "Formatting stopped. Your captured words are kept in the document or pending additions, and in History."
        bailFromCleanupCancel(rawText: rawText)
        // This capture already lives in the page or additions. A generic Resume
        // would append the same words a second time.
        pendingSessionText = nil
        pendingSessionTimestamp = nil
        return true
    }

    /// Used by stop and regression tests; each request includes an editable sentence boundary.
    func finishIncrementalRefinement(
        refinedBody: String,
        unrefinedTail: String,
        onStream: @escaping @Sendable (String) -> Void
    ) async -> DictationFormatterService.RefinementResult {
        let original = RefinementWindow.join(refinedBody, unrefinedTail)
        // With no new text there is no new boundary context to reconcile.
        guard !unrefinedTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refined(original)
        }
        var window = RefinementWindow(refinedBody: refinedBody, unrefinedTail: unrefinedTail)
        guard !window.editable.isEmpty else { return .refined(original) }
        while !Task.isCancelled {
            let next = RefinementWindow.nextChunk(window.editable)
            let prefix = window.prefix
            let result = await dictationFormatter.refine(next.chunk, forceRefine: true,
                priorContext: window.context, silentMode: true, finishing: true)
            guard result.completed, !cancelRequestedDuringStop else { return .original(original) }
            let assembled = RefinementWindow.join(prefix, result.text)
            onStream(RefinementWindow.join(assembled, next.remaining))
            if next.remaining.isEmpty { return .refined(assembled) }
            window = RefinementWindow(refinedBody: assembled, unrefinedTail: next.remaining)
        }
        return .original(original)
    }

    /// A failed final pass never sends partly refined text to another app.
    func preserveUnfinishedRefinement(_ text: String) {
        isCleaningUp = false
        cleanupStreamingText = ""
        isOverlayVisible = false
        let savedAppName = targetAppName
        targetPID = nil
        targetAppName = "Unknown"
        targetFocusedElement = nil
        pendingSessionText = text
        pendingSessionTimestamp = Date()
        accumulatedSessionNeedsRefinement = true
        historyStore.addEntry(text: text, appName: savedAppName, entryType: .dictation)
        recordDictationFailure(.refinement("Refinement could not finish. Your text is kept below and in History. Resume to try again, or copy it as captured."))
        showToast("Refinement did not finish. Your text is kept on Home.", icon: "text.badge.checkmark")
    }

    /// Shared bail logic for the two cancel checkpoints in handleStopRecording.
    /// Clears refinement state, dismisses the overlay, and stashes raw text
    /// into pendingSessionText when soft-cancel was requested.
    func bailFromCleanupCancel(rawText: String) {
        let shouldPreserve = preserveRawOnCleanupCancel
        cancelRequestedDuringStop = false
        preserveRawOnCleanupCancel = false
        isCleaningUp = false
        cleanupStreamingText = ""
        isOverlayVisible = false
        clearSpeechSuppressionIfSafe()
        let cancelledAppName = targetAppName
        targetPID = nil
        targetAppName = "Unknown"
        targetFocusedElement = nil

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        historyStore.addEntry(text: trimmed, appName: cancelledAppName, entryType: .cancelled)

        if shouldPreserve {
            withAnimation(.easeInOut(duration: 0.25)) {
                pendingSessionText = trimmed
                accumulatedSessionNeedsRefinement = true
                pendingSessionTimestamp = Date()
            }
        }
    }

    func handleCancelRecording() async {
        appStateTraceLog.notice("AppState.handleCancelRecording entry transcriptionRecording=\(self.transcriptionService.isRecording, privacy: .public) overlayVisible=\(self.isOverlayVisible, privacy: .public)")
        hotkeyManager.cancelHoldTracking()

        if isProcessingStop {
            preserveRawOnCleanupCancel = false
            cancelRequestedDuringStop = true
            dictationFormatter.cancelGeneration()
            return
        }

        // Save partial text to history before destroying (safety net for Ctrl+Escape).
        let partialText =
            (transcriptionService.confirmedText + " " + transcriptionService.volatileText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !partialText.isEmpty {
            historyStore.addEntry(text: partialText, appName: "Cancelled")
        }

        showSpecialtyPreview = false
        // Reset command mode so a cancelled spoken edit doesn't leave the next dictation in it.
        // Queued document additions belong to the document and are kept.
        isCommandDictation = false

        hotkeyManager.isRecording = false
        pendingStopAfterStart = false
        captureStart.cancel()
        let pendingStart = recordingStartTask
        pendingStart?.cancel()
        await pendingStart?.value
        restoreDictationVolumeControl()
        relayStartTask?.cancel()
        relayStartTask = nil
        relayUpdateTask?.cancel()
        relayUpdateTask = nil
        resetRecordingStats()
        draftResponseManager.cancelPending()
        let historySaved = historyStore.flush()
        await transcriptionService.cancelRecording(preserveRecovery: !historySaved)
        clearSpeechSuppressionIfSafe()
        isOverlayVisible = false
        overlayMessage = ""
        targetPID = nil
        targetAppName = "Unknown"
            targetFocusedElement = nil
        // Clear any pending session since user explicitly cancelled
        pendingSessionText = nil
        pendingSessionTimestamp = nil
        accumulatedSessionText = nil
    }

    /// Escape during recording: soft stop. Stops recording and saves text
    /// to a pending session instead of pasting. The user can resume, paste,
    /// or discard from the dashboard's pending session card.
    func handleSoftStop() async {
        hotkeyManager.cancelHoldTracking()

        if isCleaningUp {
            requestCleanupCancel()
            return
        }
        guard transcriptionService.isRecording || isProcessingStart else { return }
        if isProcessingStart {
            pendingSoftStopAfterStart = true
            pendingStopAfterStart = false
            return
        }

        guard !isProcessingStop else { return }
        isProcessingStop = true
        cancelRequestedDuringStop = false
        defer {
            isProcessingStop = false
            cancelRequestedDuringStop = false
            if pendingStartAfterStop {
                pendingStartAfterStop = false
                Task { @MainActor [weak self] in self?.handleStartRecording() }
            }
        }

        hotkeyManager.isRecording = false
        pendingStopAfterStart = false
        captureStart.cancel()
        restoreDictationVolumeControl()

        relayStartTask?.cancel()
        relayStartTask = nil
        relayUpdateTask?.cancel()
        relayUpdateTask = nil
        resetRecordingStats()
        draftResponseManager.cancelPending()

        SoundEffectService.play(.recordingStop)

        let finalText = await transcriptionService.stopRecording()

        clearSpeechSuppressionIfSafe()
        isOverlayVisible = false
        overlayMessage = ""

        let combinedText: String
        if let accumulated = accumulatedSessionText, !accumulated.isEmpty {
            combinedText = (accumulated + " " + finalText).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            combinedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        accumulatedSessionText = nil

        // A spoken edit command was escaped mid-utterance. Abort it cleanly:
        // don't route the command words into the document and don't save a
        // duplicate of the document as a pending session.
        if isCommandDictation {
            isCommandDictation = false
            agenticEditInstruction = ""
            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
            return
        }

        // A pause preserves this capture, not a copy of the previous document.
        let pendingTextToSave = combinedText

        if cancelRequestedDuringStop {
            if !pendingTextToSave.isEmpty {
                historyStore.addEntry(text: pendingTextToSave, appName: targetAppName, entryType: .cancelled)
            }
            pendingSessionText = nil
            pendingSessionTimestamp = nil
        } else if !pendingTextToSave.isEmpty {
            withAnimation(.easeInOut(duration: 0.25)) {
                pendingSessionText = pendingTextToSave
                accumulatedSessionNeedsRefinement = true
                pendingSessionTimestamp = Date()
            }
        }

        targetPID = nil
        targetAppName = "Unknown"
            targetFocusedElement = nil
    }
}
