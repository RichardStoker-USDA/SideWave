// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import XCTest
@testable import SideWave

final class ModelSnapshotValidationTests: XCTestCase {
    @MainActor
    func testLiveRepairReusesWeightsInAnIsolatedCache() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODEL_DOWNLOADS"] == "1" else {
            throw XCTSkip("Live cache repair requires explicit download-test opt-in")
        }
        let repoID = "mlx-community/gemma-4-e2b-it-4bit"
        let source = MLXDownloadInterceptor.expectedDestination(for: repoID)
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("A prepared E2B cache is required to seed the isolated repair test") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = MLXDownloadInterceptor.expectedDestination(for: repoID, cacheRoot: root)
        try FileManager.default.copyItem(at: source, to: destination)
        let cache = HubCache(cacheDirectory: root)
        let snapshot = try XCTUnwrap(ModelSnapshotValidation.cachedSnapshot(repoID: repoID, cache: cache))
        try ModelSnapshotValidation.validate(at: snapshot)
        let before = await MLXDownloadInterceptor.snapshot(at: snapshot)
        try ModelSnapshotValidation.removeInvalidFiles(["tokenizer_config.json", "chat_template.jinja"], at: snapshot, cacheRoot: root)
        XCTAssertFalse(ModelSnapshotValidation.invalidFiles(at: snapshot).isEmpty)
        let client = HubClient(host: try XCTUnwrap(URL(string: "https://huggingface.co")), cache: cache)
        let downloader = MLXDownloadInterceptor(upstream: #hubDownloader(client), displayName: "Gemma 4 E2B", cache: cache)
        let previousIDs = Set(NetworkActivityLog.shared.events.map(\.id))
        let started = Date()
        let restored = try await downloader.download(id: repoID, revision: "main", matching: ["*.json", "*.safetensors", "*.jinja"], useLatest: false, progressHandler: { _ in })
        try ModelSnapshotValidation.validate(at: restored)
        _ = try await ModelTokenizerLoader().load(from: restored)
        let after = await MLXDownloadInterceptor.snapshot(at: restored)
        for (file, bytes) in before where file.hasSuffix(".safetensors") { XCTAssertEqual(after[file], bytes) }
        let downloaded = NetworkActivityLog.shared.events.filter { !previousIDs.contains($0.id) && $0.kind == .modelDownload }
        XCTAssertFalse(downloaded.isEmpty)
        XCTAssertFalse(downloaded.contains { $0.path.hasSuffix(".safetensors") })
        print("MODEL_REPAIR_SECONDS \(Date().timeIntervalSince(started))")
        print("MODEL_REPAIR_FILES \(downloaded.count)")
        let eventCount = NetworkActivityLog.shared.events.count
        _ = try await downloader.download(id: repoID, revision: "main", matching: ["*.json", "*.safetensors", "*.jinja"], useLatest: false, progressHandler: { _ in })
        XCTAssertEqual(NetworkActivityLog.shared.events.count, eventCount, "A valid cached model needs no network request")
    }
    func testRepairPinsCachedRevisionEvenWhenConfigurationIsMissing() async throws {
        let source = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HubCache(cacheDirectory: root)
        let id = try XCTUnwrap(Repo.ID(rawValue: "example/model"))
        let commit = String(repeating: "a", count: 40)
        let directory = cache.snapshotsDirectory(repo: id, kind: .model).appendingPathComponent(commit)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: directory)
        let refs = cache.refsDirectory(repo: id, kind: .model)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(commit.utf8).write(to: refs.appendingPathComponent("main"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("config.json"))
        XCTAssertEqual(ModelSnapshotValidation.cachedSnapshot(repoID: id.rawValue, cache: cache)?.path, directory.path)
        let upstream = SnapshotRepairDownloader(directory: directory, source: source)
        let downloader = MLXDownloadInterceptor(upstream: upstream, displayName: "Fixture", cache: cache)
        let repaired = try await downloader.download(id: id.rawValue, revision: "main", matching: ["*.json", "*.safetensors", "*.jinja"], useLatest: false, progressHandler: { _ in })
        XCTAssertEqual(repaired, directory)
        let revisions = await upstream.revisions
        XCTAssertEqual(revisions, [commit])
        try ModelSnapshotValidation.validate(at: repaired)
        _ = try await downloader.download(id: id.rawValue, revision: "main", matching: ["*"], useLatest: false, progressHandler: { _ in })
        let cachedCalls = await upstream.revisions
        XCTAssertEqual(cachedCalls.count, 1)
    }

    func testReplacementDownloadsAreLoggedEvenWhenNewFileIsSmaller() {
        let changes = MLXDownloadInterceptor.diffSnapshots(before: ["weights": 100, "same": 20], after: ["weights": 90, "same": 20, "template": 10])
        XCTAssertEqual(changes.map(\.path), ["weights", "template"])
        XCTAssertEqual(changes.map(\.bytesAdded), [90, 10])
    }

    func testSameSizeBlobReplacementIsStillARecordedDownload() async throws {
        let root = try fixture()
        let snapshot = root.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first_blob")
        let second = root.appendingPathComponent("second_blob")
        try Data("old".utf8).write(to: first)
        try Data("new".utf8).write(to: second)
        let file = snapshot.appendingPathComponent("template.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: first)
        let before = await MLXDownloadInterceptor.fileIdentities(at: snapshot)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: second)
        let after = await MLXDownloadInterceptor.fileIdentities(at: snapshot)
        let changes = MLXDownloadInterceptor.diffSnapshots(before: ["template.json": 3], after: ["template.json": 3], beforeIdentities: before, afterIdentities: after)
        XCTAssertEqual(changes.map(\.path), ["template.json"])
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model_type":"gemma4"}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        try Data(#"{"model":{"vocab":{"hello":1}}}"#.utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        try Data(#"{"tokenizer_class":"GemmaTokenizer"}"#.utf8).write(to: root.appendingPathComponent("tokenizer_config.json"))
        try Data("{% for message in messages %}{{ message.content }}{% endfor %}".utf8)
            .write(to: root.appendingPathComponent("chat_template.jinja"))
        let header = Data(#"{"weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header); data.append(contentsOf: [0, 0, 0, 0])
        try data.write(to: root.appendingPathComponent("model.safetensors"))
        return root
    }

    func testCompleteModelAndMissingTokenizerAreDistinguished() throws {
        let root = try fixture()
        XCTAssertNoThrow(try ModelSnapshotValidation.validate(at: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(ModelSnapshotValidation.invalidFiles(at: root), ["tokenizer.json"])
    }

    func testEveryIndexedShardAndTemplateAreRequired() throws {
        let root = try fixture()
        try Data(#"{"weight_map":{"one":"model.safetensors","two":"model-00002.safetensors"}}"#.utf8)
            .write(to: root.appendingPathComponent("model.safetensors.index.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("chat_template.jinja"))
        XCTAssertEqual(ModelSnapshotValidation.invalidFiles(at: root), ["chat_template.jinja", "model-00002.safetensors"])
    }

    func testTruncatedWeightsAndMalformedJSONAreRejected() throws {
        let root = try fixture()
        let file = try FileHandle(forWritingTo: root.appendingPathComponent("model.safetensors"))
        try file.truncate(atOffset: 20); try file.close()
        try Data("{broken".utf8).write(to: root.appendingPathComponent("tokenizer_config.json"))
        XCTAssertEqual(ModelSnapshotValidation.invalidFiles(at: root), ["model.safetensors", "tokenizer_config.json"])
    }

    func testRepairPreservesGoodShardsAndCannotEscapeCache() throws {
        let root = try fixture()
        let snapshot = root.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let blob = root.appendingPathComponent("corrupt_blob")
        try Data("broken".utf8).write(to: blob)
        let link = snapshot.appendingPathComponent("tokenizer.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        try ModelSnapshotValidation.removeInvalidFiles(["tokenizer.json", "../model.safetensors"], at: snapshot, cacheRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("model.safetensors").path))
    }

    func testSnapshotInspectionAcceptsReturnedSnapshotDirectory() async throws {
        let root = try fixture()
        let files = await MLXDownloadInterceptor.snapshot(at: root)
        XCTAssertNotNil(files["tokenizer.json"], "Files: \(files.keys.sorted())")
        XCTAssertNotNil(files["model.safetensors"], "Files: \(files.keys.sorted())")
        let progress = MLXDownloadInterceptor.buildFileProgress(snapshot: ["(fetching) abc": 4000], baseline: [:])
        XCTAssertFalse(try XCTUnwrap(progress.first).isFinished)
        XCTAssertEqual(progress.first?.totalBytes, 0)
        XCTAssertEqual(progress.first?.fraction, 0)
    }

    func testRepairDoesNotFollowLinkedDirectoriesOutsideCache() throws {
        let root = try fixture()
        let external = try fixture()
        let linkedSnapshot = root.appendingPathComponent("linked_snapshot")
        try FileManager.default.createSymbolicLink(at: linkedSnapshot, withDestinationURL: external)
        try ModelSnapshotValidation.removeInvalidFiles(["tokenizer.json"], at: linkedSnapshot, cacheRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("tokenizer.json").path))

        let snapshot = root.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("linked_folder"), withDestinationURL: external)
        try ModelSnapshotValidation.removeInvalidFiles(["linked_folder/tokenizer.json"], at: snapshot, cacheRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("tokenizer.json").path))

        let linkedFile = snapshot.appendingPathComponent("tokenizer.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: external.appendingPathComponent("tokenizer.json"))
        try ModelSnapshotValidation.removeInvalidFiles(["tokenizer.json"], at: snapshot, cacheRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("tokenizer.json").path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: linkedFile.path))
    }
}

private actor SnapshotRepairDownloader: Downloader {
    let directory: URL
    let source: URL
    private(set) var revisions: [String?] = []
    init(directory: URL, source: URL) { self.directory = directory; self.source = source }
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        revisions.append(revision)
        try FileManager.default.copyItem(at: source.appendingPathComponent("config.json"), to: directory.appendingPathComponent("config.json"))
        return directory
    }
}
