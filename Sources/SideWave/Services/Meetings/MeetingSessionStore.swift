// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

@preconcurrency import AVFAudio
import Foundation

// MARK: - Persistent session model

/// Status of an in-progress meeting, saved in `manifest.json`. A folder remains in
/// `Meetings/InProgress/` only while the meeting is unfinished; finished meetings are deleted once
/// their transcript is in `MeetingHistoryStore`. So any folder found at launch is an orphan, even one
/// marked `recording`, which means the previous run ended mid-capture.
enum MeetingSessionStatus: String, Codable, Sendable {
    case recording
    case stopped
    case processing
    /// Transcript is durable in `MeetingHistoryStore`; the directory is kept
    /// only so the current session can rediarize. Never an orphan; the scan
    /// deletes leftover `completed` directories at the next launch.
    case completed

    /// Tolerant decode: an unknown or missing status is treated as `recording`
    /// so a crash mid-write still classifies the directory as a resumable orphan
    /// rather than silently dropping it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingSessionStatus(rawValue: raw) ?? .recording
    }
}

/// One recording run's audio file. A resume starts a new part; batch processing
/// concatenates parts in order with a synthetic gap between them.
struct MeetingPart: Codable, Sendable {
    /// Filename relative to the session directory, e.g. `audio-001.caf`.
    var file: String
    /// Seconds of audio. `-1` while a part is still being written (or if the
    /// process died before finalizing); recovery re-derives it from the CAF.
    var duration: Double
    var sampleRate: Double
}

/// On-disk manifest. Rewritten atomically (0o600) on every part change, status
/// transition, and 10s heartbeat while recording.
struct MeetingManifest: Codable, Sendable {
    var id: UUID
    var startedAt: Date
    var parts: [MeetingPart]
    var expectedSpeakers: Int?
    var deviceUID: String?
    var status: MeetingSessionStatus
    var heartbeat: Date
    var appVersion: String

    init(
        id: UUID,
        startedAt: Date,
        parts: [MeetingPart] = [],
        expectedSpeakers: Int? = nil,
        deviceUID: String? = nil,
        status: MeetingSessionStatus = .recording,
        heartbeat: Date,
        appVersion: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.parts = parts
        self.expectedSpeakers = expectedSpeakers
        self.deviceUID = deviceUID
        self.status = status
        self.heartbeat = heartbeat
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, parts, expectedSpeakers, deviceUID, status, heartbeat, appVersion
    }

    /// Tolerant decode: a manifest written by an older/newer build with missing
    /// optionals or extra keys still opens. Missing required fields fall back to
    /// values that keep the directory classifiable as an orphan.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        startedAt = (try? c.decode(Date.self, forKey: .startedAt)) ?? Date(timeIntervalSince1970: 0)
        parts = (try? c.decode([MeetingPart].self, forKey: .parts)) ?? []
        expectedSpeakers = try? c.decodeIfPresent(Int.self, forKey: .expectedSpeakers)
        deviceUID = try? c.decodeIfPresent(String.self, forKey: .deviceUID)
        status = (try? c.decode(MeetingSessionStatus.self, forKey: .status)) ?? .recording
        heartbeat = (try? c.decode(Date.self, forKey: .heartbeat)) ?? startedAt
        appVersion = (try? c.decode(String.self, forKey: .appVersion)) ?? "unknown"
    }
}

// MARK: - Orphan descriptor

/// A resumable meeting discovered at launch. Carries enough to render a
/// "continue this meeting?" prompt without opening the audio.
struct OrphanedMeeting: Identifiable, Sendable {
    let id: UUID
    let directory: URL
    let startedAt: Date
    /// Sum of part durations; the still-open part is estimated from its CAF
    /// frame count / sample rate.
    let recordedDuration: TimeInterval
    let diskBytes: Int64
    let hasLiveSegments: Bool
    let status: MeetingSessionStatus
}

// MARK: - Session store

/// On-disk layout for in-progress meetings, and the recovery scan. Under Application Support so it
/// survives restarts:
///   Meetings/InProgress/<uuid>/
///     manifest.json      rewritten atomically, 0600
///     audio-001.caf ...  one file per recording run
///     segments.jsonl     journal of finished live segments, append only
enum MeetingSessionStore {
    static let manifestName = "manifest.json"
    static let journalName = "segments.jsonl"

    /// `Meetings/InProgress` root, created 0o700 on first access.
    static func inProgressDirectory() -> URL {
        let dir = AppPaths.applicationSupportDirectory()
            .appendingPathComponent("Meetings", isDirectory: true)
            .appendingPathComponent("InProgress", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    /// Create a fresh session directory + manifest and return a live handle.
    static func createSession(deviceUID: String?, expectedSpeakers: Int?) throws -> MeetingSession {
        let id = UUID()
        let dir = inProgressDirectory().appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let manifest = MeetingManifest(
            id: id,
            startedAt: Date(),
            expectedSpeakers: expectedSpeakers,
            deviceUID: deviceUID,
            status: .recording,
            heartbeat: Date(),
            appVersion: appVersion
        )
        let session = MeetingSession(directory: dir, manifest: manifest)
        try session.persistManifest()
        return session
    }

    /// Reopens an orphaned folder as a live session to resume or process it. Includes unlisted
    /// audio and keeps references to missing parts, so processing reports an incomplete recording
    /// instead of dropping a part.
    static func openSession(_ orphan: OrphanedMeeting) throws -> MeetingSession {
        var manifest = try readManifest(in: orphan.directory)
            ?? MeetingManifest(id: orphan.id, startedAt: orphan.startedAt, heartbeat: Date(), appVersion: appVersion)
        manifest.parts = reconciledParts(manifest.parts, files: cafFilenames(in: orphan.directory))
        if manifest.startedAt <= Date(timeIntervalSince1970: 0) { manifest.startedAt = orphan.startedAt }
        return MeetingSession(directory: orphan.directory, manifest: manifest)
    }

    /// Sorted `.caf` filenames (not full URLs) in a session directory.
    fileprivate static func cafFilenames(in directory: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.pathExtension == "caf" }
            .map { $0.lastPathComponent }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    private static func reconciledParts(_ parts: [MeetingPart], files: [String]) -> [MeetingPart] {
        let known = Set(parts.map(\.file))
        let recovered = files.filter { !known.contains($0) }
            .map { MeetingPart(file: $0, duration: -1, sampleRate: 0) }
        return (parts + recovered).sorted { $0.file.compare($1.file, options: .numeric) == .orderedAscending }
    }

    /// Delete an orphan directory (discard).
    static func discard(_ orphan: OrphanedMeeting) {
        try? FileManager.default.removeItem(at: orphan.directory)
    }

    static func readManifest(in directory: URL) throws -> MeetingManifest? {
        let url = directory.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.meeting.decode(MeetingManifest.self, from: data)
    }

    /// Finds resumable meetings; AppState calls this at launch before any cleanup. Every readable
    /// folder is an orphan. Unfinished audio is kept until processing succeeds or the user discards
    /// it; history retention never deletes the only copy of a recording.
    static func scanForOrphans() -> [OrphanedMeeting] {
        let root = inProgressDirectory()
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var orphans: [OrphanedMeeting] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            // A completed directory's transcript is already durable in history;
            // it lingered only for same-session rediarize. Reap it now.
            if (try? readManifest(in: dir))?.status == .completed {
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            guard let orphan = describeOrphan(dir) else { continue }
            orphans.append(orphan)
        }
        // Even a zero-duration recording stays visible for an explicit recovery decision.
        return orphans.sorted { $0.startedAt > $1.startedAt }
    }

    /// Build an orphan descriptor from a directory. Best-effort: a missing or
    /// corrupt manifest still surfaces the directory if it holds recoverable
    /// audio, so a crash mid-first-write doesn't hide the recording.
    private static func describeOrphan(_ dir: URL) -> OrphanedMeeting? {
        let manifest = try? readManifest(in: dir)

        let cafFiles = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ))?.filter { $0.pathExtension == "caf" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        // No audio and no manifest: nothing to recover, drop the empty shell.
        guard manifest != nil || !cafFiles.isEmpty else { return nil }

        var diskBytes: Int64 = 0
        for f in cafFiles {
            diskBytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }

        // Recorded duration: prefer manifest part durations; re-derive any
        // still-open part (duration < 0) or any missing manifest from the CAF.
        var recordedDuration: TimeInterval = 0
        let parts = reconciledParts(manifest?.parts ?? [], files: cafFiles.map(\.lastPathComponent))
        for part in parts {
            if part.duration >= 0 {
                recordedDuration += part.duration
            } else {
                let url = dir.appendingPathComponent(part.file)
                recordedDuration += cafDuration(url)
            }
        }

        let id = manifest?.id ?? UUID(uuidString: dir.lastPathComponent) ?? UUID()
        let recordedStart = manifest.flatMap { $0.startedAt > Date(timeIntervalSince1970: 0) ? $0.startedAt : nil }
        let startedAt = recordedStart
            ?? (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? Date()
        let journal = dir.appendingPathComponent(journalName)
        let hasLive = ((try? journal.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0

        return OrphanedMeeting(
            id: id,
            directory: dir,
            startedAt: startedAt,
            recordedDuration: recordedDuration,
            diskBytes: diskBytes,
            hasLiveSegments: hasLive,
            status: manifest?.status ?? .recording
        )
    }

    /// Duration of a CAF from its frame count, or 0 if it can't be opened.
    static func cafDuration(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

// MARK: - Live session handle

/// A handle to one in-progress meeting folder. The recording path updates the manifest while the
/// background pipeline appends segments, so shared state is accessed under `lock`. Writes are small
/// and infrequent (a 10 s heartbeat, one line per segment).
final class MeetingSession: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var manifest: MeetingManifest
    private var journalHandle: FileHandle?

    init(directory: URL, manifest: MeetingManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    var id: UUID { lock.withLock { manifest.id } }
    var startedAt: Date { lock.withLock { manifest.startedAt } }
    var expectedSpeakers: Int? { lock.withLock { manifest.expectedSpeakers } }
    var deviceUID: String? { lock.withLock { manifest.deviceUID } }

    // MARK: Parts

    /// Register a new recording part and return its file URL, pre-created 0o600.
    /// The part is added with an unknown duration so a crash mid-part still
    /// leaves a manifest entry recovery can estimate from the CAF.
    func beginPart() throws -> URL {
        try lock.withLock {
            let names = manifest.parts.map(\.file) + MeetingSessionStore.cafFilenames(in: directory)
            let indices = names.compactMap { name -> Int? in
                guard name.hasPrefix("audio-"), name.hasSuffix(".caf") else { return nil }
                return Int(name.dropFirst(6).dropLast(4))
            }
            let (index, overflow) = max(manifest.parts.count, indices.max() ?? 0).addingReportingOverflow(1)
            guard !overflow else { throw CocoaError(.fileWriteInvalidFileName) }
            let name = String(format: "audio-%03ld.caf", index)
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url, options: .withoutOverwriting)
            let previousManifest = manifest
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                manifest.parts.append(MeetingPart(file: name, duration: -1, sampleRate: 0))
                manifest.heartbeat = Date()
                try writeManifestLocked()
            } catch {
                manifest = previousManifest
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return url
        }
    }

    /// Record the finalized duration + sample rate of the most recent part.
    func finishCurrentPart(duration: TimeInterval, sampleRate: Double) {
        lock.withLock {
            guard !manifest.parts.isEmpty else { return }
            manifest.parts[manifest.parts.count - 1].duration = duration
            manifest.parts[manifest.parts.count - 1].sampleRate = sampleRate
            manifest.heartbeat = Date()
            try? writeManifestLocked()
        }
    }

    /// Ordered CAF URLs, including missing parts so processing cannot silently lose a recording.
    func partURLs() -> [URL] {
        lock.withLock {
            manifest.parts
                .map { directory.appendingPathComponent($0.file) }
        }
    }

    // MARK: Manifest lifecycle

    func heartbeat() {
        lock.withLock {
            manifest.heartbeat = Date()
            try? writeManifestLocked()
        }
    }

    func setStatus(_ status: MeetingSessionStatus) {
        lock.withLock {
            manifest.status = status
            manifest.heartbeat = Date()
            try? writeManifestLocked()
        }
    }

    func persistManifest() throws {
        try lock.withLock { try writeManifestLocked() }
    }

    private func writeManifestLocked() throws {
        let url = directory.appendingPathComponent(MeetingSessionStore.manifestName)
        let data = try JSONEncoder.meeting.encode(manifest)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Live-transcript journal

    /// Append one finalized segment as a single JSON line. Called off-main from
    /// the live pipeline as segments finalize.
    func appendLiveSegment(_ segment: MeetingSegment) {
        guard var line = try? JSONEncoder.meeting.encode(segment) else { return }
        line.append(0x0A) // newline
        lock.withLock {
            do {
                if journalHandle == nil {
                    let url = directory.appendingPathComponent(MeetingSessionStore.journalName)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(
                            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
                        )
                    }
                    journalHandle = try FileHandle(forWritingTo: url)
                    try journalHandle?.seekToEnd()
                }
                try journalHandle?.write(contentsOf: line)
            } catch {
                // Journaling is a best-effort convenience for the live view and
                // partial recovery; the CAF is the authoritative artifact, so a
                // failed append never interrupts recording.
            }
        }
    }

    /// Read finalized segments from the journal, tolerating a truncated or
    /// partially-written last line (a crash mid-append must not poison the
    /// whole read; drop the bad tail line only).
    func readLiveSegments() -> [MeetingSegment] {
        Self.readJournal(at: directory.appendingPathComponent(MeetingSessionStore.journalName))
    }

    /// Parse a `segments.jsonl` file, skipping any line that fails to decode.
    static func readJournal(at url: URL) -> [MeetingSegment] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        var segments: [MeetingSegment] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let segment = try? JSONDecoder.meeting.decode(MeetingSegment.self, from: Data(line))
            else { continue }
            segments.append(segment)
        }
        return segments
    }

    /// Keep unprocessed audio when dismissing results or quitting the app.
    func release(discardUnprocessed: Bool = false) {
        let completed = lock.withLock { manifest.status == .completed }
        if completed || discardUnprocessed {
            finalizeAndDelete()
        } else {
            setStatus(.stopped)
            closeJournal()
        }
    }

    /// Close the journal handle and delete the whole session directory. Called
    /// once the transcript is durable in MeetingHistoryStore, or on discard.
    func finalizeAndDelete() {
        lock.withLock {
            try? journalHandle?.close()
            journalHandle = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Close the journal handle without deleting (keep audio for rediarize).
    func closeJournal() {
        lock.withLock {
            try? journalHandle?.close()
            journalHandle = nil
        }
    }
}

// MARK: - Shared coders

extension JSONEncoder {
    /// ISO-8601 date coding so manifests/journals round-trip across builds.
    static let meeting: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let meeting: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
