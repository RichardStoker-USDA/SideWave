// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Finds vocabulary candidates in the user's plain-language description of the words they use,
/// focusing on the uncommon ones a general model would miss: names, jargon, acronyms, technical
/// terms. Uses Gemma with thinking mode when loaded, otherwise Apple Intelligence; both return
/// `Candidate` values the user reviews before saving. Runs on this Mac.
enum VocabularyAIExtractor {

    /// Categories the user can ask the model to focus on. Anything checked
    /// gets emphasized in the prompt's "focus on" list. If the user picks
    /// `.all`, every category is sent.
    enum Category: String, Hashable, CaseIterable, Identifiable, Sendable {
        case jargon
        case acronyms
        case technical
        case properNouns
        case slang

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .jargon:      return "Jargon & specialized terms"
            case .acronyms:    return "Acronyms & abbreviations"
            case .technical:   return "Technical terms"
            case .properNouns: return "Proper nouns (names, places, brands)"
            case .slang:       return "Slang & informal terms"
            }
        }

        /// Phrase the model sees in the prompt's focus list.
        var promptPhrase: String {
            switch self {
            case .jargon:      return "specialized jargon and domain-specific vocabulary"
            case .acronyms:    return "acronyms and abbreviations (USDA, gRPC, MRI, etc.)"
            case .technical:   return "technical terms a non-expert would mis-hear"
            case .properNouns: return "proper nouns — names of people, places, products, organizations"
            case .slang:       return "slang and informal phrases the user actually uses"
            }
        }
    }

    /// Lightweight struct the sheet reviews. The heavier VocabTerm gets
    /// built on save so users can tweak canonical / alias / definition
    /// before commit.
    struct Candidate: Sendable {
        let canonical: String
        let aliases: [String]
        let definition: String?
    }

    enum ExtractorError: LocalizedError {
        case noBackendReady
        case parseFailed
        case empty
        case declined
        case tooLong

        var errorDescription: String? {
            switch self {
            case .noBackendReady:
                return "The Refine model needs to be loaded before SideWave can extract vocabulary. Open Settings > Refine, switch it on, wait for it to say Ready, then try again."
            case .parseFailed:
                return "The model returned something I couldn't parse. Try rewording your description."
            case .empty:
                return "No words to extract. Be more specific about the kind of vocabulary you want."
            case .declined:
                return "The on-device model declined this description. Try rewording it, or remove anything it might read as sensitive."
            case .tooLong:
                return "That description is too long for the on-device model. Shorten it and try again."
            }
        }
    }

    /// Extracts candidates from a description.
    /// - Parameters:
    ///   - description: The user's description.
    ///   - categories: Categories to emphasize; empty means all.
    ///   - maxTerms: Maximum number of candidates. Default 12.
    ///   - formatter: The shared DictationFormatterService, whose loaded model is reused.
    @MainActor
    static func extract(
        description: String,
        categories: Set<Category>,
        maxTerms: Int,
        via formatter: DictationFormatterService
    ) async throws -> [Candidate] {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtractorError.empty }

        let clampedMax = max(3, min(30, maxTerms))
        let effectiveCategories: Set<Category> = categories.isEmpty
            ? Set(Category.allCases)
            : categories

        return try await run(
            instructions: systemInstructions(maxTerms: clampedMax),
            body: trimmed,
            bodyLabel: "USER DESCRIPTION:",
            categories: effectiveCategories,
            maxTerms: clampedMax,
            via: formatter
        )
    }

    /// Route composed instructions + prompt to the active backend, keeping the
    /// AFM and Gemma handling in one place.
    @MainActor
    private static func run(
        instructions: String,
        body: String,
        bodyLabel: String,
        categories: Set<Category>,
        maxTerms: Int,
        via formatter: DictationFormatterService
    ) async throws -> [Candidate] {
        switch formatter.activeBackend {
        case .appleIntelligence, .appleIntelligenceLegacy:
            let prompt = userPrompt(
                body: body,
                bodyLabel: bodyLabel,
                categories: categories,
                maxTerms: maxTerms,
                includeExamples: false
            )
            return try await extractWithAFM(instructions: instructions, prompt: prompt)
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            let fullPrompt = """
            \(instructions)

            \(gemmaExamples)

            \(userPrompt(
                body: body,
                bodyLabel: bodyLabel,
                categories: categories,
                maxTerms: maxTerms,
                includeExamples: true
            ))
            """
            return try await extractWithGemma(fullPrompt: fullPrompt, formatter: formatter)
        }
    }

    // MARK: - Apple Intelligence path

    private static func extractWithAFM(
        instructions: String,
        prompt: String
    ) async throws -> [Candidate] {
        // Permissive guardrails, as everywhere else Apple Intelligence is used; the defaults made
        // the first generation model refuse more descriptions.
        let model = AFMRuntime.makeModel()
        guard case .available = model.availability else {
            throw ExtractorError.noBackendReady
        }
        let session = LanguageModelSession(
            model: model,
            instructions: instructions
        )
        session.prewarm()

        // Guided generation into AFMVocabCandidates instead of asking for JSON, which the first
        // generation model often got wrong. Gemma has no equivalent, so its path parses JSON.
        do {
            var terms: [AFMVocabTerm.PartiallyGenerated] = []
            let stream = session.streamResponse(
                to: Prompt(prompt),
                generating: AFMVocabCandidates.self,
                options: GenerationOptions(samplingMode: .greedy)
            )
            for try await partial in stream {
                try Task.checkCancellation()
                if let t = partial.content.terms { terms = t }
            }
            let candidates = terms.compactMap { Self.candidate(from: $0) }
            guard !candidates.isEmpty else { throw ExtractorError.empty }
            return candidates
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw ExtractorError.declined
            case .exceededContextWindowSize:
                throw ExtractorError.tooLong
            case .assetsUnavailable, .unsupportedLanguageOrLocale:
                throw ExtractorError.noBackendReady
            default:
                throw ExtractorError.parseFailed
            }
        }
    }

    /// Map a streamed AFMVocabTerm snapshot to a Candidate, applying the same
    /// trimming + 120-char definition clip the JSON path uses. Nil when the
    /// canonical hasn't decoded or is blank.
    private static func candidate(from partial: AFMVocabTerm.PartiallyGenerated) -> Candidate? {
        guard let canonicalRaw = partial.canonical else { return nil }
        let canonical = canonicalRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return nil }
        let aliases = (partial.aliases ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let defTrimmed = partial.definition?.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition: String? = {
            guard let d = defTrimmed, !d.isEmpty else { return nil }
            return d.count > 120 ? String(d.prefix(120)) : d
        }()
        return Candidate(canonical: canonical, aliases: aliases, definition: definition)
    }

    // MARK: - Gemma path

    @MainActor
    private static func extractWithGemma(
        fullPrompt: String,
        formatter: DictationFormatterService
    ) async throws -> [Candidate] {
        // Only run when the formatter is idle-ready. Driving a second
        // generation against the same MLX ModelContainer while a Refine
        // pass is mid-stream competes for the GPU pipeline.
        guard formatter.state == .ready else {
            throw ExtractorError.noBackendReady
        }

        // Thinking mode on: it noticeably improves Gemma's extraction. Two to three times slower,
        // but the user is already watching a progress view.
        let raw = try await formatter.generateRawText(
            fullPrompt: fullPrompt,
            useThinkingMode: true
        )
        return try parseJSON(raw)
    }

    // MARK: - Prompts

    /// System-channel instructions. Used by both AFM (as `Instructions`)
    /// and Gemma (prepended to the user prompt with the chat template).
    private static func systemInstructions(maxTerms: Int) -> String {
        return """
        You extract custom vocabulary words from a description provided by the user. Your goal is to identify words the dictation model would most likely MISTRANSCRIBE or fail to recognize — proper nouns, acronyms, jargon, technical terms, brand names, specialized vocabulary, or slang the user actually says.

        DO:
        - Focus on uncommon words a standard speech recognizer would miss.
        - Honor the user's focus categories (listed in the user prompt). If they checked specific kinds, prioritize those, but always include any uncommon term the recognizer would butcher even if it doesn't fit a checked category.
        - Keep canonical capitalization natural (USDA stays all-caps; iPhone stays mixed-case; people's names stay capitalized).
        - Suggest aliases (mishearings / phonetic spellings) when the canonical contains acronyms, technical jargon, or unusual spellings. Example: "Kubernetes" → aliases ["k8s", "k eights", "kates"].
        - Write SHORT descriptions: a single phrase, 30–90 characters, describing what the word means or how it's used. No full sentences, no preambles. Examples: "Container orchestration platform." "Federal agricultural research agency." "Apple's on-device LLM."
        - Return AT MOST \(maxTerms) words.

        DO NOT:
        - Include common English words the dictation model already gets right.
        - Write definitions longer than ~90 characters.
        - Add commentary, preamble, markdown, or trailing prose.
        - Output anything except a JSON array.

        OUTPUT FORMAT (strict):
        A JSON array of objects, each with keys:
          "canonical" — string, required (the correct spelling)
          "aliases"   — array of strings (common mishearings; may be empty)
          "definition" — string (short hint; may be empty)
        """
    }

    private static let gemmaExamples = """
    EXAMPLE INPUT (focus: acronyms, technical, proper nouns; max 6):
    "I work in cloud infrastructure. We use Kubernetes, PostgreSQL, gRPC, and OpenTelemetry. CI/CD runs on GitLab."

    EXAMPLE OUTPUT:
    [
      {"canonical":"Kubernetes","aliases":["k8s","k eights","kates"],"definition":"Container orchestration platform."},
      {"canonical":"PostgreSQL","aliases":["postgres","post grease"],"definition":"Open-source relational database."},
      {"canonical":"gRPC","aliases":["g r p c","gee rpc"],"definition":"High-performance RPC framework over HTTP/2."},
      {"canonical":"OpenTelemetry","aliases":["otel","oh tell","open telemetry"],"definition":"Observability framework for traces, metrics, logs."},
      {"canonical":"CI/CD","aliases":["c i c d","see eye see dee"],"definition":"Continuous integration and continuous delivery."},
      {"canonical":"GitLab","aliases":["git lab"],"definition":"DevOps platform with built-in Git hosting."}
    ]
    """

    private static func userPrompt(
        body: String,
        bodyLabel: String,
        categories: Set<Category>,
        maxTerms: Int,
        includeExamples: Bool
    ) -> String {
        // Sort by case order so the list reads consistently across runs.
        let focused = Category.allCases.filter { categories.contains($0) }
        let focusLines = focused.map { "- " + $0.promptPhrase }.joined(separator: "\n")
        let focusBlock: String
        if focused.count == Category.allCases.count {
            focusBlock = "Focus categories: ALL (jargon, acronyms, technical terms, proper nouns, slang). The user wants every uncommon word the dictation model might miss."
        } else {
            focusBlock = "Focus categories — prioritize words from these kinds:\n\(focusLines)"
        }

        let tail = includeExamples
            ? "\n\nNow produce the JSON for the text above. Match the example output format exactly. Output only the JSON array."
            : "\n\nReturn only the JSON array."

        return """
        \(focusBlock)
        Maximum words: \(maxTerms)

        \(bodyLabel)
        \(body)
        \(tail)
        """
    }

    // MARK: - Parsing

    private static func parseJSON(_ raw: String) throws -> [Candidate] {
        // Models sometimes wrap JSON in fences or add an introduction; take the first [...] block.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"),
              start < end
        else {
            throw ExtractorError.parseFailed
        }
        let jsonString = String(trimmed[start...end])
        guard let data = jsonString.data(using: .utf8) else {
            throw ExtractorError.parseFailed
        }

        struct RawCandidate: Decodable {
            let canonical: String
            let aliases: [String]?
            let definition: String?
        }

        let raw: [RawCandidate]
        do {
            raw = try JSONDecoder().decode([RawCandidate].self, from: data)
        } catch {
            throw ExtractorError.parseFailed
        }

        let result = raw.compactMap { r -> Candidate? in
            let canonical = r.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { return nil }
            let aliases = (r.aliases ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Hard-clip the definition to 120 chars so a chatty model can't
            // bloat the prompt budget downstream. The UI cap is 120 too.
            let defTrimmed = r.definition?.trimmingCharacters(in: .whitespacesAndNewlines)
            let definition: String? = {
                guard let d = defTrimmed, !d.isEmpty else { return nil }
                return d.count > 120 ? String(d.prefix(120)) : d
            }()
            return Candidate(canonical: canonical, aliases: aliases, definition: definition)
        }
        guard !result.isEmpty else { throw ExtractorError.empty }
        return result
    }

    // MARK: - Sample building

    /// A sample of the user's recent dictation for the history-based extractor: newest first,
    /// trimmed, blanks and exact repeats skipped, whole entries added until `maxChars` (only the
    /// first entry may be cut). About 1000 tokens, leaving room for instructions and output within
    /// Apple Intelligence's 4K window. Returns "" when there's nothing usable.
    static func sampleText(fromRecent texts: [String], maxChars: Int = 4000) -> String {
        var seen = Set<String>()
        var out: [String] = []
        var used = 0
        for raw in texts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            guard seen.insert(t.lowercased()).inserted else { continue }
            if used >= maxChars { break }
            let remaining = maxChars - used
            let clip = t.count > remaining ? String(t.prefix(remaining)) : t
            out.append(clip)
            used += clip.count + 1
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - AFM guided-generation schema

/// @Generable extraction schema for the Apple Intelligence path. Constrained
/// decoding replaces the freeform-JSON prompt + firstIndex('[') scraping —
/// gen-1 in particular drifts on strict JSON prose but honors a typed schema.
@Generable
struct AFMVocabTerm {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "The correct spelling of the term, with natural capitalization (USDA stays all-caps, iPhone stays mixed-case, names stay capitalized).")
    var canonical: String

    @Guide(description: "Common mishearings or phonetic spellings a dictation model would produce (e.g. ['k8s','k eights','kates']). May be empty.")
    var aliases: [String]

    @Guide(description: "A short 30-90 character hint describing the term. No full sentences, no preamble. May be empty.")
    var definition: String
}

@Generable
struct AFMVocabCandidates {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "The extracted vocabulary terms — the uncommon proper nouns, acronyms, jargon, technical terms, brand names, and slang a standard dictation model would most likely mistranscribe.")
    var terms: [AFMVocabTerm]
}
