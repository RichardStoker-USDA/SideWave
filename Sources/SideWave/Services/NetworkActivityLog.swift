// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import Observation
import os

/// Avoid double-counting only the repository a managed downloader owns.
/// Concurrent downloads from other repositories remain visible.
enum ManagedDownloadScope {
    private static let repositories = OSAllocatedUnfairLock(initialState: [String: Int]())
    struct FileTransfer: Sendable {
        let requestID: UUID
        let completed: Int64
        let total: Int64
        let received: Int64
        let finished: Bool
    }
    typealias FileObserver = @Sendable (String, FileTransfer) -> Void
    private struct Observation: Sendable {
        let repoID: String
        let report: FileObserver
    }
    private static let observers = OSAllocatedUnfairLock(initialState: [UUID: Observation]())

    static func observe(repoID: String, report: @escaping FileObserver) -> UUID {
        let id = UUID()
        observers.withLock { $0[id] = Observation(repoID: repoID, report: report) }
        return id
    }

    static func stopObserving(_ id: UUID) { _ = observers.withLock { $0.removeValue(forKey: id) } }

    /// Keep live payload progress when URLProtocol forwarding hides download-task callbacks.
    static func progressReporter(for url: URL) -> (@Sendable (FileTransfer) -> Void)? {
        guard url.host == "huggingface.co" else { return nil }
        let reports: [(FileObserver, String)] = observers.withLock { values in
            values.values.compactMap { observation in
                let prefix = "/" + observation.repoID + "/resolve/"
                guard url.path.hasPrefix(prefix) else { return nil }
                let parts = url.path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (observation.report, String(parts[1]))
            }
        }
        guard !reports.isEmpty else { return nil }
        return { transfer in
            for (report, file) in reports { report(file, transfer) }
        }
    }

    static func begin(repoID: String) { repositories.withLock { $0[repoID, default: 0] += 1 } }
    static func end(repoID: String) {
        repositories.withLock {
            let remaining = ($0[repoID] ?? 0) - 1
            if remaining <= 0 { $0.removeValue(forKey: repoID) } else { $0[repoID] = remaining }
        }
    }
    static func ownsFile(at url: URL) -> Bool {
        guard url.host == "huggingface.co" else { return false }
        return repositories.withLock { repos in
            repos.keys.contains { url.path.hasPrefix("/" + $0 + "/resolve/") }
        }
    }
}

/// Persistent history of app-managed network requests, downloads and update checks.
/// It stores metadata only, with no transcript, request body, query or credentials.
@MainActor
@Observable
final class NetworkActivityLog {
    static let shared = NetworkActivityLog()

    /// Kind of network event. Maps to a human-readable label in the UI.
    enum EventKind: String, Codable, CaseIterable {
        case appUpdateCheck = "app_update_check"
        case appUpdateDownload = "app_update_download"
        case modelDownload = "model_download"
        case modelManifest = "model_manifest"
        case templateDownload = "template_download"
        case glossaryDownload = "glossary_download"
        case other = "other"

        var displayName: String {
            switch self {
            case .appUpdateCheck: return "App update check"
            case .appUpdateDownload: return "App update download"
            case .modelDownload: return "Model download"
            case .modelManifest: return "Model file listing"
            case .templateDownload: return "Template download"
            case .glossaryDownload: return "Glossary download"
            case .other: return "Other"
            }
        }

        var systemImage: String {
            switch self {
            case .appUpdateCheck: return "arrow.down.doc"
            case .appUpdateDownload: return "arrow.down.app"
            case .modelDownload: return "cube.box"
            case .modelManifest: return "list.bullet.rectangle"
            case .templateDownload: return "doc.text"
            case .glossaryDownload: return "character.book.closed"
            case .other: return "network"
            }
        }
    }

    enum Direction: String, Codable {
        case incoming
        case outgoing
    }

    struct Event: Identifiable, Codable, Sendable {
        let id: UUID
        let timestamp: Date
        let kind: EventKind
        let direction: Direction
        /// Host portion of the URL, e.g. "huggingface.co". Never includes
        /// user-identifying content; just the origin.
        let host: String
        /// Path portion of the URL. Documents WHAT was requested but
        /// contains no user dictation content (we never POST anything).
        let path: String
        /// Byte count if known, else 0.
        let bytes: Int64
        /// Optional human-readable detail (e.g. model name being fetched).
        let detail: String

        init(
            id: UUID = UUID(),
            timestamp: Date = .now,
            kind: EventKind,
            direction: Direction,
            host: String,
            path: String,
            bytes: Int64 = 0,
            detail: String = ""
        ) {
            self.id = id
            self.timestamp = timestamp
            self.kind = kind
            self.direction = direction
            self.host = host
            self.path = path
            self.bytes = bytes
            self.detail = detail
        }
    }

    /// All events in chronological order, oldest first.
    private(set) var events: [Event] = []

    /// Total bytes downloaded across all events. Computed at append time
    /// so the transparency view doesn't have to fold the array on every
    /// re-render.
    private(set) var totalIncomingBytes: Int64 = 0
    private(set) var totalOutgoingBytes: Int64 = 0

    private let persistenceURL: URL
    @ObservationIgnored private var persistedIDs = Set<UUID>()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var canPersist = true
    @ObservationIgnored private var recoveryNotice: String?
    private(set) var persistenceError: String?

    init(storageURL: URL? = nil) {
        persistenceURL = storageURL ?? AppPaths.applicationSupportDirectory().appendingPathComponent("network_activity_log.json")
        loadFromDisk()
    }

    /// Records a new network event. Idempotent on the ID; call sites can
    /// generate stable IDs to avoid double-logging the same event.
    func record(_ event: Event) {
        guard persistedIDs.insert(event.id).inserted else { return }
        events.append(event)
        switch event.direction {
        case .incoming: totalIncomingBytes += max(0, event.bytes)
        case .outgoing: totalOutgoingBytes += max(0, event.bytes)
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.flush()
        }
    }

    /// Convenience for the most common case: a download from a known host.
    func recordDownload(
        kind: EventKind,
        host: String,
        path: String,
        bytes: Int64,
        detail: String = ""
    ) {
        record(Event(
            kind: kind,
            direction: .incoming,
            host: host,
            path: path,
            bytes: bytes,
            detail: detail
        ))
    }

    /// Clears the log. User-initiated only via the transparency window.
    /// Doesn't affect the contract; events continue to be recorded after.
    func clear() {
        events = []
        persistedIDs = []
        totalIncomingBytes = 0
        totalOutgoingBytes = 0
        flush()
    }

    private func recomputeTotals() {
        totalIncomingBytes = events.filter { $0.direction == .incoming }.reduce(0) { $0 + $1.bytes }
        totalOutgoingBytes = events.filter { $0.direction == .outgoing }.reduce(0) { $0 + $1.bytes }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard canPersist else { return }
        let url = persistenceURL
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(events)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            persistenceError = recoveryNotice
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            persistenceError = "Network history could not be saved. Check free disk space and storage permissions."
        }
    }

    private func loadFromDisk() {
        let url = persistenceURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            events = try decoder.decode([Event].self, from: data)
            persistedIDs = Set(events.map(\.id))
            recomputeTotals()
        } catch {
            let preserved = url.appendingPathExtension("corrupt-" + UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: url, to: preserved)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preserved.path)
                recoveryNotice = "Saved network history could not be read. Its original file is preserved as \(preserved.lastPathComponent)."
            } catch {
                canPersist = false
                recoveryNotice = "Network history could not be read or preserved safely. The existing file will not be overwritten."
            }
            persistenceError = recoveryNotice
            events = []
        }
    }
}
