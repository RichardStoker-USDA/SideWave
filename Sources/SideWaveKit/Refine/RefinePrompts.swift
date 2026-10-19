// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

/// Template rules for local refine models. Live behavior tests cover
/// preservation, cleanup, translation, and custom instructions.
enum RefinePrompts {

    static let maxCustomInstructionsChars = 1000

    // MARK: Gemma system prompt

    static func gemmaSystemPrompt(
        for template: RefineTemplate,
        outputLanguage: RefineOutputLanguage,
        speakerProfile: String
    ) -> String {
        var parts: [String] = []

        switch template {
        case .standard, .custom:
            parts.append("You are a transcription editor. Clean up dictated text. Output ONLY the corrected text, no commentary.")
        case .professional:
            parts.append("You are a careful editor. Clean up dictated text into professional writing while keeping the speaker's own voice — fix mechanics and lift register, don't rewrite them into a different writer. Output ONLY the corrected text, no commentary.")
        case .concise:
            parts.append("You are a text editor. Tighten dictated text while keeping the speaker's own words and voice. Output ONLY the tightened text, no commentary.")
        }

        parts.append(templateCoreBlock(template))
        parts.append("Preserve who performs each action. Keep the speaker's grammatical person and number: never change I to we or we to I.")
        parts.append(refineLanguageRule(for: outputLanguage))
        parts.append(templateTail(template))

        parts.append("If the prompt includes a Reference vocabulary section, apply those preferred spellings and word replacements exactly — they are the user's corrections for terms the dictation model gets wrong.")

        if !speakerProfile.isEmpty {
            parts.append("About this speaker (how they naturally talk and write): \(speakerProfile) Use this only to recognize and preserve the speaker's own voice, vocabulary, and phrasing. Do NOT copy it into the output, add topics or opinions it mentions, or restyle beyond what the current input actually says.")
        }

        parts.append("Never repeat the same 3+ word phrase verbatim within your output. If your rewrite would otherwise place the same phrase twice, use it once.")

        parts.append(noCompletionRule)
        parts.append(noTruncationRule)

        return parts.joined(separator: "\n\n")
    }

    // MARK: Template blocks

    static func templateCoreBlock(_ template: RefineTemplate) -> String {
        switch template {
        case .standard:
            return """
            Clean up this dictated text. Fix grammar, punctuation, sentence capitalization, and transcription errors. Polish application vocabulary and acronyms according to any provided domain terms while strictly preserving the speaker's original voice, natural vocabulary, and sentence structure.

            Edit ONLY:
            - Acoustic repeats and false starts (e.g., "we need to... we need to go" -> "we need to go")
            - Filler words (um, uh, you know, like)
            - Punctuation, capitalization, and grammar errors
            - Transcription errors (fix mumbled or incorrect words by using context clues to determine what the speaker actually meant)
            - Domain vocabulary, terminology, and acronym formatting (e.g. expanding or capitalizing technical terms)

            Capitalization & Punctuation Rules:
            - Use standard capitalization for the input language, including personal pronouns.
            - You MUST capitalize the first word of every sentence.
            - Ensure proper comma and period placement to separate thoughts and clauses cleanly, even for short, disjointed testing sentences or quick statement lists.

            Do NOT perform full re-writings, stylistic makeovers, or structural changes. Maintain the speaker's syntax exactly. Preserve the speaker's original voice, natural vocabulary, and sentence structure. Preserve the speaker's natural slang, colloquialisms, and casual phrasing exactly as spoken. Do not sanitize their voice into generic AI speak. Do not add new information. Do not summarize.
            """
        case .professional:
            return """
            Clean up this dictated text into clear, professional writing while keeping the speaker's own voice. Fix the mechanics and lift the register; do NOT turn the speaker into a different, more formal writer.

            Edit for:
            - Grammar, punctuation, spelling, and sentence capitalization
            - Transcription errors (fix mumbled or incorrect words by using context clues to determine what the speaker actually meant)
            - Acoustic repeats, false starts, and filler words (um, uh, like, you know)
            - The roughest slang only, where it would read as unprofessional — smooth it into a natural phrasing the speaker would plausibly use, without swapping out their everyday vocabulary

            Keep the speaker's wording, phrasing, and sentence structure wherever it already reads cleanly. Do NOT rewrite sentences that are already fine, restructure the delivery, summarize, or add information. The result should sound like the speaker on their most articulate day, not like a different person.
            """
        case .concise:
            return """
            Tighten this dictated text to be as brief and direct as possible while keeping the speaker's own voice and every distinct idea.

            Edit for:
            - Grammar, punctuation, spelling
            - Transcription errors (fix mumbled or incorrect words by using context clues to determine what the speaker actually meant)
            - Wordy phrasing, empty qualifiers, redundancy, and conversational tangents
            - Acoustic repeats, false starts, and filler words (um, uh, like)

            Cut length by removing what is redundant, NOT by swapping the speaker's words for shorter synonyms — keep their vocabulary and phrasing. Do NOT drop facts, details, or points the speaker made. The result should read the way the speaker said it, just tighter.
            """
        case .custom:
            return """
            Follow the user's custom instructions below with maximum priority. The user has written specific rules for how they want their dictated text processed.

            As a baseline, fix obvious grammar errors, punctuation, and transcription mistakes. But the user's custom instructions override everything else. If they conflict with these baseline rules, follow the custom instructions.

            If the prompt includes a Field context block, treat it as informational ONLY. Use it to recognize technical terms in the speaker's dictation. Do NOT restyle the speaker's voice to match the field's tone unless the custom instructions explicitly tell you to.
            """
        }
    }

    static func templateTail(_ template: RefineTemplate) -> String {
        switch template {
        case .standard:
            return "Preserve the speaker's voice. Do not add new information. Return only the corrected text."
        case .professional:
            return "Keep the speaker's own voice. Fix mechanics and lift register without rewriting sentences that already read cleanly. Preserve every idea and detail. Return only the corrected text."
        case .concise:
            return "Keep the speaker's own words and voice. Preserve every distinct idea. Return only the tightened text."
        case .custom:
            return "Follow the custom instructions above. Return only the processed text."
        }
    }

    // MARK: Hard rules (shared, most-weighted)

    /// Both engines complete dangling thoughts when the input ends in a
    /// conjunction. Enumerating the trigger words is deliberate; the
    /// models recognize the pattern from the list.
    static let noCompletionRule = """
    HARD RULE — DO NOT EXTEND THE INPUT. The input is a slice of in-progress speech. Your output must cover ONLY what the input contains. If the input ends mid-thought, mid-clause, or with a trailing connector word (because, that, which, and, so, but, or, when, if, while, where, who, whose, whom, since, although, though, unless, after, before, until, then, also), you MUST stop your output at that connector. Do NOT add the next clause. Do NOT complete the thought. Do NOT invent the rest of the sentence. The speaker has not said those words yet. Adding them creates visible duplication on screen when the speaker continues speaking. Match your output's content scope to the input's content scope exactly. Grammar fixes (adding 1-2 missing articles, auxiliaries, prepositions to make a sentence parseable) are fine. Adding entire clauses, predicates, or trailing thoughts is fabrication and forbidden.
    """

    static let noTruncationRule = """
    HARD RULE — DO NOT TRUNCATE THE START OF THE INPUT. The input is a slice of in-progress speech. Your output MUST preserve the beginning of the input exactly, including any leading conjunctions, introductory clauses, or incomplete starting phrases (such as 'before we move on', 'because there are', 'although we planned', etc.). Do NOT drop leading words or clauses just because they start mid-thought, mid-sentence, or with a conjunction. You must retain every single word of these starting phrases, cleaning up and polishing only for grammar/spelling within the phrase itself, while syntactically blending them with the rest of the sentence. Dropping, truncating, or ignoring any leading words (especially words like 'before', 'because', 'although', 'since', 'if', 'when') is strictly forbidden. The output must begin with the exact semantic starting point and exact starting words of the input.
    """

    // MARK: Language rules

    static func refineLanguageRule(for lang: RefineOutputLanguage) -> String {
        guard !lang.isMatch else {
            return "HARD RULE — SAME LANGUAGE. Output in exactly the language the input was dictated in. NEVER translate any part of it into another language, no matter what languages the content mentions or what earlier context contains. English input produces English output."
        }
        let name = lang.promptName
        return """
        HARD RULE — TRANSLATE INTO \(name.uppercased()). You MUST write your ENTIRE response in \(name) (\(lang.rawValue)). ALWAYS — every word and every sentence, including the very last one. NEVER let any part of the output stay in the source language: not the opening word, not a greeting (translate "Hello" too), not the closing sentence, not an aside or a quoted saying. The speaker may dictate in any language; your output is native, natural \(name). Do NOT translate word for word. Carry the meaning, intent, tone, idioms, sarcasm, and humor across using the wording a native \(name) speaker would actually use, so it reads as if it were written in \(name) — never as a stiff, literal conversion. Keep proper names, brand and product names, technical terms, code, file paths, and numbers exactly as written, and keep any Reference vocabulary terms in their given spelling. Translate only what the speaker said — do not add, explain, or pad. The output covers the same content as the input, just expressed entirely in \(name).
        """
    }

    /// Condensed rule for AFM gen-1 (macOS 26 Tahoe), which follows a
    /// short imperative line more reliably than a long paragraph.
    static func refineLanguageRuleGen1(for lang: RefineOutputLanguage) -> String {
        guard !lang.isMatch else {
            return "Output in exactly the language the input was dictated in — never translate into another language."
        }
        let name = lang.promptName
        return "You MUST write your ENTIRE response in \(name) (\(lang.rawValue)) — every sentence, including the last one, and even a greeting or closing aside. Natural and native, carrying meaning, tone, and idioms the way a native \(name) speaker would, not word for word. Keep names, technical terms, code, and numbers as written. Do not add anything the speaker did not say."
    }

    /// Condensed boundary rule for gen-1: the two HARD RULE paragraphs
    /// compressed to two sentences, which gen-1 weights more reliably.
    static let gen1BoundaryRule = """
    Output only what the input actually says — never finish an unfinished thought, add a trailing clause, or invent words the speaker has not spoken yet. Preserve every meaningful opening clause and conjunction, including incomplete openings. Remove only nonsemantic hesitations; never discard an idea.
    """

    // MARK: User prompt

    /// The prompt-channel content for a one-shot refine: user rules,
    /// vocabulary, then the text. Template rules stay in each backend's
    /// system channel to avoid duplication.
    static func buildUserPrompt(rawText: String, settings: RefineSettings) -> String {
        var sections: [String] = []

        let extraFull = settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = String(extraFull.prefix(maxCustomInstructionsChars))
        if !extra.isEmpty {
            sections.append("USER INSTRUCTIONS (follow these in addition to the template rules):\n\(extra)")
        }

        if !settings.referenceVocabulary.isEmpty {
            sections.append(settings.referenceVocabulary)
        }

        if settings.outputLanguage.isMatch, settings.template != .custom,
           let speakerRule = RefineValidation.speakerPreservationInstruction(for: rawText) {
            sections.append(speakerRule)
        }
        sections.append("Dictated text:\n\(rawText)")
        return sections.joined(separator: "\n\n")
    }

    // MARK: Timeouts

    /// Wall-clock budget scaled to input length (150ms/word, 6-30s;
    /// translation runs slower: 240ms/word, 12-30s).
    static func refineTimeout(inputWords: Int, translating: Bool) -> Duration {
        let nanos: UInt64
        if translating {
            nanos = min(30_000_000_000, max(12_000_000_000, UInt64(inputWords) * 240_000_000))
        } else {
            nanos = min(30_000_000_000, max(6_000_000_000, UInt64(inputWords) * 150_000_000))
        }
        return .nanoseconds(Int64(nanos))
    }
}
