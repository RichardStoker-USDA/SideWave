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
    /// and keeps the dictation as a pending session, with the parts the stop pass finished. Does
    /// nothing when not refining, and never turns a hard cancel already in progress into a soft
    /// one.
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

    typealias FinalPassRun = StagedTranscript.FinalPassRun
    typealias OutputLanguage = DictationFormatterService.OutputLanguage

    /// What the stop pass produced. Parts Refine couldn't finish are kept as captured.
    struct FinalPassOutcome {
        var text: String
        /// The text as finished and unfinished parts. Captured parts stay unfinished, so Resume or
        /// a held translation tries them again.
        var runs: [FinalPassRun]
        /// Refine declined or failed on a part, which is kept as captured.
        var keptCaptured = false
        /// Apple Intelligence declined a part.
        var declined = false
        /// The time budget ran out; the unfinished text is kept as captured.
        var timedOut = false
        /// The user stopped the pass.
        var cancelled = false
        var completed: Bool { !keptCaptured && !timedOut && !cancelled }
    }

    /// The paused text as finished and unfinished parts, and the output language they were made
    /// for. Resume refines only the unfinished parts while the text and language still match.
    struct ParkedFinalPass: Equatable {
        var runs: [FinalPassRun]
        var outputLanguage: OutputLanguage

        var text: String { FinalPassRun.joinedText(runs) }

        func runs(matching text: String, in language: OutputLanguage) -> [FinalPassRun]? {
            language == outputLanguage && AppState.sameWords(self.text, text) ? runs : nil
        }
    }

    nonisolated static var currentOutputLanguage: OutputLanguage {
        .from(code: UserDefaults.standard.string(forKey: "dictationOutputLanguage"))
    }

    /// What to tell the user when part of the text was sent as captured.
    nonisolated static func finalPassNotice(_ outcome: FinalPassOutcome) -> String? {
        if outcome.cancelled { return nil }
        if outcome.declined { return "Apple Intelligence declined part of this dictation. That part was sent as captured." }
        if outcome.timedOut { return "Refine ran out of time. The unfinished part was sent as captured." }
        if outcome.keptCaptured { return "Refine couldn't finish part of this dictation. That part was sent as captured." }
        return nil
    }

    /// Longest the stop pass waits for the model before it sends what it has. A normal stop has
    /// one short tail and finishes in a few seconds; the budget grows with the pending words.
    nonisolated static func finalPassBudget(pendingWords: Int) -> Duration {
        .milliseconds(Int(min(25, max(10, 6 + Double(pendingWords) * 0.06)) * 1000))
    }

    /// The runs the stop pass refines and the settled text before them. A resumed session reuses
    /// its paused runs while they still match its text and output language, so only unfinished
    /// parts are refined again.
    nonisolated static func finalPassInput(
        stagedRuns: [FinalPassRun],
        continuedText: String,
        parked: ParkedFinalPass?,
        outputLanguage: OutputLanguage,
        resumedNeedsRefinement: Bool,
        newText: String,
        assembledText: String
    ) -> (runs: [FinalPassRun], prefix: String) {
        if resumedNeedsRefinement {
            if let earlier = parked?.runs(matching: continuedText, in: outputLanguage) {
                var fresh = stagedRuns.isEmpty ? [FinalPassRun(text: newText, pending: true)] : stagedRuns
                // The first new sentence goes back to the model, so its request also reopens the end
                // of the paused text and can repair a sentence split by the pause.
                if let first = fresh.first, !first.pending {
                    let split = RefinementWindow.splitLeadingSentence(first.text)
                    fresh[0] = FinalPassRun(text: split.rest, pending: false)
                    fresh.insert(FinalPassRun(text: split.head, pending: true), at: 0)
                }
                return (FinalPassRun.merged(earlier + fresh), "")
            }
            return ([.init(text: assembledText, pending: true)], "")
        }
        if stagedRuns.isEmpty { return ([.init(text: assembledText, pending: true)], "") }
        return (stagedRuns, continuedText)
    }

    /// What Pause keeps: the earlier paused parts while they still match, then this capture's
    /// runs. Nil when nothing finished is known, and Resume refines the whole text.
    nonisolated static func pausedPass(
        earlier parked: ParkedFinalPass?,
        accumulatedText: String,
        stagedRuns: [FinalPassRun],
        newText: String,
        outputLanguage: OutputLanguage
    ) -> ParkedFinalPass? {
        let accumulated = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = accumulated.isEmpty ? [] : parked?.runs(matching: accumulated, in: outputLanguage)
        if stagedRuns.isEmpty && (previous ?? []).isEmpty { return nil }
        let earlier = previous ?? [FinalPassRun(text: accumulated, pending: true)]
        let fresh = stagedRuns.isEmpty ? [FinalPassRun(text: newText, pending: true)] : stagedRuns
        let runs = FinalPassRun.merged(earlier + fresh)
        return runs.isEmpty ? nil : ParkedFinalPass(runs: runs, outputLanguage: outputLanguage)
    }

    nonisolated static func sameWords(_ first: String, _ second: String) -> Bool {
        first.split(whereSeparator: \.isWhitespace) == second.split(whereSeparator: \.isWhitespace)
    }

    /// Used by regression tests: one pending tail after settled text.
    func finishIncrementalRefinement(
        refinedBody: String,
        unrefinedTail: String,
        onStream: @escaping @Sendable (String) -> Void
    ) async -> DictationFormatterService.RefinementResult {
        let outcome = await finishPendingRuns([.init(text: unrefinedTail, pending: true)], after: refinedBody, onStream: onStream)
        return outcome.completed ? .refined(outcome.text) : .original(RefinementWindow.join(refinedBody, unrefinedTail))
    }

    /// Refines each pending run with the text before it as context and keeps refined runs as they
    /// are. Each request reopens the last sentences before it, so a false sentence break at a
    /// junction can be repaired.
    ///
    /// A part the model declines or fails on is kept as captured and locked, so later requests
    /// don't send it again, and the pass moves on. When `budget` runs out, or the user stops the
    /// pass, the unfinished text is returned as captured.
    func finishPendingRuns(
        _ runs: [FinalPassRun],
        after prefix: String,
        budget: Duration? = nil,
        onStream: @escaping @Sendable (String) -> Void
    ) async -> FinalPassOutcome {
        let clock = ContinuousClock()
        let deadline = budget.map { clock.now.advanced(by: $0) }
        var outcome = FinalPassOutcome(text: "", runs: [])
        var settled = prefix
        // The first `locked` characters of `settled`, as finished and captured parts. Each part
        // after the first starts with the whitespace before it, which keeps paragraph breaks.
        var lockedRuns: [FinalPassRun] = []
        var locked = 0
        func outcomeRuns(_ unfinished: [FinalPassRun]) -> [FinalPassRun] {
            FinalPassRun.merged(lockedRuns + [FinalPassRun(text: String(settled.dropFirst(locked)), pending: false)] + unfinished)
        }
        for (index, run) in runs.enumerated() {
            guard run.pending else {
                settled = RefinementWindow.join(settled, run.text)
                continue
            }
            // With no new text there is no new boundary to reconcile.
            guard !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let later = Array(runs[(index + 1)...])
            // Each later run joins with its own leading break, so the preview keeps paragraphs.
            func preview(_ text: String) -> String { later.reduce(text) { RefinementWindow.join($0, $1.text) } }
            var window = RefinementWindow(refinedBody: settled, unrefinedTail: run.text, lockedCount: locked)
            // The part of this run no request has finished. A chunk always covers the reopened
            // sentences, so what remains after it is this run's own text.
            var unprocessed = run.text
            while true {
                let next = RefinementWindow.nextChunk(window.editable)
                var result: DictationFormatterService.RefinementResult?
                if !cancelRequestedDuringStop {
                    result = await finalPassChunk(next.chunk, context: window.context, deadline: deadline, clock: clock)
                }
                if cancelRequestedDuringStop { outcome.cancelled = true } else if result == nil { outcome.timedOut = true }
                if outcome.cancelled || outcome.timedOut {
                    outcome.runs = outcomeRuns([FinalPassRun(text: unprocessed, pending: true)] + later)
                    outcome.text = FinalPassRun.joinedText(outcome.runs)
                    return outcome
                }
                if let result, result.completed {
                    settled = RefinementWindow.join(window.prefix, result.text)
                } else {
                    let open = String(window.prefix.dropFirst(locked))
                    let gap = String(open.reversed().prefix(while: \.isWhitespace).reversed())
                    lockedRuns.append(FinalPassRun(text: String(open.dropLast(gap.count)), pending: false))
                    lockedRuns.append(FinalPassRun(text: gap + next.chunk, pending: true))
                    settled = RefinementWindow.join(window.prefix, next.chunk)
                    locked = settled.count
                    outcome.keptCaptured = true
                    if result?.failure == .declined { outcome.declined = true }
                }
                onStream(preview(RefinementWindow.join(settled, next.remaining)))
                unprocessed = next.remaining
                if next.remaining.isEmpty { break }
                window = RefinementWindow(refinedBody: settled, unrefinedTail: next.remaining, lockedCount: locked)
            }
        }
        outcome.text = settled.trimmingCharacters(in: .whitespacesAndNewlines)
        outcome.runs = outcomeRuns([])
        return outcome
    }

    /// One stop-pass request, or nil when the deadline passed first.
    private func finalPassChunk(
        _ chunk: String,
        context: String,
        deadline: ContinuousClock.Instant?,
        clock: ContinuousClock
    ) async -> DictationFormatterService.RefinementResult? {
        guard let deadline else { return await finalPassModelCall(chunk, context: context) }
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return nil }
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        let result = await TranscriptionService.raceWithHardTimeout(seconds: seconds) { [weak self] in
            await self?.finalPassModelCall(chunk, context: context) ?? .original(chunk, failure: .cancelled)
        }
        if result == nil { dictationFormatter.cancelGeneration() }
        return result
    }

    private func finalPassModelCall(_ chunk: String, context: String) async -> DictationFormatterService.RefinementResult {
        if let finalPassRefine { return await finalPassRefine(chunk, context) }
        return await dictationFormatter.refine(chunk, forceRefine: true, priorContext: context,
                                               silentMode: true, finishing: true)
    }

    /// Keeps the text on Home instead of pasting, for a final pass that can't deliver, such as a
    /// translation with untranslated parts. With `parked`, Resume refines only unfinished parts.
    func preserveUnfinishedRefinement(_ text: String, parked: ParkedFinalPass? = nil) {
        isCleaningUp = false
        cleanupStreamingText = ""
        isOverlayVisible = false
        let savedAppName = targetAppName
        targetPID = nil
        targetAppName = "Unknown"
        targetFocusedElement = nil
        let kept = parked?.text ?? text
        pendingSessionText = kept
        pendingSessionPass = parked
        pendingSessionTimestamp = Date()
        accumulatedSessionNeedsRefinement = true
        historyStore.addEntry(text: kept, appName: savedAppName, entryType: .dictation)
        recordDictationFailure(.refinement("Refinement could not finish. Your text is kept below and in History. Resume to try again, or copy it as captured."))
        showToast("Refinement did not finish. Your text is kept on Home.", icon: "text.badge.checkmark")
    }

    /// Shared bail logic for the two cancel checkpoints in handleStopRecording.
    /// Clears refinement state, dismisses the overlay, and stashes the text into
    /// pendingSessionText when soft-cancel was requested. With `parked` from the stop pass, the
    /// pending text keeps the parts it finished, and Resume refines only the rest.
    func bailFromCleanupCancel(rawText: String, parked: ParkedFinalPass? = nil) {
        let shouldPreserve = preserveRawOnCleanupCancel
        cancelRequestedDuringStop = false
        preserveRawOnCleanupCancel = false
        isCleaningUp = false
        cleanupStreamingText = ""
        isOverlayVisible = false
        let cancelledAppName = targetAppName
        targetPID = nil
        targetAppName = "Unknown"
        targetFocusedElement = nil

        let parked = parked.flatMap { $0.runs.isEmpty ? nil : $0 }
        let trimmed = (parked?.text ?? rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        historyStore.addEntry(text: trimmed, appName: cancelledAppName, entryType: .cancelled)

        if shouldPreserve {
            withAnimation(.easeInOut(duration: 0.25)) {
                pendingSessionText = trimmed
                pendingSessionPass = parked
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
        resetRecordingStats()
        let historySaved = historyStore.flush()
        await transcriptionService.cancelRecording(preserveRecovery: !historySaved)
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
        resetRecordingStats()

        SoundEffectService.play(.recordingStop)

        let finalText = await transcriptionService.stopRecording()

        isOverlayVisible = false
        overlayMessage = ""

        var combinedText: String
        if let accumulated = accumulatedSessionText, !accumulated.isEmpty {
            combinedText = (accumulated + " " + finalText).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            combinedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Keep which parts are finished, so Resume refines only the rest. The runs hold the same
        // words as the captured text, so their text becomes the paused text.
        let pausedPass = Self.pausedPass(earlier: accumulatedSessionPass,
                                         accumulatedText: accumulatedSessionText ?? "",
                                         stagedRuns: transcriptionService.lastSessionFinalPassRuns,
                                         newText: finalText, outputLanguage: Self.currentOutputLanguage)
        if let pausedPass { combinedText = pausedPass.text }
        accumulatedSessionText = nil
        accumulatedSessionPass = nil

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
            pendingSessionPass = nil
            pendingSessionTimestamp = nil
        } else if !pendingTextToSave.isEmpty {
            withAnimation(.easeInOut(duration: 0.25)) {
                pendingSessionText = pendingTextToSave
                pendingSessionPass = pausedPass
                accumulatedSessionNeedsRefinement = true
                pendingSessionTimestamp = Date()
            }
        }

        targetPID = nil
        targetAppName = "Unknown"
            targetFocusedElement = nil
    }
}
