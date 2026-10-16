// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

@MainActor
final class VocabularyPersistenceTests: XCTestCase {
    func testPronunciationAndCategorySurviveStorageAndExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vocabulary.json")
        let store = VocabularyStore(storageURL: file)
        let id = store.createUserPack(name: "Research")
        store.addTerm(toPack: id, term: VocabTerm(canonical: "USDA", aliases: ["U.S.D.A."],
            pronunciation: "you ess dee ay", category: "Acronyms", scope: .both))
        let restored = VocabularyStore(storageURL: file)
        let term = try XCTUnwrap(restored.packs.first?.terms.first)
        XCTAssertEqual(term.pronunciation, "you ess dee ay")
        XCTAssertEqual(term.category, "Acronyms")
        XCTAssertEqual(restored.substitutionEntries().first?.aliases, ["U.S.D.A.", "you ess dee ay"])
        XCTAssertEqual(term.aliases, ["U.S.D.A."], "Derived pronunciation aliases must not change stored aliases")
        let exported = try XCTUnwrap(restored.exportData(for: id))
        let importedID = try XCTUnwrap(restored.importGlossaries(from: exported).first)
        XCTAssertEqual(restored.packs.first(where: { $0.id == importedID })?.terms.first?.category, "Acronyms")
        XCTAssertEqual(restored.packs.first(where: { $0.id == importedID })?.terms.first?.pronunciation, "you ess dee ay")
    }

    func testFailedSaveKeepsEditsAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vocabulary.json")
        let store = VocabularyStore(storageURL: file)
        let id = store.createUserPack(name: "Research")
        store.addTerm(toPack: id, term: VocabTerm(canonical: "Arabidopsis"))
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(store.packs.first?.terms.first?.canonical, "Arabidopsis")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(store.retrySaving())
        XCTAssertNil(store.persistenceError)
        let restored = VocabularyStore(storageURL: file)
        XCTAssertEqual(restored.packs.first?.terms.first?.canonical, "Arabidopsis")
    }

    func testUnreadableStorageCannotBeOverwrittenByEmptyState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vocabulary.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let sentinel = file.appendingPathComponent("original")
        try Data("preserved".utf8).write(to: sentinel)
        let store = VocabularyStore(storageURL: file)
        XCTAssertTrue(store.storageNeedsRecovery)
        _ = store.createUserPack(name: "Unsaved")
        XCTAssertFalse(store.retrySaving())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserved".utf8))
    }

    func testCorruptBytesArePreservedBeforeNewVocabularyIsSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("vocabulary.json")
        let bytes = Data("incomplete {".utf8)
        try bytes.write(to: file)
        let store = VocabularyStore(storageURL: file)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(store.storageNeedsRecovery)
        _ = store.createUserPack(name: "Replacement")
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("vocabulary.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
    }

    func testUnrelatedJSONIsNotImportedAsAnEmptyGlossary() {
        for json in ["{}", "{\"status\":\"ok\"}", "[{\"message\":\"unrelated\"}]"] {
            XCTAssertNil(VocabularyStore.decodeGlossaries(from: Data(json.utf8)))
        }
    }
}
