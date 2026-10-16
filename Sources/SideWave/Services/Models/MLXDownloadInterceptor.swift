// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import MLXLMCommon
import HuggingFace

/// Adds file progress and validates cached text models before MLX loads them.
struct MLXDownloadInterceptor: Downloader {
    let upstream: any Downloader
    let displayName: String
    var cache: HubCache = .default

    /// Resolves the hub-format model directory for a given repoID.
    /// Example: `mlx-community/gemma-4-e2b-it-4bit` →
    /// `~/.cache/huggingface/hub/models--mlx-community--gemma-4-e2b-it-4bit/`.
    static func expectedDestination(for repoID: String, cacheRoot: URL = HubCache.default.cacheDirectory) -> URL {
        let folder = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        return cacheRoot.appendingPathComponent(folder, isDirectory: true)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // This interceptor emits one transparency event per fetched file, so
        // silence the raw-layer interceptor while the download is in flight
        // to avoid logging every weight shard twice.
        ManagedDownloadScope.begin(repoID: id)
        defer { ManagedDownloadScope.end(repoID: id) }

        let likelyDestination = Self.expectedDestination(for: id, cacheRoot: cache.cacheDirectory)
        var downloadRevision = revision
        var baselineDirectory = likelyDestination
        if let cached = ModelSnapshotValidation.cachedSnapshot(repoID: id, revision: revision ?? "main", cache: cache) {
            baselineDirectory = cached
            let invalid = await Task.detached(priority: .utility) {
                ModelSnapshotValidation.invalidFiles(at: cached)
            }.value
            if invalid.isEmpty, !useLatest {
                let progress = Progress(totalUnitCount: 1)
                progress.completedUnitCount = 1
                progressHandler(progress)
                return cached
            }
            try ModelSnapshotValidation.removeInvalidFiles(invalid, at: cached, cacheRoot: cache.cacheDirectory)
            if !useLatest, ModelSnapshotValidation.isCommitRevision(cached.lastPathComponent) {
                downloadRevision = cached.lastPathComponent
            }
        }
        let transfer = MLXTransferProgress()
        let observation = ManagedDownloadScope.observe(repoID: id) { file, progress in
            transfer.updateFile(file, progress: progress)
        }
        defer { ManagedDownloadScope.stopObserving(observation) }
        let baseline = await Self.snapshot(at: baselineDirectory)
        let baselineIdentities = await Self.fileIdentities(at: baselineDirectory)
        let baselineTotalBytes = baseline.values.reduce(Int64(0), +)
        let label = displayName
        let repoID = id

        let sessionID = await MainActor.run {
            ModelDownloadActivity.shared.begin(
                displayName: label,
                repoID: repoID,
                baselineBytes: baselineTotalBytes
            )
        }

        // Poll the folder every 400 ms while the download runs, reading file sizes and publishing
        // them.
        let pollTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let snap = await Self.snapshot(at: likelyDestination)
                let files = transfer.mergedFiles(Self.buildFileProgress(snapshot: snap, baseline: baseline))
                let reading = transfer.reading(including: files)
                let overall = reading.fraction
                if let total = reading.total, let completed = reading.completed {
                    let progress = Progress(totalUnitCount: total)
                    progress.completedUnitCount = completed
                    progressHandler(progress)
                }
                // "Real download" = at least one file's downloadedBytes is
                // larger than its baseline size by any non-trivial amount.
                let hasReal = (reading.completed ?? 0) > baselineTotalBytes + 16 * 1024 || files.contains { fp in
                    let base = baseline[fp.id] ?? 0
                    return fp.downloadedBytes > base + 16 * 1024
                }
                await MainActor.run {
                    ModelDownloadActivity.shared.update(
                        files: files, overall: overall, signalsRealDownload: hasReal,
                        sessionID: sessionID,
                        downloadedBytes: reading.completed, totalBytes: reading.total
                    )
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        // Merge SDK totals with received payload bytes on the polling cadence.
        do {
            var url = try await upstream.download(
                id: id,
                revision: downloadRevision,
                matching: patterns,
                useLatest: useLatest,
                progressHandler: { progress in
                    transfer.update(progress)
                }
            )
            let firstSnapshot = url
            await MainActor.run {
                ModelDownloadActivity.shared.setStage(.verifying, detail: "Checking tokenizer, template, and weight files", sessionID: sessionID)
            }
            let invalid = await Task.detached(priority: .utility) {
                ModelSnapshotValidation.invalidFiles(at: firstSnapshot)
            }.value
            if !invalid.isEmpty {
                try Task.checkCancellation()
                try ModelSnapshotValidation.removeInvalidFiles(invalid, at: url, cacheRoot: cache.cacheDirectory)
                await MainActor.run {
                    ModelDownloadActivity.shared.setStage(.downloading, detail: "Repairing incomplete model files", sessionID: sessionID)
                }
                let repairRevision = ModelSnapshotValidation.isCommitRevision(url.lastPathComponent) ? url.lastPathComponent : downloadRevision
                url = try await upstream.download(id: id, revision: repairRevision, matching: patterns,
                    useLatest: true, progressHandler: { progress in
                        transfer.update(progress)
                    })
                let repairedSnapshot = url
                try await Task.detached(priority: .utility) {
                    try ModelSnapshotValidation.validate(at: repairedSnapshot)
                }.value
            }
            pollTask.cancel()
            await pollTask.value
            let complete = Progress(totalUnitCount: 1)
            complete.completedUnitCount = 1
            progressHandler(complete)

            // Final snapshot: compare with the baseline and record one event per new or changed
            // file, using the folder the download returned, or the expected one if it's missing.
            let finalSnapshot = await Self.snapshot(at: url)
            let finalIdentities = await Self.fileIdentities(at: url)
            let diff = Self.diffSnapshots(before: baseline, after: finalSnapshot,
                beforeIdentities: baselineIdentities, afterIdentities: finalIdentities)
            let downloadedFiles = transfer.downloadedFiles(fallback: diff)
            let revisionForLog = downloadRevision ?? "main"
            await MainActor.run {
                let log = NetworkActivityLog.shared
                for entry in downloadedFiles {
                    log.recordDownload(
                        kind: .modelDownload,
                        host: "huggingface.co",
                        path: "/\(id)/resolve/\(revisionForLog)/\(entry.path)",
                        bytes: entry.bytesAdded,
                        detail: "\(label): \(entry.path)"
                    )
                }
                let files = Self.buildFileProgress(snapshot: finalSnapshot, baseline: baseline)
                ModelDownloadActivity.shared.update(
                    files: files, overall: 1.0, signalsRealDownload: !diff.isEmpty,
                    sessionID: sessionID,
                    downloadedBytes: finalSnapshot.values.reduce(0, +), totalBytes: finalSnapshot.values.reduce(0, +)
                )
                ModelDownloadActivity.shared.markComplete(sessionID: sessionID)
            }
            return url
        } catch {
            pollTask.cancel()
            await pollTask.value
            // Capture whatever did land before the error so the user sees
            // progress instead of a blank state.
            let salvageSnapshot = await Self.snapshot(at: likelyDestination)
            let salvageDiff = Self.diffSnapshots(before: baseline, after: salvageSnapshot)
            let downloadedFiles = transfer.downloadedFiles(fallback: salvageDiff)
            let revisionForLog = downloadRevision ?? "main"
            let errorMessage = (error as? ModelSnapshotValidation.Failure)?.localizedDescription
                ?? (error is CancellationError ? "Download paused. Retry to resume the remaining files."
                    : "Download interrupted. Retry to resume the remaining files.")
            await MainActor.run {
                let log = NetworkActivityLog.shared
                for entry in downloadedFiles {
                    log.recordDownload(
                        kind: .modelDownload,
                        host: "huggingface.co",
                        path: "/\(id)/resolve/\(revisionForLog)/\(entry.path)",
                        bytes: entry.bytesAdded,
                        detail: "\(label): \(entry.path) (partial)"
                    )
                }
                log.recordDownload(kind: .modelDownload, host: "huggingface.co", path: "/\(id)", bytes: 0,
                    detail: "\(label): \(errorMessage)")
                ModelDownloadActivity.shared.markError(errorMessage, sessionID: sessionID)
            }
            throw error
        }
    }

    // MARK: - Filesystem helpers

    /// Lists every file in a Hugging Face hub model folder by name and size. Layout
    /// (`~/.cache/huggingface/hub/models--<org>--<repo>/`):
    ///   - `snapshots/<commit>/<name>`  symlink to `../../blobs/<sha>`
    ///   - `blobs/<sha>`                the file contents
    ///   - `blobs/<sha>.incomplete`     a download in progress
    /// Symlinks are resolved so sizes are the real files. Incomplete blobs get a placeholder name so the
    /// Downloads window can show them before their symlinks exist.
    static func snapshot(at root: URL) async -> [String: Int64] {
        await Task.detached(priority: .utility) {
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            var result: [String: Int64] = [:]
            let fm = FileManager.default

            let snapshotsDir = root.appendingPathComponent("snapshots", isDirectory: true)
            let snapshots: [URL]
            if let commits = try? fm.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil) {
                snapshots = commits.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                snapshots = [root]
            }
            for directory in snapshots {
                guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
                while let item = walker.nextObject() {
                    guard let url = item as? URL else { continue }
                    let real = url.resolvingSymlinksInPath()
                    guard let attrs = try? fm.attributesOfItem(atPath: real.path),
                          (attrs[.type] as? FileAttributeType) == .typeRegular,
                          let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
                    var relative = [url.lastPathComponent]
                    var parent = url.deletingLastPathComponent()
                    while parent.resolvingSymlinksInPath().path != directory.resolvingSymlinksInPath().path,
                          parent.pathComponents.count > 1 {
                        relative.insert(parent.lastPathComponent, at: 0)
                        parent.deleteLastPathComponent()
                    }
                    let name = relative.joined(separator: "/")
                    result[name] = max(result[name] ?? 0, size)
                }
            }

            // In-flight downloads (`.incomplete` blobs) under blobs/
            let blobsDir = root.appendingPathComponent("blobs", isDirectory: true)
            if let blobs = try? fm.contentsOfDirectory(
                at: blobsDir,
                includingPropertiesForKeys: [.fileSizeKey]
            ) {
                for blob in blobs where blob.lastPathComponent.hasSuffix(".incomplete") {
                    let size = Int64((try? blob.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    // Pull a stable, short identifier for the UI: hash prefix
                    // + ".incomplete" so duplicate appearances merge into the
                    // same row each poll tick.
                    let hashPrefix = blob.lastPathComponent
                        .replacingOccurrences(of: ".incomplete", with: "")
                        .prefix(12)
                    let key = "(fetching) \(hashPrefix)…"
                    result[key] = size
                }
            }
            return result
        }.value
    }

    /// Turns a snapshot and baseline into ordered entries for the Downloads window, leaving out
    /// hidden cache files under `.cache/`.
    static func buildFileProgress(
        snapshot: [String: Int64],
        baseline: [String: Int64]
    ) -> [ModelDownloadActivity.FileProgress] {
        let visible = snapshot.filter { entry in
            !entry.key.hasPrefix(".") && !entry.key.contains("/.")
        }
        return visible
            .map { (path, size) in
                let incomplete = path.hasPrefix("(fetching)")
                return ModelDownloadActivity.FileProgress(
                    id: path,
                    totalBytes: incomplete ? 0 : size,
                    downloadedBytes: size,
                    finishedAt: incomplete ? nil : Date()
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.id < rhs.id
            }
    }

    /// Hub symlinks identify immutable blobs even when a replacement has the same size.
    static func fileIdentities(at directory: URL) async -> [String: String] {
        await Task.detached(priority: .utility) {
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            let fm = FileManager.default
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }
            var result: [String: String] = [:]
            while let item = walker.nextObject() {
                guard let url = item as? URL else { continue }
                let real = url.resolvingSymlinksInPath()
                guard let attrs = try? fm.attributesOfItem(atPath: real.path),
                      attrs[.type] as? FileAttributeType == .typeRegular else { continue }
                var components = [url.lastPathComponent]
                var parent = url.deletingLastPathComponent()
                while parent.resolvingSymlinksInPath().path != root.path, parent.pathComponents.count > 1 {
                    components.insert(parent.lastPathComponent, at: 0)
                    parent.deleteLastPathComponent()
                }
                guard parent.resolvingSymlinksInPath().path == root.path else { continue }
                let relative = components.joined(separator: "/")
                if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    result[relative] = real.lastPathComponent
                } else if let modified = attrs[.modificationDate] as? Date {
                    result[relative] = String(modified.timeIntervalSince1970)
                }
            }
            return result
        }.value
    }

    struct DiffEntry { let path: String; let bytesAdded: Int64 }

    static func diffSnapshots(
        before: [String: Int64],
        after: [String: Int64],
        beforeIdentities: [String: String] = [:], afterIdentities: [String: String] = [:]
    ) -> [DiffEntry] {
        var entries: [DiffEntry] = []
        for (path, size) in after where !path.hasPrefix(".") && !path.contains("/.") {
            let baseSize = before[path] ?? 0
            let changedIdentity = beforeIdentities[path] != nil && afterIdentities[path] != nil
                && beforeIdentities[path] != afterIdentities[path]
            if (size != baseSize || changedIdentity), size > 0 {
                entries.append(DiffEntry(path: path, bytesAdded: size))
            }
        }
        return entries.sorted { $0.bytesAdded > $1.bytesAdded }
    }
}

final class MLXTransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    struct Reading { var fraction = 0.0; var completed: Int64?; var total: Int64? }
    private var value = Reading()
    private var files: [String: ModelDownloadActivity.FileProgress] = [:]
    private var received: [UUID: (file: String, bytes: Int64)] = [:]
    var reading: Reading { lock.withLock { value } }

    func updateFile(_ name: String, progress: ManagedDownloadScope.FileTransfer) {
        lock.withLock {
            files[name] = .init(id: name, totalBytes: max(0, progress.total), downloadedBytes: max(0, progress.completed),
                                finishedAt: progress.finished ? .now : nil)
            received[progress.requestID] = (name, max(0, progress.received))
        }
    }

    func downloadedFiles(fallback: [MLXDownloadInterceptor.DiffEntry]) -> [MLXDownloadInterceptor.DiffEntry] {
        lock.withLock {
            var bytes: [String: Int64] = [:]
            for transfer in received.values { bytes[transfer.file, default: 0] += transfer.bytes }
            for file in fallback where bytes[file.path] == nil {
                if !received.isEmpty && file.path.hasPrefix("(fetching)") { continue }
                bytes[file.path] = file.bytesAdded
            }
            return bytes.filter { $0.value > 0 }.map { .init(path: $0.key, bytesAdded: $0.value) }
                .sorted { $0.path < $1.path }
        }
    }

    func mergedFiles(_ saved: [ModelDownloadActivity.FileProgress]) -> [ModelDownloadActivity.FileProgress] {
        lock.withLock {
            let saved = files.isEmpty ? saved : saved.filter { !$0.id.hasPrefix("(fetching)") }
            var merged = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            for (name, file) in files { merged[name] = file }
            return merged.values.sorted {
                if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
                return $0.id < $1.id
            }
        }
    }

    func reading(including files: [ModelDownloadActivity.FileProgress]) -> Reading {
        let sdk = reading
        let completed = max(sdk.completed ?? 0, files.reduce(0) { $0 + $1.downloadedBytes })
        let total = max(sdk.total ?? 0, files.reduce(0) { $0 + max($1.totalBytes, $1.downloadedBytes) })
        guard total > 0 else { return sdk }
        return Reading(fraction: min(1, Double(completed) / Double(total)), completed: completed, total: total)
    }
    func update(_ progress: Progress) {
        lock.withLock {
            let fraction = progress.fractionCompleted
            value.fraction = fraction.isFinite ? max(0, min(1, fraction)) : 0
            if progress.totalUnitCount > 1 {
                value.completed = Int64((value.fraction * Double(min(progress.totalUnitCount, Int64.max / 2))).rounded())
                value.total = progress.totalUnitCount
            }
        }
    }
}
