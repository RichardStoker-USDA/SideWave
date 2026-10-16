// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AVFAudio
import XCTest
@testable import SideWave

@MainActor
final class TTSSuppressionTests: XCTestCase {
    func testRecordingSuppressesEverySpeechEntryPointWithoutLoadingModels() {
        let service = TTSService()
        service.isSuppressed = { true }
        for result in [service.queueSpeech("Review the figures."), service.replacePending(with: "Send the report."), service.speak("Ready.")] {
            guard case .notSpoken = result else { return XCTFail("Speech must be rejected while recording") }
        }
        XCTAssertTrue(service.pendingSentences.isEmpty)
        XCTAssertFalse(service.initializationInFlight)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(service.modelPhase, .uninitialized)
    }

    func testInvalidSynthesizedAudioIsRejectedBeforePlayback() throws {
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        XCTAssertNil(TTSService.makeBuffer(samples: [], format: mono))
        XCTAssertNil(TTSService.makeBuffer(samples: [.nan, 0.1], format: mono))
        XCTAssertNil(TTSService.makeBuffer(samples: [.infinity], format: mono))
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2))
        XCTAssertNil(TTSService.makeBuffer(samples: [0.1, 0.2], format: stereo))
        let valid = try XCTUnwrap(TTSService.makeBuffer(samples: [0.1, -0.2], format: mono))
        XCTAssertEqual(valid.frameLength, 2)
        XCTAssertEqual(valid.floatChannelData?[0][1], -0.2)
    }
}
