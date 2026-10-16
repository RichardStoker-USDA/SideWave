// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import Observation

/// A model download in progress, per file. It feeds the Downloads window with which files are being
/// fetched, and decides whether that window should open: only for downloads outside setup, where
/// nothing else explains what's happening. The download interceptor records events in
/// `NetworkActivityLog`; this holds only the observable state.
@MainActor
@Observable
final class ModelDownloadActivity {
    static let shared = ModelDownloadActivity()

    enum Stage: String, Sendable { case checking, downloading, verifying }

    /// A file inside a model snapshot, with live progress.
    struct FileProgress: Identifiable, Sendable {
        let id: String                    // relative path inside the snapshot
        var totalBytes: Int64             // 0 = unknown
        var downloadedBytes: Int64
        var finishedAt: Date?

        var fraction: Double {
            guard totalBytes > 0 else { return isFinished ? 1.0 : 0.0 }
            return min(1.0, Double(downloadedBytes) / Double(totalBytes))
        }

        var isFinished: Bool { finishedAt != nil }
    }

    /// An active or just-completed download session.
    struct Session: Identifiable, Sendable {
        let id: UUID
        /// Human-readable display name (e.g. "Gemma 4 E2B").
        let displayName: String
        /// Repository ID (e.g. "mlx-community/gemma-3n-E2B-it-lm-4bit").
        let repoID: String
        /// Bytes already on disk when the session started, so a fully cached model doing a metadata
        /// check doesn't open the window.
        let baselineBytes: Int64
        var files: [FileProgress]
        var overallFraction: Double
        var startedAt: Date
        var completedAt: Date?
        var error: String?
        /// True once a file grows past its starting size. The window stays hidden until then, so
        /// cached loads don't open it.
        var hasRealDownload: Bool
        var detail: String? = nil
        var stage: Stage = .checking
        var reportedDownloadedBytes: Int64? = nil
        var reportedTotalBytes: Int64? = nil

        /// Bytes pulled so far across every file in this session.
        var downloadedBytes: Int64 { reportedDownloadedBytes ?? files.reduce(0) { $0 + $1.downloadedBytes } }
        /// Best-known total size. Uses each file's reported size, falling back
        /// to its downloaded count when the size header was absent, so the
        /// readout never shows "142 MB of 0 MB".
        var totalBytes: Int64 { reportedTotalBytes ?? files.reduce(0) { $0 + max($1.totalBytes, $1.downloadedBytes) } }
        var hasKnownTotal: Bool {
            if let reportedTotalBytes { return reportedTotalBytes > 0 }
            return !files.isEmpty && files.allSatisfy { $0.totalBytes > 0 }
        }
    }

    private(set) var sessions: [UUID: Session] = [:]
    private var displayedID: UUID?
    var session: Session? { displayedID.flatMap { sessions[$0] } }
    var otherDownloads: [Session] {
        sessions.values.filter { $0.id != displayedID && $0.completedAt == nil }
            .sorted { $0.startedAt < $1.startedAt }
    }
    var allTransfersFinished: Bool { !sessions.isEmpty && sessions.values.allSatisfy { $0.completedAt != nil && $0.error == nil } }

    /// Current transfer rate in bytes per second, or nil until there's enough data (and after the
    /// session ends). Computed over a short rolling window, so a stall shows instead of hiding in
    /// an average.
    private(set) var bytesPerSecond: Double?

    /// Rolling (timestamp, cumulative-bytes) samples backing `bytesPerSecond`.
    @ObservationIgnored private var throughputSamples: [(t: Date, bytes: Int64)] = []
    @ObservationIgnored private static let throughputWindow: TimeInterval = 4.0

    /// Bumped each time a new session starts so SwiftUI can use `.id()` to
    /// reset transient view state like the countdown timer.
    private(set) var sessionGeneration: Int = 0

    /// User-controllable "hide for now" — closing the recovery window mid
    /// download won't reopen until the next download starts.
    var isPresentationSuppressed: Bool = false

    init() {}

    func transferRate(at now: Date) -> Double? {
        guard session?.completedAt == nil, session?.error == nil,
              session?.stage == .downloading,
              let last = throughputSamples.last, now.timeIntervalSince(last.t) < 5 else { return nil }
        return bytesPerSecond
    }

    func showSession(_ id: UUID) {
        guard sessions[id] != nil else { return }
        select(id)
    }

    func setStage(_ stage: Stage, detail: String? = nil, sessionID: UUID) {
        guard var s = sessions[sessionID], s.completedAt == nil, s.error == nil else { return }
        s.stage = stage
        if let detail { s.detail = detail }
        sessions[sessionID] = s
        if displayedID == sessionID { bytesPerSecond = nil }
    }

    /// Should the recovery window be visible right now?
    /// Visible when there's an active session that has actually downloaded
    /// data, AND the user hasn't suppressed it.
    var shouldPresentWindow: Bool {
        guard !isPresentationSuppressed else { return false }
        return sessions.values.contains { $0.hasRealDownload || $0.error != nil }
    }

    // MARK: - Mutators (called by MLXDownloadInterceptor)

    /// Starts a session and returns its ID. Callers pass it to `update`, `markComplete`, and
    /// `markError`, so an overlapping download can't write into the wrong session. Clears the
    /// hidden flag, so a new download can show the window again.
    @discardableResult
    func begin(displayName: String, repoID: String, baselineBytes: Int64) -> UUID {
        sessionGeneration &+= 1
        let id = UUID()
        sessions = sessions.filter { $0.value.completedAt == nil && !($0.value.repoID == repoID && $0.value.error != nil) }
        sessions[id] = Session(
            id: id,
            displayName: displayName,
            repoID: repoID,
            baselineBytes: baselineBytes,
            files: [],
            overallFraction: 0,
            startedAt: .now,
            completedAt: nil,
            error: nil,
            hasRealDownload: false
        )
        if session == nil || session?.completedAt != nil || session?.error != nil { select(id) }
        isPresentationSuppressed = false
        return id
    }

    /// Progress stays attached to its model while simultaneous downloads finish independently.
    func update(files: [FileProgress], overall: Double, signalsRealDownload: Bool, sessionID: UUID, detail: String? = nil,
                downloadedBytes: Int64? = nil, totalBytes: Int64? = nil, now: Date = .now) {
        guard var s = sessions[sessionID], s.completedAt == nil, s.error == nil else { return }
        s.files = files
        if let detail { s.detail = detail }
        s.overallFraction = overall.isFinite ? min(1, max(0, overall)) : 0
        if let downloadedBytes { s.reportedDownloadedBytes = max(0, downloadedBytes) }
        if let totalBytes { s.reportedTotalBytes = max(0, totalBytes) }
        if signalsRealDownload {
            s.hasRealDownload = true
            if s.stage != .verifying { s.stage = .downloading }
        }
        sessions[sessionID] = s
        if displayedID == sessionID { recordThroughputSample(max(0, s.downloadedBytes - s.baselineBytes), now: now) }
    }

    /// Adds a cumulative byte reading to the rolling window and updates the rate. A counter that
    /// goes backward (a retried file) restarts the window instead of reporting a spike; the
    /// previous rate holds until progress resumes.
    private func recordThroughputSample(_ cumulativeBytes: Int64, now: Date) {
        if let last = throughputSamples.last, cumulativeBytes < last.bytes {
            throughputSamples = [(now, cumulativeBytes)]
            bytesPerSecond = nil
            return
        }
        throughputSamples.append((now, cumulativeBytes))
        let cutoff = now.addingTimeInterval(-Self.throughputWindow)
        while throughputSamples.count > 2, let first = throughputSamples.first, first.t < cutoff {
            throughputSamples.removeFirst()
        }
        guard let first = throughputSamples.first, throughputSamples.count >= 2 else { return }
        let dt = now.timeIntervalSince(first.t)
        let db = cumulativeBytes - first.bytes
        if dt >= 0.4 {
            bytesPerSecond = Double(max(0, db)) / dt
        }
    }

    /// Finish one model without closing progress for another model still downloading.
    func markComplete(sessionID: UUID) {
        guard var s = sessions[sessionID], s.error == nil else { return }
        s.completedAt = .now
        s.overallFraction = 1
        sessions[sessionID] = s
        if displayedID == sessionID {
            select(nextUnfinishedID() ?? sessionID)
        }
    }

    func markError(_ message: String, sessionID: UUID) {
        guard var s = sessions[sessionID], s.completedAt == nil else { return }
        s.error = message
        sessions[sessionID] = s
        if displayedID == sessionID { bytesPerSecond = nil }
    }

    private func nextUnfinishedID() -> UUID? {
        sessions.values.filter { $0.completedAt == nil }
            .sorted { $0.startedAt < $1.startedAt }.first?.id
    }

    private func select(_ id: UUID?) {
        if displayedID != id { sessionGeneration &+= 1 }
        displayedID = id
        throughputSamples.removeAll(keepingCapacity: true)
        bytesPerSecond = nil
    }

    /// Dismiss finished activity while retaining any downloads still in progress.
    func clear() {
        sessions = sessions.filter { $0.value.completedAt == nil && $0.value.error == nil }
        select(nextUnfinishedID())
        isPresentationSuppressed = false
    }

    /// Hide the window for this session only — without aborting the download.
    func suppressPresentationForCurrentSession() {
        isPresentationSuppressed = true
    }
}
