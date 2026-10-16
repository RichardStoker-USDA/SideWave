// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Speech-profile store + prompt-injection tests. Pure logic only — no model
/// is loaded. The store tests snapshot and restore the shared singleton so a
/// dev machine's real profile survives the run.
@MainActor
final class SpeechProfileTests: XCTestCase {

    private var savedProfile: SpeechProfile!
    private var savedEnabled: Bool = true

    override func setUp() {
        super.setUp()
        savedProfile = SpeechProfileStore.shared.profile
        savedEnabled = SpeechProfileStore.shared.isEnabled
    }

    override func tearDown() {
        let store = SpeechProfileStore.shared
        store.isEnabled = savedEnabled
        if savedProfile.text.isEmpty {
            store.clear()
        } else {
            store.setBuilt(text: savedProfile.text, sourceEntryCount: savedProfile.sourceEntryCount)
        }
        super.tearDown()
    }

    // MARK: - SpeechProfile Codable

    func testProfileRoundTrip() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let original = SpeechProfile(
            text: "Tends to write in short, blunt sentences with dry humor.",
            builtAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceEntryCount: 7
        )
        let back = try dec.decode(SpeechProfile.self, from: enc.encode(original))
        XCTAssertEqual(back.text, original.text)
        XCTAssertEqual(back.sourceEntryCount, 7)
        XCTAssertNotNil(back.builtAt)
    }

    /// An empty object decodes to the empty profile rather than throwing.
    func testTolerantDecodeMissingKeys() throws {
        let p = try JSONDecoder().decode(SpeechProfile.self, from: Data("{}".utf8))
        XCTAssertEqual(p.text, "")
        XCTAssertNil(p.builtAt)
        XCTAssertEqual(p.sourceEntryCount, 0)
    }

    /// A partial object keeps the present key and defaults the rest.
    func testTolerantDecodePartial() throws {
        let json = Data(#"{"text":"hello there"}"#.utf8)
        let p = try JSONDecoder().decode(SpeechProfile.self, from: json)
        XCTAssertEqual(p.text, "hello there")
        XCTAssertEqual(p.sourceEntryCount, 0)
        XCTAssertNil(p.builtAt)
    }

    /// A wrong-typed value doesn't abort the whole decode.
    func testTolerantDecodeWrongType() throws {
        let json = Data(#"{"text":"hi","sourceEntryCount":"nope"}"#.utf8)
        let p = try JSONDecoder().decode(SpeechProfile.self, from: json)
        XCTAssertEqual(p.text, "hi")
        XCTAssertEqual(p.sourceEntryCount, 0)
    }

    // MARK: - Clamp

    func testClampShortTextUnchanged() {
        let s = "Speaks casually, lots of tech jargon, prefers em-dash-free prose."
        XCTAssertEqual(SpeechProfileStore.clamp(s), s)
    }

    func testClampCapsAtWordBoundary() {
        let long = String(repeating: "profile ", count: 200) // 1600 chars
        let clamped = SpeechProfileStore.clamp(long)
        XCTAssertLessThanOrEqual(clamped.count, SpeechProfileStore.charCap)
        // Word-boundary trim: never ends mid-word.
        XCTAssertFalse(clamped.hasSuffix("prof"))
        XCTAssertTrue(clamped.hasSuffix("profile"))
    }

    func testClampStripsWrappingQuotes() {
        XCTAssertEqual(SpeechProfileStore.clamp("\"Speaks plainly.\""), "Speaks plainly.")
    }

    func testClampStripsLeadingLabel() {
        XCTAssertEqual(SpeechProfileStore.clamp("Speaker profile: Speaks plainly."), "Speaks plainly.")
        XCTAssertEqual(SpeechProfileStore.clamp("About this speaker: Speaks plainly."), "Speaks plainly.")
    }

    // MARK: - Store gating

    func testPromptTextPresentWhenEnabled() {
        let store = SpeechProfileStore.shared
        store.isEnabled = true
        store.setBuilt(text: "Speaks casually with lots of tech jargon.", sourceEntryCount: 5)
        XCTAssertEqual(store.promptText, "Speaks casually with lots of tech jargon.")
        XCTAssertTrue(store.hasProfile)
        XCTAssertEqual(store.profile.sourceEntryCount, 5)
        XCTAssertNotNil(store.profile.builtAt)
    }

    func testPromptTextEmptyWhenDisabled() {
        let store = SpeechProfileStore.shared
        store.setBuilt(text: "Speaks casually.", sourceEntryCount: 5)
        store.isEnabled = false
        XCTAssertTrue(store.promptText.isEmpty)
        // Text is retained even while disabled.
        XCTAssertTrue(store.hasProfile)
    }

    func testSetEditedBlankClears() {
        let store = SpeechProfileStore.shared
        store.setBuilt(text: "something", sourceEntryCount: 2)
        store.setEdited(text: "   ")
        XCTAssertFalse(store.hasProfile)
        XCTAssertNil(store.profile.builtAt)
        XCTAssertEqual(store.profile.sourceEntryCount, 0)
    }

    func testSetEditedKeepsSourceCount() {
        let store = SpeechProfileStore.shared
        store.setBuilt(text: "built text", sourceEntryCount: 9)
        store.setEdited(text: "hand-tuned text")
        XCTAssertEqual(store.profile.text, "hand-tuned text")
        XCTAssertEqual(store.profile.sourceEntryCount, 9)
    }

    // MARK: - Prompt injection (pure builder, no model)

    func testGemmaSystemPromptInjectsProfileWhenPresent() {
        let prompt = DictationFormatterService.gemmaSystemPrompt(
            for: .standard,
            removeFillers: false,
            speakerProfile: "Tends to write in short, blunt sentences with dry humor."
        )
        XCTAssertTrue(prompt.contains("About this speaker"))
        XCTAssertTrue(prompt.contains("dry humor"))
    }

    func testGemmaSystemPromptOmitsProfileWhenEmpty() {
        let prompt = DictationFormatterService.gemmaSystemPrompt(
            for: .standard,
            removeFillers: false,
            speakerProfile: ""
        )
        XCTAssertFalse(prompt.contains("About this speaker"))
    }

    /// The profile injects the same way across templates (it's speaker-global,
    /// not template-specific).
    func testGemmaSystemPromptInjectsProfileForEmailTemplate() {
        let prompt = DictationFormatterService.gemmaSystemPrompt(
            for: .emailReady,
            removeFillers: true,
            speakerProfile: "Prefers warm, direct openings."
        )
        XCTAssertTrue(prompt.contains("About this speaker"))
        XCTAssertTrue(prompt.contains("warm, direct openings"))
    }
}
