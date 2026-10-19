// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates the short title for each History row after the entry is saved, so saving is never
/// delayed. Uses Apple Intelligence, which handles a short "give me a few words" prompt well and
/// doesn't compete with Gemma for the GPU; falls back to the opening words when it's unavailable.
enum HistorySummarizer {
    /// Characters of dictation included in the title prompt, about 1000 tokens, within Apple
    /// Intelligence's 4K window. The topic is almost always set at the start.
    private static let promptTextBudget = 3500

    /// Output cap. AFM occasionally returns a sentence-fragment when it
    /// misreads "1-3 words" as "short sentence"; this trims to a sane
    /// sidebar-row length without distorting genuinely short summaries.
    private static let summaryCharCap = 32

    static func summarize(text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Under 24 characters, the text itself is the best title.
        if trimmed.count <= 24 {
            return cleanup(trimmed)
        }

        #if canImport(FoundationModels)
        if let afm = await summarizeWithAFM(text: trimmed) {
            let cleaned = cleanup(afm)
            if !cleaned.isEmpty {
                SWLog.note("[HistorySummarizer] Title generated")
                return cleaned
            }
            SWLog.note("[HistorySummarizer] AFM returned empty after cleanup — falling back to prefix")
        } else {
            SWLog.note("[HistorySummarizer] AFM unavailable or refused — falling back to prefix")
        }
        #endif

        return fallbackPrefix(text: trimmed)
    }

    #if canImport(FoundationModels)
    private static func summarizeWithAFM(text: String) async -> String? {
        let availability = DictationFormatterService.currentAFMAvailability()
        guard case .available = availability else {
            SWLog.note("[HistorySummarizer] AFM not .available — \(availability)")
            return nil
        }

        let body = String(text.prefix(promptTextBudget))
        // Ask for 2 to 4 specific words from the dictation, not a generic category, so titles tell
        // dictations apart ("Q3 hiring", "Roadmap review" rather than "Meeting notes").
        let instructions = """
        You generate a short, specific title for a dictation transcript. The title appears in a sidebar so users can scan many dictations and pick the right one. Output ONLY the title text. No quotes, no punctuation, no preamble, no trailing period.

        Rules:
        - 2 to 4 words.
        - Title Case.
        - Pull distinctive words from the dictation itself when possible (a topic, a name, a project, a question).
        - Avoid generic categories like "Notes" or "Thoughts" unless that is genuinely all the dictation contains.
        - Each dictation gets a title that distinguishes it from other dictations on similar topics.

        Examples of good titles: "Q3 Roadmap Review", "Email to Sarah", "Bug Triage", "Drought Tolerance Plan", "Audit Findings", "Pricing Decision".
        """
        let prompt = """
        Title this dictation in 2-4 specific words:

        \(body)
        """

        let model = AFMRuntime.makeModel()
        guard case .available = model.availability else {
            SWLog.note("[HistorySummarizer] AFM model.availability not .available")
            return nil
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        } catch {
            SWLog.note("[HistorySummarizer] AFM threw: \(error)")
            return nil
        }
    }
    #endif

    /// Strip surrounding quotes / brackets, trim trailing punctuation,
    /// cap length. AFM occasionally wraps short outputs in quotes
    /// even when the instructions say not to; this normalizes those.
    private static func cleanup(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripChars: Set<Character> = ["\"", "'", "`", "“", "”", "‘", "’", "[", "]", "{", "}", "(", ")"]
        while let first = s.first, stripChars.contains(first) {
            s.removeFirst()
        }
        while let last = s.last, stripChars.contains(last) {
            s.removeLast()
        }
        let trailingPunct: Set<Character> = [".", ",", ";", ":", "!", "?"]
        while let last = s.last, trailingPunct.contains(last) {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > summaryCharCap {
            s = String(s.prefix(summaryCharCap)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Final fallback: first 3-4 words of the refined text. Used when
    /// AFM is unavailable (pre-Tahoe Mac, AI disabled, refusal).
    private static func fallbackPrefix(text: String) -> String {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(4)
            .map(String.init)
        guard !words.isEmpty else { return "" }
        let joined = words.joined(separator: " ")
        return cleanup(joined)
    }
}
