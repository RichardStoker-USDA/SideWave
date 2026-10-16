// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import CryptoKit
import XCTest
@testable import SideWave

@MainActor final class GlossaryBundleTests: XCTestCase {
    private var root: URL!
    private var store: VocabularyStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VocabularyStore(storageURL: root.appendingPathComponent("vocabulary.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func bundle(_ words: [(String, [String])], version: String = "1") throws -> (Data, GlossaryCatalog.Entry) {
        let file = VocabularyStore.GlossaryFile(glossaries: [.init(name: "Research", description: "Research terms", contextBlurb: "",
            terms: words.map { .init(canonical: $0.0, aliases: $0.1, definition: nil, usageNote: nil, priority: 2, scope: 3) })])
        let data = try XCTUnwrap(VocabularyStore.encode(file))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, .init(id: "research", name: "Research", description: "Research terms", version: version,
            path: "research.json", sha256: digest, bytes: data.count, termCount: words.count, tags: [], releaseNotes: "Curated terms"))
    }

    func testInstallIsReadOnlyAndManualByDefault() throws {
        XCTAssertTrue(store.packs.isEmpty)
        let (data, entry) = try bundle([("phenotype", ["feno type"])])
        let id = try store.installBundle(data, entry: entry)
        XCTAssertEqual(store.packs.count, 1)
        XCTAssertTrue(store.packs[0].isReadOnly)
        XCTAssertFalse(try XCTUnwrap(store.packs[0].subscription).automaticallyUpdates)
        store.addTerm(toPack: id, term: VocabTerm(canonical: "Blocked"))
        store.addTerms(toPack: id, terms: [VocabTerm(canonical: "Blocked")])
        store.renamePack(id, to: "Blocked")
        store.updateContextBlurb(id, blurb: "Blocked")
        var term = store.packs[0].terms[0]; term.canonical = "Blocked"
        store.updateTerm(term, in: id)
        store.removeTerm(fromPack: id, termID: term.id)
        XCTAssertEqual(store.packs[0].name, "Research")
        XCTAssertEqual(store.packs[0].terms.map(\.canonical), ["phenotype"])
        XCTAssertEqual(store.packs[0].contextBlurb, "")
    }

    func testSyncPreservesPersonalCopiesChoicesAndHiddenWords() throws {
        let (first, firstEntry) = try bundle([("phenotype", ["feno type"]), ("genotype", ["geno type"])])
        let id = try store.installBundle(first, entry: firstEntry)
        let copyID = try XCTUnwrap(store.cloneBuiltIn(id))
        let copy = try XCTUnwrap(store.packs.first { $0.id == copyID })
        XCTAssertNil(copy.subscription)
        XCTAssertNotEqual(copy.terms[0].id, store.packs[0].terms[0].id)
        store.setEnabled(id, false)
        store.setLinkedTemplates(id, templates: ["email"])
        try store.updateSubscription(id) { $0.automaticallyUpdates = true; $0.hiddenWords = ["phenotype"] }
        let (second, secondEntry) = try bundle([("phenotype", ["phen o type"]), ("cultivar", ["cult of ar"])], version: "2")
        XCTAssertEqual(try store.installBundle(second, entry: secondEntry), id)
        XCTAssertEqual(store.packs.first { $0.id == copyID }, copy)
        let updated = try XCTUnwrap(store.subscribedPack("research"))
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.linkedTemplates, ["email"])
        let source = try XCTUnwrap(updated.subscription)
        XCTAssertTrue(source.automaticallyUpdates)
        XCTAssertEqual(source.hiddenWords, ["phenotype"])
        XCTAssertEqual(source.changes[0].added, ["cultivar"])
        XCTAssertEqual(source.changes[0].edited, ["phenotype"])
        XCTAssertEqual(source.changes[0].removed, ["genotype"])
        let restored = VocabularyStore(storageURL: root.appendingPathComponent("vocabulary.json"))
        XCTAssertEqual(restored.packs, store.packs)
    }

    func testPersonalWordWinsAndHiddenBundleWordDoesNotReachAnyPipeline() throws {
        let (data, entry) = try bundle([("phenotype", ["publisher alias"]), ("genotype", ["geno type"])])
        let id = try store.installBundle(data, entry: entry)
        let personal = store.createUserPack(name: "My words")
        try store.copyWord(store.packs[0].terms[0], to: personal)
        var term = try XCTUnwrap(store.packs.first { $0.id == personal }?.terms.first)
        term.aliases = ["my alias"]
        store.updateTerm(term, in: personal)
        try store.updateSubscription(id) { $0.hiddenWords = ["genotype"] }
        XCTAssertEqual(store.activeEntries().map(\.canonical), ["phenotype"])
        XCTAssertEqual(store.substitutionEntries().first?.aliases, ["my alias"])
        XCTAssertEqual(store.makeSnapshot().terms.map(\.canonical), ["phenotype"])
        XCTAssertThrowsError(try store.copyWord(term, to: id))
        XCTAssertThrowsError(try store.copyWord(term, to: personal))
    }

    func testIntegrityOrWriteFailureLeavesOldBundleIntact() throws {
        let (data, entry) = try bundle([("phenotype", [])])
        try store.installBundle(data, entry: entry)
        let prior = store.packs
        XCTAssertThrowsError(try store.installBundle(data + Data(" ".utf8), entry: entry))
        XCTAssertEqual(store.packs, prior)
        let file = root.appendingPathComponent("vocabulary.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let (update, newEntry) = try bundle([("cultivar", [])], version: "2")
        XCTAssertThrowsError(try store.installBundle(update, entry: newEntry))
        XCTAssertEqual(store.packs, prior)
        XCTAssertNotNil(store.persistenceError)
    }

    func testDuplicateOrEmptyWordsCannotInstall() throws {
        let cases: [[(String, [String])]] = [[("phenotype", []), ("Phenotype", [])], [("  ", [])]]
        for words in cases {
            let (data, entry) = try bundle(words)
            XCTAssertThrowsError(try store.installBundle(data, entry: entry))
            XCTAssertTrue(store.packs.isEmpty)
        }
    }

    func testSameRevisionDoesNotDuplicateHistoryAndExportNeverSubscribes() throws {
        let (data, entry) = try bundle([("phenotype", [])])
        let id = try store.installBundle(data, entry: entry)
        try store.installBundle(data, entry: entry)
        XCTAssertEqual(store.packs.count, 1)
        XCTAssertEqual(store.packs[0].subscription?.changes.count, 1)
        let exported = try XCTUnwrap(store.exportData(for: id))
        let imported = try XCTUnwrap(store.importGlossaries(from: exported).first)
        XCTAssertNil(store.packs.first { $0.id == imported }?.subscription)
        try store.removeBundle(id)
        XCTAssertEqual(store.packs.map(\.id), [imported])
    }

    func testMetadataUpdatesRemainAvailableWithoutRepeatedDownloads() async throws {
        let (data, entry) = try bundle([("phenotype", [])])
        try store.installBundle(data, entry: entry)
        XCTAssertTrue(store.bundleIsCurrent(entry))
        let updated = GlossaryCatalog.Entry(id: entry.id, name: "Research words", description: String(repeating: "Research words. ", count: 30),
            version: "2", path: entry.path, sha256: entry.sha256, bytes: entry.bytes, termCount: entry.termCount, tags: [])
        XCTAssertFalse(store.bundleIsCurrent(updated))
        var downloads = 0
        let manager = GlossaryBundleManager(store: store, loadBundle: { _ in downloads += 1; return data })
        _ = await manager.sync(updated)
        XCTAssertTrue(store.bundleIsCurrent(updated))
        XCTAssertEqual(store.packs[0].subscription?.changes.count, 2)
        _ = await manager.sync(updated)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(store.packs[0].subscription?.changes.count, 2)
    }

    func testAutomaticUpdatesRequireOptInAndRespectDailyInterval() async throws {
        let (data, entry) = try bundle([("phenotype", [])])
        let id = try store.installBundle(data, entry: entry, now: .distantPast)
        var checks = 0
        let manager = GlossaryBundleManager(store: store, loadIndex: {
            checks += 1
            return .init(format: "sidewave.glossary.catalog", version: 1, glossaries: [entry])
        }, loadBundle: { _ in XCTFail("Unchanged bundle must not download again"); return data })
        await manager.checkAutomaticUpdates()
        XCTAssertEqual(checks, 0)
        try store.updateSubscription(id) { $0.automaticallyUpdates = true }
        await manager.checkAutomaticUpdates()
        XCTAssertEqual(checks, 1)
        await manager.checkAutomaticUpdates()
        XCTAssertEqual(checks, 1)
    }
}
