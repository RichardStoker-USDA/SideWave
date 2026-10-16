// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
@testable import SideWaveKit

/// Shared call log so tests can assert cross-subsystem ordering
/// (audio.stop before recognizer.finish before paster.paste).
actor CallRecorder {
    private(set) var calls: [String] = []
    func note(_ call: String) { calls.append(call) }
    func index(of call: String) -> Int? { calls.firstIndex(of: call) }
    func count(of call: String) -> Int { calls.filter { $0 == call }.count }
}

enum MockFailure: Error, LocalizedError {
    case rigged(String)
    var errorDescription: String? {
        if case .rigged(let s) = self { return s }
        return nil
    }
}

actor MockAudioSource: AudioSource {
    enum StartBehavior {
        case succeed(deviceName: String)
        case fail(message: String)
        /// start() returns, but no samples ever arrive (dead mic).
        case succeedSilent(deviceName: String)
    }

    private let recorder: CallRecorder
    private var behavior: StartBehavior
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastPreferredUID: String??

    init(recorder: CallRecorder, behavior: StartBehavior = .succeed(deviceName: "Mock Microphone")) {
        self.recorder = recorder
        self.behavior = behavior
    }

    func setBehavior(_ behavior: StartBehavior) { self.behavior = behavior }

    func start(
        preferredDeviceUID: String?,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) async throws -> String {
        startCount += 1
        lastPreferredUID = preferredDeviceUID
        await recorder.note("audio.start")
        switch behavior {
        case .succeed(let name), .succeedSilent(let name):
            self.onSamples = onSamples
            return name
        case .fail(let message):
            throw MockFailure.rigged(message)
        }
    }

    func stop() async {
        stopCount += 1
        onSamples = nil
        await recorder.note("audio.stop")
    }

    /// Test hook: push capture buffers as the device would.
    func emit(_ samples: [Float]) {
        onSamples?(samples)
    }

    var isCapturing: Bool { onSamples != nil }
}

actor MockRecognizer: Recognizer {
    private let recorder: CallRecorder
    private var updateOut: AsyncStream<RecognizerUpdate>.Continuation?
    private(set) var fedSampleCount = 0
    private(set) var beginCount = 0
    private(set) var finishCount = 0
    private(set) var abandonCount = 0
    /// What finish() returns; nil means synthesize from fed samples.
    var finalText: String?
    var beginError: (any Error)?
    /// Extra latency inside finish(), for drain-watchdog tests.
    var finishDelay: Duration = .zero

    init(recorder: CallRecorder) {
        self.recorder = recorder
    }

    func setFinalText(_ text: String?) { finalText = text }
    func setBeginError(_ error: (any Error)?) { beginError = error }
    func setFinishDelay(_ delay: Duration) { finishDelay = delay }

    func begin() async throws -> AsyncStream<RecognizerUpdate> {
        beginCount += 1
        await recorder.note("recognizer.begin")
        if let beginError { throw beginError }
        let (stream, continuation) = AsyncStream<RecognizerUpdate>.makeStream()
        updateOut = continuation
        return stream
    }

    func feed(_ samples: [Float]) async {
        fedSampleCount += samples.count
    }

    func finish() async -> String {
        finishCount += 1
        await recorder.note("recognizer.finish")
        if finishDelay > .zero {
            try? await Task.sleep(for: finishDelay)
        }
        updateOut?.finish()
        updateOut = nil
        if let finalText { return finalText }
        return fedSampleCount > 0 ? "mock transcript" : ""
    }

    func abandon() async {
        abandonCount += 1
        await recorder.note("recognizer.abandon")
        updateOut?.finish()
        updateOut = nil
    }

    /// Test hook: push a live update as the engine would.
    func push(_ update: RecognizerUpdate) {
        updateOut?.yield(update)
    }
}

actor MockRefiner: Refiner {
    private let recorder: CallRecorder
    var behavior: @Sendable (String) throws -> String
    private(set) var refineCount = 0
    private(set) var lastContext: String?
    /// Extra latency, for drain-watchdog tests. Honors cancellation.
    var delay: Duration = .zero

    init(recorder: CallRecorder, behavior: @escaping @Sendable (String) throws -> String = { "refined: \($0)" }) {
        self.recorder = recorder
        self.behavior = behavior
    }

    func setBehavior(_ behavior: @escaping @Sendable (String) throws -> String) {
        self.behavior = behavior
    }

    func setDelay(_ delay: Duration) { self.delay = delay }

    var isReady: Bool { true }

    func refine(_ text: String, context: String) async throws -> String {
        refineCount += 1
        lastContext = context
        await recorder.note("refiner.refine")
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try behavior(text)
    }
}

actor MockPaster: Paster {
    private let recorder: CallRecorder
    var result: PasteResult = .verified
    private(set) var pastedTexts: [String] = []
    private(set) var lastTargetPID: pid_t??

    init(recorder: CallRecorder) {
        self.recorder = recorder
    }

    func setResult(_ result: PasteResult) { self.result = result }

    func paste(_ text: String, targetPID: pid_t?) async -> PasteResult {
        pastedTexts.append(text)
        lastTargetPID = targetPID
        await recorder.note("paster.paste")
        return result
    }
}

/// Collects controller signals so tests can assert on them after the fact.
actor SignalCollector {
    private(set) var signals: [SessionSignal] = []

    func append(_ signal: SessionSignal) { signals.append(signal) }

    var completedOutcomes: [SessionOutcome] {
        signals.compactMap {
            if case .completed(let outcome) = $0 { return outcome }
            return nil
        }
    }

    var failureReasons: [String] {
        signals.compactMap {
            if case .failed(let reason) = $0 { return reason }
            return nil
        }
    }

    var stateChanges: [SessionState] {
        signals.compactMap {
            if case .stateChanged(let state, _) = $0 { return state }
            return nil
        }
    }

    var transcripts: [(settled: String, settling: String)] {
        signals.compactMap {
            if case .transcript(let settled, let settling) = $0 { return (settled, settling) }
            return nil
        }
    }

    var resolvedDeviceNames: [String] {
        signals.compactMap {
            if case .deviceResolved(let name) = $0 { return name }
            return nil
        }
    }
}
