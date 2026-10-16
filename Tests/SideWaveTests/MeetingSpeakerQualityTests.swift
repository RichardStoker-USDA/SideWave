// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import FluidAudio
import XCTest
@testable import SideWave

final class MeetingSpeakerQualityTests: XCTestCase {
    func testPublicMeetingAgainstReferenceAndPreviousModel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SIDEWAVE_LIVE_MODELS"] == "1",
              let audio = env["SIDEWAVE_MEETING_FIXTURE"], let reference = env["SIDEWAVE_MEETING_REFERENCE"] else {
            throw XCTSkip("Supply a licensed audio fixture and RTTM reference for speaker qualification")
        }
        let referenceSegments = try String(contentsOfFile: reference, encoding: .utf8).split(separator: "\n").compactMap { line -> MeetingDiarSeg? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 8, let start = Double(fields[3]), let duration = Double(fields[4]) else { return nil }
            return MeetingDiarSeg(speakerId: String(fields[7]), start: start, end: start + duration)
        }
        XCTAssertFalse(referenceSegments.isEmpty)
        let runner = SpeakerFixtureRunner()
        let url = URL(fileURLWithPath: audio)
        let current = try await runner.run(url, legacy: false)
        let previous = try await runner.run(url, legacy: true)
        let currentDER = score(current, reference: referenceSegments)
        let previousDER = score(previous, reference: referenceSegments)
        let currentCount = Set(current.map(\.speakerId)).count
        let referenceCount = Set(referenceSegments.map(\.speakerId)).count
        print("SPEAKER_QUALITY nemotron_der=\(currentDER) sortformer_der=\(previousDER) detected=\(currentCount) reference=\(referenceCount)")
        XCTAssertEqual(currentCount, referenceCount)
        XCTAssertLessThan(currentDER, 0.25)
        XCTAssertLessThanOrEqual(currentDER, previousDER + 0.01)
    }

    /// Twenty-millisecond, zero-collar DER with optimal speaker-label assignment.
    private func score(_ hypothesis: [MeetingDiarSeg], reference: [MeetingDiarSeg]) -> Double {
        let duration = max(hypothesis.map(\.end).max() ?? 0, reference.map(\.end).max() ?? 0)
        let frames = Int(ceil(duration / 0.02))
        let referenceNames = Array(Set(reference.map(\.speakerId))).sorted()
        let hypothesisNames = Array(Set(hypothesis.map(\.speakerId))).sorted()
        guard referenceNames.count <= 8, hypothesisNames.count <= 8 else { return 1 }
        func masks(_ segments: [MeetingDiarSeg], names: [String]) -> [UInt8] {
            var result = Array(repeating: UInt8(0), count: frames)
            for segment in segments {
                guard let index = names.firstIndex(of: segment.speakerId) else { continue }
                let first = max(0, Int(ceil(segment.start / 0.02 - 0.5)))
                let last = min(frames, Int(ceil(segment.end / 0.02 - 0.5)))
                if first < last { for frame in first..<last { result[frame] |= 1 << index } }
            }
            return result
        }
        let truth = masks(reference, names: referenceNames)
        let predicted = masks(hypothesis, names: hypothesisNames)
        var joint = Array(repeating: Array(repeating: 0, count: 8), count: 8)
        var total = 0
        var denominator = 0
        for frame in 0..<frames {
            let r = truth[frame], h = predicted[frame]
            denominator += r.nonzeroBitCount
            total += max(r.nonzeroBitCount, h.nonzeroBitCount)
            for i in 0..<8 where r & (1 << i) != 0 {
                for j in 0..<8 where h & (1 << j) != 0 { joint[i][j] += 1 }
            }
        }
        func best(_ row: Int, _ used: UInt8) -> Int {
            guard row < referenceNames.count else { return 0 }
            return (0..<8).filter { used & (1 << $0) == 0 }.map {
                joint[row][$0] + best(row + 1, used | (1 << $0))
            }.max() ?? 0
        }
        return Double(total - best(0, 0)) / Double(max(1, denominator))
    }
}

private actor SpeakerFixtureRunner {
    func run(_ url: URL, legacy: Bool) async throws -> [MeetingDiarSeg] {
        let reader = MeetingEngine(asrVersion: .v3)
        let start = Date()
        let result: [MeetingDiarSeg]
        if legacy {
            let models = try await SortformerModels.loadFromHuggingFace(config: .balancedV2_1, computeUnits: .cpuAndNeuralEngine)
            let diarizer = SortformerDiarizer(config: .balancedV2_1, timelineConfig: .sortformerDefault)
            diarizer.initialize(models: models)
            try await reader.streamCAF(url) { samples in
                diarizer.addAudio(samples)
                _ = try diarizer.process()
            }
            _ = try diarizer.finalizeSession()
            result = diarizer.timeline.speakers.values.flatMap { $0.finalizedSegments }.map {
                MeetingDiarSeg(speakerId: $0.speakerLabel, start: Double($0.startTime), end: Double($0.endTime))
            }
        } else {
            let models = try await Nemotron3Models.loadFromHuggingFace(config: .fast128, computeUnits: .cpuAndNeuralEngine)
            let diarizer = MeetingSpeakerDiarizer(config: .fast128, models: models)
            try await reader.streamCAF(url) { try diarizer.append($0) }
            try diarizer.finish()
            result = diarizer.segments
        }
        print("SPEAKER_PASS_SECONDS legacy=\(legacy) seconds=\(Date().timeIntervalSince(start))")
        return result
    }
}
