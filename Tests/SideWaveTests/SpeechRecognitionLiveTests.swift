// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import FluidAudio
import XCTest
@testable import SideWave

@MainActor
final class SpeechRecognitionLiveTests: XCTestCase {
    private func requireModels() throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Live speech models require SIDEWAVE_LIVE_MODELS=1")
        }
    }

    private func speechFixture(_ text: String = "Review the samples on Friday, then send the revised report before lunch.") throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-o", url.path,
                             text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let selector = ChannelSelector(mode: .mix, channelCount: Int(buffer.format.channelCount), deviceUID: nil, cachedAutoChannel: nil, onAutoCalibrated: nil)
        return AudioResampler(useHQ: true).resampleTo16k(samples: selector.selectAndDownmix(buffer), sourceSampleRate: buffer.format.sampleRate)
    }

    func testPreparationRetainsBothSpeechEnginesBeforeReady() async throws {
        try requireModels()
        let defaults = UserDefaults.standard
        let keys = ["selectedModelVersion", "useDualEngineSmartPTT"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("v3", forKey: "selectedModelVersion")
        defaults.set(true, forKey: "useDualEngineSmartPTT")
        let service = TranscriptionService()
        let start = Date()
        await service.downloadModel(version: .v3)
        // A cached launch can already be in .loading, which launch warm-up owns.
        await service.warmUpModelsIfNeeded()
        XCTAssertEqual(service.modelState, .ready)
        XCTAssertTrue(service.speechModelsPrepared)
        XCTAssertTrue(service.hasInstalledSpeechModels)
        XCTAssertFalse(service.isRecording)
        let loadedAt = Date()
        async let first: Void = service.warmUpModelsIfNeeded()
        async let second: Void = service.warmUpModelsIfNeeded()
        _ = await (first, second)
        XCTAssertEqual(service.modelState, .ready)
        XCTAssertTrue(service.speechModelsPrepared)
        XCTAssertLessThan(Date().timeIntervalSince(loadedAt), 1, "Prepared engines must be reused")
        print("SPEECH_PREPARE_SECONDS \(loadedAt.timeIntervalSince(start)) cached_seconds=\(Date().timeIntervalSince(loadedAt))")
    }

    func testSwitchingToMinimalisticReleasesStreamingAndRewarmsBasic() async throws {
        try requireModels()
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "useDualEngineSmartPTT")
        defer {
            if let previous { defaults.set(previous, forKey: "useDualEngineSmartPTT") }
            else { defaults.removeObject(forKey: "useDualEngineSmartPTT") }
        }
        let service = TranscriptionService()
        defaults.set(true, forKey: "useDualEngineSmartPTT")
        await service.warmUpModelsIfNeeded()
        XCTAssertTrue(service.hasPreparedStreamingModel)
        defaults.set(false, forKey: "useDualEngineSmartPTT")
        await service.warmUpModelsIfNeeded()
        XCTAssertTrue(service.speechModelsPrepared)
        XCTAssertFalse(service.hasPreparedStreamingModel)
        defaults.set(true, forKey: "useDualEngineSmartPTT")
        await service.warmUpModelsIfNeeded()
        XCTAssertTrue(service.hasPreparedStreamingModel)
        XCTAssertTrue(service.speechModelsPrepared)
        XCTAssertFalse(service.isRecording)
    }

    func testRecognitionModesKeepShortFinalWordAfterCommittedSegment() async throws {
        try requireModels()
        let defaults = UserDefaults.standard
        let keys = ["useDualEngineSmartPTT", "useMultiStageRendering", "useRealTimeRefine", "skipRefine", "showLiveGhostText", "useEouToRefineDirect"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let first = try speechFixture("Review the report.")
        let spokenTail = try speechFixture("Monday.")
        let firstSpeech = try XCTUnwrap(spokenTail.firstIndex { abs($0) > 0.002 })
        let lastSpeech = try XCTUnwrap(spokenTail.lastIndex { abs($0) > 0.002 })
        let tail = Array(spokenTail[max(0, firstSpeech - 400)..<min(spokenTail.count, lastSpeech + 801)])
        XCTAssertGreaterThanOrEqual(tail.count, 3_200)
        XCTAssertLessThan(tail.count, 16_000, "Fixture must exercise a sub-second final segment")
        defaults.set(false, forKey: "useRealTimeRefine")
        defaults.set(true, forKey: "skipRefine")
        defaults.set(true, forKey: "showLiveGhostText")
        defaults.set(false, forKey: "useEouToRefineDirect")
        for (dual, fast) in [(false, false), (false, true), (true, false), (true, true)] {
            defaults.set(dual, forKey: "useDualEngineSmartPTT")
            defaults.set(dual, forKey: "useMultiStageRendering")
            let service = TranscriptionService()
            let result = try await service.recognizeFixture([first, tail], preferFastResult: fast)
            XCTAssertEqual(result.usesStagedPreview, dual)
            XCTAssertTrue(result.confirmedBeforeStop.lowercased().contains("report"))
            XCTAssertFalse(result.previewBeforeStop.isEmpty)
            let words = result.finalText.lowercased().split { !$0.isLetter }.map(String.init)
            XCTAssertTrue(words.contains("report"), "The committed beginning must survive stop")
            XCTAssertEqual(words.filter { $0 == "monday" }.count, 1, "Keep the final word once: dual=\(dual) fast=\(fast)")
            XCTAssertFalse(service.isRecording)
            XCTAssertEqual(service.refinesCompletedCount, 0)
        }
    }

    func testOriginalTDTKeepsTheBeginningAndShortTail() async throws {
        try requireModels()
        let samples = try speechFixture()
        for version in [ModelVersion.v2, .v3] {
            try await ModelDownloadManager.download(version: version, verifyCachedFiles: true)
            let models = try await version.loadModels()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            var decoder = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &decoder)
            assertFixture(result.text, context: version.rawValue)
            XCTAssertTrue(version.isCached(at: AsrModels.defaultCacheDirectory(for: version.asrVersion)))
        }
    }

    func testParakeetUltraKeepsTheWholeFixture() async throws {
        try requireModels()
        let samples = try speechFixture()
        for version in [ModelVersion.ultra] {
            try await ModelDownloadManager.download(version: version, verifyCachedFiles: true)
            let models = try await version.loadModels()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            var decoder = try TdtDecoderState()
            let start = Date()
            let result = try await manager.transcribe(samples, decoderState: &decoder)
            assertFixture(result.text, context: version.rawValue)
            XCTAssertTrue(version.isCached(at: AsrModels.defaultCacheDirectory(for: version.asrVersion)))
            print("SPEECH_MODEL \(version.rawValue) seconds=\(Date().timeIntervalSince(start))")
        }
    }

    /// Kept outside the accepted model lane: the current checkpoint substitutes a word in this fixture.
    func testPhononCandidateRecognition() async throws {
        try requireModels()
        guard ProcessInfo.processInfo.environment["SIDEWAVE_CANDIDATE_PHONON2"] == "1" else {
            throw XCTSkip("Phonon-2 remains an unpromoted speech candidate")
        }
        let models = try await AsrModels.loadFromCache(version: .phonon2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var decoder = try TdtDecoderState()
        let result = try await manager.transcribe(try speechFixture(), decoderState: &decoder)
        assertFixture(result.text, context: "phonon2 candidate")
    }

    func testOriginalStreamingEOUKeepsTheFinalWords() async throws {
        try requireModels()
        let manager = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: nil)
        try await TranscriptionService.prepareEouSession(manager)
        let samples = try speechFixture() + [Float](repeating: 0, count: 32_000)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        for offset in stride(from: 0, to: samples.count, by: 4096) {
            let end = min(samples.count, offset + 4096)
            let chunk = Array(samples[offset..<end])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)))
            buffer.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
            }
            _ = try await manager.process(audioBuffer: buffer)
        }
        assertFixture(try await manager.finish())
        await manager.reset()
    }

    func testAuthorizedMicrophoneDeliversBuffersAndReleasesInput() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MIC"] == "1" else {
            throw XCTSkip("Microphone capture requires SIDEWAVE_LIVE_MIC=1 and an idle authorized machine")
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("SideWave Dev needs microphone permission on this machine")
        }
        let controller = MicTestController()
        defer { controller.stop() }
        for _ in 0..<3 {
            await controller.start(deviceUID: nil)
            XCTAssertTrue(controller.isRunning, controller.lastError ?? "Microphone did not start")
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertGreaterThan(controller.receivedBufferCount, 0)
            XCTAssertGreaterThan(controller.detectedSampleRate, 0)
            XCTAssertGreaterThan(controller.detectedChannelCount, 0)
            XCTAssertTrue(controller.audioLevel.isFinite)
            controller.stop()
            XCTAssertFalse(controller.isRunning)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while MicTestController.isCapturing && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(MicTestController.isCapturing)
            XCTAssertNotNil(controller.resultDescription)
        }
    }

    private func assertFixture(_ transcript: String, context: String = "v3", file: StaticString = #filePath, line: UInt = #line) {
        let text = transcript.lowercased()
        XCTAssertTrue(text.contains("review the samples"), "The leading clause must survive (\(context)): \(transcript)", file: file, line: line)
        XCTAssertTrue(text.contains("friday"), "The date must survive (\(context)): \(transcript)", file: file, line: line)
        XCTAssertTrue(text.contains("before lunch"), "The short final phrase must survive (\(context)): \(transcript)", file: file, line: line)
    }
}
