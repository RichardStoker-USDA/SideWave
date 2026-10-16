// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import FluidAudio

/// Retains speaker intervals, not an hour of frame probabilities. Open intervals
/// cross model chunks and recording parts without creating artificial turns.
struct MeetingSpeakerTimeline {
    private struct Turn {
        var start: Int?
        var end = 0
    }
    private var turns = Array(repeating: Turn(), count: 8)
    private var completed: [MeetingDiarSeg] = []
    private(set) var frameCount = 0
    private let minimumFrames = 20
    private let gapFrames = 15

    mutating func append(probabilities: [Float], frames: Int, speakers: Int) throws {
        guard frames >= 0, speakers == turns.count,
              frames <= Int.max / speakers, probabilities.count == frames * speakers else {
            throw MeetingError.invalidSpeakerOutput
        }
        for frame in 0..<frames {
            for speaker in 0..<speakers {
                let probability = probabilities[frame * speakers + speaker]
                guard probability.isFinite else { throw MeetingError.invalidSpeakerOutput }
                if probability >= 0.5 {
                    if turns[speaker].start == nil { turns[speaker].start = frameCount }
                    turns[speaker].end = frameCount + 1
                } else if turns[speaker].start != nil,
                          frameCount + 1 - turns[speaker].end >= gapFrames {
                    close(speaker)
                }
            }
            frameCount += 1
        }
    }

    mutating func finish() {
        for speaker in turns.indices { close(speaker) }
    }

    var segments: [MeetingDiarSeg] {
        var result = completed
        for speaker in turns.indices {
            if let start = turns[speaker].start, turns[speaker].end - start >= minimumFrames {
                result.append(segment(speaker: speaker, start: start, end: turns[speaker].end))
            }
        }
        return result.sorted { $0.start == $1.start ? $0.speakerId < $1.speakerId : $0.start < $1.start }
    }

    private mutating func close(_ speaker: Int) {
        if let start = turns[speaker].start, turns[speaker].end - start >= minimumFrames {
            completed.append(segment(speaker: speaker, start: start, end: turns[speaker].end))
        }
        turns[speaker].start = nil
    }

    private func segment(speaker: Int, start: Int, end: Int) -> MeetingDiarSeg {
        MeetingDiarSeg(speakerId: "Speaker \(speaker + 1)",
                       start: Double(start) * 0.01, end: Double(end) * 0.01)
    }
}

/// Confined to MeetingEngine. The model owns bounded audio and speaker caches.
final class MeetingSpeakerDiarizer {
    private let model: Nemotron3Diarizer
    private var timeline = MeetingSpeakerTimeline()

    init(config: Nemotron3Config, models: Nemotron3Models) {
        model = Nemotron3Diarizer(config: config, models: models)
    }

    func append(_ samples: [Float]) throws {
        try Task.checkCancellation()
        model.appendAudio(samples)
        try consume(model.processBufferedAudio())
    }

    func finish() throws {
        try Task.checkCancellation()
        try consume(model.finishStream())
        timeline.finish()
    }

    var segments: [MeetingDiarSeg] { timeline.segments }
    var duration: Double { Double(timeline.frameCount) * 0.01 }

    private func consume(_ chunks: [Nemotron3ChunkResult]) throws {
        for chunk in chunks {
            try timeline.append(probabilities: chunk.probabilities,
                                frames: chunk.frameCount, speakers: chunk.numSpeakers)
        }
    }
}
