// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Tracks scheduled audio until the output device has played it.
struct SpeechPlaybackTimeline {
    private struct Buffer {
        let id: Int
        let utteranceID: UUID
        let text: String
        let samples: Int
    }

    private var buffers: [Buffer] = []
    private var completed: Set<Int> = []
    private var nextID = 0
    private(set) var bufferedSamples = 0

    var isEmpty: Bool { buffers.isEmpty }
    var playingText: String { buffers.first?.text ?? "" }
    var nextText: String {
        guard let first = buffers.first else { return "" }
        return buffers.first(where: { $0.utteranceID != first.utteranceID })?.text ?? ""
    }

    mutating func schedule(samples: Int, utteranceID: UUID, text: String) -> Int {
        nextID += 1
        buffers.append(Buffer(id: nextID, utteranceID: utteranceID, text: text, samples: samples))
        bufferedSamples += samples
        return nextID
    }

    mutating func didPlay(_ id: Int) {
        guard buffers.contains(where: { $0.id == id }) else { return }
        completed.insert(id)
        while let first = buffers.first, completed.remove(first.id) != nil {
            bufferedSamples -= first.samples
            buffers.removeFirst()
        }
    }

    mutating func reset() {
        buffers.removeAll(keepingCapacity: true)
        completed.removeAll(keepingCapacity: true)
        bufferedSamples = 0
    }
}
