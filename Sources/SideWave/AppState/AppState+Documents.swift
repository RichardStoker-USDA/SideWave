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
    // MARK: - Agentic Specialty Editing

    func saveSpecialtyDraft() {
        guard !isSwitchingSpecialtyTemplate,
              DictationFormatterService.Template(rawValue: dictationCleanupTemplate)?.isSpecialty == true else { return }
        guard !isProcessingAgenticEdit else { return }
        documentDrafts.save(specialtyEditedText, for: dictationCleanupTemplate,
                            additions: specialtyQueuedSegments.map(\.text), instruction: agenticEditInstruction)
    }

    /// Simple output selection also owns routing. Turning Refine off leaves a document safely saved.
    var selectedDictationTemplate: DictationFormatterService.Template {
        DictationFormatterService.Template(rawValue: dictationCleanupTemplate) ?? .standard
    }

    func selectDictationOutput(_ template: DictationFormatterService.Template?, openDocument: Bool = true) {
        guard !isDictationBusy, !isProcessingAgenticEdit, pendingSessionText == nil else { return }
        if let template {
            dictationCleanupTemplate = template.rawValue
            if !template.isSpecialty {
                isSpecialtyActive = false
                nextDictationTarget = .auto
            }
            UserDefaults.standard.set(false, forKey: "skipRefine")
            UserDefaults.standard.removeObject(forKey: "skipRefineAutoForced")
            // Selecting a template must do work even after a no-refine engine preset.
            if !UserDefaults.standard.bool(forKey: "useRealTimeRefine") {
                UserDefaults.standard.set(true, forKey: "performFinalRefinePass")
            }
            if !dictationCleanupEnabled { dictationCleanupEnabled = true }
            else { dictationFormatter.enable() }
            if template.isSpecialty && openDocument { openSpecialtyEditor() }
        } else {
            if DictationFormatterService.Template(rawValue: dictationCleanupTemplate)?.isSpecialty == true {
                dictationCleanupTemplate = DictationFormatterService.Template.standard.rawValue
                isSpecialtyActive = false
                nextDictationTarget = .auto
            }
            UserDefaults.standard.set(true, forKey: "skipRefine")
        }
    }

    func appendSpecialtyAddition(id: UUID) {
        guard !isDictationBusy, !isProcessingAgenticEdit,
              let item = specialtyQueuedSegments.first(where: { $0.id == id }) else { return }
        specialtyEditedText += (specialtyEditedText.isEmpty ? "" : "\n\n") + item.text
        specialtyQueuedSegments.removeAll { $0.id == id }
    }

    @discardableResult
    func newSpecialtyDocument() -> Bool {
        guard !isDictationBusy, !isProcessingAgenticEdit, pendingSessionText == nil, selectedDictationTemplate.isSpecialty else { return false }
        saveSpecialtyDraft()
        guard documentDrafts.startNewDocument(for: dictationCleanupTemplate) else { return false }
        loadCurrentSpecialtyDraft()
        return true
    }

    func restoreSpecialtyDocument(id: UUID) {
        guard !isDictationBusy, !isProcessingAgenticEdit, pendingSessionText == nil else { return }
        saveSpecialtyDraft()
        guard let saved = documentDrafts.recentDocuments.first(where: { $0.id == id }),
              DictationFormatterService.Template(rawValue: saved.template)?.isSpecialty == true else { return }
        // Switch first so the old template's save cannot overwrite the restored page.
        dictationCleanupTemplate = saved.template
        guard documentDrafts.restoreDocument(id: id) != nil else { return }
        loadCurrentSpecialtyDraft()
    }

    private func loadCurrentSpecialtyDraft() {
        isSwitchingSpecialtyTemplate = true
        let draft = documentDrafts.draft(for: dictationCleanupTemplate)
        specialtyEditedText = draft.text
        specialtyFormattedText = draft.text
        specialtyIsEdited = !draft.text.isEmpty
        specialtyQueuedSegments = draft.additions.map { SpecialtyQueuedSegment(text: $0) }
        agenticEditInstruction = draft.instruction
        documentEditNotice = nil
        isSwitchingSpecialtyTemplate = false
        documentRevision &+= 1
    }

    /// Runs after permission/model preflight and before acquiring the microphone.
    @discardableResult
    func prepareDocumentCapture(target: NextDictationTarget, resuming: Bool) -> Bool {
        guard target != .askBar || pendingSessionText == nil else {
            documentEditNotice = "Resume or discard the paused dictation before speaking an edit instruction."
            return false
        }
        isCommandDictation = selectedDictationTemplate.isSpecialty && target == .askBar
        guard selectedDictationTemplate.isSpecialty else { return true }
        if isCommandDictation {
            agenticEditInstruction = ""
        } else {
            if target == .auto && !resuming && !newSpecialtyDocument() { return false }
            agenticEditGeneration &+= 1
            didAutoOpenSpecialtyEditor = false
        }
        return true
    }

    /// Format once from the complete capture, including the final streaming tail.
    /// Save raw text before inference so cancellation, model failure, or quit keeps it recoverable.
    func formatCapturedDocument(_ text: String, refine: Bool) async -> String {
        let captured = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { return "" }
        let original = specialtyEditedText
        let addition = SpecialtyQueuedSegment(text: captured)
        if original.isEmpty {
            specialtyEditedText = captured
        } else {
            specialtyQueuedSegments.append(addition)
        }
        documentDrafts.flush()

        if !original.isEmpty && !autoAppendSpecialtyAdditions {
            documentEditNotice = "Dictation saved in pending additions. Open Activity to review and add it."
            return captured
        }

        var result = captured
        if refine {
            if original.isEmpty {
                result = await dictationFormatter.formatOrReturnRaw(captured, forceRefine: true,
                    forceSpecialty: true, thoroughPass: true)
            } else {
                result = await dictationFormatter.editDocumentWithInstruction(original,
                    instruction: "Integrate this dictated addition into the document. Keep all existing facts and the document's structure.\n\n<dictated_addition>\n\(captured)\n</dictated_addition>",
                    template: selectedDictationTemplate)
            }
        } else if !original.isEmpty {
            result = original + "\n\n" + captured
        }
        guard !cancelRequestedDuringStop else { return captured }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || (!original.isEmpty && trimmed == original.trimmingCharacters(in: .whitespacesAndNewlines)) {
            documentEditNotice = original.isEmpty
                ? "Formatting returned no document. Your captured words are kept on the page."
                : "No document changes were returned. Your dictated addition is kept in Activity."
            return captured
        }
        let expected = original.isEmpty ? captured : original
        guard specialtyEditedText == expected else {
            if original.isEmpty { specialtyQueuedSegments.append(addition) }
            documentEditNotice = "Your direct edits are kept. The captured dictation is available in Activity."
            return captured
        }
        specialtyEditedText = trimmed
        specialtyFormattedText = trimmed
        specialtyQueuedSegments.removeAll { $0.id == addition.id }
        documentDrafts.flush()
        return trimmed
    }

    /// Whether the Refine backend can run a document edit now, so a failed edit says so instead of
    /// returning the unchanged document.
    private func isAgenticEditModelReady() -> Bool {
        switch dictationFormatter.activeBackend {
        case .appleIntelligence, .appleIntelligenceLegacy:
            if case .available = DictationFormatterService.currentAFMAvailability() {
                return dictationFormatter.state == .ready
            }
            return false
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            // The MLX container only exists while Refine is enabled/loaded.
            return dictationFormatter.state == .ready
        }
    }

    func applyAgenticEdit() async {
        let instruction = agenticEditInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !specialtyEditedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isDictationBusy, pendingSessionText == nil else { return }
        // Serialize edits: a dictated command auto-applied from the stop path
        // must not interleave its token stream with a typed edit already running.
        guard !isProcessingAgenticEdit else { return }

        agenticEditGeneration &+= 1
        let gen = agenticEditGeneration

        let originalText = specialtyEditedText
        agenticEditOriginalText = originalText

        // Preflight: bail with a clear message rather than silently returning the
        // untouched document when the model can't run the edit.
        guard isAgenticEditModelReady() else {
            let msg: String
            switch dictationFormatter.activeBackend {
            case .appleIntelligence, .appleIntelligenceLegacy:
                msg = "Edit unavailable. Apple Intelligence is off or not ready"
            case .gemma4E2B, .gemma4E4B, .gemma4_12B:
                msg = "Edit unavailable. Enable Refine to load the AI editor"
            }
            documentEditNotice = msg + ". Your document and instruction are kept."
            return
        }

        documentEditNotice = nil
        documentDrafts.flush()
        isProcessingAgenticEdit = true

        // Keep the original visible and its undo stack intact until the complete edit is ready.
        let formatter = dictationFormatter
        agenticEditTask = Task { [self] in
            let result = await formatter.editDocumentWithInstruction(
                originalText,
                instruction: instruction,
                template: DictationFormatterService.Template(rawValue: dictationCleanupTemplate) ?? .custom
            ) { [weak self] partialText in
                guard let self else { return }
                Task { @MainActor in
                    guard gen == self.agenticEditGeneration else { return }
                    self.isProgrammaticWrite = true
                    self.specialtyEditedText = partialText
                    self.isProgrammaticWrite = false
                }
            }

            Task { @MainActor in
                guard gen == self.agenticEditGeneration else { return }
                self.agenticEditGeneration &+= 1
                self.agenticEditTask = nil
                let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedOriginal = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.isProgrammaticWrite = true
                if trimmedResult.isEmpty {
                    // Model produced nothing usable. Restore and say so.
                    self.specialtyEditedText = originalText
                    self.documentEditNotice = "The model returned no usable edit. Your document and instruction are kept."
                } else if trimmedResult == trimmedOriginal {
                    // editDocumentWithInstruction returns the original unchanged
                    // on a model failure or a genuine no-op. The document is
                    // intact either way; tell the user nothing changed.
                    self.specialtyEditedText = originalText
                    self.documentEditNotice = self.documentEditNotice ?? "No changes were applied. Your document and instruction are kept; you can revise the request or try again."
                } else {
                    self.specialtyEditedText = result
                    self.specialtyFormattedText = result
                    self.agenticEditInstruction = ""
                }
                self.isProgrammaticWrite = false
                self.isProcessingAgenticEdit = false
            }
        }
    }

    func cancelAgenticEdit() {
        // Invalidate any running edit before restoring, so a late write can't land afterward.
        agenticEditGeneration &+= 1
        agenticEditTask?.cancel()
        agenticEditTask = nil
        if isProcessingAgenticEdit {
            isProgrammaticWrite = true
            specialtyEditedText = agenticEditOriginalText
            isProgrammaticWrite = false
            documentEditNotice = "Edit stopped. Your previous document and instruction are kept."
        }
        isProcessingAgenticEdit = false
    }

    func clearSpecialtyDocument() {
        cancelAgenticEdit()
        // Bump again so cancelAgenticEdit's restore can't be the last write and
        // any straggler edit stays invalidated against the now-empty document.
        agenticEditGeneration &+= 1
        isProgrammaticWrite = true
        specialtyFormattedText = ""
        specialtyEditedText = ""
        specialtyIsEdited = false
        specialtyQueuedSegments = []
        agenticEditInstruction = ""
        isProgrammaticWrite = false
        agenticEditOriginalText = ""
        documentEditNotice = nil
        // Insights describe a document that no longer exists — drop them too.
        transcriptionService.specialtyLiveStatus = nil
    }

    /// Open the specialty editor window reliably. Prefers the captured
    /// OpenWindowAction; falls back to the observed boolean for the first frames
    /// before the dashboard installs the action.
    func openSpecialtyEditor() {
        guard DictationFormatterService.Template(rawValue: dictationCleanupTemplate)?.isSpecialty == true else { return }
        if let action = openSpecialtyWindowAction {
            action()
            showSpecialtyPreview = false
        } else {
            showSpecialtyPreview = true
        }
    }
}
