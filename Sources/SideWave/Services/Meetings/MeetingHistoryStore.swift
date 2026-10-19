// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Persists structured meeting transcripts (with speaker labels, timestamps)
/// so users can re-open them for AI formatting after dismissing.
/// Separate from HistoryStore which only keeps plain text for dictation history.
@Observable
@MainActor
final class MeetingHistoryStore {
    static let shared = MeetingHistoryStore()

    private(set) var meetings: [MeetingTranscript] = []
    private(set) var persistenceError: String?
    private var storageNeedsRecovery = false
    private let fileURL: URL

    init(storageURL: URL) {
        fileURL = storageURL
        loadMeetings()
    }

    var storageDirectory: URL { fileURL.deletingLastPathComponent() }

    @discardableResult
    func retrySaving() -> Bool { saveMeetings() }

    private init() {
        let appDir = AppPaths.applicationSupportDirectory()
        fileURL = appDir.appendingPathComponent("meeting-history.json")
        loadMeetings()
        pruneExpiredMeetings()
    }

    /// Remove meetings older than the user's retention setting.
    /// Uses the same "historyRetentionDays" UserDefaults key as HistoryStore.
    func pruneExpiredMeetings(defaults: UserDefaults = .standard) {
        let retentionDays = defaults.integer(forKey: "historyRetentionDays")
        guard retentionDays > 0 else { return } // 0 = keep forever

        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let before = meetings.count
        meetings.removeAll { $0.timestamp < cutoff && !$0.isPartial && $0.hasSpeech }
        if meetings.count < before {
            saveMeetings()
            SWLog.note("[MeetingHistory] Pruned \(before - meetings.count) expired meetings")
        }
    }

    /// Returns whether the transcript reached disk. The caller (meeting commit)
    /// keeps the source audio recoverable when this is false, so a failed save
    /// (disk full, read-only) never loses the meeting with no trace.
    @discardableResult
    func addMeeting(_ transcript: MeetingTranscript) -> Bool {
        meetings.insert(transcript, at: 0)
        return saveMeetings()
    }

    func deleteMeeting(id: UUID) {
        meetings.removeAll { $0.id == id }
        saveMeetings()
    }

    func saveFormattedOutput(meetingID: UUID, format: String, output: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        meetings[index].savedFormats[format] = output
        // A fresh generation supersedes any pre-rediarize staleness for this
        // format; without this the "generated before re-detection" note would
        // survive a regenerate across relaunch.
        meetings[index].staleFormats.remove(format)
        saveMeetings()
    }

    /// Update speaker display names for a persisted meeting. Called by the
    /// speaker-name pill strip when the user commits a rename.
    func updateSpeakerNames(meetingID: UUID, names: [String: String]) {
        guard let idx = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        meetings[idx].speakerNames = names
        saveMeetings()
    }

    /// Replace a meeting in place (preserves ordering). Used after rediarize
    /// to write new segments + speaker names back to disk without duplicating
    /// the entry. If the meeting isn't in history yet, inserts it at the top.
    @discardableResult
    func replaceMeeting(_ transcript: MeetingTranscript) -> Bool {
        if let idx = meetings.firstIndex(where: { $0.id == transcript.id }) {
            meetings[idx] = transcript
            return saveMeetings()
        } else {
            return addMeeting(transcript)
        }
    }

    func clearAll() {
        meetings.removeAll()
        saveMeetings()
    }

    // MARK: - Persistence

    private func loadMeetings() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            meetings = try JSONDecoder().decode([MeetingTranscript].self, from: data)
        } catch {
            let fm = FileManager.default
            let backupURL = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
            do {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
                guard values.isRegularFile == true, values.isReadable == true else { throw error }
                try fm.moveItem(at: fileURL, to: backupURL)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
                persistenceError = "Meeting history could not be decoded. The original file is preserved in \(backupURL.lastPathComponent)."
            } catch {
                storageNeedsRecovery = true
                persistenceError = "Meeting history could not be read or preserved safely. Existing history will not be overwritten."
            }
            meetings = []
        }
    }

    /// Returns whether the write succeeded so callers that hold the only other
    /// copy (meeting commit holds the source audio) can react to a failure.
    @discardableResult
    private func saveMeetings() -> Bool {
        guard !storageNeedsRecovery else { return false }
        // Meeting transcripts are the only copy of what was said; a silently
        // swallowed write (read-only dir, disk full) would drop them without
        // a trace. Log loudly; the in-memory copy stays intact this session.
        do {
            let data = try JSONEncoder().encode(meetings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            persistenceError = "Meeting changes could not be saved. Keep or export the transcript before quitting."
            return false
        }
        // Lock the file down to the owning user so another process on the
        // machine (a different UID) can't read meeting transcripts that contain
        // diarized conversation. Mirrors HistoryStore's pattern.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        persistenceError = nil
        return true
    }
}
