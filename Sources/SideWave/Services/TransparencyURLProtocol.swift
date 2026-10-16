// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import os

/// Observes HTTP traffic using default URLSession configurations.
/// Framework-owned processes also report through their explicit delegates.
public final class TransparencyURLProtocol: URLProtocol, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    
    private static let handledKey = "TransparencyURLProtocolHandled"
    private struct TransferState {
        var session: URLSession?
        var task: URLSessionDataTask?
        var bytes: Int64 = 0
        var response: URLResponse?
        var stopped = false
        var completed = false
        var accountedByDownloader = false
        var reportProgress: (@Sendable (ManagedDownloadScope.FileTransfer) -> Void)?
        let requestID = UUID()
        var resumeOffset: Int64 = 0
        var expectedBytes: Int64 = 0
    }
    private let transfer = OSAllocatedUnfairLock(initialState: TransferState())

    // MARK: - Swizzling Setup
    
    public static func setupSwizzling() {
        _ = swizzleDefaultGetter
    }
    
    private static let swizzleDefaultGetter: Void = {
        let originalSelector = #selector(getter: URLSessionConfiguration.default)
        let swizzledSelector = #selector(getter: URLSessionConfiguration.swizzledDefault)
        
        guard let originalMethod = class_getClassMethod(URLSessionConfiguration.self, originalSelector),
              let swizzledMethod = class_getClassMethod(URLSessionConfiguration.self, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    
    // MARK: - Overrides
    
    public override class func canInit(with request: URLRequest) -> Bool {
        // Prevent recursive loops
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }

        // Metadata delegates must see the original redirect and its headers.
        // Hugging Face uses HEAD to capture the commit and ETag before a CDN hop.
        // Payload bytes and their sources are recorded by the subsequent GET.
        if request.httpMethod?.uppercased() == "HEAD", permitsDownloadRequest(request) {
            return false
        }
        
        // Keep managed requests inside this forwarding session, including redirects.
        // Their downloader owns byte accounting; CDN redirects must not be counted again.
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        
        return true
    }
    
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    static func permitsDownloadRequest(_ request: URLRequest) -> Bool {
        ["GET", "HEAD"].contains(request.httpMethod?.uppercased() ?? "GET")
            && request.httpBody?.isEmpty != false && request.httpBodyStream == nil
    }

    public override func startLoading() {
        guard Self.permitsDownloadRequest(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.dataNotAllowed))
            Task { @MainActor [url = request.url] in
                NetworkActivityLog.shared.record(.init(kind: .other, direction: .outgoing,
                    host: url?.host ?? "", path: url?.path ?? "", bytes: 0,
                    detail: "Blocked non-download request; no data sent"))
            }
            return
        }
        transfer.withLock { state in
            state.accountedByDownloader = request.url.map { ManagedDownloadScope.ownsFile(at: $0) } ?? false
            state.reportProgress = request.url.flatMap { ManagedDownloadScope.progressReporter(for: $0) }
        }
        guard let mutableRequest = (self.request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            self.client?.urlProtocol(self, didFailWithError: NSError(domain: "TransparencyURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to copy request"]))
            return
        }
        
        // Mark request as handled to avoid infinite loops
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)
        
        let config = URLSessionConfiguration.ephemeral
        // Explicitly exclude our protocol from the ephemeral configuration to prevent loop
        config.protocolClasses = config.protocolClasses?.filter { $0 != TransparencyURLProtocol.self }
        
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: mutableRequest as URLRequest)
        let shouldStart = transfer.withLock { state in
            guard !state.stopped else { return false }
            state.session = session
            state.task = task
            return true
        }
        if shouldStart { task.resume() } else { session.invalidateAndCancel() }
    }
    
    public override func stopLoading() {
        let session = transfer.withLock { state in
            state.stopped = true
            let session = state.session
            state.task = nil
            state.session = nil
            return session
        }
        session?.invalidateAndCancel()
    }
    
    // MARK: - URLSessionDataDelegate / URLSessionTaskDelegate
    
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let stopped = transfer.withLock { state in
            state.response = response
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                state.expectedBytes = max(0, response.expectedContentLength)
                if http.statusCode == 206,
                   let range = http.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes "),
                   let start = range.dropFirst(6).split(separator: "-").first.flatMap({ Int64($0) }), start >= 0 {
                    state.resumeOffset = start
                    state.expectedBytes += start
                }
            } else {
                state.reportProgress = nil
            }
            return state.stopped
        }
        if !stopped { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        completionHandler(stopped ? .cancel : .allow)
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let snapshot = transfer.withLock { state -> TransferState in
            state.bytes += Int64(data.count)
            return state
        }
        if !snapshot.stopped {
            snapshot.reportProgress?(.init(requestID: snapshot.requestID,
                completed: snapshot.bytes + snapshot.resumeOffset, total: snapshot.expectedBytes,
                received: snapshot.bytes, finished: false))
            self.client?.urlProtocol(self, didLoad: data)
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let snapshot = transfer.withLock { state -> TransferState? in
            guard !state.completed else { return nil }
            state.completed = true
            let snapshot = state
            state.task = nil
            state.session = nil
            return snapshot
        }
        session.finishTasksAndInvalidate()
        guard let snapshot else { return }
        snapshot.reportProgress?(.init(requestID: snapshot.requestID,
            completed: snapshot.bytes + snapshot.resumeOffset, total: snapshot.expectedBytes,
            received: snapshot.bytes, finished: error == nil && !snapshot.stopped))
        if !snapshot.stopped {
            if let error { self.client?.urlProtocol(self, didFailWithError: error) }
            else { self.client?.urlProtocolDidFinishLoading(self) }
        }
        let failure: String?
        if snapshot.stopped || (error as? URLError)?.code == .cancelled { failure = "cancelled" }
        else if error != nil { failure = "request failed" }
        else if let response = snapshot.response as? HTTPURLResponse, !(200...399).contains(response.statusCode) {
            failure = "HTTP \(response.statusCode)"
        } else { failure = nil }
        if !snapshot.accountedByDownloader {
            logTransaction(bytes: max(snapshot.bytes, task.countOfBytesReceived), failureNote: failure)
        }
    }

    // MARK: - Logging Implementation
    
    private func logTransaction(bytes downloadBytes: Int64, failureNote: String? = nil) {
        guard let url = self.request.url,
              let host = url.host else {
            return
        }
        
        let path = url.path
        let httpMethod = self.request.httpMethod ?? "GET"
        
        // 1. Calculate outgoing (upload) bytes
        var uploadBytes: Int64 = 0
        if let body = self.request.httpBody {
            uploadBytes = Int64(body.count)
        } else if self.request.httpBodyStream != nil {
            // Best effort approximation if streaming
            uploadBytes = 0
        } else if let headerFields = self.request.allHTTPHeaderFields {
            // Rough check for Content-Length
            if let contentLengthString = headerFields["Content-Length"],
               let cl = Int64(contentLengthString) {
                uploadBytes = cl
            }
        }
        
        let isHF = host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host == "hf.co" || host.hasSuffix(".hf.co")

        // 4. Resolve the EventKind and metadata
        var kind: NetworkActivityLog.EventKind = .other
        var detail = ""

        if host.contains("sparkle-project") || path.contains("appcast.xml") {
            kind = .appUpdateCheck
            detail = "App update check"
        } else if path.hasSuffix(".dmg") || path.hasSuffix(".zip") {
            kind = .appUpdateDownload
            detail = "Downloading app update bundle"
        } else if isHF {
            if path.contains("api/models/") {
                kind = .modelManifest
                detail = "Querying HuggingFace model listing"
            } else if path.contains("/resolve/") || path.contains("/blobs/") {
                // A model file fetched outside the app's own downloader —
                // name the file so the transparency row is meaningful.
                kind = .modelDownload
                let file = (path as NSString).lastPathComponent
                detail = file.isEmpty ? "Model file download" : "Model file: \(file)"
            } else {
                kind = .modelDownload
                detail = "HuggingFace query"
            }
        }
        
        let localTimestamp = Date()
        
        // Log both uploads and downloads in a thread-safe way on MainActor
        Task { @MainActor in
            let log = NetworkActivityLog.shared
            
            // Request metadata never includes the body, headers or query.
            do {
                log.record(NetworkActivityLog.Event(
                    timestamp: localTimestamp,
                    kind: kind,
                    direction: .outgoing,
                    host: host,
                    path: path,
                    bytes: uploadBytes,
                    detail: "\(httpMethod) - \(detail.isEmpty ? "Network request" : detail)"
                ))
            }
            
            // Record the incoming response as a download event if we received any bytes
            if downloadBytes > 0 || failureNote != nil {
                let baseDetail = detail.isEmpty ? "\(httpMethod) Response" : detail
                log.record(NetworkActivityLog.Event(
                    timestamp: localTimestamp,
                    kind: kind,
                    direction: .incoming,
                    host: host,
                    path: path,
                    bytes: downloadBytes,
                    detail: failureNote.map { "\(baseDetail) (interrupted: \($0))" } ?? baseDetail
                ))
            }
        }
    }
}

// MARK: - Swizzling Helper Extension

extension URLSessionConfiguration {
    @objc class var swizzledDefault: URLSessionConfiguration {
        let sel = #selector(getter: URLSessionConfiguration.swizzledDefault)
        guard let config = URLSessionConfiguration.perform(sel)?.takeUnretainedValue() as? URLSessionConfiguration else {
            return URLSessionConfiguration.ephemeral
        }
        if var classes = config.protocolClasses {
            if !classes.contains(where: { $0 == TransparencyURLProtocol.self }) {
                classes.insert(TransparencyURLProtocol.self, at: 0)
                config.protocolClasses = classes
            }
        } else {
            config.protocolClasses = [TransparencyURLProtocol.self]
        }
        return config
    }
}
