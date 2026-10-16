// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
import Network
import os
@testable import SideWave

@MainActor
final class NetworkActivityTests: XCTestCase {
    override func setUp() async throws {
        URLProtocol.registerClass(TransparencyURLProtocol.self)
        TransparencyURLProtocol.setupSwizzling()
    }

    func testModelMetadataKeepsItsRedirectPolicyAndCacheHeaders() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_DOWNLOADS"] == "1" else {
            throw XCTSkip("Network integration requires SIDEWAVE_LIVE_DOWNLOADS=1")
        }
        let url = try XCTUnwrap(URL(string: "https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/resolve/main/model.safetensors"))
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransparencyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request, delegate: MetadataRedirectPolicy())
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 302)
        XCTAssertNotNil(http.value(forHTTPHeaderField: "X-Repo-Commit"))
        XCTAssertNotNil(http.value(forHTTPHeaderField: "X-Linked-Etag"))
        XCTAssertEqual(response.url?.host, "huggingface.co")
    }

    func testManagedRedirectAccountsDownloadedBytesOnce() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_DOWNLOADS"] == "1" else {
            throw XCTSkip("Network integration requires SIDEWAVE_LIVE_DOWNLOADS=1")
        }
        let repo = "mlx-community/gemma-4-e2b-it-4bit"
        let url = try XCTUnwrap(URL(string: "https://huggingface.co/\(repo)/resolve/main/tokenizer.json"))
        let before = Set(NetworkActivityLog.shared.events.map(\.id))
        ManagedDownloadScope.begin(repoID: repo)
        defer { ManagedDownloadScope.end(repoID: repo) }
        let updates = OSAllocatedUnfairLock(initialState: [ManagedDownloadScope.FileTransfer]())
        let observer = ManagedDownloadScope.observe(repoID: repo) { _, progress in
            updates.withLock { $0.append(progress) }
        }
        defer { ManagedDownloadScope.stopObserving(observer) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransparencyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fractions = OSAllocatedUnfairLock(initialState: [Double]())
        let (file, response) = try await ModelDownloadManager.downloadWithProgress(url: url, session: session,
            onFileProgress: { fraction in fractions.withLock { $0.append(fraction) } })
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let size = try Data(contentsOf: file).count
        XCTAssertGreaterThan(size, 1000)
        XCTAssertTrue(fractions.withLock { $0.contains { $0 > 0 && $0 < 1 } },
                      "Speech-model progress must advance while the payload is still arriving")
        let streamed = updates.withLock { $0 }
        XCTAssertTrue(streamed.contains { !$0.finished && $0.completed > 0 && $0.completed < Int64(size) },
                      "Payload progress must arrive before a forwarded download finishes")
        XCTAssertEqual(streamed.last?.received, Int64(size))
        XCTAssertTrue(streamed.last?.finished == true)
        for _ in 0..<100 {
            if NetworkActivityLog.shared.events.contains(where: { !before.contains($0.id) && $0.path == url.path && $0.direction == .incoming }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let incoming = NetworkActivityLog.shared.events.filter { !before.contains($0.id) && $0.direction == .incoming }
        XCTAssertEqual(incoming.count, 1, "Redirect hops must not duplicate downloaded bytes")
        XCTAssertEqual(incoming.reduce(Int64(0)) { $0 + $1.bytes }, Int64(size))
    }

    func testNetworkObserverRejectsUploadsAndRequestBodies() throws {
        let url = try XCTUnwrap(URL(string: "https://example.org/model"))
        for method in ["GET", "HEAD"] {
            var request = URLRequest(url: url); request.httpMethod = method
            XCTAssertTrue(TransparencyURLProtocol.permitsDownloadRequest(request))
            request.httpBody = Data("private dictation".utf8)
            XCTAssertFalse(TransparencyURLProtocol.permitsDownloadRequest(request))
            request.httpBody = nil; request.httpBodyStream = InputStream(data: Data())
            XCTAssertFalse(TransparencyURLProtocol.permitsDownloadRequest(request))
        }
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            var request = URLRequest(url: url); request.httpMethod = method
            XCTAssertFalse(TransparencyURLProtocol.permitsDownloadRequest(request))
        }
    }

    func testHTTPFailureAndCancelledTransferRemainVisibleWithoutQueryOrBody() async throws {
        XCTAssertTrue(AppPaths.isTestHost)
        let server = try NetworkHistoryHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransparencyURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identifier = UUID().uuidString
        let missing = root.appendingPathComponent("missing/" + identifier)
        var components = try XCTUnwrap(URLComponents(url: missing, resolvingAgainstBaseURL: false))
        components.queryItems = [.init(name: "fixture", value: "unlogged_marker")]
        let (data, response) = try await session.data(from: try XCTUnwrap(components.url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "fixture body")
        let slow = root.appendingPathComponent("slow/" + identifier)
        let pending = Task { try await session.data(from: slow) }
        try await Task.sleep(for: .milliseconds(200))
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("The unfinished response must be cancelled")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        session.invalidateAndCancel()
        for _ in 0..<200 {
            let events = NetworkActivityLog.shared.events.filter { $0.path.contains(identifier) }
            if events.contains(where: { $0.direction == .incoming && $0.detail.contains("cancelled") }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = NetworkActivityLog.shared.events.filter { $0.path.contains(identifier) }
        XCTAssertTrue(events.contains { $0.direction == .incoming && $0.detail.contains("HTTP 404") && $0.bytes == data.count })
        XCTAssertTrue(events.contains { $0.direction == .incoming && $0.detail.contains("cancelled") && $0.bytes > 0 })
        XCTAssertFalse(events.contains { ($0.path + $0.detail).contains("unlogged_marker") || $0.detail.contains("fixture body") })
    }

    func testUnreadableHistoryIsPreservedBeforeNewRequestsAreSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("network.json")
        let damaged = Data("[{\"host\":\"example.org\"".utf8)
        try damaged.write(to: url)
        let log = NetworkActivityLog(storageURL: url)
        log.record(.init(kind: .modelDownload, direction: .incoming, host: "example.org", path: "/model", bytes: 100))
        log.flush()
        let preserved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".corrupt-") })
        XCTAssertEqual(try Data(contentsOf: preserved), damaged)
        XCTAssertNotNil(log.persistenceError)
        XCTAssertEqual(NetworkActivityLog(storageURL: url).events.count, 1)
    }

    func testHistorySurvivesRestartWithoutDiscardingOlderDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("network.json")
        let log = NetworkActivityLog(storageURL: url)
        for index in 0..<700 {
            log.record(.init(kind: .modelDownload, direction: .incoming, host: "huggingface.co",
                             path: "/example/model/file_\(index)", bytes: 100))
        }
        let duplicate = try XCTUnwrap(log.events.first)
        log.record(duplicate)
        log.flush()
        XCTAssertNil(log.persistenceError)
        let reloaded = NetworkActivityLog(storageURL: url)
        XCTAssertEqual(reloaded.events.count, 700)
        XCTAssertEqual(reloaded.events.first?.id, duplicate.id)
        XCTAssertEqual(reloaded.totalIncomingBytes, 70_000)
        reloaded.clear()
        XCTAssertTrue(NetworkActivityLog(storageURL: url).events.isEmpty)
    }

    func testManagedDownloadDoesNotHideUnrelatedConcurrentModels() throws {
        let repo = "example/gemma"
        ManagedDownloadScope.begin(repoID: repo)
        ManagedDownloadScope.begin(repoID: repo)
        defer { ManagedDownloadScope.end(repoID: repo) }
        XCTAssertTrue(ManagedDownloadScope.ownsFile(at: try XCTUnwrap(URL(string: "https://huggingface.co/example/gemma/resolve/main/model.safetensors"))))
        XCTAssertFalse(ManagedDownloadScope.ownsFile(at: try XCTUnwrap(URL(string: "https://huggingface.co/FluidInference/speakers/resolve/main/model.bin"))))
        XCTAssertFalse(ManagedDownloadScope.ownsFile(at: try XCTUnwrap(URL(string: "https://huggingface.co/api/models/example/gemma/tree/main"))))
        XCTAssertFalse(ManagedDownloadScope.ownsFile(at: try XCTUnwrap(URL(string: "https://another.example/example/gemma/resolve/main/file"))))
        ManagedDownloadScope.end(repoID: repo)
        XCTAssertTrue(ManagedDownloadScope.ownsFile(at: try XCTUnwrap(URL(string: "https://huggingface.co/example/gemma/resolve/main/model.safetensors"))))
    }

    func testLiveProgressObserverIsScopedAndRemovedAfterPreparation() throws {
        let transfer = MLXTransferProgress()
        let id = ManagedDownloadScope.observe(repoID: "example/progress") { file, progress in
            transfer.updateFile(file, progress: progress)
        }
        let url = try XCTUnwrap(URL(string: "https://huggingface.co/example/progress/resolve/main/weights.bin"))
        let report = try XCTUnwrap(ManagedDownloadScope.progressReporter(for: url))
        XCTAssertNil(ManagedDownloadScope.progressReporter(for: try XCTUnwrap(URL(string: "https://huggingface.co/example/other/resolve/main/weights.bin"))))
        report(.init(requestID: UUID(), completed: 20, total: 100, received: 20, finished: false))
        XCTAssertEqual(transfer.mergedFiles([]).first?.id, "weights.bin")
        ManagedDownloadScope.stopObserving(id)
        XCTAssertNil(ManagedDownloadScope.progressReporter(for: url))
    }

    func testStorageFailureIsVisible() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = NetworkActivityLog(storageURL: url.appendingPathComponent("log.json"))
        log.record(.init(kind: .glossaryDownload, direction: .incoming, host: "raw.githubusercontent.com", path: "/example/catalog.json"))
        log.flush()
        XCTAssertNotNil(log.persistenceError)
        XCTAssertEqual(log.events.count, 1)
    }
}

private final class MetadataRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(task.originalRequest?.url?.host == request.url?.host ? request : nil)
    }
}

private final class NetworkHistoryHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [connections] connection in
            connections.withLock { $0.append(connection) }
            connection.start(queue: .global(qos: .utility))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let slow = String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("GET /slow/")
                let body = slow ? String(repeating: "x", count: 262_144) : "fixture body"
                let header = "HTTP/1.1 \(slow ? "200 OK" : "404 Not Found")\r\nContent-Length: \(slow ? 1_048_576 : body.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((header + body).utf8), completion: .contentProcessed { _ in
                    if !slow { connection.cancel() }
                })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                        continuation.resume(throwing: URLError(.badURL)); return
                    }
                    continuation.resume(returning: url)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
    }

    func stop() {
        listener.cancel()
        connections.withLock { active in
            active.forEach { $0.cancel() }
            active.removeAll()
        }
    }
}
