// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

@MainActor
extension MeetingFormatterService {
    // MARK: - Long-transcript map-reduce

    /// Output-token ceiling for the main formatting / synthesis pass. Bounds
    /// runaway generation (ChatSession's default leaves maxTokens nil) while
    /// leaving room for a thorough Full Report (~3,000 words).
    nonisolated static let maxOutputTokens = 4096

    nonisolated static func canReuseContext(cachedTokens: Int, promptTokens: Int, contextCap: Int) -> Bool {
        cachedTokens + promptTokens + maxOutputTokens + 512 <= contextCap
    }
    /// Smaller ceiling for per-chunk map-reduce notes — these are working
    /// notes, not prose.
    nonisolated private static let maxChunkNotesTokens = 1024
    /// Per-chunk token budget for map-reduce. Comfortably under the window so
    /// each notes pass has room for its own output and the section stays
    /// coherent.
    nonisolated private static let chunkTokenBudget = 6000

    /// Conservative token estimate at ~3.5 characters per token. Deliberately
    /// low chars-per-token so the estimate runs high and budgeting errs toward
    /// smaller chunks rather than context overflow.
    nonisolated static func estimatedTokens(forCharacters count: Int) -> Int {
        Int((Double(max(0, count)) / 3.5).rounded(.up))
    }

    /// Deterministic extraction with a mild repetition penalty and bounded output.
    static func gemmaParameters(maxTokens: Int) -> GenerateParameters {
        GenerateParameters(maxTokens: maxTokens, temperature: 0,
                           repetitionPenalty: 1.1, repetitionContextSize: 128)
    }

    /// System instruction for the per-chunk map pass. Extracts structured,
    /// attribution-preserving notes that the synthesis pass later combines.
    private static let chunkNotesInstruction = """
    Extract concise working notes from a section of a meeting transcript. Write each note as "- [Type] Speaker: fact", where Type is Decision, Action, Proposal, Fact, or Open question. Preserve whether a statement was agreed, proposed, rejected, or uncertain. A Decision requires explicit agreement; preserve the commitment as stated, even when mentioned only once. Preserve exact speaker labels, owners, amounts, dates, and deadlines. List each distinct fact once. Do not continue repetitive passages or invent information. Do not add an introduction or conclusion.
    """

    /// Render a run of segments to the same "[time] Name: text" form as
    /// `MeetingTranscript.plainText`, resolving names from `speakerNames`.
    nonisolated private static func renderChunk(_ segments: [MeetingSegment], speakerNames: [String: String]) -> String {
        segments.map { seg in
            let name = speakerNames[seg.speakerId] ?? seg.speakerLabel
            return "[\(seg.formattedTimeRange)] \(name): \(seg.text)"
        }.joined(separator: "\n\n")
    }

    /// Rendered line length, including the speaker label and timestamp range.
    nonisolated static func renderedLength(of segment: MeetingSegment, speakerName: String? = nil) -> Int {
        segment.text.count + (speakerName ?? segment.speakerLabel).count + segment.formattedTimeRange.count + 7
    }

    /// Keep speaker turns together when they fit. Split a long monologue at
    /// word boundaries, retaining every character, speaker, and source time range.
    nonisolated static func chunkSegments(_ segments: [MeetingSegment], tokenBudget: Int,
                                          speakerNames: [String: String] = [:],
                                          tokenCount: ((String) -> Int)? = nil) -> [[MeetingSegment]] {
        guard !segments.isEmpty else { return [] }
        let budget = max(1, tokenBudget)
        func measuredTokens(_ segment: MeetingSegment) -> Int {
            if let tokenCount { return tokenCount(renderChunk([segment], speakerNames: speakerNames) + "\n\n") }
            return estimatedTokens(forCharacters: renderedLength(of: segment, speakerName: speakerNames[segment.speakerId]))
        }
        let bounded = segments.flatMap { segment -> [MeetingSegment] in
            let overhead = renderedLength(of: segment, speakerName: speakerNames[segment.speakerId]) - segment.text.count
            let characterBudget = max(1, Int(Double(budget) * 3.5) - overhead)
            guard measuredTokens(segment) > budget else { return [segment] }
            var pieces: [MeetingSegment] = []
            var start = segment.text.startIndex
            while start < segment.text.endIndex {
                var size = characterBudget
                var end = segment.text.index(start, offsetBy: size, limitedBy: segment.text.endIndex) ?? segment.text.endIndex
                func piece(endingAt end: String.Index) -> MeetingSegment {
                    MeetingSegment(id: segment.id, speakerId: segment.speakerId,
                        speakerLabel: segment.speakerLabel, text: String(segment.text[start..<end]),
                        startTime: segment.startTime, endTime: segment.endTime)
                }
                while measuredTokens(piece(endingAt: end)) > budget, size > 1 {
                    size = max(1, size / 2)
                    end = segment.text.index(start, offsetBy: size, limitedBy: segment.text.endIndex) ?? segment.text.endIndex
                }
                if end < segment.text.endIndex,
                   let boundary = segment.text[start..<end].lastIndex(where: \.isWhitespace) {
                    end = segment.text.index(after: boundary)
                }
                pieces.append(piece(endingAt: end))
                start = end
            }
            return pieces
        }
        var chunks: [[MeetingSegment]] = []
        var current: [MeetingSegment] = []
        var currentTokens = 0
        for segment in bounded {
            let segTokens = measuredTokens(segment)
            if !current.isEmpty, currentTokens + segTokens > budget {
                chunks.append(current)
                current = []
                currentTokens = 0
            }
            current.append(segment)
            currentTokens += segTokens
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Remove consecutive repeated sentence blocks from model input only.
    nonisolated static func notesSource(_ text: String) -> String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { value, _, _, _ in
            if let value { sentences.append(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard sentences.count > 1 else { return text }
        var result: [String] = []
        var index = 0
        while index < sentences.count {
            let remaining = sentences.count - index
            var blockSize = 1
            if remaining >= 2 {
                for size in 1...min(8, remaining / 2) {
                    if sentences[index..<(index + size)].elementsEqual(sentences[(index + size)..<(index + 2 * size)]) {
                        blockSize = size
                        break
                    }
                }
            }
            let block = sentences[index..<(index + blockSize)]
            result.append(contentsOf: block)
            index += blockSize
            while index + blockSize <= sentences.count,
                  block.elementsEqual(sentences[index..<(index + blockSize)]) {
                index += blockSize
            }
        }
        return result.joined(separator: " ")
    }

    /// Compare numeric facts without treating grouping commas as new values.
    nonisolated static func numericFacts(in text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])\d+(?:[.,]\d+)*(?![\p{L}\p{N}])"#) else { return [] }
        let nsText = text as NSString
        return Set(expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map {
            let value = nsText.substring(with: $0.range)
            if value.range(of: #"^\d{1,3}(?:,\d{3})+(?:\.\d+)?$"#, options: .regularExpression) != nil {
                return value.replacingOccurrences(of: ",", with: "")
            }
            return value
        })
    }

    /// Verbatim excerpts let synthesis check amounts against the source, not just a summary.
    nonisolated static func numericSourceExcerpts(_ segments: [MeetingSegment], speakerNames: [String: String]) -> String {
        var excerpts: [String] = []
        var seen = Set<String>()
        for segment in segments {
            let speaker = speakerNames[segment.speakerId] ?? segment.speakerLabel
            let source = notesSource(segment.text)
            source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: .bySentences) { value, _, _, _ in
                guard let value, !numericFacts(in: value).isEmpty else { return }
                let excerpt = "- [Source] \(speaker): \(value.trimmingCharacters(in: .whitespacesAndNewlines))"
                if seen.insert(excerpt).inserted { excerpts.append(excerpt) }
            }
        }
        return excerpts.joined(separator: "\n")
    }

    nonisolated static func decisionNumericFacts(in notes: String) -> Set<String> {
        notes.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains("[Decision]") }
            .reduce(into: Set<String>()) { $0.formUnion(numericFacts(in: String($1))) }
    }

    private func extractSectionNotes(_ segments: [MeetingSegment], speakerNames: [String: String],
                                     container: ModelContainer, retryDepth: Int = 0) async throws -> String {
        try Task.checkCancellation()
        let compactSegments = segments.map { segment in
            MeetingSegment(id: segment.id, speakerId: segment.speakerId, speakerLabel: segment.speakerLabel,
                text: Self.notesSource(segment.text), startTime: segment.startTime, endTime: segment.endTime)
        }
        let source = Self.renderChunk(compactSegments, speakerNames: speakerNames)
        let sourceTokens = await container.encode(source).count
        guard sourceTokens <= Self.chunkTokenBudget else { throw FormatterError.incompleteNotes }
        let session = ChatSession(container, instructions: Self.chunkNotesInstruction,
            generateParameters: Self.gemmaParameters(maxTokens: Self.maxChunkNotesTokens),
            additionalContext: ["enable_thinking": false])
        let prompt = """
        <transcript_section>
        \(source)
        </transcript_section>

        Extract every distinct fact from this section. Keep amounts, dates, deadlines, and owners, including facts mentioned only once. Repeated statements need only one note.
        """
        var notes = ""
        for try await piece in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            notes += piece
        }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let required = Self.numericFacts(in: segments.map(\.text).joined(separator: "\n"))
        let preservesNumbers = required.isSubset(of: Self.numericFacts(in: trimmed))
        let outputTokens = await container.encode(trimmed).count
        let excerpts = Self.numericSourceExcerpts(compactSegments, speakerNames: speakerNames)
        let result = excerpts.isEmpty ? trimmed : trimmed + "\nVerbatim excerpts for checking numeric facts:\n" + excerpts
        let resultTokens = await container.encode(result).count
        if !trimmed.isEmpty, preservesNumbers, outputTokens < Self.maxChunkNotesTokens,
           resultTokens < Self.chunkTokenBudget - 64 {
            return result
        }

        // Shorter sections give isolated facts another chance without changing the transcript.
        guard retryDepth < 2 else { throw FormatterError.incompleteNotes }
        state = .generating(output: "", note: "Checking details in a shorter section")
        let parts = await container.perform { context in
            Self.chunkSegments(compactSegments, tokenBudget: max(128, sourceTokens / 2 - 64),
                speakerNames: speakerNames, tokenCount: { context.tokenizer.encode(text: $0).count })
        }
        guard parts.count > 1 else { throw FormatterError.incompleteNotes }
        var retried: [String] = []
        for part in parts {
            retried.append(try await extractSectionNotes(part, speakerNames: speakerNames,
                container: container, retryDepth: retryDepth + 1))
        }
        return retried.joined(separator: "\n")
    }

    func runGemmaMapReduce(
        container: ModelContainer,
        transcript: MeetingTranscript,
        vocabSection: String,
        format: MeetingFormat
    ) async throws {
        // Map-reduce doesn't reuse the transcript KV cache (each chunk is
        // independent, synthesis runs over notes), so drop any stale session.
        chatSession = nil
        cachedTranscriptHash = nil

        let speakerNames = transcript.speakerNames
        let chunks = await container.perform { context in
            Self.chunkSegments(transcript.segments, tokenBudget: Self.chunkTokenBudget - 64,
                speakerNames: speakerNames, tokenCount: { context.tokenizer.encode(text: $0).count })
        }
        guard !chunks.isEmpty else {
            state = .error("This meeting has no transcript to format.")
            return
        }
        print("[MeetingFormatter] Map-reduce over \(chunks.count) sections")

        // Map: per-section structured notes.
        let notesParams = Self.gemmaParameters(maxTokens: Self.maxChunkNotesTokens)
        var sectionNotes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { return }
            state = .generating(
                output: "",
                note: "Working through the transcript in sections (\(index + 1) of \(chunks.count))"
            )
            let trimmed = try await extractSectionNotes(chunk, speakerNames: speakerNames, container: container)
            sectionNotes.append("## Section \(index + 1)\n\(trimmed)")
        }

        guard !Task.isCancelled else { return }
        guard !sectionNotes.isEmpty else {
            state = .error("No output generated. Try a different format.")
            return
        }

        // Reduce notes in bounded groups before the final synthesis. A long
        // meeting can otherwise overflow the window even after the map pass.
        var mergePass = 0
        while await container.encode(sectionNotes.joined(separator: "\n\n")).count > Self.chunkTokenBudget {
            try Task.checkCancellation()
            mergePass += 1
            guard mergePass <= 8 else { throw FormatterError.incompleteNotes }
            let notesToGroup = sectionNotes
            let groups = await container.perform { context in
                Self.groupNotes(notesToGroup, tokenBudget: Self.chunkTokenBudget - 64,
                    tokenCount: { context.tokenizer.encode(text: $0).count })
            }
            let previousSize = sectionNotes.reduce(0) { $0 + $1.count }
            var combined: [String] = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                guard await container.encode(group.joined(separator: "\n\n")).count <= Self.chunkTokenBudget else {
                    throw FormatterError.incompleteNotes
                }
                state = .generating(output: "", note: "Combining notes (\(index + 1) of \(groups.count))")
                let session = ChatSession(container,
                    instructions: "Combine these meeting notes into concise working notes. Merge repeated facts into one note. Preserve all distinct decisions, owners, dates, numbers, and unresolved questions. Use only the provided notes. Keep speaker labels and each note's [Type] prefix unchanged.",
                    generateParameters: notesParams, additionalContext: ["enable_thinking": false])
                var merged = ""
                for try await piece in session.streamResponse(to: group.joined(separator: "\n\n")) {
                    try Task.checkCancellation()
                    merged += piece
                }
                let cleaned = merged.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { throw FormatterError.incompleteNotes }
                combined.append(cleaned)
            }
            guard combined.reduce(0, { $0 + $1.count }) < previousSize else { throw FormatterError.incompleteNotes }
            sectionNotes = combined
        }

        state = .generating(output: "", note: "Combining sections")
        let notesDoc = sectionNotes.joined(separator: "\n\n")
        let base = """
        Below are structured notes taken section by section from a long meeting transcript, in order. Produce the final document from these notes only. Merge duplicate facts across sections; do not repeat a decision just because several sections mention it. Preserve the exact amounts, dates, deadlines, and owners relevant to the requested format.

        Meeting date: \(transcript.formattedDate)
        Duration: \(MeetingSegment.formatTimestamp(transcript.duration))

        NOTES:
        \(notesDoc)

        Format this as: \(format.rawValue)

        \(resolvedSystemPrompt(for: format))
        """
        let synthMessage = withVocabulary(base, vocabSection)
        let synthSession = ChatSession(
            container,
            instructions: "You are a professional meeting transcript processor. Follow the user's formatting instructions precisely. Be concise, accurate, and well-organized. Only use information from the provided notes.",
            generateParameters: Self.gemmaParameters(maxTokens: Self.maxOutputTokens),
            additionalContext: ["enable_thinking": false]
        )
        var fullOutput = ""
        for try await piece in synthSession.streamResponse(to: synthMessage) {
            guard !Task.isCancelled else { return }
            fullOutput += piece
            guard !Task.isCancelled else { return }
            state = .generating(output: fullOutput, note: nil)
        }

        guard !Task.isCancelled else { return }

        if format == .keyDecisions {
            let required = Self.decisionNumericFacts(in: notesDoc)
            let mentioned = transcript.segments.reduce(into: Set<String>()) { $0.formUnion(Self.numericFacts(in: $1.text)) }
            if !required.union(mentioned).isSubset(of: Self.numericFacts(in: fullOutput)) {
                state = .generating(output: "", note: "Checking decisions against the source notes")
                let reviewSession = ChatSession(container,
                    instructions: "Correct a meeting decision list using only the provided source notes. Include every [Decision] note and every explicit agreement in a [Source] excerpt, preserving its exact amount, owner, deadline, and conditions. Source excerpts are verbatim and take precedence over a note's category when they clearly state agreement. Do not turn a Proposal or Fact into a decision. Return only the corrected numbered list.",
                    generateParameters: Self.gemmaParameters(maxTokens: Self.maxOutputTokens),
                    additionalContext: ["enable_thinking": false])
                let reviewPrompt = "SOURCE NOTES:\n\(notesDoc)\n\nDRAFT:\n\(fullOutput)\n\nCorrect the omitted decisions and return the complete list."
                fullOutput = ""
                for try await piece in reviewSession.streamResponse(to: reviewPrompt) {
                    try Task.checkCancellation()
                    fullOutput += piece
                    state = .generating(output: fullOutput, note: "Checking decisions")
                }
                guard required.isSubset(of: Self.numericFacts(in: fullOutput)) else { throw FormatterError.incompleteNotes }
            }
        }

        if fullOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .error("No output generated. Try a different format.")
        } else {
            state = .complete(output: fullOutput)
            MeetingHistoryStore.shared.saveFormattedOutput(
                meetingID: transcript.id,
                format: format.rawValue,
                output: fullOutput
            )
        }
        print("[MeetingFormatter] Map-reduce complete (\(fullOutput.count) chars)")
    }

    nonisolated static func groupNotes(_ notes: [String], tokenBudget: Int,
                                      tokenCount: ((String) -> Int)? = nil) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var size = 0
        for note in notes {
            let text = note + (current.isEmpty ? "" : "\n\n")
            let added = tokenCount?(text) ?? estimatedTokens(forCharacters: text.count)
            if !current.isEmpty, size + added > max(1, tokenBudget) {
                groups.append(current)
                current = []
                size = 0
            }
            size += added
            current.append(note)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
