// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

@MainActor
final class CustomDictionaryTests: XCTestCase {

    private var originalPacks: [VocabPack] = []

    override func setUp() {
        super.setUp()
        originalPacks = VocabularyStore.shared.packs
    }

    override func tearDown() {
        VocabularyStore.shared.packs = originalPacks
        CustomDictionary.invalidateCache()
        super.tearDown()
    }

    func testNoSubstitutionsUnchanged() {
        VocabularyStore.shared.packs = []
        CustomDictionary.invalidateCache()
        
        let text = "This is a simple test without replacements."
        XCTAssertEqual(CustomDictionary.apply(to: text), text)
    }

    func testExactSubstitutionMatching() {
        // Clear all packs and set a custom test pack
        let term1 = VocabTerm(canonical: "Antigravity", aliases: ["antigrav", "anti gravity"], scope: .substitution)
        let term2 = VocabTerm(canonical: "macOS", aliases: ["macos", "mac os"], scope: .substitution)
        let pack = VocabPack(
            name: "Test Pack",
            description: "For tests",
            isEnabled: true,
            terms: [term1, term2]
        )
        VocabularyStore.shared.packs = [pack]
        CustomDictionary.invalidateCache()

        XCTAssertEqual(CustomDictionary.apply(to: "running on macos"), "running on macOS")
        XCTAssertEqual(CustomDictionary.apply(to: "testing antigrav engine"), "testing Antigravity engine")
    }

    func testCaseInsensitivityOfTriggers() {
        let term = VocabTerm(canonical: "iPad", aliases: ["ipad"], scope: .substitution)
        let pack = VocabPack(
            name: "Test Pack",
            description: "For tests",
            isEnabled: true,
            terms: [term]
        )
        VocabularyStore.shared.packs = [pack]
        CustomDictionary.invalidateCache()

        XCTAssertEqual(CustomDictionary.apply(to: "my IPAD is new"), "my iPad is new")
        XCTAssertEqual(CustomDictionary.apply(to: "the iPad works"), "the iPad works")
    }

    func testWordBoundariesPreserved() {
        let term = VocabTerm(canonical: "fluid", aliases: ["flu"], scope: .substitution)
        let pack = VocabPack(
            name: "Test Pack",
            description: "For tests",
            isEnabled: true,
            terms: [term]
        )
        VocabularyStore.shared.packs = [pack]
        CustomDictionary.invalidateCache()

        // "flu" should trigger, but "influence" or "flute" should NOT.
        XCTAssertEqual(CustomDictionary.apply(to: "she has the flu"), "she has the fluid")
        XCTAssertEqual(CustomDictionary.apply(to: "under the influence of a flute"), "under the influence of a flute")
    }

    func testBuildVocabularyTerms() {
        // Clear all packs and set a custom test pack with various scopes and term lengths
        let term1 = VocabTerm(canonical: "Antigravity", aliases: ["antigrav"], scope: .substitution)
        let term2 = VocabTerm(canonical: "MLX", aliases: [], scope: .refineHint)
        let term3 = VocabTerm(canonical: "Go", aliases: ["go"], scope: .substitution) // shorter than 3 characters
        let term4 = VocabTerm(canonical: "Swift", aliases: ["swift-lang"], scope: .refineHint)
        
        let pack = VocabPack(
            name: "Test Pack",
            description: "For tests",
            isEnabled: true,
            terms: [term1, term2, term3, term4]
        )
        VocabularyStore.shared.packs = [pack]
        CustomDictionary.invalidateCache()

        let terms = CustomDictionary.buildVocabularyTerms()
        
        // "Go" has length 2 < 3, so it should be filtered out.
        // "Antigravity", "MLX", and "Swift" are >= 3, so they should be included.
        XCTAssertEqual(terms.count, 3)
        
        let texts = terms.map { $0.text }
        XCTAssertTrue(texts.contains("Antigravity"))
        XCTAssertTrue(texts.contains("MLX"))
        XCTAssertTrue(texts.contains("Swift"))
        XCTAssertFalse(texts.contains("Go"))
        
        // Verify aliases are populated
        if let antiTerm = terms.first(where: { $0.text == "Antigravity" }) {
            XCTAssertEqual(antiTerm.aliases, ["antigrav"])
        } else {
            XCTFail("Antigravity term not found")
        }
        
        if let mlxTerm = terms.first(where: { $0.text == "MLX" }) {
            XCTAssertNil(mlxTerm.aliases)
        } else {
            XCTFail("MLX term not found")
        }
    }
    func testLongestAliasWinsWithoutCascadingCanonicalText() {
        VocabularyStore.shared.packs = [VocabPack(name: "Terms", description: "", isEnabled: true, terms: [
            VocabTerm(canonical: "sensor", aliases: ["probe"], scope: .substitution),
            VocabTerm(canonical: "soil sensor", aliases: ["probe array"], scope: .substitution),
            VocabTerm(canonical: "instrument", aliases: ["sensor"], scope: .substitution)
        ])]
        CustomDictionary.invalidateCache()
        XCTAssertEqual(CustomDictionary.apply(to: "probe array, probe, sensor"), "soil sensor, sensor, instrument")
    }

    func testCanonicalReplacementIsLiteralAndSupportsUnicode() {
        VocabularyStore.shared.packs = [VocabPack(name: "Terms", description: "", isEnabled: true, terms: [
            VocabTerm(canonical: "$1\\plots", aliases: ["data path"], scope: .substitution),
            VocabTerm(canonical: "C++", aliases: ["c++"], scope: .substitution)
        ])]
        CustomDictionary.invalidateCache()
        XCTAssertEqual(CustomDictionary.apply(to: "🌿 data path and c++"), "🌿 $1\\plots and C++")
    }

}
