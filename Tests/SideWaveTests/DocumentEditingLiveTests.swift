// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

@MainActor
final class DocumentEditingLiveTests: XCTestCase {
    func testPreparationAndTemplateAwareEdits() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SIDEWAVE_LIVE_MODELS"] == "1", env["SIDEWAVE_ALLOW_MODEL_LOAD_IN_TESTS"] == "1" else {
            throw XCTSkip("Live document editing requires explicit model-test opt-in")
        }
        URLProtocol.registerClass(TransparencyURLProtocol.self)
        TransparencyURLProtocol.setupSwizzling()
        let backend = try XCTUnwrap(DictationFormatterService.Backend(rawValue: env["SIDEWAVE_REFINE_BACKEND"] ?? "apple-intelligence"),
            "SIDEWAVE_REFINE_BACKEND must name a supported backend")
        let defaults = UserDefaults.standard
        let keys = ["dictationCleanupTemplate", "dictationCleanupInstructions", "dictationCleanupBackend", "dictationCleanupEnabled", "skipRefine", "skipRefineAutoForced", "gemmaThinkingMode", "removeFillerWords", "dictationOutputLanguage", "redactPII", "redactSSN", "redactCreditCard", "redactAPIKey", "redactPhone", "redactEmail", "redactURL", "redactIPAddress"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "redactPII")
        defaults.set(false, forKey: "gemmaThinkingMode")
        defaults.set(true, forKey: "removeFillerWords")
        defaults.set("match", forKey: "dictationOutputLanguage")
        let state = AppState()
        let formatter = state.dictationFormatter
        let previousFallback = formatter.onSilentFallback
        formatter.onSilentFallback = { detail in
            previousFallback?(detail)
            print("DOCUMENT_FALLBACK \(backend.rawValue) \(detail)")
        }
        formatter.setBackend(backend)
        formatter.enable()
        defer { formatter.disable() }
        let started = Date()
        while formatter.state != .ready, Date().timeIntervalSince(started) < 900 {
            switch formatter.state {
            case .error(let detail), .unavailable(let detail): XCTFail(detail); return
            default: break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(formatter.state, .ready)
        guard formatter.state == .ready else { return }
        print("MODEL_PREPARATION_SECONDS \(backend.rawValue) \(Date().timeIntervalSince(started))")
        let dictations: [(DictationFormatterService.Template, String, [String])] = [
            (.instructions, "First label the samples. Second put the samples in the freezer. Third send the report on Friday.", ["1.", "2.", "3.", "freezer", "Friday"]),
            (.emailReady, "Hello team, please review the samples by Friday. Thank you.", ["team", "samples", "Friday"]),
            (.aiPrompt, "Review the sample report by Friday. Keep all measurements and do not invent results.", ["<task>", "</task>", "Friday", "measurement"]),
            (.custom, "The samples stay in the freezer. The report is due Friday. Keep the control group separate.", ["freezer", "Friday", "control"])
        ]
        for (template, input, required) in dictations {
            state.dictationCleanupTemplate = template.rawValue
            formatter.customInstructions = template == .custom ? "Turn the statements into a bulleted list. Preserve every fact." : ""
            let begin = Date()
            let completed = formatter.completedRefinementCount
            let streamed = DocumentTestStream()
            let result = await formatter.formatOrReturnRaw(input, forceRefine: true, forceSpecialty: true, thoroughPass: true, onStream: { streamed.set($0) })
            print("DOCUMENT_FORMAT_SECONDS \(backend.rawValue) \(template.rawValue) \(Date().timeIntervalSince(begin))")
            for word in required { XCTAssertTrue(result.localizedCaseInsensitiveContains(word), "\(template.rawValue) is missing \(word): \(result)") }
            XCTAssertGreaterThan(formatter.completedRefinementCount, completed, "The template must finish a real formatting pass. Model output: \(streamed.text)")
            if template == .aiPrompt {
                XCTAssertTrue(DocumentEditFormatting.validXML(result), result)
                XCTAssertFalse(result.contains("<role>"), "Do not invent a role: \(result)")
                XCTAssertFalse(result.contains("<output_format>"), "Do not invent a response format: \(result)")
                let edited = await formatter.editDocumentWithInstruction(result,
                    instruction: "Change the deadline from Friday to Monday. Keep all constraints and the context placeholder.", template: .aiPrompt)
                XCTAssertTrue(edited.contains("Monday"), edited)
                XCTAssertFalse(edited.contains("Friday"), edited)
                XCTAssertTrue(edited.localizedCaseInsensitiveContains("measurement"), edited)
                XCTAssertTrue(edited.contains("<pasted_context>"), edited)
                XCTAssertTrue(DocumentEditFormatting.validXML(edited), edited)
                for key in ["redactPII", "redactSSN", "redactCreditCard", "redactAPIKey", "redactPhone", "redactEmail", "redactURL", "redactIPAddress"] {
                    defaults.set(true, forKey: key)
                }
                let withLegacyPreferences = await formatter.refine(input, forceRefine: true, forceSpecialty: true)
                XCTAssertTrue(withLegacyPreferences.completed)
                for word in required { XCTAssertTrue(withLegacyPreferences.text.localizedCaseInsensitiveContains(word), withLegacyPreferences.text) }
                XCTAssertTrue(withLegacyPreferences.text.localizedCaseInsensitiveContains("invent"), withLegacyPreferences.text)
                defaults.set(false, forKey: "redactPII")
            }
            if template == .custom {
                XCTAssertGreaterThanOrEqual(result.split(separator: "\n").filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("• ") }.count, 3, result)
            }
            XCTAssertFalse(result.lowercased().hasPrefix("here is"))
            XCTAssertFalse(result.hasPrefix("```"))
            XCTAssertFalse(result.contains("nonsemantic hesitations"), "Internal editing rules must not become document content")
            XCTAssertFalse(result.contains("selected categories"), "Removed filtering instructions must not become document content")
            XCTAssertEqual(formatter.state, .ready)
        }
        state.dictationCleanupTemplate = "instructions"
        formatter.customInstructions = ""
        formatter.minimumWordCount = 50
        let priorCount = formatter.completedRefinementCount
        let short = await formatter.formatOrReturnRaw("First label samples. Then freeze samples.", forceRefine: true, forceSpecialty: true)
        XCTAssertTrue(short.contains("1."), short)
        XCTAssertTrue(short.contains("2."), short)
        XCTAssertGreaterThan(formatter.completedRefinementCount, priorCount, "A short document must still apply its chosen template")
        formatter.minimumWordCount = 10
        state.dictationCleanupTemplate = "standard"
        let segmentInputs = [
            "um we need to keep all the samples in the freezer until Friday",
            "the control group stays separate and we will review the report after lunch"
        ]
        var context = ""
        for input in segmentInputs {
            XCTAssertTrue(DictationFormatterService.Settings.fromCurrentUserDefaults(customInstructions: "").removeFillerWords)
            let count = formatter.completedRefinementCount
            let result = await formatter.formatOrReturnRaw(input, forceRefine: true, priorContext: context)
            XCTAssertGreaterThan(formatter.completedRefinementCount, count, "The live segment path must complete a model pass")
            XCTAssertFalse(result.contains("<|think|>"))
            XCTAssertFalse(result.lowercased().contains("um "), result)
            XCTAssertTrue(result.contains(input.contains("Friday") ? "Friday" : "lunch"))
            context += result + " "
        }
        if env["SIDEWAVE_TEST_THINKING"] == "1", backend.huggingFaceRepoID != nil {
            state.dictationCleanupTemplate = "instructions"
            defaults.set(true, forKey: "gemmaThinkingMode")
            let count = formatter.completedRefinementCount
            let begin = Date()
            let thought = await formatter.formatOrReturnRaw("First label the samples. Second place them in the freezer.", forceRefine: true, forceSpecialty: true, thoroughPass: true)
            print("DOCUMENT_THINKING_SECONDS \(backend.rawValue) \(Date().timeIntervalSince(begin))")
            XCTAssertGreaterThan(formatter.completedRefinementCount, count)
            XCTAssertTrue(thought.contains("1."))
            XCTAssertTrue(thought.contains("2."))
            XCTAssertTrue(thought.localizedCaseInsensitiveContains("freezer"))
            XCTAssertFalse(thought.contains("<|think|>"))
            defaults.set(false, forKey: "gemmaThinkingMode")
        }
        let fixtures: [(DictationFormatterService.Template, String, String, [String])] = [
            (.instructions, "1. Label the samples.\n    - Keep the control group separate.\n2. Put the samples in the freezer.\n3. Send the report on Friday.",
             "Change the deadline from Friday to Monday. Keep all numbered steps and the nested bullet.", ["1.", "2.", "3.", "Monday", "freezer", "control group"]),
            (.emailReady, "Subject: Sample review\n\nHello team,\n\nPlease review the samples by Friday.\n\nThank you.",
             "Change Friday to Monday. Keep the subject, greeting, paragraphs and closing.", ["Subject:", "Hello", "Monday", "Thank"]),
            (.custom, "We reviewed the samples. The report is due Friday. The freezer stays closed.",
             "Turn the three statements into three bullets. Return only the document.", ["samples", "Friday", "freezer"]),
            (.aiPrompt, "<task>Review the samples by Friday.</task>\n<constraints>Keep all units. Do not invent measurements.</constraints>",
             "Change Friday to Monday. Keep the XML tags and constraints.", ["<task>", "</task>", "<constraints>", "</constraints>", "Monday", "units"])
        ]
        for (template, document, instruction, required) in fixtures {
            let begin = Date()
            let result = await formatter.editDocumentWithInstruction(document, instruction: instruction, template: template)
            print("DOCUMENT_EDIT_SECONDS \(backend.rawValue) \(template.rawValue) \(Date().timeIntervalSince(begin))")
            XCTAssertNotEqual(result, document)
            for word in required { XCTAssertTrue(result.localizedCaseInsensitiveContains(word), "Missing required content: \(word)") }
            XCTAssertFalse(result.hasPrefix("```"))
            XCTAssertFalse(result.lowercased().hasPrefix("here is"))
            XCTAssertFalse(result.lowercased().contains("let me know"))
            if template == .custom {
                XCTAssertGreaterThanOrEqual(result.split(separator: "\n").filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("• ") }.count, 3, result)
            }
            if template == .instructions {
                XCTAssertTrue(result.split(separator: "\n").contains { $0.hasPrefix("    - ") && $0.localizedCaseInsensitiveContains("control") }, result)
            }
            XCTAssertEqual(formatter.state, .ready)
            if template == .aiPrompt { XCTAssertTrue(DocumentEditFormatting.preservesXMLStructure(result, original: document)) }
        }
        let preservedEmail = "Review draft\n\nSubject: Schedule check\n\nHello team,\n\nPlease finish these two tasks before Thursday:\n- Check the sample labels.\n- Review the freezer log.\n\nThank you."
        let numberedEmail = preservedEmail.replacingOccurrences(of: "- Check", with: "1. Check")
            .replacingOccurrences(of: "- Review", with: "2. Review")
        let numbered = await formatter.editDocumentWithInstruction(preservedEmail,
            instruction: "Turn the two bullet points into a numbered list. Keep every other line unchanged, including the title and Thursday deadline.", template: .emailReady)
        XCTAssertEqual(numbered, numberedEmail, "A targeted format edit must preserve every unrelated line")
        let removedTitle = await formatter.editDocumentWithInstruction(preservedEmail,
            instruction: "Remove the first line, Review draft, and the blank line after it. Turn the two bullet points into a numbered list. Keep everything else unchanged.", template: .emailReady)
        XCTAssertEqual(removedTitle, String(numberedEmail.dropFirst("Review draft\n\n".count)))

        state.dictationCleanupTemplate = "emailReady"
        state.specialtyEditedText = "An earlier, unrelated message."
        XCTAssertTrue(state.prepareDocumentCapture(target: .auto, resuming: false))
        let fresh = await state.formatCapturedDocument("Hello team, please review the samples by Friday. Thank you.", refine: true)
        XCTAssertTrue(fresh.contains("Friday"), fresh)
        XCTAssertFalse(fresh.contains("unrelated"), fresh)
        XCTAssertTrue(state.prepareDocumentCapture(target: .document, resuming: false))
        let extended = await state.formatCapturedDocument("Also send the inventory list on Tuesday.", refine: true)
        XCTAssertTrue(extended.contains("Friday"), extended)
        XCTAssertTrue(extended.contains("Tuesday"), extended)
        XCTAssertTrue(extended.localizedCaseInsensitiveContains("inventory"), extended)
        XCTAssertTrue(state.specialtyQueuedSegments.isEmpty, "A successful addition must be integrated once")
        XCTAssertEqual(state.documentDrafts.text(for: "emailReady"), extended)

        let document = String(repeating: "The samples are stored safely. Review the report on Friday. ", count: 60)
        let cancelled = Task { await formatter.editDocumentWithInstruction(document,
            instruction: "Rewrite this as detailed numbered instructions.", template: .instructions) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertEqual(cancelledResult, document)
        XCTAssertEqual(formatter.state, .ready)

        state.dictationCleanupTemplate = "instructions"
        state.specialtyEditedText = "1. Keep the samples cold.\n2. Send the report on Friday."
        state.agenticEditInstruction = "Change Friday to Monday. Keep both numbered steps."
        await state.applyAgenticEdit()
        XCTAssertTrue(state.isProcessingAgenticEdit)
        state.handleStartRecording()
        XCTAssertTrue(state.isProcessingAgenticEdit)
        XCTAssertFalse(state.isDictationBusy)
        let deadline = Date().addingTimeInterval(120)
        while state.isProcessingAgenticEdit && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(state.isProcessingAgenticEdit)
        XCTAssertTrue(state.specialtyEditedText.contains("Monday"))
        XCTAssertTrue(state.agenticEditInstruction.isEmpty)
        XCTAssertEqual(state.documentDrafts.text(for: "instructions"), state.specialtyEditedText)
        let complete = state.specialtyEditedText
        state.agenticEditInstruction = "Write a detailed numbered explanation for each step."
        await state.applyAgenticEdit()
        state.cancelAgenticEdit()
        XCTAssertEqual(state.specialtyEditedText, complete)
        XCTAssertFalse(state.agenticEditInstruction.isEmpty)
        XCTAssertNotNil(state.documentEditNotice)
    }
}

private final class DocumentTestStream: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String { lock.withLock { value } }
    func set(_ text: String) { lock.withLock { value = text } }
}
