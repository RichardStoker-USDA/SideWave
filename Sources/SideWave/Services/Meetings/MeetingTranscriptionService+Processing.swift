// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
@preconcurrency import AVFAudio
import FluidAudio
import Foundation

@MainActor
extension MeetingTranscriptionService {
    // MARK: - Processing

    func processRecording() {
        guard !isCaptureActive, processingTask == nil else { return }
        guard let session else {
            state = .error("No audio file found")
            return
        }
        let liveActive = liveWasActive
        processingEpoch &+= 1
        let epoch = processingEpoch
        state = .processing(stage: .preparingModels)
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.processingEpoch == epoch { self.processingTask = nil } }
            do {
                try await self.runProcessing(session: session, liveActive: liveActive)
            } catch {
                if !Task.isCancelled {
                    self.state = .error(error.localizedDescription)
                    SWLog.note("[MeetingTranscription] Processing failed: \(error)")
                }
            }
        }
    }

    /// Process an orphaned meeting (batch) without resuming recording.
    func processOrphan(orphan: OrphanedMeeting) {
        // Never clobber a live recording/processing session: the recovery sheet
        // runs at launch (idle), but a stray call mid-flight must not swap out
        // `session` under the running pipeline.
        guard case .idle = state, processingTask == nil else { return }
        let reopened: MeetingSession
        do {
            reopened = try MeetingSessionStore.openSession(orphan)
        } catch {
            state = .error(error.localizedDescription)
            return
        }
        reopened.setStatus(.processing)
        session = reopened
        audioFileURL = reopened.partURLs().first
        liveWasActive = false
        // Names re-derive at commit; don't inherit the previous meeting's renames.
        speakerNames = [:]
        recordingDuration = orphan.recordedDuration
        processingEpoch &+= 1
        let epoch = processingEpoch
        state = .processing(stage: .preparingModels)
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.processingEpoch == epoch { self.processingTask = nil } }
            do {
                try await self.runProcessing(session: reopened, liveActive: false)
            } catch {
                if !Task.isCancelled {
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Discard an orphaned meeting directory.
    func discardOrphan(orphan: OrphanedMeeting) {
        MeetingSessionStore.discard(orphan)
    }

    private func runProcessing(session: MeetingSession, liveActive: Bool) async throws {
        // The recording is authoritative. The final model pass includes every
        // disk-backed part and uses the more accurate speaker preset.
        if liveActive { _ = await engine.finishLive() }

        session.setStatus(.processing)
        try await ensureModelsReady()
        guard !Task.isCancelled else { return }

        state = .processing(stage: .diarizing(method: ""))
        processingProgress = 0
        let epoch = processingEpoch
        do {
            let result = try await engine.batchProcess(partURLs: session.partURLs()) { [weak self] stage, fraction in
                guard let self else { return }
                Task { @MainActor in
                    guard self.processingEpoch == epoch, case .processing = self.state else { return }
                    if self.state != .processing(stage: stage) { self.state = .processing(stage: stage) }
                    self.processingProgress = fraction
                }
            }
            guard !Task.isCancelled else { return }
            try commit(result, session: session)
        } catch {
            guard !Task.isCancelled else { return }
            // Batch processing failed (transcription error or unreadable audio). Recover the
            // transcript from the live segment journal if there is one, as the recovery sheet
            // promises.
            if commitFromJournal(session: session) { return }
            throw error
        }
    }

    /// Builds a transcript from the live segment journal when batch processing failed. The text is
    /// raw live transcription. Returns true when something was recovered; duration comes from the
    /// parts on disk.
    private func commitFromJournal(session: MeetingSession) -> Bool {
        let segments = session.readLiveSegments()
        guard !segments.isEmpty else { return false }
        let uniqueSpeakers = Array(Set(segments.map(\.speakerId))).sorted()
        var names: [String: String] = [:]
        for (index, speaker) in uniqueSpeakers.enumerated() { names[speaker] = "Speaker \(index + 1)" }
        let duration = session.partURLs().reduce(0.0) { $0 + MeetingSessionStore.cafDuration($1) }
        var t = MeetingTranscript(
            id: session.id, segments: segments, speakerNames: names,
            duration: duration > 0 ? duration : recordingDuration, timestamp: session.startedAt, isPartial: true)
        preserveGeneratedNotes(in: &t)
        transcript = t
        speakerCount = uniqueSpeakers.count
        // No batch words/timings; a later rediarize will full-reprocess the CAFs.
        cachedWords = []
        cachedTokenTimings = []
        cachedDuration = t.duration
        liveSegments = []
        processingProgress = nil
        let saved = MeetingHistoryStore.shared.replaceMeeting(t)
        session.setStatus(.stopped)
        postRecordingWarning = saved
            ? "A partial transcript was recovered. The recording is kept on disk. Use Process Saved Audio to try again, or recover it at the next launch."
            : "A partial transcript was recovered but could not be saved to history. Copy it now. The recording is kept for recovery at the next launch."
        session.closeJournal()
        state = .complete
        SWLog.note("[MeetingTranscription] Recovered \(segments.count) segments from live journal after batch failure")
        return true
    }

    private func ensureModelsReady() async throws {
        if meetingModelsState.isReady { return }
        state = .processing(stage: .preparingModels)
        processingProgress = nil
        let engine = self.engine
        // Show model status during processing, sharing any preparation already running. Batch
        // processing needs only speaker detection and transcription, never the live model download.
        try await engine.prepare(includeLive: false, progress: makePrepHandler())
        meetingModelsState = .ready
        modelPrepDetail = nil
        modelPrepIndeterminate = false
    }

    /// Build the final transcript from a batch/live result, persist it, and mark
    /// the session terminal (kept on disk so rediarize still works this session).
    func commit(_ result: MeetingBatchResult, session: MeetingSession) throws {
        guard !Task.isCancelled else { return }
        let finalSegments = finalizeSegments(result.rawSegments)
        let uniqueSpeakers = Array(Set(finalSegments.map(\.speakerId))).sorted()
        var names = speakerNames
        for (index, speaker) in uniqueSpeakers.enumerated() where names[speaker] == nil {
            names[speaker] = "Speaker \(index + 1)"
        }
        var t = MeetingTranscript(
            id: session.id, segments: finalSegments,
            speakerNames: names,
            duration: result.duration > 0 ? result.duration : recordingDuration,
            timestamp: session.startedAt)
        if !t.hasSpeech,
           let previous = MeetingHistoryStore.shared.meetings.first(where: { $0.id == t.id }),
           previous.hasSpeech {
            retainAfterEmptyRecognition(previous, session: session)
            return
        }
        preserveGeneratedNotes(in: &t)

        transcript = t
        speakerCount = result.speakerCount
        cachedWords = result.words
        cachedTokenTimings = result.tokenTimings
        cachedDuration = t.duration
        liveSegments = []
        processingProgress = nil

        let saved = MeetingHistoryStore.shared.replaceMeeting(t)
        if saved && t.hasSpeech {
            // Transcript is durable; keep the directory so rediarize can reuse
            // the audio, and mark it completed so the next launch reaps it (not
            // treated as an orphan). reset()/dismiss deletes it earlier.
            session.setStatus(.completed)
            postRecordingWarning = nil
        } else {
            // Empty recognition and failed persistence both leave the audio recoverable.
            session.setStatus(.stopped)
            postRecordingWarning = !t.hasSpeech
                ? "No speech was recognized. The recording is kept for another processing attempt, including after you close SideWave."
                : "Couldn't save this meeting to history (the disk may be full). Export it now with Copy or Save, or free up space and reprocess it from the recovery prompt at next launch."
        }
        session.closeJournal()

        state = .complete
        SWLog.note("[MeetingTranscription] Complete. \(finalSegments.count) segments from \(uniqueSpeakers.count) speakers (saved=\(saved))")
    }

    private func preserveGeneratedNotes(in updated: inout MeetingTranscript) {
        guard let previous = MeetingHistoryStore.shared.meetings.first(where: { $0.id == updated.id }) else { return }
        updated.savedFormats = previous.savedFormats
        updated.staleFormats = Set(previous.savedFormats.keys)
    }

    private func retainAfterEmptyRecognition(_ previous: MeetingTranscript, session: MeetingSession) {
        transcript = previous
        speakerNames = previous.speakerNames
        speakerCount = Set(previous.segments.map(\.speakerId)).count
        processingProgress = nil
        session.setStatus(.stopped)
        session.closeJournal()
        postRecordingWarning = previous.hasSpeech
            ? "No speech was recognized on this attempt. Your previous transcript and recording are kept. You can process the saved audio again."
            : "No speech was recognized. The recording is kept for another processing attempt, including after you close SideWave."
        state = .complete
    }

    /// Apply the dictation text pipeline per speaker segment (MainActor-bound
    /// helpers) and drop segments that normalize to empty. Cheap relative to the
    /// off-main diarize/ASR, so it runs here without a perceptible hitch.
    private func finalizeSegments(_ raw: [MeetingRawSegment]) -> [MeetingSegment] {
        raw.compactMap { seg in
            let text = processSegmentText(seg.rawText)
            guard !text.isEmpty else { return nil }
            return MeetingSegment(
                speakerId: seg.speakerId, speakerLabel: seg.speakerId,
                text: text, startTime: seg.start, endTime: seg.end)
        }
    }

    private func processSegmentText(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        t = TranscriptionService.removeFillerWords(t)
        t = ProseOrdinalReverter.revert(TextNormalizer.shared.normalizeSentence(t))
        t = TranscriptionService.filterProfanity(t)
        t = CustomDictionary.apply(to: t)

        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Speaker names (single source of truth)

    /// Updates a speaker's name in the live transcript and history, so formatting always uses
    /// current names. An empty name restores "Speaker N" in stable order, never the raw detector
    /// ID.
    func updateSpeakerName(id: String, name: String) {
        guard var t = transcript else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            t.speakerNames[id] = defaultDisplayName(for: id, in: t)
        } else {
            t.speakerNames[id] = trimmed
        }
        transcript = t
        speakerNames = t.speakerNames
        MeetingHistoryStore.shared.updateSpeakerNames(meetingID: t.id, names: t.speakerNames)
    }

    private func defaultDisplayName(for id: String, in t: MeetingTranscript) -> String {
        let unique = Array(Set(t.segments.map(\.speakerId))).sorted()
        if let idx = unique.firstIndex(of: id) { return "Speaker \(idx + 1)" }
        return "Speaker 1"
    }

    // MARK: - Rediarize

    /// Runs speaker detection again on the session audio and reassigns the cached words without
    /// transcribing again. Runs off the main actor, keeps renamed speakers, and marks generated formats
    /// stale since the speakers may have changed. Nemotron 3 ignores a requested speaker count, so
    /// `expected` has no effect; the UI calls this "run detection again".
    func rediarize(expected: Int?) async {
        guard canRediarize, processingTask == nil, let session, let existing = transcript else { return }
        processingEpoch &+= 1
        let epoch = processingEpoch
        let words = cachedWords
        let timings = cachedTokenTimings
        let duration = cachedDuration
        let engine = self.engine
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.processingEpoch == epoch { self.processingTask = nil } }
            self.state = .processing(stage: .diarizing(method: ""))
            self.processingProgress = 0
            do {
                let progressHop: @Sendable (MeetingState.ProcessingStage, Double) -> Void = { [weak self] stage, fraction in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.processingEpoch == epoch, case .processing = self.state else { return }
                        if self.state != .processing(stage: stage) { self.state = .processing(stage: stage) }
                        self.processingProgress = fraction
                    }
                }
                let result: MeetingBatchResult
                if words.isEmpty {
                    // Live-recorded meeting: no cached batch words. Full reprocess
                    // from the CAFs for batch-quality diarization + ASR.
                    try await self.ensureModelsReady()
                    guard !Task.isCancelled else { return }
                    result = try await engine.batchProcess(
                        partURLs: session.partURLs(), progress: progressHop)
                } else {
                    result = try await engine.rediarize(
                        partURLs: session.partURLs(), words: words,
                        tokenTimings: timings, duration: duration, progress: progressHop)
                }
                guard !Task.isCancelled else { return }

                let finalSegments = self.finalizeSegments(result.rawSegments)
                let unique = Array(Set(finalSegments.map(\.speakerId))).sorted()
                var names: [String: String] = [:]
                for (i, id) in unique.enumerated() {
                    let prior = existing.speakerNames[id]
                    let isStillDefault: Bool = {
                        guard let prior else { return true }
                        return prior.range(of: "^Speaker \\d+$", options: .regularExpression) != nil
                    }()
                    names[id] = isStillDefault ? "Speaker \(i + 1)" : (prior ?? "Speaker \(i + 1)")
                }

                var updated = existing
                updated.isPartial = false
                updated.segments = finalSegments
                updated.speakerNames = names
                guard updated.hasSpeech else {
                    self.retainAfterEmptyRecognition(existing, session: session)
                    return
                }
                // Cache only after recognition produced usable text.
                self.cachedWords = result.words
                self.cachedTokenTimings = result.tokenTimings
                self.cachedDuration = result.duration
                // Formats generated before this pass may use the old speakers.
                updated.staleFormats = Set(updated.savedFormats.keys)
                self.transcript = updated
                self.speakerNames = names
                self.speakerCount = unique.count
                self.expectedSpeakers = expected
                self.processingProgress = nil
                let saved = MeetingHistoryStore.shared.replaceMeeting(updated)
                session.setStatus(saved ? .completed : .stopped)
                self.postRecordingWarning = saved ? nil : "The updated transcript could not be saved to history. Copy it now. The recording is kept for recovery."
                self.state = .complete
            } catch {
                if !Task.isCancelled {
                    let action = existing.isPartial ? "process the saved recording" : "re-detect speakers"
                    self.state = .error("Could not \(action). \(error.localizedDescription)")
                }
            }
        }
        processingTask = task
        await task.value
    }
}
