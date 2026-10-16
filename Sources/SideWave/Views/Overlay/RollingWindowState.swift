// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
@preconcurrency import AppKit

// MARK: - Rolling Window State

/// Keeps the last few confirmed lines and the current volatile segment, so rendering cost stays
/// constant. In polling mode only the volatile text changes, so it is split into lines and all but
/// the last are treated as confirmed.
@MainActor
@Observable
final class RollingWindowState {
    struct TranscriptionLine: Identifiable, Equatable {
        let id: String
        let text: String
    }

    var confirmedLines: [TranscriptionLine] = []
    var volatileText: String = ""

    var maxLines: Int = 5
    /// Characters per line before word-wrapping. Scales with overlay width.
    /// At body font size, ~1 character = ~8.5px. Subtract ~40px for horizontal padding.
    var wrapCharLimit: Int = 55
    private var previousConfirmed = ""
    private var previousVolatile = ""

    /// Call this whenever TranscriptionService publishes new confirmed/volatile values.
    func update(confirmed: String, volatile: String) {
        // Polling mode: confirmed stays empty, all text arrives as volatile.
        // Split volatile into pseudo-confirmed lines so the rolling window works.
        if confirmed.isEmpty && !volatile.isEmpty {
            updatePollingMode(volatile: volatile)
            return
        }

        // Standard mode: confirmed text grows over time, volatile is the
        // active segment being transcribed.

        // Always update volatile text. This must happen on every call so
        // the overlay keeps showing new speech between segment finalizations
        // (when confirmed stays constant for ~14s).
        volatileText = volatile

        // Confirmed text hasn't changed, so its lines are already built.
        guard confirmed != previousConfirmed else { return }
        previousConfirmed = confirmed

        // Clear stale polling-mode tracking so a future transition back to
        // polling mode (unlikely but defensive) doesn't skip the first update.
        previousVolatile = ""

        if confirmed.isEmpty {
            confirmedLines = []
            return
        }

        // Only process the tail to avoid O(n) on the full transcript each update
        let textToSplit: String
        if confirmed.count > 2000 {
            textToSplit = String(confirmed.suffix(2000))
        } else {
            textToSplit = confirmed
        }
        let sentences = splitIntoLines(textToSplit)
        let tail = Array(sentences.suffix(maxLines))
        let newLines = makePositionalLines(from: tail)
        // Only publish if line content actually changed to avoid unnecessary re-renders
        if newLines.map(\.text) != confirmedLines.map(\.text) {
            confirmedLines = newLines
        }
    }

    /// Polling mode handler. Splits the full volatile text into display lines,
    /// treats all but the last as pseudo-confirmed for the rolling effect.
    private func updatePollingMode(volatile: String) {
        guard volatile != previousVolatile else { return }
        previousVolatile = volatile

        // Only process the tail to avoid O(n) on the full transcript each update
        let textToSplit: String
        if volatile.count > 2000 {
            textToSplit = String(volatile.suffix(2000))
        } else {
            textToSplit = volatile
        }
        let allLines = splitIntoLines(textToSplit)

        if allLines.count <= 1 {
            // Single line or less: everything is volatile, no confirmed lines
            confirmedLines = []
            volatileText = volatile
            return
        }

        // All lines except the last become pseudo-confirmed (capped to maxLines)
        let pseudoConfirmed = Array(allLines.dropLast())
        let tail = Array(pseudoConfirmed.suffix(maxLines))
        let newLines = makePositionalLines(from: tail)
        // Only publish if line content actually changed to avoid unnecessary re-renders
        if newLines.map(\.text) != confirmedLines.map(\.text) {
            confirmedLines = newLines
        }

        // Last line stays volatile (still being spoken)
        volatileText = allLines.last ?? ""
    }

    func reset() {
        confirmedLines = []
        volatileText = ""
        previousConfirmed = ""
        previousVolatile = ""
    }

    /// Lines get position-based IDs, so SwiftUI updates their text in place when the recognizer
    /// revises wording, instead of animating a removal and insertion.
    private func makePositionalLines(from texts: [String]) -> [TranscriptionLine] {
        texts.enumerated().map { index, text in
            TranscriptionLine(id: "line-\(index)", text: text)
        }
    }

    /// Wraps on the character limit only, so short sentences share a row instead of each leaving
    /// empty space after it.
    private func splitIntoLines(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let limit = wrapCharLimit
        var lines: [String] = []
        var current = ""
        let chars = Array(trimmed)

        for char in chars {
            current.append(char)
            if current.count > limit && char == " " {
                lines.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
            }
        }

        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(current.trimmingCharacters(in: .whitespaces))
        }

        return lines
    }
}
