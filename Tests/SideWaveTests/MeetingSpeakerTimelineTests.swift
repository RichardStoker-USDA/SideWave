// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class MeetingSpeakerTimelineTests: XCTestCase {
    func testTurnSurvivesChunkAndPartBoundaries() throws {
        var timeline = MeetingSpeakerTimeline()
        try timeline.append(probabilities: frames(100, speakers: [7]), frames: 100, speakers: 8)
        try timeline.append(probabilities: frames(100, speakers: [7]), frames: 100, speakers: 8)
        try timeline.append(probabilities: frames(20, speakers: []), frames: 20, speakers: 8)
        timeline.finish()
        XCTAssertEqual(timeline.segments.count, 1)
        let segment = try XCTUnwrap(timeline.segments.first)
        XCTAssertEqual(segment.speakerId, "Speaker 8")
        XCTAssertEqual(segment.start, 0)
        XCTAssertEqual(segment.end, 2)
        XCTAssertEqual(timeline.frameCount, 220)
    }

    func testOverlapBriefGapsAndNoise() throws {
        var timeline = MeetingSpeakerTimeline()
        try timeline.append(probabilities: frames(30, speakers: [0, 1]), frames: 30, speakers: 8)
        try timeline.append(probabilities: frames(10, speakers: []), frames: 10, speakers: 8)
        try timeline.append(probabilities: frames(30, speakers: [0]), frames: 30, speakers: 8)
        try timeline.append(probabilities: frames(5, speakers: [2]), frames: 5, speakers: 8)
        timeline.finish()
        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.segments.first?.end ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(timeline.segments.last?.end ?? -1, 0.3, accuracy: 0.001)
    }

    func testMalformedProbabilitiesFailRecoverably() {
        var timeline = MeetingSpeakerTimeline()
        XCTAssertThrowsError(try timeline.append(probabilities: [0], frames: 1, speakers: 8))
        XCTAssertThrowsError(try timeline.append(probabilities: [], frames: 0, speakers: 0))
        XCTAssertThrowsError(try timeline.append(probabilities: [.nan] + Array(repeating: 0, count: 7), frames: 1, speakers: 8))
    }

    func testHourRetainsIntervalsInsteadOfFrames() throws {
        var timeline = MeetingSpeakerTimeline()
        for turn in 0..<360 {
            try timeline.append(probabilities: frames(900, speakers: [turn % 8]), frames: 900, speakers: 8)
            try timeline.append(probabilities: frames(100, speakers: []), frames: 100, speakers: 8)
        }
        timeline.finish()
        XCTAssertEqual(timeline.frameCount, 360_000)
        XCTAssertEqual(timeline.segments.count, 360)
        XCTAssertEqual(Set(timeline.segments.map(\.speakerId)).count, 8)
        XCTAssertEqual(timeline.segments.last?.end, 3599)
    }

    private func frames(_ count: Int, speakers: Set<Int>) -> [Float] {
        (0..<(count * 8)).map { speakers.contains($0 % 8) ? 0.95 : 0.05 }
    }
}
