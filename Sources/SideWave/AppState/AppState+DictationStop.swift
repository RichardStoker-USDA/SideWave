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

    /// Called after a hold past the Refine threshold, or a push-to-talk release with "Always
    /// refine" (`holdGesture: false`). Sets one-time flags and runs the normal stop; the formatter
    /// skips its enabled check when they're set. The hold gets the full pass with thinking; a
    /// release refines at normal speed.
    func handleStopRefinedRecording(holdGesture: Bool = true) async {
        forceRefineThisCapture = dictationCleanupEnabled
        thoroughRefineThisCapture = dictationCleanupEnabled && holdGesture
        await handleStopRecording()
    }

    func handleStopRecording() async {
        guard !isProcessingStop else { return }
        defer {
            if pendingStartAfterStop {
                pendingStartAfterStop = false
                Task { @MainActor [weak self] in self?.handleStartRecording() }
            }
        }
        // Read the push-to-talk flag before cancelHoldTracking clears it. It decides between the
        // fast EOU paste and the TDT paste.
        let smartPttActiveAtStop = hotkeyManager.isSmartPTTActive

        // Clear cancel flags a previous stop may have left set. The early returns below skip the
        // places that normally clear them, and a stale value would make this stop exit with no
        // paste and a cancelled history entry. Both are set only later in this call.
        // handleStartRecording clears them too.
        cancelRequestedDuringStop = false
        preserveRawOnCleanupCancel = false
        appStateTraceLog.notice("AppState.handleStopRecording entry isSmartPTTActive=\(self.hotkeyManager.isSmartPTTActive, privacy: .public) transcriptionRecording=\(self.transcriptionService.isRecording, privacy: .public)")

        // Stop hold tracking now, in case the modifier-up event was lost.
        hotkeyManager.cancelHoldTracking()

        let signpostID = signposter.makeSignpostID()
        let signpostState = signposter.beginInterval("Stop Path", id: signpostID)
        defer { signposter.endInterval("Stop Path", signpostState) }

        // A stop while the start is still running: queue it so it runs once recording begins. Otherwise
        // the stop is lost while hotkeyManager.isRecording is already true, and recording can't be
        // stopped.
        //
        // Two cases:
        // - A quick toggle tap or push-to-talk release during a normal start: the user means stop.
        // - A press several seconds into a cold first-run warm-up: the user is checking whether it's
        //   working. A queued stop would end the session the moment it starts, so show a toast instead.
        //   Esc still cancels.
        if !transcriptionService.isRecording && isProcessingStart {
            let inFlight = startInFlightSince.map { Date().timeIntervalSince($0) } ?? 0
            if smartPttActiveAtStop || inFlight < 2.0 {
                pendingStopAfterStart = true
            } else {
                // Stop refused (session stays alive); expire the one-shot
                // refine-gesture flags so they can't leak a surprise forced
                // or thinking pass into a later, unrelated stop.
                forceRefineThisCapture = false
                thoroughRefineThisCapture = false
                showToast("Warming up the speech engine. Starting in a moment", icon: "hourglass")
            }
            return
        }

        // TranscriptionService stopped on its own (for example audio recovery failed). Still clean
        // up: restore volume, hide the overlay, reset the hotkey, and clear the start flags so the
        // next press works.
        guard transcriptionService.isRecording else {
            // Recording may have self-stopped (audio engine failure, health check).
            // Save any accumulated text to history so nothing is lost.
            let partialText =
                (transcriptionService.confirmedText + " " + transcriptionService.volatileText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !partialText.isEmpty {
                historyStore.addEntry(text: partialText, appName: targetAppName)
                if historyStore.flush() {
                    transcriptionService.acknowledgeSavedSession()
                    showToast("Recording ended early. Text saved to history.", icon: "exclamationmark.triangle")
                } else {
                    recordDictationFailure(.persistence("History could not be saved. Copy the recovered text before quitting."))
                }
            }
            restoreDictationVolumeControl()
            hotkeyManager.isRecording = false
            isOverlayVisible = false
            captureStart.cancel()
            pendingStopAfterStart = false
            // Session is fully over; one-shot refine-gesture flags die with it.
            forceRefineThisCapture = false
            thoroughRefineThisCapture = false
            return
        }

        isProcessingStop = true
        let previousHistoryID = historyStore.entries.first?.id
        defer {
            isProcessingStop = false
            if historyStore.entries.first?.id != previousHistoryID {
                if historyStore.flush() {
                    transcriptionService.acknowledgeSavedSession()
                } else {
                    recordDictationFailure(.persistence("History could not be saved. Copy the output before quitting; recovery text has been kept."))
                    showToast("History save failed. Copy your output before quitting", icon: "doc.on.clipboard")
                }
            }
        }
        // Take the one-time refine flags here, after the reentrancy check, so early returns can't
        // leave them set for the next stop. shouldForceRefine skips the enabled and strategy
        // checks; shouldThoroughRefine (hold only) adds the full pass with thinking.
        let shouldForceRefine = forceRefineThisCapture
        forceRefineThisCapture = false
        let shouldThoroughRefine = thoroughRefineThisCapture
        thoroughRefineThisCapture = false
        captureStart.cancel()
        hotkeyManager.isRecording = false
        SoundEffectService.play(.recordingStop)

        // Restore system volume after dictation ends
        restoreDictationVolumeControl()

        // Capture target before any async work -- stopRecording() can take time.
        // In "finish window" mode, capture the currently focused window now.
        let savedPID: pid_t?
        let savedAppName: String
        let savedFieldFP: TextFieldFingerprint?
        if targetPID == nil && pasteTargetTiming == "finish" {
            savedPID = TypingService.captureSystemFocusedPID()
            savedAppName = TypingService.appName(for: savedPID)
            if let pid = savedPID {
                savedFieldFP = WindowTargetingService.captureFocusedFieldFingerprint(pid: pid)
            } else {
                savedFieldFP = nil
            }
        } else {
            savedPID = targetPID
            savedAppName = targetAppName
            savedFieldFP = targetFieldFingerprint
        }

        // Prepend accumulated text from a "continue" session
        cleanupStatus = "Finishing speech recognition"
        let stopPathBegan = CFAbsoluteTimeGetCurrent()
        let rawFinalText = await transcriptionService.stopRecording(
            preferFastResult: smartPttActiveAtStop
        )
        appStateTraceLog.notice("stop drain done elapsed=\((CFAbsoluteTimeGetCurrent() - stopPathBegan) * 1000, format: .fixed(precision: 0), privacy: .public)ms")
        let assembledRaw: String
        // Prior "continue" segments are already delivery-quality text; the
        // incremental stop strategy treats them as part of the refined body so
        // they are never re-refined. Empty for a normal (non-continued) session.
        let continuedPrefix: String
        if let accumulated = accumulatedSessionText, !accumulated.isEmpty {
            assembledRaw = (accumulated + " " + rawFinalText).trimmingCharacters(in: .whitespacesAndNewlines)
            continuedPrefix = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            accumulatedSessionText = nil
        } else {
            assembledRaw = rawFinalText
            continuedPrefix = ""
        }
        // Clear pending session on successful stop-and-paste
        pendingSessionText = nil
        pendingSessionTimestamp = nil

        // 1. Silent/No-Speech check: if empty, cleanly cancel and exit early
        if assembledRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isOverlayVisible = false
            isCleaningUp = false
            cleanupStreamingText = ""
            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
            isCommandDictation = false
            return
        }

        // 2. Command redirection check: if this is a command dictation session, route to the input bar and return
        if isCommandDictation {
            isOverlayVisible = false
            isCleaningUp = false
            cleanupStreamingText = ""
            
            // Set the instruction to the spoken command
            agenticEditInstruction = assembledRaw
            
            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
            
            isCommandDictation = false
            
            // Automatically apply the dictated edit command
            Task {
                await applyAgenticEdit()
            }
            return
        }

        let stagedOriginal = transcriptionService.lastSessionOriginalText
        let stagedEouRaw = transcriptionService.lastSessionEouRawText
        let rawForHistory: String?
        if !stagedOriginal.isEmpty {
            rawForHistory = stagedOriginal
        } else if dictationCleanupEnabled {
            rawForHistory = assembledRaw
        } else {
            rawForHistory = nil
        }
        let eouForHistory: String? = stagedEouRaw.isEmpty ? nil : stagedEouRaw

        let strategy = UserDefaults.standard.string(forKey: "finalPassStrategy") ?? "incremental"
        // The optional rewrite gesture requests a full-session pass. Smart PTT
        // refinement still uses the selected strategy, incremental by default.
        let effectiveStrategy = shouldThoroughRefine ? "full" : (accumulatedSessionNeedsRefinement ? "incremental" : strategy)
        let skipRefine = UserDefaults.standard.bool(forKey: "skipRefine")
        let totalWords = assembledRaw.split(whereSeparator: \.isWhitespace).count
        let templateRaw = UserDefaults.standard.string(forKey: "dictationCleanupTemplate") ?? ""
        let template = DictationFormatterService.Template(rawValue: templateRaw) ?? .standard
        let allowsFinalRefine = template.isSpecialty || !bypassRefineOnShortSessions || totalWords >= dictationCleanupMinWords
        // Document formatting is part of the chosen output. Ordinary dictation
        // honors the optional final pass and short-session bypass.
        let performFinal = (template.isSpecialty || (UserDefaults.standard.object(forKey: "performFinalRefinePass") as? Bool ?? true))
            && dictationCleanupEnabled && !skipRefine
            && allowsFinalRefine

        let performRefinement = performFinal || (shouldForceRefine && allowsFinalRefine)

        // Keep text visible and label the work between capture and delivery.
        cleanupStatus = !performRefinement ? "Sending text"
            : effectiveStrategy == "full" ? "Rewriting full dictation"
            : effectiveStrategy == "smart" ? "Checking the ending" : "Finishing remaining text"
        isCleaningUp = true
        // splitSmartWindow(assembledRaw) is deterministic on the same input and
        // was being computed twice (preview here + refine dispatch below).
        // Compute once and reuse.
        let smartSplit: (String?, String)? = (performRefinement && effectiveStrategy == "smart")
            ? splitSmartWindow(assembledRaw) : nil
        // Keep the captured text visible while its ending is checked. Streaming
        // a replacement prefix made settled words disappear and grow back.
        cleanupStreamingText = assembledRaw

        let cleanedText: String
        var finalRefinementCompleted = true
        let isSpecialtyTargeted = template.isSpecialty || isSpecialtyActive
        if isSpecialtyTargeted {
            cleanedText = await formatCapturedDocument(assembledRaw, refine: performRefinement)
            if cancelSpecialtyFinishingIfRequested(rawText: assembledRaw) { return }

            // SPECIALTY FINISH: Save to history, play sound, and exit BEFORE pasting
            isOverlayVisible = false
            isCleaningUp = false
            cleanupStreamingText = ""
            
            if !cleanedText.isEmpty {
                SoundEffectService.play(.promptConfirmed)
                let backendForHistory = sessionRefineBackendForHistory
                historyStore.addEntry(
                    text: cleanedText,
                    appName: template.workspaceTitle,
                    entryType: .document,
                    rawText: rawForHistory,
                    eouText: eouForHistory,
                    refineBackend: backendForHistory,
                    outputLanguage: historyOutputLanguage(refined: backendForHistory != nil)
                )
            }
            
            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
            return
        } else {
            if performRefinement && effectiveStrategy == "full" {
                let result = await dictationFormatter.refine(
                    assembledRaw,
                    forceRefine: true,
                    // Thinking mode only for a hold; taps and push-to-talk releases stay fast.
                    thoroughPass: shouldThoroughRefine,
                    finishing: true,
                    onStream: { [weak self] accumulated in
                        Task { @MainActor [weak self] in
                            // Drop stale chunks that arrive after cancel has already
                            // reset state; without the guard, a late MLX straggler
                            // token batch can clobber the cleared streaming text.
                            guard let self, self.isCleaningUp else { return }
                            self.cleanupStreamingText = accumulated
                        }
                    }
                )
                cleanedText = result.text
                finalRefinementCompleted = result.completed
            } else if performRefinement && effectiveStrategy == "smart" {
                // SMART STRATEGY FOR NON-SPECIALTY TEMPLATE:
                let (priorContext, tailToRefine) = smartSplit ?? splitSmartWindow(assembledRaw)
                if !tailToRefine.isEmpty {
                    let result = await dictationFormatter.refine(
                        tailToRefine,
                        forceRefine: true,
                        priorContext: priorContext,
                        finishing: true,
                        onStream: { [weak self] accumulated in
                            Task { @MainActor [weak self] in
                                guard let self, self.isCleaningUp else { return }
                                if let prior = priorContext {
                                    self.cleanupStreamingText = prior + " " + accumulated
                                } else {
                                    self.cleanupStreamingText = accumulated
                                }
                            }
                        }
                    )
                    finalRefinementCompleted = result.completed
                    cleanedText = RefinementWindow.join(priorContext ?? "", result.text)
                } else {
                    cleanedText = assembledRaw
                }
            } else if performRefinement {
                let stagedRuns = transcriptionService.lastSessionFinalPassRuns
                let needsEntireText = accumulatedSessionNeedsRefinement || stagedRuns.isEmpty
                let runs = needsEntireText ? [StagedTranscript.FinalPassRun(text: assembledRaw, pending: true)] : stagedRuns
                let prefix = needsEntireText ? "" : continuedPrefix
                let result = await finishPendingRuns(runs, after: prefix) { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCleaningUp else { return }
                        self.cleanupStreamingText = text
                    }
                }
                cleanedText = result.text
                let language = DictationFormatterService.OutputLanguage.from(
                    code: UserDefaults.standard.string(forKey: "dictationOutputLanguage"))
                let translationStillPending = !language.isMatch
                    && transcriptionService.translateRefineKeptSourceLanguage
                    && TranscriptionService.translateLikelyFailed(output: result.text,
                        input: runs.map(\.text).reduce(prefix, RefinementWindow.join), target: language)
                finalRefinementCompleted = result.completed && !translationStillPending
            } else {
                // No force-refine, refine disabled/skipped, or session too
                // short. The staged transcript already holds the real-time-
                // refined text; paste it as-is.
                cleanedText = assembledRaw
            }
        }

        // Cancelled while refining: skip the paste. Escape or the Stop button keeps the raw
        // dictation as a pending session; Control-Escape discards it.
        if cancelRequestedDuringStop {
            bailFromCleanupCancel(rawText: assembledRaw)
            return
        }

        guard finalRefinementCompleted else {
            preserveUnfinishedRefinement(assembledRaw)
            return
        }
        accumulatedSessionNeedsRefinement = false

        // Briefly show the final text before the overlay closes, when the final pass changed it.
        if cleanedText != assembledRaw && cleanupStreamingText != cleanedText {
            // Only when the final text differs from what streamed; otherwise the pause only delays
            // the paste.
            cleanupStreamingText = cleanedText
            try? await Task.sleep(nanoseconds: 60_000_000) // 0.06s
        }
        // Re-check cancel flag after the flash so cancel during this window
        // also bails out cleanly.
        if cancelRequestedDuringStop {
            bailFromCleanupCancel(rawText: assembledRaw)
            return
        }
        isCleaningUp = false
        cleanupStreamingText = ""
        // Neither flag should be set here; clear them anyway.
        cancelRequestedDuringStop = false
        preserveRawOnCleanupCancel = false

        appStateTraceLog.notice("stop refine done totalMs=\((CFAbsoluteTimeGetCurrent() - stopPathBegan) * 1000, format: .fixed(precision: 0), privacy: .public)")

        // Correct standalone pronoun capitalization before delivery.
        let finalText = StagedTranscript.fixStandalonePronounI(cleanedText)
        // Save the raw dictation whenever Refine was attempted, even if it fell back to raw text
        // (timeout, ratio check, context overflow, cancel), so the user can compare. History shows
        // "Show original" only when the texts differ. With real-time refine,
        // TranscriptionService.lastSessionOriginalText (unrefined spans plus the live tail) is the
        // better original; fall back to assembledRaw.

        guard !finalText.isEmpty else {
            isOverlayVisible = false
            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
            return
        }

        // Optionally copy to clipboard
        if copyToClipboard {
            TypingService.writeSensitiveString(finalText, to: .general)
        }

        // A closed target must not redirect dictation into an unrelated app.
        let activePID = savedPID
        if let pid = savedPID, !TypingService.isAppStillAlive(pid: pid) {
            let backendForHistory = sessionRefineBackendForHistory
            historyStore.addEntry(text: finalText, appName: savedAppName, rawText: rawForHistory, eouText: eouForHistory, refineBackend: backendForHistory, outputLanguage: historyOutputLanguage(refined: backendForHistory != nil))
            recordDictationFailure(.delivery("Target app closed. Text saved to history."))
            showToast("Target app closed. Text saved to history", icon: "doc.text")
            isOverlayVisible = false
            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
            return
        }

        // Use the assigned window only in assigned mode and only when the paste target is the
        // assigned app. Otherwise a stale window ID could raise the wrong window and paste there.
        let sessionWindowID: CGWindowID? = (DictationTargetMode(rawValue: dictationTargetMode) == .assignedWindow
            && activePID == assignedAppPID) ? assignedWindowID : nil

        // Without a resolved target, a paste while SideWave is frontmost would type into SideWave's
        // own window. Save the text and warn instead.
        if activePID == nil,
           let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier == Bundle.main.bundleIdentifier {
            SoundEffectService.play(.error)
            recordDictationFailure(.delivery("Choose a text field before dictating. This output is saved to history."))
            showToast("No target window. Text saved to history", icon: "exclamationmark.triangle")
            let backendForHistory = sessionRefineBackendForHistory
            historyStore.addEntry(text: finalText, appName: savedAppName, rawText: rawForHistory, eouText: eouForHistory, refineBackend: backendForHistory, outputLanguage: historyOutputLanguage(refined: backendForHistory != nil))
            isOverlayVisible = false
            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
            return
        }

        // Relay mode with an explicit target tries app-specific injection first: AppleScript writes
        // to Terminal or iTerm2 directly, including the newline, so no activation or timing is
        // needed. Relay auto-submit runs only when the user assigned a target and the paste target
        // is still that app. If the assigned app quit, the paste goes to whatever is focused, and
        // auto-submitting there could run the text as a command or send a half-written message, so
        // it becomes a plain paste.
        let hasExplicitTarget = DictationTargetMode(rawValue: dictationTargetMode) == .assignedWindow
            && assignedAppPID != nil
            && activePID == assignedAppPID
        if relayModeEnabled, hasExplicitTarget, await typingService.injectAndSubmit(finalText, targetPID: activePID, windowTitle: assignedWindowTitle) {
            // Injection delivered the text. Still record the entry and clear the target state, as
            // every other delivery path does.
            let actualAppName = (activePID != savedPID) ? TypingService.appName(for: activePID) : savedAppName
            let backendForHistory = sessionRefineBackendForHistory
            historyStore.addEntry(text: finalText, appName: actualAppName, rawText: rawForHistory, eouText: eouForHistory, refineBackend: backendForHistory, outputLanguage: historyOutputLanguage(refined: backendForHistory != nil))
            isOverlayVisible = false
            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
        } else {
            // Standard path: activate target window, hide overlay, then paste.
            // Activation must happen BEFORE hiding overlay so macOS doesn't
            // refocus an unrelated window when the overlay disappears.
            if let wid = sessionWindowID, let pid = activePID {
                // raiseWindow reports whether it worked; if not, activate the app so the check
                // below can still succeed.
                if !WindowTargetingService.raiseWindow(windowID: wid, pid: pid) {
                    TypingService.activateApp(pid: pid)
                }
            } else if let pid = activePID {
                TypingService.activateApp(pid: pid)
            }

            // Wait for the target app to become frontmost, up to 500 ms in 50 ms steps. Electron
            // apps can take longer than 150 ms, and a Command-V sent too early is dropped.
            if let pid = activePID {
                var focusConfirmed = false
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    if let front = NSWorkspace.shared.frontmostApplication,
                       front.processIdentifier == pid {
                        focusConfirmed = true
                        break
                    }
                }
                if !focusConfirmed {
                    // One last attempt to force focus. When a specific window is
                    // in play, re-raise it; activate alone won't reorder windows
                    // within an already-frontmost app.
                    if let wid = sessionWindowID {
                        _ = WindowTargetingService.raiseWindow(windowID: wid, pid: pid)
                    } else {
                        TypingService.activateApp(pid: pid)
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            } else {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }

            // Focus the field the user was in:
            // 1. The saved element; if AX focus fails (common for web content), click its center.
            // 2. The fingerprint.
            // 3. ensureTextFieldFocused, which focuses the largest text input in the window, for a window that
            //    was hovered but never clicked.
            // 4. The app's own focus restoration.
            if let pid = activePID {
                try? await Task.sleep(nanoseconds: 100_000_000)
                var focused = false
                
                DictationTracingService.shared.log(.pasteCascade, .info, "Paste Cascade started for PID \(pid), Target Window ID: \(sessionWindowID?.description ?? "none")")

                if let savedElement = targetFocusedElement {
                    // Only refocus the saved element if it belongs to the paste target, or its
                    // click fallback would hit whatever window is there now.
                    let elementPID = Self.elementPID(savedElement)
                    if elementPID == pid {
                        let startLayer1 = Date()
                        focused = WindowTargetingService.refocusElement(savedElement)
                        let duration = Date().timeIntervalSince(startLayer1) * 1000.0
                        if focused {
                            DictationTracingService.shared.log(.pasteCascade, .info, "Layer 1: Direct AXUIElement refocusing succeeded.", durationMs: duration)
                            try? await Task.sleep(nanoseconds: 80_000_000)
                        } else {
                            DictationTracingService.shared.log(.pasteCascade, .warning, "Layer 1: Direct AXUIElement refocusing failed.", durationMs: duration)
                        }
                    } else {
                        DictationTracingService.shared.log(.pasteCascade, .warning, "Layer 1: Saved focus element belongs to PID \(elementPID), not target \(pid); skipping direct refocus.")
                    }
                }

                if !focused, let fp = savedFieldFP {
                    let startLayer2 = Date()
                    focused = WindowTargetingService.focusFieldByFingerprint(
                        fp, pid: pid, windowID: sessionWindowID
                    )
                    let duration = Date().timeIntervalSince(startLayer2) * 1000.0
                    if focused {
                        DictationTracingService.shared.log(.pasteCascade, .info, "Layer 2: Fingerprint autofind matching succeeded.", durationMs: duration)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    } else {
                        DictationTracingService.shared.log(.pasteCascade, .warning, "Layer 2: Fingerprint autofind matching failed.", durationMs: duration)
                    }
                }

                if !focused {
                    let startLayer3 = Date()
                    // Last resort when the element and fingerprint are stale: focus the largest
                    // text input in the target window.
                    focused = WindowTargetingService.ensureTextFieldFocused(
                        pid: pid, windowID: sessionWindowID
                    )
                    let duration = Date().timeIntervalSince(startLayer3) * 1000.0
                    if focused {
                        DictationTracingService.shared.log(.pasteCascade, .info, "Layer 3: Primary Window text field search fallback succeeded.", durationMs: duration)
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    } else {
                        DictationTracingService.shared.log(.pasteCascade, .error, "Layer 3: Primary Window text field search fallback failed. Refusing active focusing.", durationMs: duration)
                        DictationTracingService.shared.log(.pasteCascade, .warning, "Layer 4: Falling back to OS-default window active typing (no target refocusing).")
                        SWLog.note("[AppState] Paste focus could not be confirmed for pid \(pid); proceeding anyway and the paste may not land in the intended field")
                    }
                }
            }

            isOverlayVisible = false

            // Post a mouse-moved event at the cursor before pasting. With the cursor resting over a
            // window, the window server can keep stale focus tracking and drop the paste until the
            // mouse moves. The cursor doesn't move. Then wait 30 ms.
            nudgeMouseTrackingForPaste()
            try? await Task.sleep(nanoseconds: 30_000_000)

            let finalActivePID = activePID
            // Play the sound when the paste is sent, not after verification, which can take 400 ms
            // on apps whose text can't be read back. A real failure still plays the error sound
            // with a toast.
            SoundEffectService.play(.promptConfirmed)
            let outcome: PasteOutcome = await withCheckedContinuation { continuation in
                typingService.typeTextInstantly(
                    finalText,
                    preferredTargetPID: finalActivePID,
                    appendTrailingSpace: appendTrailingSpace
                ) { continuation.resume(returning: $0) }
            }
            didFinishDictation = outcome.landed
            if outcome.landed {
                let actualAppName = (finalActivePID != savedPID) ? TypingService.appName(for: finalActivePID) : savedAppName
                let backendForHistory = sessionRefineBackendForHistory
                historyStore.addEntry(text: finalText, appName: actualAppName, rawText: rawForHistory, eouText: eouForHistory, refineBackend: backendForHistory, outputLanguage: historyOutputLanguage(refined: backendForHistory != nil))

                // Auto-submit waits for delivery. When the paste is unconfirmed (a slow Electron
                // composer), an early Return would send an empty message, so wait the grace period
                // (`autoSubmitDeliveryGraceMs`); when confirmed, 50 ms is enough.
                let submitGraceNs: UInt64
                if outcome == .verified {
                    submitGraceNs = 50_000_000
                } else {
                    let g = UserDefaults.standard.integer(forKey: "autoSubmitDeliveryGraceMs")
                    submitGraceNs = UInt64(g > 0 ? g : 400) * 1_000_000
                }

                // Send Enter/Shift+Enter if needed
                if relayModeEnabled && hasExplicitTarget {
                    if let pid = finalActivePID {
                        TypingService.activateApp(pid: pid)
                    }
                    try? await Task.sleep(nanoseconds: submitGraceNs)
                    typingService.sendReturnKey(targetPID: finalActivePID)
                } else if smartPttActiveAtStop && smartPTTAutoSubmit {
                    if let pid = finalActivePID {
                        TypingService.activateApp(pid: pid)
                    }
                    try? await Task.sleep(nanoseconds: submitGraceNs)
                    let useShift = (smartPTTAutoSubmitKey == "shift-return")
                    typingService.sendReturnKey(targetPID: finalActivePID, withShift: useShift)
                }
            } else {
                SoundEffectService.play(.error)
                let failText = (outcome == .blockedSecureInput)
                    ? "Paste blocked: another app is holding secure keyboard input. Text saved to history"
                    : "Paste failed. Text saved to history"
                recordDictationFailure(.delivery(failText))
                showToast(failText, icon: "exclamationmark.triangle")

                let actualAppName = (finalActivePID != savedPID) ? TypingService.appName(for: finalActivePID) : savedAppName
                let backendForHistory = sessionRefineBackendForHistory
                historyStore.addEntry(text: finalText, appName: actualAppName, rawText: rawForHistory, eouText: eouForHistory, refineBackend: backendForHistory, outputLanguage: historyOutputLanguage(refined: backendForHistory != nil))
            }

            targetPID = nil
            targetAppName = "Unknown"
            targetFocusedElement = nil
        }
    }

    /// Posts a mouse-moved event at the cursor position, which makes the window server update focus
    /// tracking without moving the cursor.
    private func nudgeMouseTrackingForPaste() {
        let nsLocation = NSEvent.mouseLocation
        // NSEvent.mouseLocation uses bottom-left origin; CGEvent uses
        // top-left. Convert by subtracting from the primary screen height.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: nsLocation.x, y: primaryHeight - nsLocation.y)
        if let nudge = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: cgPoint,
            mouseButton: .left
        ) {
            nudge.post(tap: .cghidEventTap)
        }
    }

    /// Process ID that owns an element, to check a saved element belongs to the paste target before
    /// refocusing or clicking it.
    static func elementPID(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    internal func splitSmartWindow(_ text: String) -> (priorContext: String?, tailToRefine: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "") }
        
        let terminators: Set<Character> = [".", "!", "?"]
        var boundaryIndices: [String.Index] = []
        
        var i = trimmed.index(before: trimmed.endIndex)
        while i > trimmed.startIndex {
            let c = trimmed[i]
            if c.isWhitespace {
                var j = trimmed.index(before: i)
                while j > trimmed.startIndex && trimmed[j].isWhitespace {
                    j = trimmed.index(before: j)
                }
                if j >= trimmed.startIndex && !trimmed[j].isWhitespace {
                    var k = j
                    while k > trimmed.startIndex && (trimmed[k] == "\"" || trimmed[k] == "'" || trimmed[k] == ")" || trimmed[k] == "]") {
                        k = trimmed.index(before: k)
                    }
                    if terminators.contains(trimmed[k]) {
                        boundaryIndices.append(i)
                        if boundaryIndices.count >= 2 {
                            break
                        }
                    }
                }
            }
            i = trimmed.index(before: i)
        }
        
        if !boundaryIndices.isEmpty {
            let lastBoundary = boundaryIndices[0]
            let tail = String(trimmed[lastBoundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tailWords = tail.split(whereSeparator: \.isWhitespace).count
            
            if tailWords >= 3 {
                let prior = String(trimmed[..<lastBoundary]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (prior.isEmpty ? nil : prior, tail)
            } else if boundaryIndices.count > 1 {
                let secondBoundary = boundaryIndices[1]
                let prior = String(trimmed[..<secondBoundary]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tailCombined = String(trimmed[secondBoundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (prior.isEmpty ? nil : prior, tailCombined)
            }
        }
        
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count > 30 {
            let priorCount = words.count - 30
            let prior = words.prefix(priorCount).joined(separator: " ")
            let tail = words.suffix(30).joined(separator: " ")
            return (prior, tail)
        } else {
            return (nil, trimmed)
        }
    }
}
