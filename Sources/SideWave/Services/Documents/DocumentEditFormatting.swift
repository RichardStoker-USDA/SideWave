// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

enum DocumentEditFormatting {
    enum StructureError: LocalizedError {
        case invalid
        var errorDescription: String? { "The model returned an incomplete document structure." }
    }

    struct InstructionDocument: Codable, Sendable {
        struct Step: Codable, Sendable {
            let text: String
            var number: Int? = nil
            var subSteps: [String]? = nil

            init(text: String, number: Int? = nil, subSteps: [String]? = nil) {
                self.text = text
                self.number = number
                self.subSteps = subSteps
            }

            private enum CodingKeys: String, CodingKey { case text, number, subSteps }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                text = try values.decode(String.self, forKey: .text)
                subSteps = try values.decodeIfPresent([String].self, forKey: .subSteps)
                if try !values.contains(.number) || values.decodeNil(forKey: .number) {
                    number = nil
                } else if let integer = try? values.decode(Int.self, forKey: .number) {
                    number = integer
                } else {
                    let value = try values.decode(String.self, forKey: .number)
                    guard let integer = Self.stepNumber(value) else {
                        throw DecodingError.dataCorruptedError(forKey: .number, in: values,
                            debugDescription: "A step number must be an integer or an unambiguous number word.")
                    }
                    number = integer
                }
            }

            private static func stepNumber(_ value: String) -> Int? {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let integer = Int(trimmed) { return integer }
                let canonical: (String) -> String = {
                    $0.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0 != "and" }.joined()
                }
                for locale in [Locale.current, Locale(identifier: "en_US")] {
                    let formatter = NumberFormatter()
                    formatter.numberStyle = .spellOut
                    formatter.locale = locale
                    for spelling in [trimmed, trimmed.replacingOccurrences(of: " ", with: "-")] {
                        guard let parsed = formatter.number(from: spelling),
                              let integer = Int(parsed.stringValue),
                              let roundTrip = formatter.string(from: NSNumber(value: integer)),
                              canonical(roundTrip) == canonical(trimmed) else { continue }
                        return integer
                    }
                }
                return nil
            }
        }
        var intro: String? = nil
        let steps: [Step]
    }

    struct PromptDocument: Codable, Sendable {
        var task: String? = nil
        let sections: [XMLSection]
    }

    static func decodeDocument<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let data = Data(json.utf8)
        if let document = try? decoder.decode(type, from: data) { return document }
        let documents = try decoder.decode([T].self, from: data)
        guard documents.count == 1, let document = documents.first else { throw StructureError.invalid }
        return document
    }
    static let contextPlaceholder = "<pasted_context>\n  <!-- [PASTE ADDITIONAL CONTEXT OR COPIED DATA HERE IF APPLICABLE] -->\n</pasted_context>"

    static func separatingContextPlaceholder(_ text: String) -> (body: String, suffix: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(contextPlaceholder) else { return (text, "") }
        return (String(trimmed.dropLast(contextPlaceholder.count)).trimmingCharacters(in: .whitespacesAndNewlines),
                "\n\n" + contextPlaceholder)
    }

    static func renderInstructions(_ document: InstructionDocument) throws -> String {
        guard !document.steps.isEmpty, document.steps.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw StructureError.invalid }
        var lines: [String] = []
        if let intro = document.intro?.trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty { lines += [intro, ""] }
        for (index, step) in document.steps.enumerated() {
            let number = step.number.flatMap { $0 > 0 ? $0 : nil } ?? index + 1
            lines.append("\(number). \(step.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            let actionWords = step.text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            for detail in step.subSteps ?? [] where !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let detailWords = detail.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                guard detailWords != actionWords else { continue }
                lines.append("    - " + detail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Remove an instruction echoed as an introduction, while retaining the same words when dictated.
    static func excludingInstructionEcho(_ document: InstructionDocument, source: String, instructions: String) -> InstructionDocument {
        guard let intro = document.intro else { return document }
        let canonical: (String) -> String = {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let rules = canonical(instructions)
        let supplied = canonical(source)
        var kept: [String] = []
        var removed = false
        intro.enumerateSubstrings(in: intro.startIndex..<intro.endIndex, options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            let candidate = canonical(sentence)
            if !candidate.isEmpty, rules.contains(candidate), !supplied.contains(candidate) {
                removed = true
            } else {
                kept.append(sentence)
            }
        }
        guard removed else { return document }
        var result = document
        let remaining = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        result.intro = remaining.isEmpty ? nil : remaining
        return result
    }

    static func renderPrompt(_ document: PromptDocument) throws -> String {
        var sections = document.sections.filter { $0.tag != "pasted_context" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let task = document.task {
            sections.removeAll { $0.tag == "task" }
            sections.insert(.init(tag: "task", text: task), at: 0)
        }
        guard sections.contains(where: { $0.tag == "task" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let xml = renderXML(sections) else { throw StructureError.invalid }
        return xml + "\n\n" + contextPlaceholder
    }

    static func rules(for template: DictationFormatterService.Template) -> String {
        let base = "Return the entire edited document. Keep facts, names, and unchanged sections. Apply only the requested changes. Never add an introduction about your work, a closing offer, document boundary labels, or an outer code fence. Use a blank line between paragraphs and before a list. Put each list item on its own line, using '- ' for bullets or '1. ', '2. ', and so on for ordered steps. Indent nested items by four spaces. Do not put list markers inside a sentence."
        switch template {
        case .emailReady:
            return base + " This is an email. Keep its greeting and signature if present. Do not invent recipients, signatures, or a subject. Use plain text with no markdown headings or bold markers."
        case .instructions:
            return base + " This is a tutorial. Keep numbered steps in sequence. Use indented bullets for substeps. Do not repeat a step number within the same list. Keep any title and context separate from the steps."
        case .aiPrompt:
            return base + " This is a structured prompt. Preserve its XML tags and sections unless the user asks to change the format. Put list items on separate lines inside their existing section. Close every XML tag."
        default:
            return base + " Preserve the document's existing format unless the instruction explicitly changes it."
        }
    }

    static func preservesXMLStructure(_ output: String, original: String) -> Bool {
        guard original.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"), validXML(original) else { return true }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") && validXML(output)
    }

    struct XMLSection: Codable, Sendable, Equatable {
        let tag: String
        let text: String
    }

    /// Flat prompt sections can use constrained generation without asking a model to serialize XML.
    static func xmlSections(_ text: String) -> [XMLSection]? {
        guard validXML(text), let document = try? XMLDocument(xmlString: "<document>" + text + "</document>"),
              let children = document.rootElement()?.children else { return nil }
        var sections: [XMLSection] = []
        for child in children {
            if child.kind == .text, (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let element = child as? XMLElement, let tag = element.name,
                  (element.attributes ?? []).isEmpty,
                  (element.children ?? []).allSatisfy({ $0.kind == .text }) else { return nil }
            sections.append(XMLSection(tag: tag, text: element.stringValue ?? ""))
        }
        return sections.isEmpty ? nil : sections
    }

    static func renderXML(_ sections: [XMLSection]) -> String? {
        guard !sections.isEmpty else { return nil }
        var rendered: [String] = []
        for section in sections {
            guard section.tag.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else { return nil }
            let element = XMLElement(name: section.tag, stringValue: section.text)
            rendered.append(element.xmlString)
        }
        let text = rendered.joined(separator: "\n\n")
        return validXML(text) ? text : nil
    }

    static func validXML(_ text: String) -> Bool {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE") else { return false }
        let parser = XMLParser(data: Data(("<document>" + text + "</document>").utf8))
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    /// Remove response wrappers without rewriting the user's prose, numbering, or indentation.
    static func clean(_ output: String, original: String) -> String {
        var text = output.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preamble = #"(?i)^(?:here(?: is|'s) (?:the |your )?(?:edited|updated|revised|modified|formatted) (?:document|text|version)|(?:edited|updated|revised|modified) (?:document|text))\s*:\s*\n?"#
        if original.range(of: preamble, options: .regularExpression) == nil {
            text = text.replacingOccurrences(of: preamble, with: "", options: .regularExpression)
        }
        if text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n"),
           newline < text.index(text.endIndex, offsetBy: -3) {
            text = String(text[text.index(after: newline)..<text.index(text.endIndex, offsetBy: -3)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let wrappers = [("--- START OF DOCUMENT ---", "--- END OF DOCUMENT ---"),
                        ("<edited_document>", "</edited_document>")]
        for (start, end) in wrappers where text.hasPrefix(start) && text.hasSuffix(end) && !original.hasPrefix(start) {
            text = String(text.dropFirst(start.count).dropLast(end.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"[\t ]+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
