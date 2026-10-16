// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Presentation only. Recognition owns the text and decides when it is confirmed.
struct RecognitionPreviewState: Equatable {
    struct Word: Equatable {
        let text: String
        var separator: String = ""
        let confirmedAt: TimeInterval
    }

    static let fadeDuration: TimeInterval = 0.2
    static let maximumStagger: TimeInterval = 0.24
    static let wordLimit = 1_024
    private(set) var words: [Word] = []
    private var confirmedText = ""

    func updating(confirmed: String, at now: TimeInterval) -> Self {
        guard confirmed != confirmedText else { return self }
        let tokens = Self.tokenize(confirmed)
        let next = tokens.map(\.text)
        let old = words.map(\.text)
        let difference = next.difference(from: old)
        var retained = words
        for change in difference.removals.reversed() {
            if case let .remove(offset, _, _) = change { retained.remove(at: offset) }
        }
        var inserted = Set<Int>()
        for change in difference.insertions {
            if case let .insert(offset, text, _) = change {
                retained.insert(Word(text: text, confirmedAt: now), at: offset)
                inserted.insert(offset)
            }
        }
        let step = min(0.025, Self.maximumStagger / Double(max(1, inserted.count - 1)))
        for (index, offset) in inserted.sorted().enumerated() {
            retained[offset] = Word(text: retained[offset].text, confirmedAt: now + Double(index) * step)
        }
        for index in retained.indices { retained[index].separator = tokens[index].separator }
        var result = self
        result.words = retained
        result.confirmedText = confirmed
        return result
    }

    private static func tokenize(_ text: String) -> [(text: String, separator: String)] {
        var tokens: [(text: String, separator: String)] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text[cursor...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            let next = text[end...].firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
            if cursor < end { tokens.append((String(text[cursor..<end]), String(text[end..<next]))) }
            cursor = next
        }
        return Array(tokens.suffix(wordLimit))
    }

    func progress(for word: Word, at now: TimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        let fraction = min(1, max(0, (now - word.confirmedAt) / Self.fadeDuration))
        return fraction * fraction * (3 - 2 * fraction)
    }

    var settledAt: TimeInterval { (words.map(\.confirmedAt).max() ?? 0) + Self.fadeDuration }

    func frameDates(after now: TimeInterval) -> [Date] {
        guard settledAt > now else { return [] }
        return stride(from: now, to: settledAt, by: 1.0 / 30).map(Date.init(timeIntervalSinceReferenceDate:))
            + [Date(timeIntervalSinceReferenceDate: settledAt)]
    }
}

/// A shared ASR-only preview. Drafts update immediately; commits settle once.
struct RecognitionPreview: View {
    let confirmed: String
    let draft: String
    let reduceMotion: Bool
    var sampleTime: TimeInterval? = nil
    @State private var presentation = RecognitionPreviewState()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let now = sampleTime ?? Date.timeIntervalSinceReferenceDate
        let current = presentation.updating(confirmed: confirmed, at: now)
        let dates = current.frameDates(after: now)
        Group {
            if reduceMotion || sampleTime != nil || dates.isEmpty {
                text(current, at: now)
            } else {
                TimelineView(.explicit(dates)) { timeline in
                    text(current, at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .font(.system(.body, weight: .medium))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcription")
        .accessibilityValue(([current.words.map(\.text).joined(separator: " "), draft])
            .filter { !$0.isEmpty }.joined(separator: " "))
        .onChange(of: confirmed, initial: true) {
            presentation = presentation.updating(confirmed: confirmed, at: sampleTime ?? Date.timeIntervalSinceReferenceDate)
        }
    }

    private func text(_ state: RecognitionPreviewState, at now: TimeInterval) -> Text {
        let gray: Double = colorScheme == .dark ? 0.65 : 0.42
        let primary: Double = colorScheme == .dark ? 1 : 0
        var result = Text("")
        for (index, word) in state.words.enumerated() {
            let progress = state.progress(for: word, at: now, reduceMotion: reduceMotion)
            let value = gray + (primary - gray) * progress
            let suffix = word.separator.isEmpty && index == state.words.count - 1 && !draft.isEmpty
                ? " " : word.separator
            let part = Text(word.text + suffix).foregroundColor(Color(.sRGB, red: value, green: value, blue: value, opacity: 1))
            result = Text("\(result)\(part)")
        }
        let tail = Text(draft).foregroundColor(Color(.sRGB, red: gray, green: gray, blue: gray, opacity: 1))
        return Text("\(result)\(tail)")
    }
}
