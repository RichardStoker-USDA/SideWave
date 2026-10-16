// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFoundation
import XCTest

@testable import SideWaveKit

/// Opt-in end-to-end check against the REAL Nemotron models: synthesize
/// speech with the system voice, push it through prepare -> begin -> feed
/// -> finish, and require real words out. First run downloads the model
/// variant (hundreds of MB) into the standard FluidAudio cache, which the
/// app shares.
///
/// Run with: SIDEWAVE_LIVE_MODELS=1 (skipped otherwise so the suite stays
/// hermetic).
final class NemotronLiveIntegrationTests: XCTestCase {

    func testLiveNemotronTranscribesSynthesizedSpeech() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("live model test skipped (set SIDEWAVE_LIVE_MODELS=1 to run)")
        }

        // 1. Synthesize a known utterance.
        let phrase = "The quick brown fox jumps over the lazy dog"
        let aiffURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidewave_kit_live_\(ProcessInfo.processInfo.processIdentifier).aiff")
        defer { try? FileManager.default.removeItem(at: aiffURL) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", aiffURL.path, phrase]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say must synthesize the fixture")

        // 2. Read and convert with the kit's own conversion path.
        let file = try AVAudioFile(forReading: aiffURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        try file.read(into: buffer)
        let selector = ChannelSelector(
            mode: .mix, channelCount: Int(format.channelCount),
            deviceUID: nil, cachedAutoChannel: nil, onAutoCalibrated: nil)
        let mono = selector.selectAndDownmix(buffer)
        let resampler = AudioResampler(useHQ: true)
        let samples16k = resampler.resampleTo16k(samples: mono, sourceSampleRate: format.sampleRate)
        XCTAssertGreaterThan(samples16k.count, 16_000, "fixture must be at least a second of audio")

        // 3. Prepare (downloads on first run, cached after) and transcribe.
        let recognizer = NemotronRecognizer(options: NemotronRecognizer.Options(languageCode: "en-US"))
        try await recognizer.prepare { progress in
            print("[live-test] setup \(Int(progress.fraction * 100))%: \(progress.detail)")
        }

        let updates = try await recognizer.begin()
        let sawTranscript = LockedBox<Bool>(false)
        let pump = Task {
            for await update in updates {
                if case .transcript(let settled, let settling) = update {
                    sawTranscript.set(true)
                    print("[live-test] partial settled=\"\(settled)\" settling=\"\(settling)\"")
                }
            }
        }

        var offset = 0
        while offset < samples16k.count {
            let end = min(offset + 4_096, samples16k.count)
            await recognizer.feed(Array(samples16k[offset..<end]))
            offset = end
        }
        // A second of trailing silence lets VAD close the last speech
        // segment the way a real session would.
        for _ in 0..<4 {
            await recognizer.feed([Float](repeating: 0, count: 4_096))
        }

        let final = await recognizer.finish()
        pump.cancel()
        print("[live-test] final=\"\(final)\"")

        let lowered = final.lowercased()
        XCTAssertTrue(lowered.contains("quick brown fox"), "expected the fixture phrase, got \"\(final)\"")
        XCTAssertTrue(lowered.contains("lazy dog"), "expected the fixture tail, got \"\(final)\"")
        XCTAssertTrue(sawTranscript.get(), "live partials must flow during the session")
    }
}
