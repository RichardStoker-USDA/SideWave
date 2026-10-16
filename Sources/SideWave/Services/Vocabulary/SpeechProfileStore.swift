// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A short description of how the user speaks and writes (vocabulary, tone, punctuation habits,
/// recurring topics), built on this Mac from their dictation history and editable. Added to every
/// Refine prompt so refinement keeps their voice. Separate from glossaries, which teach spellings;
/// this goes in the system channel with its own small budget.
struct SpeechProfile: Codable, Sendable, Equatable {
    /// The profile text the Refine model reads. Third-person, compact.
    var text: String
    /// When it was last built or edited. Nil for a never-built profile.
    var builtAt: Date?
    /// How many dictation entries the last build sampled. 0 for hand-written
    /// or never-built profiles. Surfaced as "Built from N dictations".
    var sourceEntryCount: Int

    static let empty = SpeechProfile(text: "", builtAt: nil, sourceEntryCount: 0)

    /// Tolerant decode: an older or partially-written file still loads. Any
    /// missing key falls back to the empty-profile default rather than
    /// failing the whole decode and losing the user's text.
    enum CodingKeys: String, CodingKey {
        case text, builtAt, sourceEntryCount
    }

    init(text: String, builtAt: Date?, sourceEntryCount: Int) {
        self.text = text
        self.builtAt = builtAt
        self.sourceEntryCount = sourceEntryCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = (try? c.decode(String.self, forKey: .text)) ?? ""
        self.builtAt = try? c.decodeIfPresent(Date.self, forKey: .builtAt)
        self.sourceEntryCount = (try? c.decode(Int.self, forKey: .sourceEntryCount)) ?? 0
    }
}

/// Persists the user's speech profile and its on/off toggle, and hands the
/// formatter the text to inject. One instance app-wide (`shared`).
@Observable
@MainActor
final class SpeechProfileStore {
    static let shared = SpeechProfileStore()

    /// Hard cap on the profile's length. It rides in every Refine prompt, so
    /// the budget matters — kept small and independent of the vocabulary cap.
    nonisolated static let charCap = 600

    private static let fileName = "speech-profile.json"
    private static let enabledDefaultsKey = "speechProfileEnabled"

    /// The persisted profile. Written to disk on every mutation.
    private(set) var profile: SpeechProfile

    /// Whether the profile is fed to Refine. Persisted; defaults on so a
    /// freshly built profile takes effect without an extra step. Turning it
    /// off keeps the text but stops injecting it.
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
        }
    }

    init() {
        // Default the toggle on when the key was never written.
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        }
        self.profile = Self.load()
    }

    // MARK: - Injection

    /// The text to fold into the Refine prompt: the profile when enabled and
    /// non-empty (clamped to the cap), otherwise empty. Read on the MainActor
    /// by `Settings.fromCurrentUserDefaults` and the AFM session builders.
    var promptText: String {
        guard isEnabled else { return "" }
        return Self.clamp(profile.text)
    }

    /// True when there is a saved profile to show / rebuild / clear.
    var hasProfile: Bool {
        !profile.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Mutation

    /// Replace the profile with freshly built model output.
    func setBuilt(text: String, sourceEntryCount: Int) {
        profile = SpeechProfile(
            text: Self.clamp(text),
            builtAt: Date(),
            sourceEntryCount: max(0, sourceEntryCount)
        )
        persist()
    }

    /// Save a hand-edited profile. Keeps the existing source count; refreshes
    /// `builtAt` so the "last updated" line reflects the edit. A blank edit
    /// clears the profile.
    func setEdited(text: String) {
        let clamped = Self.clamp(text)
        if clamped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clear()
            return
        }
        profile = SpeechProfile(
            text: clamped,
            builtAt: Date(),
            sourceEntryCount: profile.sourceEntryCount
        )
        persist()
    }

    /// Remove the profile entirely.
    func clear() {
        profile = .empty
        persist()
    }

    // MARK: - Persistence

    private var fileURL: URL {
        AppPaths.applicationSupportDirectory().appendingPathComponent(Self.fileName)
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profile)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[SpeechProfileStore] Could not save \(Self.fileName): \(error.localizedDescription)")
        }
    }

    private static func load() -> SpeechProfile {
        let url = AppPaths.applicationSupportDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(SpeechProfile.self, from: data) else {
            return .empty
        }
        return SpeechProfile(
            text: clamp(decoded.text),
            builtAt: decoded.builtAt,
            sourceEntryCount: decoded.sourceEntryCount
        )
    }

    // MARK: - Cleanup

    /// Cleans the model's output into a stored profile: removes wrapping quotes and a "profile:"
    /// prefix, and cuts to the length limit at a word boundary. Used by build, edit, and load so
    /// the limit is the same everywhere.
    nonisolated static func clamp(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop a wrapping pair of quotes a chatty model sometimes adds.
        if s.count > 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip a leading label the model may prepend.
        for p in ["Speaker profile:", "Profile:", "Here is the profile:", "About this speaker:"] {
            if s.lowercased().hasPrefix(p.lowercased()) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard s.count > charCap else { return s }
        let cut = String(s.prefix(charCap))
        // Prefer to end on a whole word rather than slicing one in half.
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Builder

/// Builds a speech profile from a sample of the user's dictation with the active Refine model,
/// routed like `VocabularyAIExtractor`: its own Apple Intelligence session, or Gemma through the
/// formatter. The sample stays on this Mac.
enum SpeechProfileBuilder {

    enum BuildError: LocalizedError {
        case noBackendReady
        case empty
        case declined
        case tooLong
        case failed

        var errorDescription: String? {
            switch self {
            case .noBackendReady:
                return "The Refine model needs to be loaded first. Open Settings > Refine, switch it on, wait for it to say Ready, then try again."
            case .empty:
                return "There wasn't enough dictation to read yet. Dictate a bit more, then build your profile."
            case .declined:
                return "The on-device model declined this. Try again, or edit the profile by hand."
            case .tooLong:
                return "That sample was too long for the on-device model. Try again."
            case .failed:
                return "The model couldn't build a profile from that sample. Try again, or write one by hand."
            }
        }
    }

    /// Builds a profile from a sample of the user's dictation.
    /// - Parameters:
    ///   - sampleText: A limited sample of the user's dictation, preferably refined text, from
    ///     `VocabularyAIExtractor.sampleText(fromRecent:maxChars:)`.
    ///   - formatter: The shared DictationFormatterService, whose loaded model is reused.
    @MainActor
    static func build(
        fromSampleText sampleText: String,
        via formatter: DictationFormatterService
    ) async throws -> String {
        let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BuildError.empty }

        switch formatter.activeBackend {
        case .appleIntelligence, .appleIntelligenceLegacy:
            return try await buildWithAFM(sample: trimmed)
        case .gemma4E2B, .gemma4E4B, .gemma4_12B:
            guard formatter.state == .ready else { throw BuildError.noBackendReady }
            let full = "\(systemInstructions)\n\n\(userPrompt(sample: trimmed))"
            let raw = try await formatter.generateRawText(fullPrompt: full, useThinkingMode: true)
            let clamped = SpeechProfileStore.clamp(raw)
            guard !clamped.isEmpty else { throw BuildError.empty }
            return clamped
        }
    }

    // MARK: Apple Intelligence

    private static func buildWithAFM(sample: String) async throws -> String {
        // Permissive guardrails, matching every other AFM surface in the app —
        // this transforms the user's own dictation, it doesn't generate new
        // content, and the default guardrails make gen-1 refuse more of it.
        let model = AFMRuntime.makeModel()
        guard case .available = model.availability else { throw BuildError.noBackendReady }

        let session = LanguageModelSession(
            model: model,
            instructions: Instructions { systemInstructions }
        )
        session.prewarm()

        do {
            let response = try await session.respond(
                to: Prompt(userPrompt(sample: sample)),
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 260)
            )
            let clamped = SpeechProfileStore.clamp(response.content)
            guard !clamped.isEmpty else { throw BuildError.empty }
            return clamped
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw BuildError.declined
            case .exceededContextWindowSize:
                throw BuildError.tooLong
            case .assetsUnavailable, .unsupportedLanguageOrLocale:
                throw BuildError.noBackendReady
            default:
                throw BuildError.failed
            }
        }
    }

    // MARK: Prompt

    /// System instructions for both Apple Intelligence and Gemma: describe the speaker's voice
    /// briefly in the third person, without copying content or private details.
    static let systemInstructions = """
    You read a sample of things one person has dictated and write a SHORT profile of how that person naturally speaks and writes. The profile is given to a text-cleanup model as background so it can preserve the speaker's voice instead of flattening it into generic prose.

    Capture, compactly:
    - Characteristic vocabulary and expressions they reach for.
    - Tone and register (formal, casual, blunt, warm, dry humor, technical, and so on).
    - Punctuation and formatting habits worth preserving.
    - Recurring topics or the domain they dictate about.

    DO:
    - Write ONE compact paragraph, about 400 to 600 characters total.
    - Describe the speaker in the third person ("Tends to...", "Often uses...", "Prefers...").
    - Be concrete and specific to THIS sample. Name the actual words, phrasings, and quirks you see.
    - Focus on what a cleanup model would need in order to keep the speaker sounding like themselves.

    DO NOT:
    - Quote long passages or list every word.
    - Include private facts (names, numbers, addresses, credentials, health details). Describe STYLE, not content.
    - Add a heading, preamble, or commentary. Output ONLY the profile text.
    - Exceed 600 characters.
    """

    static func userPrompt(sample: String) -> String {
        """
        SAMPLE OF THINGS THIS PERSON DICTATED:
        \(sample)

        Write the speaker profile now, following the rules above. Output only the profile text (about 400 to 600 characters), no preamble.
        """
    }
}
