// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

@MainActor
extension DictationFormatterService {
    /// Processing preferences are instructions, never source document content.
    nonisolated static func processingInstructions(rawText: String, settings: Settings, includeCustomInstructions: Bool = true) -> String {
        var upstreamNotes: [String] = []
        if settings.outputLanguage == .matchInput, !settings.template.isSpecialty {
            let words = rawText.split(whereSeparator: \.isWhitespace)
            let ending = words.last?.trimmingCharacters(in: .punctuationCharacters).lowercased() ?? ""
            let continuations: Set<String> = ["because", "that", "which", "and", "so", "but", "or", "when", "if",
                "while", "where", "who", "whose", "whom", "since", "although", "though", "unless", "after", "before", "until"]
            if continuations.contains(ending) {
                let boundary = words.suffix(5).joined(separator: " ")
                upstreamNotes.append("The recording stops at this unfinished ending: \"\(boundary)\". Stop at the same word, \"\(ending)\". Do not supply a continuation; the speaker has not said it.")
            }
        }
        if settings.outputLanguage == .matchInput,
           [.standard, .professional, .concise].contains(settings.template),
           let speakerRule = RefineValidation.speakerPreservationInstruction(for: rawText) {
            upstreamNotes.append(speakerRule)
        }
        if settings.removeFillerWords {
            var note = "Remove remaining nonsemantic hesitations (um, uh, er). Keep quoted words and meaningful uncertainty."
            let customFillers = settings.customFillerPhrases.filter { !$0.isEmpty }
            if !customFillers.isEmpty {
                note += " User also removed: " + customFillers.prefix(8).joined(separator: ", ") + "."
            }
            upstreamNotes.append(note)
        } else {
            upstreamNotes.append("Filler removal is disabled; preserve any fillers naturally.")
        }
        switch settings.profanityMode {
        case .redact:
            upstreamNotes.append("Profanity has been replaced with first letter + asterisks (e.g., f***). Preserve these placeholders exactly.")
        case .replace:
            upstreamNotes.append("Profanity has been replaced with mild alternatives. Preserve those replacements as-is.")
        case .none:
            break
        }
        var sections: [String] = []
        if !upstreamNotes.isEmpty {
            sections.append("Editing rules (apply these without including them in the document):\n" + upstreamNotes.map { "- " + $0 }.joined(separator: "\n"))
        }
        let extra = String(settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxCustomInstructionsChars))
        if includeCustomInstructions && !extra.isEmpty {
            sections.append("USER INSTRUCTIONS (follow these in addition to the template rules):\n\(extra)")
        }
        return sections.joined(separator: "\n\n")
    }

    nonisolated static func buildPrompt(
        rawText: String,
        settings: Settings,
        structuredDocument: Bool = false
    ) -> String {
        var sections: [String] = []

        // Template rules aren't repeated here; each backend gets them in its system channel
        // (gemmaSystemPrompt() for Gemma, afmInstructions() for Apple Intelligence).

        if !structuredDocument {
            let rules = processingInstructions(rawText: rawText, settings: settings)
            if !rules.isEmpty {
                sections.append(rules)
            }
        }

        // Section 4b: Enabled VocabPack context + domain terms. Lives in the
        // user prompt, not Instructions, per Apple's prompt-injection defense
        // for Foundation Models (WWDC25 #248).
        let vocabSection = settings.vocabulary.buildPromptSection(for: rawText)
        if !vocabSection.isEmpty {
            sections.append(vocabSection)
        }
        if structuredDocument {
            sections.append("<dictated_text>\n\(rawText)\n</dictated_text>")
            return sections.joined(separator: "\n\n")
        }

        if !settings.outputLanguage.isMatch {
            if let prior = settings.priorContext, !prior.isEmpty {
                sections.append("Earlier translated text (read-only context; never repeat it):\n\(String(prior.suffix(600)))")
            }
            sections.append(translationInput(rawText, language: settings.outputLanguage))
            return sections.joined(separator: "\n\n")
        }

        // Output-shape example for templates defined by structure. Apple Intelligence and small
        // Gemma models follow a concrete example better than abstract rules: without one, Email and
        // Instructions came back as prose instead of a greeting and sign-off or a numbered list,
        // and AI Prompt needs its XML skeleton. Prose templates (Standard, Professional, Concise,
        // Custom) get no example, which would over-constrain them.
        if !structuredDocument, let example = Self.templateOutputExample(template: settings.template) {
            sections.append(example)
        }

        // The input text, with no "Corrected text:" anchor: Gemma's chat template already opens the
        // model turn and Apple Intelligence's schema sets the output shape, and an anchor pulls
        // toward continuation.
        //
        // With `priorContext`, the input is framed as the continuation of text already refined, so
        // the model bridges from the last sentence instead of starting a new paragraph (which
        // produced seams like "but. But we'll").
        if let priorContext = settings.priorContext,
           !priorContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Two levels of context: the last 3000 characters of earlier dictation for vocabulary
            // and tone, and the last one or two sentences as an explicit bridge. Without the
            // bridge, each refined piece read like a new paragraph.
            let trimmedContext: String
            if priorContext.count > 3000 {
                trimmedContext = "…" + String(priorContext.suffix(3000))
            } else {
                trimmedContext = priorContext
            }
            let bridgeAnchor = Self.lastSentences(from: priorContext, count: 2)
            let bridgeSection: String
            if bridgeAnchor.isEmpty || bridgeAnchor == trimmedContext {
                // Either no clear sentence boundary in priorContext yet, or
                // the broader context is already short enough that
                // duplicating it as a bridge would be redundant.
                bridgeSection = ""
            } else {
                bridgeSection = """

                Bridge from this — the last sentence(s) the user just refined. The new portion below should flow as a direct continuation of this:
                \(bridgeAnchor)
                """
            }
            // Continuity rules. Without them, models:
            // 1. Repeat the last prior sentence as a polished restart, so the paste contains it twice.
            // 2. Invent an opening on long boundary-merge inputs, for example "Venus Path is a sidecar
            //    proxy" for "the cleanest path is a sidecar proxy", treating the input as a new sentence.
            //
            // Both Gemma and Apple Intelligence ignore softer wording, so the rules say what happens to the
            // output (it is appended to the prior text), what not to do, and how to capitalize depending on
            // whether the prior text ended a sentence.
            sections.append("""
            You are refining a slice of in-progress dictation. The slice begins MID-THOUGHT, picking up immediately after the prior text below — often mid-sentence. Your output is appended directly after the prior text, character-by-character, so the combined result must read as one coherent passage. Apply the template's style rules to the new slice ONLY. The prior text is read-only context.

            CRITICAL CONTINUITY RULES — failing these breaks the user's transcript:
            1. DO NOT echo, paraphrase, or restate ANY content from the prior text in your output. Your output is the refined version of the new slice ONLY.
            2. DO NOT begin your output with a fresh sentence-starter ("Okay,", "So,", "Here's,", "I think,", "Please,", "First,", "Now,", "Let's,") UNLESS the user actually said one of those words at the start of the new slice. If the user did not, neither should you.
            3. If the prior text's last visible character is NOT a sentence terminator (`.`, `!`, `?`), THE FIRST WORD of your output MUST begin with a lowercase letter and MUST NOT start a new sentence. This rule applies ONLY to the first word — internal capitalization follows normal English rules: capitalize after every `.`/`!`/`?` within your output, capitalize proper nouns, capitalize "I".
            4. If the prior text already ended a sentence, your new slice begins a fresh sentence — capitalize the first word accordingly.
            5. Preserve every proper noun, named entity, identifier, and technical term from the new slice exactly as written. Do not invent names.
            6. If the new slice ENDS without a sentence terminator (`.`, `!`, `?`), the user is mid-thought. Default: keep the trailing fragment mid-thought — your output ends without a sentence terminator. The next slice will pick up the thread. EXCEPTION: if the prior text above ALREADY contains the exact words or phrase that would complete the sentence (the speaker said it earlier in the same session), you MAY complete the sentence using ONLY words drawn from the prior text. NEVER invent completion words. Do NOT add "proceed.", "etc.", "and so on.", or any generic filler. Grounded completion is allowed; fabrication is not.
            7. If the new slice contains a mid-thought period (a stray "." inserted by the dictation engine at a silence, where the speaker did not actually finish the sentence), MERGE the two halves into one coherent sentence and drop the stray period. The grammatical and semantic flow of the prior text + the new slice tells you whether the period is real or stray.

            Prior text (already refined, read-only context):
            \(trimmedContext)\(bridgeSection)

            New slice — output ONLY the refined version of this slice, nothing more:
            \(rawText)
            """)
        } else {
            sections.append("Dictated text:\n\(rawText)")
            if settings.template.isSpecialty && !structuredDocument { sections.append(templateTail(settings.template)) }
        }

        return sections.joined(separator: "\n\n")
    }

    /// Last `count` sentences of `text`, where a sentence ends at `.`, `!`, or `?` before
    /// whitespace or the end. Used as the bridge anchor in real-time refine prompts.
    nonisolated static func lastSentences(from text: String, count: Int) -> String {
        guard count > 0 else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let chars = Array(trimmed)
        var enderIndices: [Int] = []
        for (i, c) in chars.enumerated() {
            guard c == "." || c == "!" || c == "?" else { continue }
            let next = i + 1
            // Sentence end requires the punctuation to be at end-of-text or
            // followed by whitespace. Without this guard, "U.S.A." would
            // be split mid-acronym.
            if next == chars.count || chars[next].isWhitespace {
                enderIndices.append(i)
            }
        }
        // A range of `count` sentences needs `count + 1` sentence ends. With fewer, return the
        // whole text.
        guard enderIndices.count > count else { return trimmed }
        let cutoffEnderIdx = enderIndices[enderIndices.count - count - 1]
        let startIdx = cutoffEnderIdx + 1
        let suffix = chars[startIdx...].drop(while: { $0.isWhitespace })
        return String(suffix)
    }

    /// Template-specific cleanup rules for Gemma 4. Also used by
    /// gemmaSystemPrompt(). AFM has its own version in afmInstructions().
    nonisolated private static func templateCoreBlock(_ template: Template) -> String {
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
        case .emailReady:
            return """
            Turn this dictated text into a ready-to-send email body in the speaker's own voice.

            You MUST:
            - Keep the speaker's tone and about the same length: a short, casual note stays short and casual, and a formal message stays formal
            - Fix all grammar, punctuation, and capitalization
            - Remove all filler words, false starts, tangents, and repeated thoughts
            - When the speaker lists multiple items or points, format them as a bulleted or numbered list using plain text (use "- " for bullets, "1. " for numbered items)
            - Use short paragraphs
            - Fix transcription errors
            - Never add pleasantries, stock business phrases, or anything the speaker did not say

            Use plain text formatting only (no markdown, no asterisks for bold, no headers with #). Structure with line breaks, indentation, dashes for bullets, and numbers for ordered lists.

            Keep every distinct point and state each one once. Do not drop details.

            If the prompt includes a Field context block, use it to spell and understand technical terms, not to change the speaker's tone.
            """
        case .instructions:
            return """
            Rewrite this dictated text as clear step-by-step instructions, a tutorial, or a how-to guide. The speaker dictated casually and expects formatted instructions ready to publish.

            You MUST:
            - Detect ordered steps in natural language ("step one... step two...", "first... next... then... finally...", "and after that...") and format them as a numbered list using "1. ", "2. ", "3. " etc.
            - Detect unordered options or considerations and format them as bullets using "- "
            - Detect sub-steps and indent them under the parent step (use four spaces indent + "- " for sub-bullets)
            - Fix grammar, punctuation, capitalization, and transcription errors
            - Remove filler words, false starts, and tangents
            - Preserve technical terms, command names, file paths, code, version numbers, and product names exactly as the speaker said them
            - Use imperative voice for steps ("Click File", "Open the menu" — not "you should click" or "I would open")
            - Add a brief intro paragraph if the speaker provided context before the steps
            - Keep numbers and ordering deterministic; if the speaker says "step one... step three..." preserve that ordering, don't renumber

            Use plain text formatting only (no markdown, no asterisks for bold, no headers with #). Structure with paragraphs, line breaks, bullets, and numbered items only.

            Keep every distinct step and detail. Do not drop information. The result should be something the speaker can paste directly into a documentation page, README, or wiki.

            If the prompt includes a Field context block, USE it to inform vocabulary and phrasing. The steps should read naturally to someone working in the speaker's domain.
            """
        case .aiPrompt:
            return """
            The speaker is dictating their thoughts, goals, vision, constraints, and intent for an AI agent or chatbot to follow. Convert the freeform dictation into a structured XML prompt that any modern AI model (Claude, GPT, Gemini, Llama, Mistral, etc.) can parse and act on reliably.

            Output schema — emit these XML sections in this order, omit any that the speaker did not address (except for pasted_context, which is mandatory and must always be present at the bottom):

            <role>One-sentence statement of what role the AI should adopt, if the speaker described it.</role>

            <task>What the AI is being asked to do, in the speaker's words but cleaned up. Preserve their intent verbatim.</task>

            <context>Background, audience, situation, prior state — anything the speaker provided to set the scene.</context>

            <goals>
            - Each distinct goal the speaker stated, one per bullet.
            - Preserve every goal. Do not merge or collapse.
            </goals>

            <constraints>
            - Each "must do" / "must not do" / "never" / "always" the speaker stated, one per bullet.
            - Include "avoid" / "don't" / "stay away from" items here.
            </constraints>

            <preferences>
            - Soft preferences: tone, voice, length, format, style.
            </preferences>

            <examples>If the speaker gave examples of desired or undesired output, include them verbatim.</examples>

            <output_format>If the speaker specified how the AI should format its response (XML, JSON, markdown, plain text, length, structure), state it here.</output_format>

            <pasted_context>
              <!-- [PASTE ADDITIONAL CONTEXT OR COPIED DATA HERE IF APPLICABLE] -->
            </pasted_context>

            You MUST:
            - Preserve every distinct idea, goal, constraint, preference, and small detail. Nuance matters.
            - Use the speaker's own words inside the tags — clean up grammar but do not rephrase intent.
            - Output ONLY the XML structure above. No preamble, no closing remarks, no markdown code fences.
            - Use lowercase snake_case for any custom tags if the speaker introduced concepts that don't fit the standard tags.
            - Indent inner content by 2 spaces inside multiline tags.
            - Escape only XML reserved chars (&, <, >) — leave the speaker's punctuation, quotes, and apostrophes intact.
            - Always append the literal, exact `<pasted_context>` block shown above at the very bottom of your output as a placeholder for additional user data.

            This is not a generic conversion — preserve every signal the speaker provided. The result is a production prompt the user can paste directly into an AI tool.
            """
        case .custom:
            return """
            Follow the user's custom instructions below with maximum priority. The user has written specific rules for how they want their dictated text processed.

            As a baseline, fix obvious grammar errors, punctuation, and transcription mistakes. But the user's custom instructions override everything else. If they conflict with these baseline rules, follow the custom instructions.

            If the prompt includes a Field context block, treat it as informational ONLY. Use it to recognize technical terms in the speaker's dictation. Do NOT restyle the speaker's voice to match the field's tone unless the custom instructions explicitly tell you to.
            """
        }
    }

    /// Example of a template's output shape, inserted into the prompt for the model to follow.
    /// Matters most for Apple Intelligence and helps Gemma E2B. Nil for prose templates.
    nonisolated static func templateOutputExample(template: Template) -> String? {
        switch template {
        case .emailReady:
            return """
            OUTPUT SHAPE EXAMPLE (mimic this structure when appropriate to the speaker's content):
            Hi [Name],

            [Body paragraph 1 covering the first main point in clear sentences.]

            [Body paragraph 2 covering the second main point. Only if the speaker listed several items, put each one on its own line starting with "- ".]

            [Closing line, only if the speaker said one.]

            [Sign-off with the speaker's name, only if the speaker said one.]

            Adapt the greeting, signoff, and paragraphing to what the speaker actually said. If they didn't say a recipient name, skip the greeting line. If they didn't say a sign-off name, skip it. NEVER invent a recipient or signoff name the speaker didn't say.
            """
        case .instructions:
            return """
            OUTPUT SHAPE EXAMPLE (mimic this structure):
            [Optional one-paragraph intro if the speaker provided context before the steps.]

            1. [First step in imperative voice.]
            2. [Second step.]
                - [Sub-detail or option for step 2.]
                - [Another sub-detail for step 2.]
            3. [Third step.]
            4. [Fourth step.]

            Use plain text only — no markdown bold (`**`), no markdown headers (`#`), no markdown italic (`*`). Use the exact bullet character `- ` for sub-items and `1. `, `2. `, `3. ` for top-level steps. Indent sub-items with four spaces before the dash.
            """
        case .aiPrompt:
            return """
            OUTPUT SHAPE EXAMPLE (mimic this structure):
            <task>[The task actually dictated, including its timing and scope.]</task>

            <constraints>
              - [A requirement actually dictated.]
            </constraints>

            <pasted_context>
              <!-- [PASTE ADDITIONAL CONTEXT OR COPIED DATA HERE IF APPLICABLE] -->
            </pasted_context>

            Omit any section the speaker didn't address (except for pasted_context, which must always be present at the bottom). Output ONLY the XML — no preamble, no markdown fences, no explanation.
            """
        case .standard, .professional, .concise, .custom:
            return nil
        }
    }

    /// Per-template output constraint.
    nonisolated private static func templateTail(_ template: Template) -> String {
        switch template {
        case .standard:
            return "Preserve the speaker's voice. Do not add new information. Return only the corrected text."
        case .professional:
            return "Keep the speaker's own voice. Fix mechanics and lift register without rewriting sentences that already read cleanly. Preserve every idea and detail. Return only the corrected text."
        case .concise:
            return "Keep the speaker's own words and voice. Preserve every distinct idea. Return only the tightened text."
        case .emailReady:
            return "Preserve every idea and detail. Return only the formatted email body text."
        case .instructions:
            return "Write the actions as an ordered list, including when there are only one or two steps. Each top-level action starts on its own line with its number followed by a period and space. Convert spoken sequencing words into these list markers. Keep any context before the list. Preserve every step and detail. Return only the formatted instructions."
        case .aiPrompt:
            return "Preserve every distinct idea, goal, constraint, and preference. Return only the XML prompt structure — no preamble, no markdown fences."
        case .custom:
            return "Follow the custom instructions above. Return only the processed text."
        }
    }

    // Generic fallback; used by raw generation and prompt preview when
    // no template context is available.
    nonisolated static let systemInstructions = """
    You are a text cleanup assistant. You receive speech-to-text output and return clean, correctly formatted text. Output ONLY the corrected text. No explanations, no preamble, no markdown formatting, no quotes around the text.
    """

    /// Template-specific system prompt for Gemma 4. Puts the cleanup rules
    /// in the system role where the model weighs them more heavily than the
    /// user turn. Each template gets its own variant.
    nonisolated static let speechBoundaryRule = """
    Speech recognition can insert a period during a pause. Repair punctuation by reading the complete supplied text: join an unfinished phrase to the words that complete it. For example, "Attach the. Labels to each bottle." becomes "Attach the labels to each bottle." Keep periods between separate complete thoughts. Using continuation words already present in the input is allowed; inventing missing content is not.
    """

    nonisolated static func gemmaSystemPrompt(
        for template: Template,
        removeFillers: Bool,
        outputLanguage: OutputLanguage = .matchInput,
        speakerProfile: String = ""
    ) -> String {
        if !outputLanguage.isMatch {
            return translationInstructions(for: template, language: outputLanguage, speakerProfile: speakerProfile)
        }
        var parts: [String] = []

        switch template {
        case .standard, .custom:
            parts.append("You are a transcription editor. Clean up dictated text. Output ONLY the corrected text, no commentary.")
        case .professional:
            parts.append("You are a careful editor. Clean up dictated text into professional writing while keeping the speaker's own voice — fix mechanics and lift register, don't rewrite them into a different writer. Output ONLY the corrected text, no commentary.")
        case .emailReady:
            parts.append("You are a professional writing assistant. Rewrite dictated text into polished prose. Output ONLY the rewritten text, no commentary.")
        case .concise:
            parts.append("You are a text editor. Tighten dictated text while keeping the speaker's own words and voice. Output ONLY the tightened text, no commentary.")
        case .instructions:
            parts.append("You are a technical writer. Format dictated text as clear step-by-step instructions, tutorials, or how-to guides with numbered steps and bullet sub-points. Output ONLY the formatted instructions, no commentary.")
        case .aiPrompt:
            parts.append("You are a prompt engineer. Convert dictated thoughts into a structured XML prompt that any modern AI model can parse and act on. Output ONLY the XML structure, no commentary, no markdown fences.")
        }

        parts.append(templateCoreBlock(template))
        parts.append("Preserve who performs each action. Keep the speaker's grammatical person and number: never change I to we or we to I.")
        parts.append(Self.refineLanguageRule(for: outputLanguage))

        parts.append(templateTail(template))

        // Tells the model to apply the "Reference vocabulary" section from VocabularyStore; without
        // it, Gemma treats the section as background. Harmless when no section is present.
        parts.append("If the prompt includes a Reference vocabulary section, apply those preferred spellings and word replacements exactly — they are the user's corrections for terms the dictation model gets wrong.")

        // The speaker profile describes how the user talks, to preserve their voice, never to add
        // content or restyle. It comes before the hard rules, which stay last and carry the most
        // weight.
        if !speakerProfile.isEmpty {
            parts.append("About this speaker (how they naturally talk and write): \(speakerProfile) Use this only to recognize and preserve the speaker's own voice, vocabulary, and phrasing. Do NOT copy it into the output, add topics or opinions it mentions, or restyle beyond what the current input actually says.")
        }

        if template.isSpecialty {
            parts.append("This is a complete document-formatting request, not a live speech continuation. Reorganize the supplied content into the selected template. Preserve every fact, including dates, deadlines, numbers, units, names, conditions, and exceptions. Do not shorten a task by removing its timing or scope. List markers and XML tags belong to the requested format; they may replace spoken sequencing words. Do not invent facts, actions, recipients, or signatures.")
            return parts.joined(separator: "\n\n")
        }

        // No repeated phrases. Gemma E2B and E4B duplicated phrases in rewriting templates when the
        // input was repetitive ("we need to implement some we need to implement some form of rate
        // limiting"). One cheap line.
        parts.append("Never repeat the same 3+ word phrase verbatim within your output. If your rewrite would otherwise place the same phrase twice, use it once.")

        // No-completion rule, the same text as `afmNoCompletionRule`. Gemma also sometimes finishes
        // a sentence the speaker left open, especially after a conjunction. Last in the system
        // prompt, where it carries the most weight.
        parts.append("HARD RULE — DO NOT EXTEND THE INPUT. The input is a slice of in-progress speech. Your output must cover ONLY what the input contains. If the input ends mid-thought, mid-clause, or with a trailing connector word (because, that, which, and, so, but, or, when, if, while, where, who, whose, whom, since, although, though, unless, after, before, until, then, also), you MUST stop your output at that connector. Do NOT add the next clause. Do NOT complete the thought. Do NOT invent the rest of the sentence. The speaker has not said those words yet. Adding them creates visible duplication on screen when the speaker continues speaking. Match your output's content scope to the input's content scope exactly. Grammar fixes (adding 1-2 missing articles, auxiliaries, prepositions to make a sentence parseable) are fine. Adding entire clauses, predicates, or trailing thoughts is fabrication and forbidden.")

        // No-truncation rule. Prevents dropping starting dependent clauses.
        parts.append("HARD RULE — DO NOT TRUNCATE THE START OF THE INPUT. The input is a slice of in-progress speech. Your output MUST preserve the beginning of the input exactly, including any leading conjunctions, introductory clauses, or incomplete starting phrases (such as 'before we move on', 'because there are', 'although we planned', etc.). Do NOT drop leading words or clauses just because they start mid-thought, mid-sentence, or with a conjunction. You must retain every single word of these starting phrases, cleaning up and polishing only for grammar/spelling within the phrase itself, while syntactically blending them with the rest of the sentence. Dropping, truncating, or ignoring any leading words (especially words like 'before', 'because', 'although', 'since', 'if', 'when') is strictly forbidden. The output must begin with the exact semantic starting point and exact starting words of the input.")

        parts.append(Self.speechBoundaryRule)

        return parts.joined(separator: "\n\n")
    }
}
