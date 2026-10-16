// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// A stalled model stream must not hold the caller past its deadline.
final class RefineDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var earlyResult: Result<String, Error>?
    private var completed = false
    private var tasks: [Task<Void, Never>] = []

    private func install(_ receiver: CheckedContinuation<String, Error>) -> Bool {
        let result = lock.withLock { () -> Result<String, Error>? in
            if let result = earlyResult {
                earlyResult = nil
                return result
            }
            continuation = receiver
            return nil
        }
        if let result { receiver.resume(with: result); return false }
        return true
    }

    private func retain(_ tasks: [Task<Void, Never>]) {
        let cancel = lock.withLock {
            if completed { return true }
            self.tasks = tasks
            return false
        }
        if cancel { tasks.forEach { $0.cancel() } }
    }

    private func finish(_ result: Result<String, Error>) {
        let delivery = lock.withLock { () -> (CheckedContinuation<String, Error>?, [Task<Void, Never>]) in
            guard !completed else { return (nil, []) }
            completed = true
            let receiver = continuation
            continuation = nil
            if receiver == nil { earlyResult = result }
            let pending = tasks
            tasks = []
            return (receiver, pending)
        }
        delivery.1.forEach { $0.cancel() }
        delivery.0?.resume(with: result)
    }

    static func run(
        timeout: Duration,
        work: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let deadline = RefineDeadline()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard deadline.install(continuation) else { return }
                let worker = Task.detached {
                    do {
                        try Task.checkCancellation()
                        deadline.finish(.success(try await work()))
                    } catch {
                        deadline.finish(.failure(error))
                    }
                }
                let timer = Task.detached {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    deadline.finish(.failure(RefinerFailure.timedOut))
                }
                deadline.retain([worker, timer])
            }
        } onCancel: {
            deadline.finish(.failure(CancellationError()))
        }
    }
}
