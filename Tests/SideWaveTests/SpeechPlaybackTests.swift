// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import CoreML
import XCTest
@testable import SideWave

@MainActor
final class SpeechPlaybackTests: XCTestCase {
    func testPlaybackStatusWaitsForPlayedAudioRatherThanGeneration() {
        var timeline = SpeechPlaybackTimeline()
        let first = UUID(), second = UUID()
        let a = timeline.schedule(samples: 1_920, utteranceID: first, text: "First sentence.")
        let b = timeline.schedule(samples: 1_920, utteranceID: first, text: "First sentence.")
        let c = timeline.schedule(samples: 1_920, utteranceID: second, text: "Next sentence.")
        XCTAssertEqual(timeline.playingText, "First sentence.")
        XCTAssertEqual(timeline.nextText, "Next sentence.")
        timeline.didPlay(a)
        XCTAssertEqual(timeline.playingText, "First sentence.")
        timeline.didPlay(b)
        XCTAssertEqual(timeline.playingText, "Next sentence.")
        XCTAssertEqual(timeline.bufferedSamples, 1_920)
        timeline.didPlay(c)
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertEqual(timeline.bufferedSamples, 0)
    }

    func testOutOfOrderAndStaleCallbacksCannotAdvanceNewSpeech() {
        var timeline = SpeechPlaybackTimeline()
        let id = UUID()
        let a = timeline.schedule(samples: 1_920, utteranceID: id, text: "Still playing.")
        let b = timeline.schedule(samples: 1_920, utteranceID: id, text: "Still playing.")
        timeline.didPlay(b)
        XCTAssertEqual(timeline.bufferedSamples, 3_840)
        timeline.didPlay(a)
        XCTAssertTrue(timeline.isEmpty)
        let old = timeline.schedule(samples: 1_920, utteranceID: id, text: "Cancelled.")
        timeline.reset()
        let current = timeline.schedule(samples: 1_920, utteranceID: UUID(), text: "Replacement.")
        timeline.didPlay(old)
        XCTAssertEqual(timeline.playingText, "Replacement.")
        timeline.didPlay(current)
        XCTAssertTrue(timeline.isEmpty)
    }

    func testM1SpeechAvoidsTheKnownNeuralEngineAbort() {
        for brand in ["Apple M1", "Apple M1 Pro", "Apple M1 Max", "Apple M1 Ultra"] {
            let units = TTSService.computeUnits(chipBrand: brand)
            XCTAssertEqual(units.flowDecoder, .cpuAndGPU)
            XCTAssertEqual(units.mimiDecoder, .cpuOnly)
        }
        for brand in ["Apple M2 Ultra", "Apple M4 Max", "Apple M10", ""] {
            XCTAssertNil(TTSService.computeUnits(chipBrand: brand).flowDecoder)
        }
    }

    func testLongUnpunctuatedSpeechHasBoundedLookaheadWithoutLosingWords() {
        let text = Array(repeating: "review the sample and compare each observation", count: 150).joined(separator: " ")
        let chunks = TTSService.splitIntoSentences(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TTSService.maximumSentenceCharacters })
        XCTAssertEqual(chunks.joined(separator: " "), text)
        let unicode = String(repeating: "観察結果🌿", count: 300)
        let unicodeChunks = TTSService.splitIntoSentences(unicode)
        XCTAssertTrue(unicodeChunks.allSatisfy { $0.count <= TTSService.maximumSentenceCharacters })
        XCTAssertEqual(unicodeChunks.joined(), unicode)
        XCTAssertTrue(TTSService.splitIntoSentences(" \n\t ").isEmpty)
    }

    func testSpeculativeResponsesRejectMeaningChanges() {
        let manager = DraftResponseManager()
        for (snapshot, final) in [
            ("Send the report now", "Do not send the report now"),
            ("Set the rate to 15", "Set the rate to 50"),
            ("Copy A to B", "Copy B to A"),
            ("Set the value to -5", "Set the value to 5"),
            ("Set the value to .5", "Set the value to 5"),
            ("Review the report", "Review the report and delete the draft")
        ] {
            let id = manager.submit(text: "A speculative response.", transcriptSnapshot: snapshot)
            XCTAssertNil(manager.consumeIfValid(finalTranscript: final))
            XCTAssertEqual(manager.outcomeFor(draftID: id), .discarded)
        }
        let id = manager.submit(text: "Ready for review.", transcriptSnapshot: "review the report")
        XCTAssertEqual(manager.consumeIfValid(finalTranscript: "Review\n the report."), "Ready for review.")
        XCTAssertEqual(manager.outcomeFor(draftID: id), .used)
        XCTAssertFalse(DraftResponseManager.transcriptsMatch("", ""))
    }

    func testCopiedMCPCommandPreservesSpacesAndShellMetacharacters() throws {
        let path = "/Applications/Voice Studio's $(false) App.app/Contents/MacOS/sidewave-mcp"
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + ExperimentalSettingsPane.shellQuotedPath(path)]
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: output, encoding: .utf8), path)
    }
}
