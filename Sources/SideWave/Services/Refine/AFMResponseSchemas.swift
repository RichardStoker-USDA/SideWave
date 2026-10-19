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

#if canImport(FoundationModels)

// MARK: - Structured document responses

@Generable
struct AFMXMLDocumentOutput {
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "Requested content organized into sections. Include only sections supported by the supplied content or edit instruction. Preserve all unchanged sections when editing. Do not repeat a point across sections.")
    var sections: [AFMXMLDocumentSection]
}

@Generable
struct AFMXMLDocumentSection {
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "A lowercase XML tag name, without angle brackets, such as task, constraints, or context. When editing, keep existing names unless asked to change them.")
    var tag: String
    @Guide(description: "The entire section text, preserving facts and unchanged text. No surrounding XML tags or commentary.")
    var text: String
}

@Generable
struct AFMRefinedDictation {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "Preserve every meaningful opening clause, conjunction, and incomplete starting phrase. Remove nonsemantic hesitations and empty spoken setup only; never discard an idea. The refined version of the new slice ONLY. Do NOT echo or restate prior-text content. If the slice ends mid-thought, leave it mid-thought UNLESS the prior text above already contains the exact words that would complete the sentence (then you may complete using ONLY those grounded words). NEVER invent or fabricate completion words. CRITICAL: when the input contains a period mid-thought (the dictation engine inserted it at a brief silence), DROP that period and merge the two halves into one flowing sentence. Examples: 'I went to the store. and then home' becomes 'I went to the store and then home'; 'so we need to ship. But also keep tests green' becomes 'so we need to ship but also keep tests green'. Only keep periods that mark genuine sentence boundaries. Preserve all named entities, proper nouns, and identifiers from the slice exactly as written. NEVER repeat the same 3+ word phrase verbatim within your output. May include line breaks, bullet points, and paragraph structure when the template requires it.")
    var cleanedText: String
}

/// Professional output: one entry per paragraph the speaker made, so the model can't merge or split
/// paragraphs. Joined with blank lines.
@Generable
struct AFMProfessionalOutput {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "Preserve every meaningful opening clause, conjunction, and incomplete starting phrase. Remove nonsemantic hesitations and empty spoken setup only; never discard an idea. You may remove leading spoken hesitations and empty setup phrases, but must preserve every meaningful leading clause. Polished professional rewrite of the new slice, split into paragraphs. One entry per coherent paragraph the speaker created. Each paragraph is grammatical professional prose, fixed for ALL grammar and punctuation, register lifted while keeping the speaker's own voice and everyday words (smooth only the roughest slang, don't swap words wholesale), filler removed. KEEP every distinct point and idea. If the slice is short and one paragraph suffices, return a single-entry array. NEVER fabricate paragraphs beyond what the speaker said. NEVER complete unfinished sentences unless the prior context above unambiguously contains the ending.")
    var paragraphs: [String]
}

/// Email output in three parts, which stops the model from inventing recipient or sign-off names.
/// Nil greeting or sign-off means the speaker didn't say one.
@Generable
struct AFMEmailReadyOutput {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "Greeting line — only if the speaker addressed a specific recipient by name (e.g. 'Hi Sarah,'). Leave nil if the speaker did not name a recipient. NEVER invent a name.")
    var greeting: String?

    @Guide(description: "Body paragraphs of the email. One entry per paragraph the speaker created. Plain text only — no markdown, no asterisks. When the speaker listed items, format that paragraph as bulleted lines starting with '- ' (one dash + space + item, one item per line within the paragraph string). KEEP every distinct point. Fix all grammar and punctuation. Replace casual phrasing with professional equivalents.")
    var paragraphs: [String]

    @Guide(description: "Sign-off block — only if the speaker explicitly said a sign-off (e.g. 'Thanks, Rich' or 'Best regards'). May span multiple lines. Leave nil if no sign-off was stated. NEVER invent a signature line.")
    var signoff: String?
}

/// Single step item used inside the Instructions / Tutorial schema.
@Generable
struct AFMStepItem {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "The action the speaker supplied, in imperative voice. Omit spoken list markers such as first, next, step two. Preserve facts; do not add detail.")
    var text: String

    @Guide(description: "Details explicitly supplied for this action, otherwise nil. Do not repeat the main action or invent sub-steps.")
    var subSteps: [String]?

    @Guide(description: "The step number explicitly supplied by the speaker, otherwise null. Preserve numbers even when the sequence starts after one or skips a number.")
    var number: Int?
}

/// Numbered actions and optional background for the Instructions template.
/// Actions decode first so the opening step is not consumed as an intro.
@Generable
struct AFMInstructionListOutput {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "Every action supplied in the dictation, in order, including the first action. One item per distinct step. Include each fact once. Never invent or repeat an action.")
    var steps: [AFMStepItem]

    @Guide(description: "Background context explicitly supplied before the actions, otherwise nil. Never put an action, a step, or a summary of the steps here.")
    var intro: String?
}

/// AI Prompt preserves the complete task and only the additional sections supplied.
@Generable
struct AFMPromptDocumentOutput {
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }
    @Guide(description: "The main request the speaker dictated, including its scope and deadline. Put additional constraints in their own section, not in both places. Preserve the speaker's wording.")
    var task: String
    @Guide(description: "Distinct additional content explicitly supplied by the speaker, such as constraints, context, preferences, or examples. Empty if none. Each fact appears in one section only. Never invent a role or output format, and omit empty sections.")
    var sections: [AFMXMLDocumentSection]
}

/// Live-status analysis schema for the specialty overlay. Constrained
/// decoding replaces the hand-rolled XML parser on the AFM path; far more
/// reliable on gen-1, which drifts on "emit these exact XML tags" prose.
@Generable
struct AFMLiveStatus {
    // Explicit witnesses avoid the macOS 27 SDK's non-back-deployed Generable defaults.
    var promptRepresentation: Prompt { Prompt(generatedContent) }
    var instructionsRepresentation: Instructions { Instructions(generatedContent) }

    @Guide(description: "A concise 1-2 sentence summary of what the speaker is dictating and what the final document is about. Describe it — do not repeat the dictation verbatim.")
    var understanding: String

    @Guide(description: "One sentence describing how you will format or structure the final document once the speaker finishes (e.g. email outline, numbered steps).")
    var plannedAction: String

    @Guide(description: "Clarifying questions about information still missing to complete a high-quality document. Empty when nothing is missing. One question per entry, no numbering or bullets.")
    var questions: [String]
}

// MARK: - Per-template schema renderers (struct → final text)

extension AFMProfessionalOutput {
    /// Joins paragraphs with a double newline. Drops empty / whitespace-only
    /// entries so the model can't sneak in a blank paragraph that becomes
    /// extra whitespace in the paste.
    func renderText() -> String {
        paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

extension AFMEmailReadyOutput {
    /// Greeting, blank line, paragraphs, blank line, sign-off; empty parts are skipped. Lists
    /// inside paragraphs already use "- " and are kept as is.
    func renderText() -> String {
        var parts: [String] = []
        if let g = greeting?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            parts.append(g)
        }
        let body = paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !body.isEmpty {
            parts.append(body)
        }
        if let s = signoff?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            parts.append(s)
        }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AFMInstructionListOutput {
    /// Numbered list rendering: optional intro paragraph, then each step
    /// as "N. <text>" with sub-steps indented as "    - <line>".
    /// Preserves the speaker's order via array iteration.
    func renderText() -> String {
        var lines: [String] = []
        if let intro = intro?.trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty {
            lines.append(intro)
            lines.append("")
        }
        for (i, step) in steps.enumerated() {
            let cleanedText = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedText.isEmpty else { continue }
            let number = step.number.flatMap { $0 > 0 ? $0 : nil } ?? i + 1
            lines.append("\(number). \(cleanedText)")
            if let subs = step.subSteps {
                for sub in subs {
                    let cleanedSub = sub.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanedSub.isEmpty else { continue }
                    lines.append("    - \(cleanedSub)")
                }
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
