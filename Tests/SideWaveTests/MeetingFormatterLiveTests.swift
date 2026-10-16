// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FoundationModels
import XCTest
@testable import SideWave

@MainActor
final class MeetingFormatterLiveTests: XCTestCase {
    private func requireModels() throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_MODELS"] == "1" else {
            throw XCTSkip("Live meeting formatting requires SIDEWAVE_LIVE_MODELS=1")
        }
    }

    private var gemmaBackend: MeetingFormatterBackend {
        let selected = ProcessInfo.processInfo.environment["SIDEWAVE_REFINE_BACKEND"] ?? "gemma4-e2b"
        return MeetingFormatterBackend(rawValue: selected) ?? .gemma4E2B
    }

    private var fixture: MeetingTranscript {
        MeetingTranscript(segments: [
            MeetingSegment(speakerId: "one", speakerLabel: "Speaker 1", text: "I will send the greenhouse report before Friday. We agreed to use the blue labels for the next trial.", startTime: 0, endTime: 8),
            MeetingSegment(speakerId: "two", speakerLabel: "Speaker 2", text: "I will check the irrigation records on Monday. The control plants will stay in chamber two.", startTime: 9, endTime: 16)
        ], speakerNames: [:], duration: 16, timestamp: Date())
    }

    private func waitForOutput(_ service: MeetingFormatterService, timeout: Double = 120) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            switch service.state {
            case .complete(let output): return output
            case .error(let message): throw NSError(domain: "MeetingFormatterLiveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            default: try await Task.sleep(for: .milliseconds(50))
            }
        }
        service.cancel()
        throw NSError(domain: "MeetingFormatterLiveTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Meeting formatting timed out"])
    }

    func testAppleIntelligenceKeepsActionOwnersAndDeadlines() async throws {
        try requireModels()
        guard case .available = AFMRuntime.makeModel().availability else { throw XCTSkip("Apple Intelligence is unavailable") }
        let service = MeetingFormatterService()
        defer { service.unloadModel() }
        service.setBackend(.appleIntelligence)
        service.format(transcript: fixture, as: .actionItems)
        let output = try await waitForOutput(service).lowercased()
        for word in ["speaker 1", "speaker 2", "friday", "monday", "irrigation"] {
            XCTAssertTrue(output.contains(word), "Missing \(word): \(output)")
        }
    }

    func testGemmaReformatsCachedTranscriptWithoutLosingFacts() async throws {
        try requireModels()
        let service = MeetingFormatterService()
        defer { service.unloadModel() }
        service.setBackend(gemmaBackend)
        let transcript = fixture
        service.format(transcript: transcript, as: .summary)
        let summary = try await waitForOutput(service).lowercased()
        XCTAssertTrue(gemmaBackend.isDownloaded, "A prepared Gemma model must be recognized in the configured cache")
        XCTAssertTrue(summary.contains("greenhouse"), summary)
        XCTAssertTrue(summary.contains("blue"), summary)
        XCTAssertTrue(service.reformatIsCached)
        service.format(transcript: transcript, as: .actionItems)
        let actions = try await waitForOutput(service).lowercased()
        for word in ["speaker 1", "speaker 2", "friday", "monday"] {
            XCTAssertTrue(actions.contains(word), "Missing \(word): \(actions)")
        }
    }

    func testLongSingleSpeakerMeetingUsesBoundedSections() async throws {
        guard ProcessInfo.processInfo.environment["SIDEWAVE_LIVE_LONG_MEETING"] == "1" else {
            throw XCTSkip("Long meeting formatting requires SIDEWAVE_LIVE_LONG_MEETING=1")
        }
        let discussion = String(repeating: "The trial uses blue labels. We checked the greenhouse samples and the irrigation records. ", count: 1_000)
        let transcript = MeetingTranscript(segments: [MeetingSegment(
            speakerId: "one", speakerLabel: "Speaker 1",
            text: "We agreed on a budget of 420 dollars. " + discussion + "We agreed that the final deadline is Friday.",
            startTime: 0, endTime: 3_600)], speakerNames: [:], duration: 3_600, timestamp: Date())
        let service = MeetingFormatterService()
        defer { service.unloadModel() }
        service.setBackend(gemmaBackend)
        service.format(transcript: transcript, as: .keyDecisions)
        let output = try await waitForOutput(service, timeout: 360).lowercased()
        XCTAssertTrue(output.contains("420"), output)
        XCTAssertTrue(output.contains("friday"), output)
        // Background discussion can be omitted from a decision-only document.
        XCTAssertLessThanOrEqual(output.components(separatedBy: "blue labels").count - 1, 3, "Repeated discussion must not produce repeated decisions: \(output)")
        XCTAssertFalse(service.reformatIsCached)
    }
}
