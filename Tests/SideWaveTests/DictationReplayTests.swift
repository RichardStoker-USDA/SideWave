// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import FluidAudio
import XCTest
@testable import SideWave

/// Replays audio through the whole dictation pipeline in place of the microphone: TDT polling,
/// VAD, the streaming model and its ghost gate, segment commits, and the stop path. Synthetic
/// speech by default; with SIDEWAVE_REPLAY_DIR, every WAV in that folder (for example saved
/// dictation recordings). Prints timings and word counts, never text.
@MainActor
final class DictationReplayTests: XCTestCase {
    private func speech(_ text: String, rate: Int = 175) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-r", "\(rate)", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        return try Self.load(url)
    }

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let selector = ChannelSelector(mode: .mix, channelCount: Int(buffer.format.channelCount), deviceUID: nil,
                                       cachedAutoChannel: nil, onAutoCalibrated: nil)
        let mono = selector.selectAndDownmix(buffer)
        return buffer.format.sampleRate == 16_000 ? mono
            : AudioResampler(useHQ: true).resampleTo16k(samples: mono, sourceSampleRate: buffer.format.sampleRate)
    }

    struct Result {
        var firstGrayMs: Int?
        var longestStallMs = 0
        var finalWords = 0
        var timing = ""
    }

    /// One dictation: starts the service on `samples`, watches the live preview until the audio
    /// has played, then stops with the toggle path.
    static func replay(_ samples: [Float], on service: TranscriptionService, tailSeconds: Double = 1.5) async -> Result {
        var result = Result()
        service.replayInput = samples
        defer { service.replayInput = nil }
        let start = Date()
        await service.startRecording()
        guard service.isRecording else { return result }
        let audioSeconds = Double(samples.count) / 16_000
        var lastText = ""
        var lastChange = Date()
        while Date().timeIntervalSince(start) < audioSeconds + tailSeconds {
            try? await Task.sleep(nanoseconds: 40_000_000)
            let staged = service.stagedTranscript
            let text = staged.confirmedSpans.map(\.originalEouText).joined(separator: " ") + " " + staged.liveEouTail
            let now = Date()
            if text != lastText {
                if result.firstGrayMs == nil, !staged.liveEouTail.isEmpty {
                    result.firstGrayMs = Int(now.timeIntervalSince(start) * 1000)
                }
                // Only stalls while speech is still playing count.
                if now.timeIntervalSince(start) < audioSeconds {
                    result.longestStallMs = max(result.longestStallMs, Int(now.timeIntervalSince(lastChange) * 1000))
                }
                lastText = text
                lastChange = now
            }
        }
        let final = await service.stopRecording()
        result.finalWords = wordCount(final)
        result.timing = service.grayTextTiming.summary
        return result
    }

    func testReplayShowsGrayTextFromTheStart() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1",
                          "Replay needs SIDEWAVE_LIVE_MODELS=1")
        let defaults = UserDefaults.standard
        // SIDEWAVE_REPLAY_REFINE=gemma4-e4b (or another backend) adds live refine.
        let refineBackend = ProcessInfo.processInfo.environment["SIDEWAVE_REPLAY_REFINE"]
            .flatMap(DictationFormatterService.Backend.init(rawValue:))
        let settings: [String: Any] = [
            "selectedModelVersion": "v3", "useDualEngineSmartPTT": true, "useMultiStageRendering": true,
            "useRealTimeRefine": refineBackend != nil, "skipRefine": refineBackend == nil, "showLiveGhostText": true,
            "eouGhostSuppression": true, "refineCadence": "faster", "refineFixedIntervalEnabled": true,
            "dictationCleanupEnabled": true, "dictationCleanupTemplate": "standard",
        ]
        let saved = settings.keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for (key, value) in settings { defaults.set(value, forKey: key) }

        let service = TranscriptionService()
        await service.warmUpModelsIfNeeded()
        XCTAssertEqual(service.modelState, .ready)
        let formatter = DictationFormatterService()
        if let refineBackend {
            formatter.activeBackend = refineBackend
            await formatter.loadModel()
            XCTAssertEqual(formatter.state, .ready)
            service.dictationFormatter = formatter
        }

        var inputs: [(String, [Float])] = []
        if let dir = ProcessInfo.processInfo.environment["SIDEWAVE_REPLAY_DIR"] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            for url in urls.filter({ $0.pathExtension == "wav" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                inputs.append((url.deletingPathExtension().lastPathComponent, try Self.load(url)))
            }
        } else {
            let first = try speech("Send the updated schedule to the field crew and ask them to confirm the pickup times for Thursday morning.")
            let second = try speech("After lunch we will check the pump logs, compare them with last week, and flag anything that looks off.")
            let long = try speech("The crew checked every valve along the east line before the heat came in and two of the older fittings were loose so we replaced them and ran the pump for ten minutes to watch the pressure settle and after that we moved to the greenhouse to clean the benches and label the new trays by row and by week.")
            inputs = [
                ("long", long),
                ("normal", first),
                ("right-after", second),
                ("quiet", first.map { $0 * 0.03 }),
                ("late-start", [Float](repeating: 0, count: 24_000) + second),
            ]
        }
        for (name, samples) in inputs {
            let result = await Self.replay(samples, on: service, tailSeconds: name == "right-after" ? 0.3 : 1.5)
            print("REPLAY \(name) audio_s=\(String(format: "%.1f", Double(samples.count) / 16_000)) first_gray_ms=\(result.firstGrayMs.map(String.init) ?? "never") longest_stall_ms=\(result.longestStallMs) final_words=\(result.finalWords)")
            print("REPLAY \(name) \(result.timing)")
            if ProcessInfo.processInfo.environment["SIDEWAVE_REPLAY_DIR"] == nil {
                XCTAssertNotNil(result.firstGrayMs, name)
            }
        }
        // A Gemma generation still running when the test host exits crashes MLX's Metal teardown,
        // so let the last one stop first.
        if refineBackend != nil {
            _ = await formatter.drainGenerationBeforeLoad(deadlineNanos: 15_000_000_000)
            while !formatter.retiringGenerationTasks.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
