// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import XCTest
@testable import SideWave

final class TTSPipelineLiveTests: XCTestCase {
    func testPocketTTSProducesFiniteNonSilentFramesForTwoVoices() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Live speech synthesis requires SIDEWAVE_LIVE_MODELS=1")
        }
        let manager = PocketTtsManager(defaultVoice: "jane",
            computeUnits: TTSService.computeUnits(chipBrand: HardwareDetector.chipBrand))
        try await manager.initialize()
        do {
            for voice in ["jane", "george"] {
                let session = try await manager.makeSession(voice: voice, seed: 42)
                session.enqueue("The report is ready for review.")
                session.finish()
                var sampleCount = 0
                var peak: Float = 0
                for try await frame in session.frames {
                    XCTAssertTrue(frame.samples.allSatisfy(\.isFinite))
                    sampleCount += frame.samples.count
                    peak = max(peak, frame.samples.map(abs).max() ?? 0)
                }
                XCTAssertGreaterThan(sampleCount, 12_000, "Speech must last longer than half a second")
                XCTAssertGreaterThan(peak, 0.001, "Speech must contain a non-silent signal")
            }
        } catch {
            await manager.cleanup()
            throw error
        }
        await manager.cleanup()
    }

    @MainActor
    func testAuthorizedPlaybackCanStopAndImmediatelyStartAgain() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_AUDIO_OUTPUT"] == "1" else {
            throw XCTSkip("Speaker playback requires SIDEWAVE_LIVE_AUDIO_OUTPUT=1 on an authorized idle machine")
        }
        let service = TTSService()
        defer { service.cleanup() }
        await service.initialize()
        XCTAssertTrue(service.isInitialized, String(describing: service.modelPhase))
        guard service.isInitialized else { return }
        XCTAssertEqual(service.speak("This sentence will be interrupted before it finishes."), .started)
        try await Task.sleep(for: .milliseconds(150))
        service.stopSpeaking()
        let restartedAt = ContinuousClock.now
        XCTAssertEqual(service.queueSpeech("The audio check is complete and playback has restarted. The next sentence should play in order."), .started)
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        var firstAudio: Duration?
        var observedFirst = false
        var observedSecond = false
        while service.hasPendingSpeech {
            guard ContinuousClock.now < deadline else { return XCTFail("Playback did not finish") }
            if service.isSpeaking {
                if firstAudio == nil { firstAudio = restartedAt.duration(to: .now) }
                if service.currentlyPlayingText.contains("audio check") { observedFirst = true }
                if service.currentlyPlayingText.contains("next sentence") {
                    XCTAssertTrue(observedFirst, "Playback status must follow the output sequence")
                    observedSecond = true
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(firstAudio, "The player must actually begin playing")
        XCTAssertTrue(observedSecond, "The queued sentence must play")
        print("TTS_RESTART first_audio=\(String(describing: firstAudio)) total=\(restartedAt.duration(to: .now))")
        XCTAssertNil(service.lastPlaybackError)
        XCTAssertEqual(service.consumeDroppedCount(), 0)
        XCTAssertFalse(service.isSpeaking)
    }
}
