// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Deterministic text filters and refinement settings.
@MainActor
final class TextProcessingTests: XCTestCase {

    override func setUp() async throws {
        let defaults = UserDefaults.standard
        let keys = ["removeFillerWords", "removeProfanity", "replaceProfanity"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        addTeardownBlock { @MainActor in
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }
    }

    // MARK: - Filler-word removal

    func testRemoveFillerWordsWhenEnabled() {
        UserDefaults.standard.set(true, forKey: "removeFillerWords")
        let out = TranscriptionService.removeFillerWords("um hello uh world")
        XCTAssertFalse(out.split(separator: " ").contains("um"), out)
        XCTAssertFalse(out.split(separator: " ").contains("uh"), out)
        XCTAssertTrue(out.contains("hello"))
        XCTAssertTrue(out.contains("world"))
    }

    func testRemoveFillerWordsNoOpWhenDisabled() {
        UserDefaults.standard.set(false, forKey: "removeFillerWords")
        let input = "um hello uh world"
        XCTAssertEqual(TranscriptionService.removeFillerWords(input), input)
    }

    func testProfanityFiltersPreservePunctuationAndUnrelatedWords() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "removeProfanity")
        defaults.set(false, forKey: "replaceProfanity")
        let input = "The assessment is complete. Damn!"
        XCTAssertEqual(TranscriptionService.filterProfanity(input), input)
        defaults.set(true, forKey: "removeProfanity")
        XCTAssertEqual(TranscriptionService.filterProfanity(input), "The assessment is complete. D***!")
        defaults.set(false, forKey: "removeProfanity")
        defaults.set(true, forKey: "replaceProfanity")
        let replaced = TranscriptionService.filterProfanity(input)
        XCTAssertTrue(replaced.hasPrefix("The assessment is complete. "))
        XCTAssertTrue(replaced.hasSuffix("!"))
        XCTAssertFalse(replaced.contains("Damn"))
    }

    // MARK: - Short session bypass settings

    func testBypassRefinementOnShortSessions() {
        let defaults = UserDefaults.standard
        let keys = ["bypassRefineOnShortSessions", "dictationCleanupMinWords"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let appState = AppState()
        XCTAssertFalse(appState.bypassRefineOnShortSessions)
        XCTAssertEqual(appState.dictationCleanupMinWords, 10)
        XCTAssertEqual(appState.dictationFormatter.minimumWordCount, 0)
        appState.bypassRefineOnShortSessions = true
        appState.dictationCleanupMinWords = 20
        XCTAssertEqual(appState.dictationFormatter.minimumWordCount, 20)
        appState.bypassRefineOnShortSessions = false
        XCTAssertFalse(defaults.bool(forKey: "bypassRefineOnShortSessions"))
        XCTAssertEqual(appState.dictationFormatter.minimumWordCount, 0)
    }

    func testDictationFormatterServiceWordCountBypass() async {
        let formatter = DictationFormatterService()
        
        // Let's check that if input word count is less than minimumWordCount,
        // formatOrReturnRaw returns the raw text without checking model readiness.
        formatter.minimumWordCount = 5
        
        // Verify state is not .ready (in unit tests it defaults to .unloaded or similar)
        XCTAssertNotEqual(formatter.state, .ready)
        
        var fallbackCalled = false
        formatter.onSilentFallback = { _ in
            fallbackCalled = true
        }
        
        // 1. Short input: 3 words (< 5). Should skip refinement immediately, returning raw text,
        // and NOT triggering onSilentFallback because the readiness check is never reached.
        fallbackCalled = false
        let shortInput = "hello world today"
        let shortOutput = await formatter.formatOrReturnRaw(shortInput, forceRefine: true, silentMode: false)
        XCTAssertEqual(shortOutput, shortInput)
        XCTAssertFalse(fallbackCalled, "Short input should have bypassed refinement before checking model readiness")
        
        // 2. Long input: 6 words (>= 5). Should pass the word count check and trigger the model
        // readiness check, which calls onSilentFallback because the model is not loaded/ready.
        fallbackCalled = false
        let longInput = "one two three four five six"
        let longOutput = await formatter.formatOrReturnRaw(longInput, forceRefine: true, silentMode: false)
        XCTAssertEqual(longOutput, longInput)
        XCTAssertTrue(fallbackCalled, "Long input should have reached model readiness check and triggered fallback")
    }

    func testModelDownloadCancellation() async {
        let task = Task {
            do {
                try await ModelDownloadManager.downloadVAD()
                return false
            } catch is CancellationError {
                return true
            } catch {
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    return true
                }
                return false
            }
        }
        
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        task.cancel()
        
        let cancelledCleanly = await task.value
        XCTAssertTrue(cancelledCleanly, "Model download should cancel cleanly when the Swift task is cancelled")
    }

    func testCustomRegistryOwnerSanitization() {
        let original = UserDefaults.standard.string(forKey: "customHuggingFaceOwner")
        defer {
            UserDefaults.standard.set(original, forKey: "customHuggingFaceOwner")
        }
        
        // Set a malicious owner with special characters, directory traversal, and domain spoofing
        UserDefaults.standard.set("malicious:password@attacker.com/../dangerous_owner", forKey: "customHuggingFaceOwner")
        
        let resolved = ModelDownloadManager.resolveRepoID("mlx-community/gemma-4-e2b-it-4bit")

        XCTAssertEqual(resolved, "maliciouspasswordattackercomdangerous_owner/gemma-4-e2b-it-4bit")
    }

    // MARK: - Gemma thinking-block stripping

    func testStripGemmaChannelThoughtBlock() {
        let raw = "<|channel>thought\n* Capitalize personal pronoun I.\n* Remove filler words.\n<channel|>The assay showed a clear signal."
        XCTAssertEqual(
            DictationFormatterService.stripGemmaThinkBlock(raw),
            "The assay showed a clear signal."
        )
    }

    func testStripGemmaUnclosedThoughtHidesReasoningMidStream() {
        // While the model is still thinking, the closing marker hasn't
        // arrived yet; everything from the marker on must be suppressed so
        // reasoning never streams into the overlay.
        let raw = "<|channel>thought\n* Maintain original voice/structure\n* Strictly adhere to"
        XCTAssertEqual(DictationFormatterService.stripGemmaThinkBlock(raw), "")
    }

    func testStripGemmaLegacyThinkBlockAndPassThrough() {
        XCTAssertEqual(
            DictationFormatterService.stripGemmaThinkBlock("<|think|>reasoning here<|/think|>Final answer."),
            "Final answer."
        )
        XCTAssertEqual(
            DictationFormatterService.stripGemmaThinkBlock("No markers at all."),
            "No markers at all."
        )
    }
}
