// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// A timed-out HAL worker still owns the input route until its cleanup finishes.
final class AudioSetupActivity: @unchecked Sendable {
    private static let shared = AudioSetupActivity()
    private let lock = NSLock()
    private var active = false

    static var isActive: Bool { shared.lock.withLock { shared.active } }
    static func begin() -> Bool {
        shared.lock.withLock {
            guard !shared.active else { return false }
            shared.active = true
            return true
        }
    }
    static func end() { shared.lock.withLock { shared.active = false } }
    static var busyError: NSError {
        NSError(domain: "SideWave.AudioSetup", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "The microphone is still preparing or closing. Wait a moment, then try again. If it stays stuck, reconnect the device or restart SideWave."])
    }
}

/// A HAL call can block a thread without responding to Swift cancellation.
/// Return at the deadline and dispose any resource that arrives after it.
final class AudioSetupOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var earlyResult: Result<Value, Error>?
    private var completed = false
    private var abandoned = false

    var isAbandoned: Bool { lock.withLock { abandoned } }

    private func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result: Result<Value, Error>? = lock.withLock {
            if let result = earlyResult {
                earlyResult = nil
                return result
            }
            self.continuation = continuation
            return nil as Result<Value, Error>?
        }
        if let result { continuation.resume(with: result) }
    }

    @discardableResult
    private func complete(_ result: Result<Value, Error>, abandoned: Bool = false,
                          beforeDelivery: () -> Void = {}) -> Bool {
        let delivery: (Bool, CheckedContinuation<Value, Error>?) = lock.withLock {
            guard !completed else { return (false, nil) }
            completed = true
            self.abandoned = abandoned
            beforeDelivery()
            let receiver = continuation
            continuation = nil
            if receiver == nil { earlyResult = result }
            return (true, receiver)
        }
        delivery.1?.resume(with: result)
        return delivery.0
    }

    static func run(
        timeout: TimeInterval,
        work: @escaping @Sendable (AudioSetupOperation<Value>) throws -> Value,
        dispose: @escaping @Sendable (Value) -> Void,
        workFinished: @escaping @Sendable () -> Void = {}
    ) async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw AudioSetupActivity.busyError }
                if AudioSetupActivity.begin() { break }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            workFinished()
            throw error
        }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let remainingSeconds = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
        let operation = AudioSetupOperation<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { workFinished() }
                    do {
                        guard !operation.isAbandoned else { throw CancellationError() }
                        let value = try work(operation)
                        if !operation.complete(.success(value), beforeDelivery: { AudioSetupActivity.end() }) {
                            dispose(value)
                            AudioSetupActivity.end()
                        }
                    } catch {
                        AudioSetupActivity.end()
                        operation.complete(.failure(error), abandoned: true)
                    }
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + remainingSeconds) {
                    operation.complete(.failure(NSError(
                        domain: "SideWave.AudioSetup", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The microphone did not respond. Reconnect it or choose another input, then try again."]
                    )), abandoned: true)
                }
            }
        } onCancel: {
            operation.complete(.failure(CancellationError()), abandoned: true)
        }
    }
}
