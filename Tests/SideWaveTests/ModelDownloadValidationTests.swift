// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class ModelDownloadValidationTests: XCTestCase {
    func testForwardedPayloadUpdatesProgressBeforeTheSDKFinishes() throws {
        let transfer = MLXTransferProgress()
        transfer.update(Progress(totalUnitCount: 1_100))
        let id = UUID()
        transfer.updateFile("weights.bin", progress: .init(requestID: id, completed: 250, total: 1_000,
            received: 250, finished: false))
        let saved = MLXDownloadInterceptor.buildFileProgress(snapshot: ["config.json": 100, "(fetching) hash": 250], baseline: [:])
        let files = transfer.mergedFiles(saved)
        XCTAssertEqual(files.count, 2)
        XCTAssertFalse(try XCTUnwrap(files.first { $0.id == "weights.bin" }).isFinished)
        XCTAssertEqual(transfer.reading(including: files).completed, 350)
        XCTAssertEqual(transfer.reading(including: files).total, 1_100)
        transfer.updateFile("weights.bin", progress: .init(requestID: id, completed: 1_000, total: 1_000,
            received: 1_000, finished: true))
        XCTAssertEqual(transfer.reading(including: transfer.mergedFiles(saved)).fraction, 1)
    }

    func testRetriedPayloadAccountsReceivedBytesWithoutCountingResumeOffsetTwice() {
        let transfer = MLXTransferProgress()
        let first = UUID(), retry = UUID()
        transfer.updateFile("weights.bin", progress: .init(requestID: first, completed: 250, total: 1_000,
            received: 250, finished: false))
        transfer.updateFile("weights.bin", progress: .init(requestID: first, completed: 400, total: 1_000,
            received: 400, finished: false))
        XCTAssertEqual(transfer.downloadedFiles(fallback: []).first?.bytesAdded, 400)
        transfer.updateFile("weights.bin", progress: .init(requestID: retry, completed: 1_000, total: 1_000,
            received: 600, finished: true))
        let log = transfer.downloadedFiles(fallback: [.init(path: "weights.bin", bytesAdded: 1_000),
                                                     .init(path: "config.json", bytesAdded: 100)])
        XCTAssertEqual(log.first { $0.path == "weights.bin" }?.bytesAdded, 1_000)
        XCTAssertEqual(log.first { $0.path == "config.json" }?.bytesAdded, 100)
    }

    func testNestedSDKProgressIncludesFilesStillInFlight() {
        let total = Progress(totalUnitCount: 1_000)
        let file = Progress(totalUnitCount: 100, parent: total, pendingUnitCount: 1_000)
        file.completedUnitCount = 25
        let transfer = MLXTransferProgress()
        transfer.update(total)
        XCTAssertEqual(transfer.reading.completed, 250)
        XCTAssertEqual(transfer.reading.total, 1_000)
    }
    @MainActor
    func testTransferTotalsStallsAndRetriesStayTruthful() {
        let activity = ModelDownloadActivity()
        let id = activity.begin(displayName: "Language model", repoID: "example/language", baselineBytes: 500)
        let start = Date(timeIntervalSince1970: 1_000)
        activity.update(files: [], overall: 0.5, signalsRealDownload: true, sessionID: id,
                        downloadedBytes: 500, totalBytes: 1_000, now: start)
        activity.update(files: [], overall: 0.6, signalsRealDownload: true, sessionID: id,
                        downloadedBytes: 600, totalBytes: 1_000, now: start.addingTimeInterval(1))
        XCTAssertEqual(activity.session?.totalBytes, 1_000)
        XCTAssertEqual(activity.session?.downloadedBytes, 600)
        XCTAssertEqual(activity.transferRate(at: start.addingTimeInterval(1)), 100)
        XCTAssertNil(activity.transferRate(at: start.addingTimeInterval(7)))
        activity.setStage(.verifying, sessionID: id)
        activity.update(files: [], overall: 1, signalsRealDownload: true, sessionID: id)
        XCTAssertEqual(activity.session?.stage, .verifying)
        XCTAssertNil(activity.transferRate(at: start.addingTimeInterval(2)))
        activity.markError("Connection interrupted", sessionID: id)
        let retry = activity.begin(displayName: "Language model", repoID: "example/language", baselineBytes: 600)
        XCTAssertEqual(activity.sessions.count, 1)
        XCTAssertEqual(activity.session?.id, retry)
        activity.update(files: [], overall: .nan, signalsRealDownload: false, sessionID: retry)
        XCTAssertEqual(activity.session?.overallFraction, 0)
    }

    @MainActor
    func testSelectingCompletedModelCannotCloseAnActiveDownload() {
        let activity = ModelDownloadActivity()
        let first = activity.begin(displayName: "First", repoID: "example/first", baselineBytes: 0)
        let second = activity.begin(displayName: "Second", repoID: "example/second", baselineBytes: 0)
        activity.markComplete(sessionID: first)
        activity.showSession(first)
        XCTAssertFalse(activity.allTransfersFinished)
        activity.markComplete(sessionID: second)
        XCTAssertTrue(activity.allTransfersFinished)
    }

    @MainActor
    func testConcurrentDownloadsKeepTheirProgressAndFailures() {
        let activity = ModelDownloadActivity()
        let first = activity.begin(displayName: "Language model", repoID: "example/language", baselineBytes: 0)
        let second = activity.begin(displayName: "Speech model", repoID: "example/speech", baselineBytes: 0)
        activity.update(files: [], overall: 0.3, signalsRealDownload: true, sessionID: first)
        activity.update(files: [], overall: 0.8, signalsRealDownload: true, sessionID: second)
        XCTAssertEqual(activity.session?.id, first)
        XCTAssertEqual(activity.otherDownloads.first?.overallFraction, 0.8)
        activity.markComplete(sessionID: first)
        XCTAssertEqual(activity.session?.id, second)
        XCTAssertNil(activity.session?.completedAt)
        activity.markError("Connection interrupted", sessionID: second)
        activity.markComplete(sessionID: second)
        activity.update(files: [], overall: 1, signalsRealDownload: true, sessionID: second)
        XCTAssertEqual(activity.session?.error, "Connection interrupted")
        XCTAssertEqual(activity.session?.overallFraction, 0.8)
        activity.clear()
        XCTAssertNil(activity.session)
    }

    func testReadinessRejectsMissingRuntimeFilesAndInterruptedBundles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = directory.appendingPathComponent("Encoder.mlmodelc")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let roots: Set<String> = ["Encoder.mlmodelc", "vocab.json"]
        XCTAssertFalse(ModelDownloadManager.runtimeFilesPresent(at: directory, roots: roots))
        try Data([1]).write(to: model.appendingPathComponent("coremldata.bin"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("vocab.json"))
        XCTAssertFalse(ModelDownloadManager.runtimeFilesPresent(at: directory, roots: roots))
        try Data("program {}".utf8).write(to: model.appendingPathComponent("model.mil"))
        XCTAssertTrue(ModelDownloadManager.runtimeFilesPresent(at: directory, roots: roots))
        let partial = model.appendingPathComponent("weight.bin.partial")
        try Data([1]).write(to: partial)
        XCTAssertFalse(ModelDownloadManager.runtimeFilesPresent(at: directory, roots: roots))
        try FileManager.default.removeItem(at: partial)
        try Data().write(to: model.appendingPathComponent("weight.bin"))
        XCTAssertFalse(ModelDownloadManager.runtimeFilesPresent(at: directory, roots: roots))
    }

    func testCompiledModelReadinessRequiresReferencedWeights() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = directory.appendingPathComponent("Encoder.mlmodelc")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: model.appendingPathComponent("coremldata.bin"))
        try Data(#"BLOBFILE(path = tensor<string, []>("@model_path/weights/data.bin"))"#.utf8)
            .write(to: model.appendingPathComponent("model.mil"))
        XCTAssertFalse(ModelDownloadManager.runtimeFilesPresent(at: directory, roots: ["Encoder.mlmodelc"]))
        let weights = model.appendingPathComponent("weights/data.bin")
        try FileManager.default.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: weights)
        XCTAssertTrue(ModelDownloadManager.runtimeFilesPresent(at: directory, roots: ["Encoder.mlmodelc"]))
        try Data(#"BLOBFILE(path = tensor<string, []>("@model_path/../data.bin"))"#.utf8)
            .write(to: model.appendingPathComponent("model.mil"))
        XCTAssertFalse(ModelDownloadManager.runtimeFilesPresent(at: directory, roots: ["Encoder.mlmodelc"]))
    }

    func testGemmaSnapshotRequiresTokenizerAndAllWeightShards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model-00001-of-00002.safetensors"] {
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        try Data(#"{"weight_map":{"first":"model-00001-of-00002.safetensors","second":"model-00002-of-00002.safetensors"}}"#.utf8).write(to: index)
        XCTAssertFalse(MeetingFormatterBackend.isCompleteSnapshot(directory))
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))
        XCTAssertTrue(MeetingFormatterBackend.isCompleteSnapshot(directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("tokenizer.json"))
        XCTAssertFalse(MeetingFormatterBackend.isCompleteSnapshot(directory))
    }

    func testGemmaSnapshotSupportsSingleWeightsAndRejectsInvalidIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
        XCTAssertTrue(MeetingFormatterBackend.isCompleteSnapshot(directory))
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        try Data(#"{"weight_map":{"first":"../model.safetensors"}}"#.utf8).write(to: index)
        XCTAssertFalse(MeetingFormatterBackend.isCompleteSnapshot(directory))
        try Data("invalid".utf8).write(to: index)
        XCTAssertFalse(MeetingFormatterBackend.isCompleteSnapshot(directory))
    }

    func testPartialOrEmptyModelIsNeverAcceptedAsReady() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        XCTAssertThrowsError(try ModelDownloadManager.validateDownload(at: url, expectedSize: 10))
        XCTAssertNoThrow(try ModelDownloadManager.validateDownload(at: url, expectedSize: 3))
        try Data().write(to: url)
        XCTAssertThrowsError(try ModelDownloadManager.validateDownload(at: url, expectedSize: 0))
    }

    func testManifestPaginationFollowsOnlyTheSameEndpoint() throws {
        let current = try XCTUnwrap(URL(string: "https://huggingface.co/api/models/example/model/tree/main"))
        let next = current.absoluteString + "?cursor=next"
        XCTAssertEqual(try ModelDownloadManager.nextPageURL(link: "<\(next)>; rel=\"next\"", relativeTo: current)?.absoluteString, next)
        XCTAssertNil(try ModelDownloadManager.nextPageURL(link: nil, relativeTo: current))
        XCTAssertNil(try ModelDownloadManager.nextPageURL(link: "<\(next)>; rel=\"prev\"", relativeTo: current))
        XCTAssertThrowsError(try ModelDownloadManager.nextPageURL(link: "<https://other.invalid/files>; rel=\"next\"", relativeTo: current))
        XCTAssertThrowsError(try ModelDownloadManager.nextPageURL(link: "<http://huggingface.co/api/models/example/model/tree/main>; rel=\"next\"", relativeTo: current))
    }

    func testSameSizeCorruptionFailsChecksumVerification() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data("abc".utf8).write(to: url)
        XCTAssertNoThrow(try ModelDownloadManager.validateDownload(at: url, expectedSize: 3, sha256: sha256))
        XCTAssertNoThrow(try ModelDownloadManager.validateDownload(at: url, expectedSize: 3, gitBlob: "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f"))
        try Data("abd".utf8).write(to: url)
        XCTAssertThrowsError(try ModelDownloadManager.validateDownload(at: url, expectedSize: 3, sha256: sha256))
        XCTAssertThrowsError(try ModelDownloadManager.validateDownload(at: url, expectedSize: 3, gitBlob: "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f"))
    }

    func testCachedManifestRequiresEveryFileToBeComplete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent(".sidewave_download_manifest.json")
        try Data(#"[{"rfilename":"weights.bin","size":3}]"#.utf8).write(to: manifest)
        XCTAssertFalse(ModelDownloadManager.hasCompleteManifest(in: directory))
        let weights = directory.appendingPathComponent("weights.bin")
        try Data([1, 2]).write(to: weights)
        XCTAssertFalse(ModelDownloadManager.hasCompleteManifest(in: directory))
        try Data([1, 2, 3]).write(to: weights)
        XCTAssertTrue(ModelDownloadManager.hasCompleteManifest(in: directory))
        try Data(#"[{"rfilename":"../weights.bin","size":3}]"#.utf8).write(to: manifest)
        XCTAssertFalse(ModelDownloadManager.hasCompleteManifest(in: directory))
    }
}

private final class ModelTransferProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts = 0
    nonisolated(unsafe) private static var failuresRemaining = 0

    static func configure(failures: Int) {
        lock.withLock { attempts = 0; failuresRemaining = failures }
    }
    static var requestCount: Int { lock.withLock { attempts } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "model.test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fail = Self.lock.withLock {
            Self.attempts += 1
            if Self.failuresRemaining > 0 { Self.failuresRemaining -= 1; return true }
            return false
        }
        if fail { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let data = Data("download fixture".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count), "ETag": "fixture"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModelDownloadTransportTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelTransferProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testTransientNetworkFailureRetriesAndReturnsTheDownloadedFile() async throws {
        ModelTransferProtocol.configure(failures: 1)
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://model.test.invalid/weights.bin"))
        let (file, response) = try await ModelDownloadManager.downloadWithProgress(url: url, session: session, onFileProgress: { _ in })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data("download fixture".utf8))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(ModelTransferProtocol.requestCount, 2)
    }

    func testCancellationDuringRetryDoesNotStartAnotherRequest() async throws {
        ModelTransferProtocol.configure(failures: 10)
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://model.test.invalid/weights.bin"))
        let task = Task { try await ModelDownloadManager.downloadWithProgress(url: url, session: session, onFileProgress: { _ in }) }
        let deadline = Date().addingTimeInterval(2)
        while ModelTransferProtocol.requestCount == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do {
            let result = try await task.value
            try? FileManager.default.removeItem(at: result.0)
            XCTFail("Cancelled transfer unexpectedly completed")
        } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(ModelTransferProtocol.requestCount, 1)
    }

    func testInvalidResumeDataFallsBackToAFreshRequest() async throws {
        ModelTransferProtocol.configure(failures: 0)
        let session = session()
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resume = root.appendingPathComponent("resume.data")
        try Data("unreadable resume state".utf8).write(to: resume)
        let url = try XCTUnwrap(URL(string: "https://model.test.invalid/weights.bin"))
        let (file, _) = try await ModelDownloadManager.downloadWithProgress(url: url, resumeDataURL: resume, session: session, onFileProgress: { _ in })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data("download fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path))
        XCTAssertEqual(ModelTransferProtocol.requestCount, 1)
    }

    func testRepeatedNetworkFailureStopsAfterThreeAttempts() async throws {
        ModelTransferProtocol.configure(failures: 10)
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://model.test.invalid/weights.bin"))
        do {
            _ = try await ModelDownloadManager.downloadWithProgress(url: url, session: session, onFileProgress: { _ in })
            XCTFail("Expected the bounded retry to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(ModelTransferProtocol.requestCount, 3)
    }
}
