// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class DocumentEditFormattingTests: XCTestCase {
    /// Apple Intelligence copied literal example list items ("First item") into an email, so every
    /// list line in a template's output example must be a bracketed placeholder.
    @MainActor
    func testTemplateOutputExamplesHaveNoLiteralListItems() {
        for template in DictationFormatterService.Template.allCases {
            guard let example = DictationFormatterService.templateOutputExample(template: template) else { continue }
            for line in example.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where line.hasPrefix("- ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                XCTAssertTrue(line.contains("["), "\(template.rawValue) example has a literal list item: \(line)")
            }
        }
    }

    func testEmailListItemsStayTogetherAndParagraphsStaySeparate() {
        let join = DictationFormatterService.joinEmailParagraphs
        XCTAssertEqual(join(["We need three things:", "- probes", "- batteries", "- the plot map", "Thanks."]),
                       "We need three things:\n\n- probes\n- batteries\n- the plot map\n\nThanks.")
        XCTAssertEqual(join(["1. Collect samples", " ", "2. Log them"]), "1. Collect samples\n2. Log them")
        XCTAssertEqual(join(["First paragraph.", "Second paragraph."]), "First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(join(["Please collect your samples Wednesday.", "- Let me know if that works.", "Thanks, Jordan"]),
                       "Please collect your samples Wednesday.\n\nLet me know if that works.\n\nThanks, Jordan")
        XCTAssertEqual(join(["We need:", "- probes\n- batteries"]), "We need:\n\n- probes\n- batteries")
        XCTAssertEqual(join(["Samples move to Wednesday.\n- Let me know if that works."]),
                       "Samples move to Wednesday.\nLet me know if that works.")
        // A paragraph that only repeats words from another paragraph is dropped.
        XCTAssertEqual(join(["I am writing to request access to the greenhouse on Saturday.", "access to the greenhouse on Saturday"]),
                       "I am writing to request access to the greenhouse on Saturday.")
        XCTAssertEqual(join(["Thanks.", "Thanks."]), "Thanks.\n\nThanks.")
        XCTAssertEqual(join(["Can you send the plot map?", "-", "Thanks"]), "Can you send the plot map?\n\nThanks")
        // Indented items still make a list, so the first one keeps its dash.
        XCTAssertEqual(join(["Packing list:", "- soil probes\n - spare batteries\n - the plot map"]),
                       "Packing list:\n\n- soil probes\n - spare batteries\n - the plot map")
    }

    func testEmailGreetingAndSignOffPlaceholdersAreDropped() {
        XCTAssertNil(DictationFormatterService.emailLine("Nil"))
        XCTAssertNil(DictationFormatterService.emailLine(" none "))
        XCTAssertNil(DictationFormatterService.emailLine(nil))
        XCTAssertEqual(DictationFormatterService.emailLine("Thanks, Jordan"), "Thanks, Jordan")
        XCTAssertNil(DictationFormatterService.emailLine("-"))
        XCTAssertEqual(DictationFormatterService.emailLine("hey Sam,"), "Hey Sam,")
        XCTAssertEqual(DictationFormatterService.emailLine("thanks"), "Thanks")
        XCTAssertEqual(DictationFormatterService.capitalizingFirstWord("iPhone sync is fixed."), "iPhone sync is fixed.")
        XCTAssertEqual(DictationFormatterService.joinEmailParagraphs(["send me the map", "- probes\n- batteries"]),
                       "Send me the map\n\n- probes\n- batteries")
        XCTAssertEqual(DictationFormatterService.joinEmailParagraphs(["I need the map.\n\nsend it by Friday"]),
                       "I need the map.\n\nSend it by Friday")
        XCTAssertEqual(DictationFormatterService.joinEmailParagraphs(["I need the map.", "- send it by Friday"]),
                       "I need the map.\n\nSend it by Friday")
    }

    func testInstructionEchoRemovalDoesNotRemoveDictatedOrUnrelatedBackground() {
        let rules = "Preserve every measurement.\nUse the input language."
        let original = DocumentEditFormatting.InstructionDocument(intro: "Use the input language.", steps: [.init(text: "Review samples.")])
        XCTAssertNil(DocumentEditFormatting.excludingInstructionEcho(original, source: "Review samples.", instructions: rules).intro)
        XCTAssertEqual(DocumentEditFormatting.excludingInstructionEcho(original, source: "Use the input language. Review samples.", instructions: rules).intro, original.intro)
        let background = DocumentEditFormatting.InstructionDocument(intro: "Preparing the report.", steps: original.steps)
        XCTAssertEqual(DocumentEditFormatting.excludingInstructionEcho(background, source: "We are preparing the report.", instructions: rules).intro, background.intro)
        let fragments = DocumentEditFormatting.InstructionDocument(intro: "Preserve every measurement. Use the input language.", steps: original.steps)
        let separatedRules = "Preserve every measurement. Never add facts. Use the input language."
        XCTAssertNil(DocumentEditFormatting.excludingInstructionEcho(fragments, source: "Review samples.", instructions: separatedRules).intro)
        XCTAssertEqual(DocumentEditFormatting.excludingInstructionEcho(fragments, source: "Preserve every measurement. Review samples.", instructions: separatedRules).intro, "Preserve every measurement.")
    }

    func testModelDocumentSyntaxAndDuplicateDetailsKeepTheSuppliedActions() throws {
        for json in [#"{steps:[{text:'Review the report.',number:5,subSteps:['Review the report','Keep all units.']},],intro:null}"#,
                     #"[{steps:[{text:'Review the report.',number:5,subSteps:['Review the report','Keep all units.']}]}]"#] {
            let document = try DocumentEditFormatting.decodeDocument(DocumentEditFormatting.InstructionDocument.self, from: json)
            XCTAssertEqual(try DocumentEditFormatting.renderInstructions(document), "5. Review the report.\n    - Keep all units.")
        }
        for json in ["[]", "[{},{}]", "{steps: false}"] {
            XCTAssertThrowsError(try DocumentEditFormatting.decodeDocument(DocumentEditFormatting.InstructionDocument.self, from: json))
        }
    }

    func testModelStepNumbersAcceptUnambiguousStringsWithoutChangingTheirValue() throws {
        for (value, expected) in [("six", 6), ("56", 56), ("fifty-six", 56), ("twenty three", 23)] {
            let data = try JSONSerialization.data(withJSONObject: ["steps": [["text": "Review the report.", "number": value]]])
            let document = try JSONDecoder().decode(DocumentEditFormatting.InstructionDocument.self, from: data)
            XCTAssertEqual(document.steps.first?.number, expected)
            XCTAssertEqual(try DocumentEditFormatting.renderInstructions(document), "\(expected). Review the report.")
        }
        for value in ["six or seven", "2.5", "twelve samples", ""] {
            let data = try JSONSerialization.data(withJSONObject: ["steps": [["text": "Review the report.", "number": value]]])
            XCTAssertThrowsError(try JSONDecoder().decode(DocumentEditFormatting.InstructionDocument.self, from: data))
        }
    }

    func testAppleStepsPreserveExplicitNumbersAndNestedDetails() {
        let output = AFMInstructionListOutput(steps: [
            AFMStepItem(text: "Label samples.", subSteps: ["Keep the controls separate."], number: 2),
            AFMStepItem(text: "Review the report.", subSteps: nil, number: 4)
        ], intro: nil)
        XCTAssertEqual(output.renderText(), "2. Label samples.\n    - Keep the controls separate.\n4. Review the report.")
    }

    func testStructuredStepsRenderNumbersAndNestedDetails() throws {
        let document = DocumentEditFormatting.InstructionDocument(intro: "Preparation", steps: [
            .init(text: "Label samples.", number: 2, subSteps: ["Keep the control group separate."]),
            .init(text: "Send the report on Friday.", number: 4)
        ])
        XCTAssertEqual(try DocumentEditFormatting.renderInstructions(document), "Preparation\n\n2. Label samples.\n    - Keep the control group separate.\n4. Send the report on Friday.")
        XCTAssertThrowsError(try DocumentEditFormatting.renderInstructions(.init(steps: [])))
    }

    func testStructuredPromptEscapesContentAndAddsOneContextPlaceholder() throws {
        let prompt = try DocumentEditFormatting.renderPrompt(.init(sections: [.init(tag: "task", text: "Compare A & B before Friday.")]))
        XCTAssertTrue(prompt.contains("A &amp; B before Friday"))
        XCTAssertTrue(DocumentEditFormatting.validXML(prompt))
        XCTAssertEqual(prompt.components(separatedBy: "<pasted_context>").count, 2)
        XCTAssertThrowsError(try DocumentEditFormatting.renderPrompt(.init(sections: [])))
    }

    func testPromptOmitsEmptyOptionalSectionsAndKeepsSuppliedContent() throws {
        let rendered = try DocumentEditFormatting.renderPrompt(.init(task: "Review the report.", sections: [
            .init(tag: "output_format", text: " \n "),
            .init(tag: "examples", text: ""),
            .init(tag: "constraints", text: "Keep every measurement.")
        ]))
        XCTAssertFalse(rendered.contains("<output_format>"))
        XCTAssertFalse(rendered.contains("<examples>"))
        XCTAssertTrue(rendered.contains("<constraints>Keep every measurement.</constraints>"))
        XCTAssertTrue(DocumentEditFormatting.validXML(rendered))
    }

    func testOnlyTheUnchangedContextPlaceholderIsSeparatedForEditing() throws {
        let original = try DocumentEditFormatting.renderPrompt(.init(sections: [.init(tag: "task", text: "Review A & B.")]))
        let parts = DocumentEditFormatting.separatingContextPlaceholder(original)
        XCTAssertEqual(parts.body + parts.suffix, original)
        XCTAssertNotNil(DocumentEditFormatting.xmlSections(parts.body))
        let filled = "<task>Review.</task><pasted_context><!-- User note -->Keep this data.</pasted_context>"
        XCTAssertEqual(DocumentEditFormatting.separatingContextPlaceholder(filled).body, filled)
        XCTAssertTrue(DocumentEditFormatting.separatingContextPlaceholder(filled).suffix.isEmpty)
    }

    func testResponseWrappersAreRemovedAndListsKeepTheirStructure() {
        let document = "Prepare the samples.\n\n1. Label each tube.\n  - Record its location.\n2. Store the tubes."
        let output = "Here is the revised document:\n```text\n\(document)\n```"
        XCTAssertEqual(DocumentEditFormatting.clean(output, original: "Prepare the samples."), document)
    }

    func testQuotedBoundaryLabelsInTheOriginalAreNotDeleted() {
        let original = "--- START OF DOCUMENT ---\nA label used by the import tool.\n--- END OF DOCUMENT ---"
        XCTAssertEqual(DocumentEditFormatting.clean(original, original: original), original)
    }

    func testPromptXMLAndInlineCodeRemainUntouched() {
        let document = "<task>Review `sample_id`.</task>\n\n<constraints>\n- Keep all rows.\n</constraints>"
        XCTAssertEqual(DocumentEditFormatting.clean(document, original: document), document)
    }

    func testPromptMustContainCompleteXMLInsteadOfPlainProse() {
        XCTAssertFalse(DocumentEditFormatting.validXML("Review the report before Monday."))
        XCTAssertFalse(DocumentEditFormatting.validXML("<task>Review the report."))
        XCTAssertTrue(DocumentEditFormatting.validXML("<task>Review the report.</task><pasted_context><!-- Optional context --></pasted_context>"))
    }

    func testMalformedPromptEditKeepsTheOriginalStructure() {
        let original = "<task>Review the results.</task><constraints>Keep the units.</constraints>"
        XCTAssertFalse(DocumentEditFormatting.preservesXMLStructure("<task>Review them", original: original))
        XCTAssertFalse(DocumentEditFormatting.preservesXMLStructure("Review them on Monday.", original: original))
        XCTAssertTrue(DocumentEditFormatting.preservesXMLStructure(original, original: original))
    }

    func testStructuredPromptSectionsRoundTripWithoutMarkupInjection() throws {
        let original = "<task>Keep A &amp; B.</task>\n<constraints>Use &lt; 5 mL.</constraints>"
        let sections = try XCTUnwrap(DocumentEditFormatting.xmlSections(original))
        XCTAssertEqual(sections.map(\.tag), ["task", "constraints"])
        let rendered = try XCTUnwrap(DocumentEditFormatting.renderXML(sections))
        XCTAssertEqual(DocumentEditFormatting.xmlSections(rendered), sections)
        XCTAssertNil(DocumentEditFormatting.renderXML([.init(tag: "task><bad", text: "invalid")]))
        XCTAssertNil(DocumentEditFormatting.xmlSections("<task><nested>Keep nesting</nested></task>"))
    }

    func testFollowUpRulesKeepTemplateSpecificStructure() {
        XCTAssertTrue(DocumentEditFormatting.rules(for: .instructions).contains("numbered steps"))
        XCTAssertTrue(DocumentEditFormatting.rules(for: .emailReady).contains("Do not invent recipients"))
        XCTAssertTrue(DocumentEditFormatting.rules(for: .aiPrompt).contains("Close every XML tag"))
    }
}
