// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
import AVFoundation
import FluidAudio
@testable import SideWave

/// Opt-in probe for the cold-inference warm-up decode (the ghost-words
/// trigger fix). Runs the REAL Parakeet models from the local cache, so it
/// only makes sense on a machine that has them downloaded.
///
/// What it proves:
/// 1. The throwaway silent decode the production warm-up runs is viable on
///    both engines: it completes, doesn't throw, and leaves the engine
///    reusable.
/// 2. Post-warm-up, silence decodes to NOTHING. That's the property the fix
///    relies on: once the first inference has been burned on a silent
///    buffer, a quiet session start can't inherit hallucinated tokens.
/// 3. If the first pass DOES emit tokens (a truly cold ANE program), the
///    probe logs them; that text is literally what a fresh-install user
///    would have seen as ghost words. With a warm OS-level ANE cache, an empty
///    first pass is expected.
///
/// Run:
///   TEST_RUNNER_SIDEWAVE_WARMUP_PROBE=1 xcodebuild test ... \
///     -only-testing:SideWaveTests/WarmupDecodeProbeTests
final class WarmupDecodeProbeTests: XCTestCase {

    private func requireProbeEnabled() throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_WARMUP_PROBE"] == "1" else {
            throw XCTSkip("Warm-up probe is opt-in. Set SIDEWAVE_WARMUP_PROBE=1 to run it.")
        }
    }

    /// 2s of silence at 16kHz mono; the exact buffer the production
    /// warm-up decode feeds.
    private func silentBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let frames: AVAudioFrameCount = 32_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        // AVAudioPCMBuffer memory is zero-initialized; make it explicit.
        if let ch = buffer.floatChannelData?[0] {
            ch.update(repeating: 0, count: Int(frames))
        }
        return buffer
    }

    func testEouWarmupDecodeThenSilenceIsClean() async throws {
        try requireProbeEnabled()

        let eou = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
        try await eou.loadModels(to: nil, configuration: nil, progressHandler: nil)

        // Pass 1: the process-cold inference; the production warm-up decode.
        let firstStart = Date()
        _ = try await eou.process(audioBuffer: try silentBuffer())
        let firstText = try await eou.finish()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstMs = Int(Date().timeIntervalSince(firstStart) * 1000)
        await eou.reset()
        print("[warmup-probe] EOU pass 1 (cold): \(firstMs)ms text=\"\(firstText)\"")

        // Pass 2: the state a user's first session now starts in. Silence
        // after the warm-up MUST decode to nothing; this is the assertion
        // that makes the trigger fix meaningful.
        let secondStart = Date()
        _ = try await eou.process(audioBuffer: try silentBuffer())
        let secondText = try await eou.finish()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secondMs = Int(Date().timeIntervalSince(secondStart) * 1000)
        await eou.reset()
        print("[warmup-probe] EOU pass 2 (warm): \(secondMs)ms text=\"\(secondText)\"")

        XCTAssertTrue(
            secondText.isEmpty,
            "post-warm-up silence must decode to nothing, got \"\(secondText)\""
        )
    }

    func testTdtWarmupDecodeThenSilenceIsClean() async throws {
        try requireProbeEnabled()

        let models = try await AsrModels.loadFromCache()
        let manager = AsrManager(config: ASRConfig.default)
        try await manager.loadModels(models)
        let silence = [Float](repeating: 0, count: 32_000)

        let firstStart = Date()
        var firstState = try TdtDecoderState()
        let first = try await manager.transcribe(silence, decoderState: &firstState)
        let firstText = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstMs = Int(Date().timeIntervalSince(firstStart) * 1000)
        print("[warmup-probe] TDT pass 1 (cold): \(firstMs)ms text=\"\(firstText)\"")

        let secondStart = Date()
        var secondState = try TdtDecoderState()
        let second = try await manager.transcribe(silence, decoderState: &secondState)
        let secondText = second.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondMs = Int(Date().timeIntervalSince(secondStart) * 1000)
        print("[warmup-probe] TDT pass 2 (warm): \(secondMs)ms text=\"\(secondText)\"")

        XCTAssertTrue(
            secondText.isEmpty,
            "post-warm-up silence must decode to nothing, got \"\(secondText)\""
        )
    }
}
