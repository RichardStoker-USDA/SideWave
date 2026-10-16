// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import Foundation
import CryptoKit

/// Downloads the selected speech model into FluidAudio's cache directory.
/// Pre-populates the cache so FluidAudio's built-in downloader sees files and skips its own download.
///
/// Optimizations:
/// - Filters out .mlpackage source bundles (only .mlmodelc compiled files needed at runtime)
/// - Downloads up to 4 files concurrently via TaskGroup
/// - Thread-safe progress tracking via actor
enum ModelDownloadManager {

    // MARK: - richtext/ repo IDs

    static let ctcRepoID = "richtext/parakeet-ctc-110m-coreml"
    static let vadRepoID = "richtext/silero-vad-coreml"

    /// Maximum concurrent file downloads
    private static let maxConcurrent = 4

    /// Readiness must reject interrupted bundles even when their directories already exist.
    static func runtimeFilesPresent(at directory: URL, roots: Set<String>) -> Bool {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        for root in roots {
            let url = directory.appendingPathComponent(root)
            if url.pathExtension == "mlmodelc" {
                let metadata = url.appendingPathComponent("coremldata.bin")
                guard let values = try? metadata.resourceValues(forKeys: keys),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0,
                      let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return false }
                let mil = url.appendingPathComponent("model.mil")
                guard let source = try? String(contentsOf: mil, encoding: .utf8), !source.isEmpty,
                      let paths = try? NSRegularExpression(pattern: #"@model_path/([^"\n]+)"#) else { return false }
                let text = source as NSString
                let references = Set(paths.matches(in: source, range: NSRange(location: 0, length: text.length)).map {
                    text.substring(with: $0.range(at: 1))
                })
                for relative in references {
                    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return false }
                    let referencedFile = url.appendingPathComponent(relative)
                    guard let values = try? referencedFile.resourceValues(forKeys: keys),
                          values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
                }
                for case let file as URL in files {
                    if file.pathExtension == "partial" { return false }
                    guard let values = try? file.resourceValues(forKeys: keys) else { return false }
                    if values.isRegularFile == true, (values.fileSize ?? 0) == 0 { return false }
                }
            } else {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
            }
        }
        return !roots.isEmpty
    }

    // MARK: - File Filtering

    /// Files/directories to skip (not needed at runtime)
    private static func shouldDownload(_ filename: String) -> Bool {
        // Defense-in-depth: reject any filename that could escape the cache
        // directory via path traversal. URL.appendingPathComponent does NOT
        // normalize ".." segments, so a malicious or buggy upstream API
        // could land a file outside the intended cache root.
        if filename.hasPrefix("/") { return false }
        if filename.contains("..") { return false }
        // Skip .mlpackage source bundles (only .mlmodelc compiled models are needed)
        if filename.contains(".mlpackage") { return false }
        // Skip metadata files
        let skip = [".gitattributes", "README.md", ".DS_Store", "LICENSE"]
        if skip.contains(where: { filename.hasSuffix($0) || filename == $0 }) { return false }
        // Skip test audio files
        if filename.hasPrefix("test/") { return false }
        return true
    }

    // MARK: - Thread-Safe Progress Tracker

    private actor ProgressTracker {
        private let repoID: String
        private let displayName: String
        private let sessionID: UUID
        private let totalBytes: Int64
        private var fileSizes: [String: Int64] = [:]
        private var fileBytes: [String: Int64] = [:]
        private var finishedFiles: Set<String> = []
        private let onProgress: @Sendable (Double) -> Void

        init(
            repoID: String,
            displayName: String,
            sessionID: UUID,
            files: [RepoFile],
            onProgress: @Sendable @escaping (Double) -> Void
        ) {
            self.repoID = repoID
            self.displayName = displayName
            self.sessionID = sessionID
            self.totalBytes = Int64(files.reduce(0) { $0 + $1.size })
            self.onProgress = onProgress
            for file in files {
                self.fileSizes[file.rfilename] = Int64(file.size)
                self.fileBytes[file.rfilename] = 0
            }
        }

        func update(file: String, bytes: Int64) {
            guard !finishedFiles.contains(file), let size = fileSizes[file] else { return }
            fileBytes[file] = min(size, max(0, bytes))
            publishProgress(signalsRealDownload: bytes > 16384)
        }

        func complete(file: String, size: Int64, downloaded: Bool = true) {
            fileBytes[file] = size
            finishedFiles.insert(file)
            publishProgress(signalsRealDownload: downloaded)
        }

        private func publishProgress(signalsRealDownload: Bool) {
            guard totalBytes > 0 else { return }
            let completed = fileBytes.values.reduce(0, +)
            let fraction = min(1.0, Double(completed) / Double(totalBytes))
            
            var fileProgresses: [ModelDownloadActivity.FileProgress] = []
            for (filename, size) in fileSizes {
                let downloaded = fileBytes[filename] ?? 0
                let isFinished = finishedFiles.contains(filename)
                let progress = ModelDownloadActivity.FileProgress(
                    id: filename,
                    totalBytes: size,
                    downloadedBytes: downloaded,
                    finishedAt: isFinished ? Date() : nil
                )
                fileProgresses.append(progress)
            }
            fileProgresses.sort { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.id < rhs.id
            }

            let fileList = fileProgresses
            let session = sessionID
            Task { @MainActor in
                ModelDownloadActivity.shared.update(
                    files: fileList,
                    overall: fraction,
                    signalsRealDownload: signalsRealDownload,
                    sessionID: session
                )
            }
            onProgress(fraction)
        }
    }

    // MARK: - Custom Registry Resolver
    
    static func resolveRepoID(_ defaultRepoID: String) -> String {
        let customOwner = UserDefaults.standard.string(forKey: "customHuggingFaceOwner")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sanitizedOwner = customOwner.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !sanitizedOwner.isEmpty else { return defaultRepoID }
        let parts = defaultRepoID.split(separator: "/")
        if parts.count == 2 {
            return "\(sanitizedOwner)/\(parts[1])"
        }
        return defaultRepoID
    }

    // MARK: - Public API

    /// Download the selected speech model from its configured repository.
    static func download(
        version: ModelVersion,
        verifyCachedFiles: Bool = false,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        let repoID = resolveRepoID(version.repoID)
        let cacheDir = AsrModels.defaultCacheDirectory(for: version.asrVersion)

        if !verifyCachedFiles, version.isCached(at: cacheDir) {
            onProgress(1.0)
            return
        }

        try await downloadRepoConcurrent(repoID: repoID, displayName: version.displayName, to: cacheDir,
                                         allowedRoots: version.runtimeRoots, onProgress: onProgress)
    }

    /// Pre-populate CTC vocabulary boosting model from richtext/ mirror.
    static func downloadCTC(
        verifyCachedFiles: Bool = false,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        let cacheDir = CtcModels.defaultCacheDirectory(for: .ctc110m)

        if !verifyCachedFiles, CtcModels.modelsExist(at: cacheDir) {
            onProgress(1.0)
            return
        }

        let repoID = resolveRepoID(ctcRepoID)
        try await downloadRepoConcurrent(repoID: repoID, displayName: "CTC Boosting", to: cacheDir, onProgress: onProgress)
    }

    /// Pre-populate Silero VAD model from richtext/ mirror.
    static func downloadVAD(
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ModelDownloadError.invalidURL("Application Support directory unavailable")
        }
        let cacheDir = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("silero-vad-coreml", isDirectory: true)

        let expectedFile = cacheDir.appendingPathComponent("silero_vad_v6.mlmodelc")
        if FileManager.default.fileExists(atPath: expectedFile.path), hasCompleteManifest(in: cacheDir) {
            onProgress(1.0)
            return
        }

        let repoID = resolveRepoID(vadRepoID)
        try await downloadRepoConcurrent(repoID: repoID, displayName: "Silero VAD", to: cacheDir, onProgress: onProgress)
    }

    // MARK: - Concurrent Download Engine

    /// Downloads all runtime-needed files from a repo concurrently (up to maxConcurrent at a time).
    private static func downloadRepoConcurrent(
        repoID: String,
        displayName: String,
        to cacheDir: URL,
        allowedRoots: Set<String>? = nil,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // This engine records its own per-file transparency events (with real
        // byte counts), so silence the raw-layer interceptor for the duration
        // to avoid logging every transfer twice.
        ManagedDownloadScope.begin(repoID: repoID)
        defer { ManagedDownloadScope.end(repoID: repoID) }

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // List and filter files
        let allFiles = try await listRepoFiles(repoID: repoID, allowedRoots: allowedRoots)
        let files = allFiles.filter {
            guard shouldDownload($0.rfilename) else { return false }
            return allowedRoots == nil || allowedRoots!.contains(String($0.rfilename.split(separator: "/")[0]))
        }
        guard !files.isEmpty else { throw ModelDownloadError.emptyRepo(repoID) }

        // Pre-create directories and identify what needs downloading
        var needed: [RepoFile] = []
        var cached = Set<String>()
        var baselineBytes: Int64 = 0
        for file in files {
            let localPath = cacheDir.appendingPathComponent(file.rfilename)
            try FileManager.default.createDirectory(
                at: localPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if (try? validateDownload(at: localPath, expectedSize: Int64(file.size), sha256: file.sha256, gitBlob: file.gitBlob)) != nil {
                baselineBytes += Int64(file.size)
                cached.insert(file.rfilename)
                continue
            }

            needed.append(file)
        }
        needed.sort { $0.size > $1.size }

        let initialRepoID = repoID
        let initialDisplayName = displayName
        let initialBaseline = baselineBytes
        
        let sessionID = await MainActor.run {
            ModelDownloadActivity.shared.begin(
                displayName: initialDisplayName,
                repoID: initialRepoID,
                baselineBytes: initialBaseline
            )
        }

        let tracker = ProgressTracker(
            repoID: repoID,
            displayName: displayName,
            sessionID: sessionID,
            files: files,
            onProgress: onProgress
        )

        // Populate baseline/already completed files in tracker
        for file in files {
            if cached.contains(file.rfilename) {
                await tracker.complete(file: file.rfilename, size: Int64(file.size), downloaded: false)
            }
        }

        guard !needed.isEmpty else {
            try writeManifest(files, to: cacheDir)
            await MainActor.run {
                ModelDownloadActivity.shared.markComplete(sessionID: sessionID)
            }
            return
        }

        do {
            // Download up to maxConcurrent files at a time
            try await withThrowingTaskGroup(of: Void.self) { group in
                var active = 0
                var idx = 0

                while idx < needed.count {
                    while active < maxConcurrent, idx < needed.count {
                        let file = needed[idx]
                        idx += 1
                        active += 1

                        group.addTask {
                            let url = try resolveURL(repoID: repoID, filename: file.rfilename)
                            let fileBytes = Int64(file.size)
                            let fileName = file.rfilename
                            let identity = file.sha256 ?? file.gitBlob ?? String(file.size)
                            let resumeKey = SHA256.hash(data: Data((repoID + "/" + fileName + ":" + identity).utf8))
                                .map { String(format: "%02x", $0) }.joined()
                            let resumeURL = cacheDir.appendingPathComponent(".resume_" + resumeKey)

                            let (tempURL, response) = try await downloadWithProgress(url: url, resumeDataURL: resumeURL) { fraction in
                                let bytes = Int64(fraction * Double(fileBytes))
                                Task { await tracker.update(file: fileName, bytes: bytes) }
                            }

                            defer { try? FileManager.default.removeItem(at: tempURL) }
                            try Task.checkCancellation()
                            guard let http = response as? HTTPURLResponse,
                                   (200...299).contains(http.statusCode)
                            else { throw ModelDownloadError.downloadFailed(file.rfilename) }

                            try validateDownload(at: tempURL, expectedSize: fileBytes, sha256: file.sha256, gitBlob: file.gitBlob)
                            let localPath = cacheDir.appendingPathComponent(file.rfilename)
                            if FileManager.default.fileExists(atPath: localPath.path) {
                                _ = try FileManager.default.replaceItemAt(localPath, withItemAt: tempURL)
                            } else {
                                try FileManager.default.moveItem(at: tempURL, to: localPath)
                            }

                            await tracker.complete(file: file.rfilename, size: fileBytes)
                        }
                    }

                    try await group.next()
                    active -= 1
                }

                try await group.waitForAll()
            }

            try writeManifest(files, to: cacheDir)
            await MainActor.run {
                ModelDownloadActivity.shared.markComplete(sessionID: sessionID)
            }
        } catch {
            let errorMsg = error.localizedDescription
            await MainActor.run {
                ModelDownloadActivity.shared.markError(errorMsg, sessionID: sessionID)
            }
            throw error
        }
    }

    static func validateDownload(at url: URL, expectedSize: Int64, sha256: String? = nil, gitBlob: String? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              bytes > 0, expectedSize <= 0 || bytes == expectedSize else {
            throw ModelDownloadError.incompleteDownload
        }
        guard sha256 != nil || gitBlob != nil else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest256 = SHA256()
        var digest1 = Insecure.SHA1()
        if sha256 == nil { digest1.update(data: Data("blob \(bytes)\0".utf8)) }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            if sha256 != nil { digest256.update(data: data) } else { digest1.update(data: data) }
        }
        let actual = sha256 != nil
            ? digest256.finalize().map { String(format: "%02x", $0) }.joined()
            : digest1.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == (sha256 ?? gitBlob)?.lowercased() else { throw ModelDownloadError.checksumMismatch }
    }

    private static let manifestName = ".sidewave_download_manifest.json"

    private static func writeManifest(_ files: [RepoFile], to directory: URL) throws {
        try JSONEncoder().encode(files).write(to: directory.appendingPathComponent(manifestName), options: .atomic)
    }

    static func hasCompleteManifest(in directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
              let files = try? JSONDecoder().decode([RepoFile].self, from: data), !files.isEmpty else { return false }
        return files.allSatisfy { file in
            guard shouldDownload(file.rfilename), file.size > 0 else { return false }
            return (try? validateDownload(at: directory.appendingPathComponent(file.rfilename), expectedSize: Int64(file.size), sha256: file.sha256, gitBlob: file.gitBlob)) != nil
        }
    }

    // MARK: - Single File Download

    private final class TaskRef: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var isCancelled = false
        private let resumeDataURL: URL?

        init(resumeDataURL: URL?) { self.resumeDataURL = resumeDataURL }

        func preserve(_ data: Data?) {
            guard let data, !data.isEmpty, let resumeDataURL else { return }
            do {
                try data.write(to: resumeDataURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resumeDataURL.path)
            } catch { /* The next attempt can safely download this file again. */ }
        }

        func set(_ task: URLSessionDownloadTask) {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
            if isCancelled {
                task.cancel(byProducingResumeData: { [self] in preserve($0) })
            }
        }

        func finish() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            let bytes = task?.countOfBytesReceived ?? 0
            task = nil
            return bytes
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            task?.cancel(byProducingResumeData: { [self] in preserve($0) })
        }
    }

    /// URLSession owns range/ETag handling; completed files are still checksum-verified before installation.
    static func downloadWithProgress(
        url: URL,
        resumeDataURL: URL? = nil,
        session: URLSession = .shared,
        onFileProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let resumeData = resumeDataURL.flatMap { try? Data(contentsOf: $0) }
            do {
                let result = try await downloadAttempt(url: url, resumeDataURL: resumeDataURL,
                    resumeData: resumeData, session: session, onFileProgress: onFileProgress)
                if let resumeDataURL { try? FileManager.default.removeItem(at: resumeDataURL) }
                return result
            } catch {
                try Task.checkCancellation()
                let code = (error as? URLError)?.code
                let transientCodes: [URLError.Code] = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .badServerResponse]
                let transient = code.map { transientCodes.contains($0) } ?? false
                if resumeData != nil, !transient, let resumeDataURL {
                    try? FileManager.default.removeItem(at: resumeDataURL)
                }
                guard attempt < 2, transient || resumeData != nil else { throw error }
                try await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
            }
        }
        throw URLError(.networkConnectionLost)
    }

    private static func downloadAttempt(
        url: URL,
        resumeDataURL: URL?,
        resumeData: Data?,
        session: URLSession,
        onFileProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let taskRef = TaskRef(resumeDataURL: resumeDataURL)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { tempURL, response, error in
                    let receivedBytes = taskRef.finish()
                    let fileBytes = tempURL.flatMap {
                        (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value
                    }
                    let bytes = fileBytes ?? receivedBytes
                    let status = (response as? HTTPURLResponse)?.statusCode
                    let suffix: String
                    if (error as? URLError)?.code == .cancelled { suffix = " (cancelled)" }
                    else if error != nil { suffix = " (interrupted)" }
                    else if let status, !(200...299).contains(status) { suffix = " (HTTP \(status))" }
                    else { suffix = "" }
                    Task { @MainActor in
                        NetworkActivityLog.shared.recordDownload(kind: .modelDownload,
                            host: url.host ?? "", path: url.path, bytes: bytes,
                            detail: url.lastPathComponent + suffix)
                    }
                    if let error {
                        taskRef.preserve((error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
                        continuation.resume(throwing: error)
                        return
                    }
                    if let status, [408, 429, 500, 502, 503, 504].contains(status) {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    guard let tempURL, let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    let stableURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: tempURL, to: stableURL)
                        continuation.resume(returning: (stableURL, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let task = resumeData.map { session.downloadTask(withResumeData: $0, completionHandler: completion) }
                    ?? session.downloadTask(with: url, completionHandler: completion)

                taskRef.set(task)

                let observer = ProgressObserver(onUpdate: onFileProgress)
                task.progress.addObserver(observer, forKeyPath: "fractionCompleted", options: .new, context: nil)
                objc_setAssociatedObject(task, &ProgressObserver.associationKey, observer, .OBJC_ASSOCIATION_RETAIN)

                task.resume()
            }
        } onCancel: {
            taskRef.cancel()
        }
    }

    // MARK: - HuggingFace API

    private struct RepoFile: Codable {
        let rfilename: String
        let size: Int
        let sha256: String?
        let gitBlob: String?

        enum CodingKeys: String, CodingKey {
            case rfilename
            case size
            case sha256, gitBlob
        }
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int?
        let oid: String?
        let lfs: LFSInfo?

        struct LFSInfo: Decodable {
            let oid: String
        }
    }

    static func nextPageURL(link: String?, relativeTo current: URL) throws -> URL? {
        guard let link else { return nil }
        let pattern = #"<([^>]+)>\s*;\s*rel\s*=\s*"?next"?(?:[,;\s]|$)"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        guard let match = regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
              let range = Range(match.range(at: 1), in: link) else { return nil }
        guard let next = URL(string: String(link[range]), relativeTo: current)?.absoluteURL,
              next.scheme == "https", next.host == current.host, next.path == current.path,
              next.user == nil, next.password == nil, next.port == current.port else {
            throw ModelDownloadError.apiError("Invalid model manifest pagination")
        }
        return next
    }

    private static func listTreePages(at initial: URL, repoID: String) async throws -> [TreeEntry] {
        var next: URL? = initial
        var visited = Set<URL>()
        var entries: [TreeEntry] = []
        while let url = next {
            try Task.checkCancellation()
            guard visited.insert(url).inserted, visited.count <= 100 else {
                throw ModelDownloadError.apiError(repoID)
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw ModelDownloadError.apiError(repoID)
            }
            entries.append(contentsOf: try JSONDecoder().decode([TreeEntry].self, from: data))
            next = try nextPageURL(link: http.value(forHTTPHeaderField: "Link"), relativeTo: url)
        }
        return entries
    }

    private static func listRepoFiles(repoID: String, allowedRoots: Set<String>? = nil) async throws -> [RepoFile] {
        let urlString = "https://huggingface.co/api/models/\(repoID)/tree/main"
        guard let url = URL(string: urlString) else {
            throw ModelDownloadError.invalidURL(urlString)
        }

        let topLevel = try await listTreePages(at: url, repoID: repoID)
        var allFiles: [RepoFile] = []

        // Collect directories to list concurrently
        var directories: [String] = []
        for entry in topLevel {
            if let allowedRoots, !allowedRoots.contains(String(entry.path.split(separator: "/").first ?? "")) { continue }
            if entry.type == "file" {
                allFiles.append(RepoFile(rfilename: entry.path, size: entry.size ?? 0, sha256: entry.lfs?.oid, gitBlob: entry.lfs == nil ? entry.oid : nil))
            } else if entry.type == "directory" {
                // Skip .mlpackage directories entirely (saves dozens of API calls)
                if entry.path.contains(".mlpackage") { continue }
                directories.append(entry.path)
            }
        }

        // List subdirectories concurrently
        try await withThrowingTaskGroup(of: [RepoFile].self) { group in
            for dir in directories {
                group.addTask {
                    try await listTreeRecursive(repoID: repoID, path: dir)
                }
            }
            for try await subFiles in group {
                allFiles.append(contentsOf: subFiles)
            }
        }

        return allFiles
    }

    private static func listTreeRecursive(repoID: String, path: String, depth: Int = 0) async throws -> [RepoFile] {
        guard depth < 10 else { throw ModelDownloadError.apiError(repoID) }
        // Skip .mlpackage directories
        if path.contains(".mlpackage") { return [] }

        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let urlString = "https://huggingface.co/api/models/\(repoID)/tree/main/\(encoded)"
        guard let url = URL(string: urlString) else { throw ModelDownloadError.invalidURL(urlString) }

        let entries = try await listTreePages(at: url, repoID: repoID)
        var files: [RepoFile] = []

        var subdirs: [String] = []
        for entry in entries {
            if entry.type == "file" {
                files.append(RepoFile(rfilename: entry.path, size: entry.size ?? 0, sha256: entry.lfs?.oid, gitBlob: entry.lfs == nil ? entry.oid : nil))
            } else if entry.type == "directory" {
                if entry.path.contains(".mlpackage") { continue }
                subdirs.append(entry.path)
            }
        }

        // Recurse into subdirectories concurrently
        if !subdirs.isEmpty {
            try await withThrowingTaskGroup(of: [RepoFile].self) { group in
                for dir in subdirs {
                    group.addTask {
                        try await listTreeRecursive(repoID: repoID, path: dir, depth: depth + 1)
                    }
                }
                for try await subFiles in group {
                    files.append(contentsOf: subFiles)
                }
            }
        }

        return files
    }

    private static func resolveURL(repoID: String, filename: String) throws -> URL {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encoded)") else {
            throw URLError(.badURL)
        }
        return url
    }
}

// MARK: - Progress Observer

private final class ProgressObserver: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static var associationKey: UInt8 = 0

    private let onUpdate: @Sendable (Double) -> Void

    init(onUpdate: @Sendable @escaping (Double) -> Void) {
        self.onUpdate = onUpdate
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == "fractionCompleted",
              let fraction = change?[.newKey] as? Double else { return }
        onUpdate(fraction)
    }
}

// MARK: - Errors

enum ModelDownloadError: LocalizedError {
    case emptyRepo(String)
    case downloadFailed(String)
    case invalidURL(String)
    case apiError(String)
    case incompleteDownload
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .emptyRepo(let repo): return "No files found in repo: \(repo)"
        case .downloadFailed(let file): return "Failed to download: \(file)"
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .apiError(let repo): return "Could not list all model files for: \(repo). Check your connection and retry."
        case .incompleteDownload: return "A model file was incomplete. Retry the download to finish preparation."
        case .checksumMismatch: return "A model file failed verification. Retry the download to replace it."
        }
    }
}
