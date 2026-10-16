// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class ModelCacheInventoryTests: XCTestCase {
    @MainActor
    func testResetPathsOnlyNameKnownModelFolders() throws {
        let root = URL(fileURLWithPath: "/scoped_fixture")
        let paths = AppResetService.modelResetPaths(home: root, appSupport: root.appendingPathComponent("support"),
            hubRoot: root.appendingPathComponent("custom_hub"), repositoryIDs: ["publisher/model", "../outside", "publisher/../../outside"])
        XCTAssertTrue(paths.contains(root.appendingPathComponent("custom_hub/models--publisher--model", isDirectory: true)))
        XCTAssertFalse(paths.contains(root.appendingPathComponent("support/FluidAudio")))
        XCTAssertFalse(paths.contains(root.appendingPathComponent(".cache/fluidaudio")))
        XCTAssertFalse(paths.contains(root.appendingPathComponent("custom_hub")))
        XCTAssertTrue(paths.allSatisfy { !$0.path.contains("..") })
        XCTAssertFalse(paths.contains { $0.lastPathComponent.contains("embeddinggemma") })
    }

    private func cacheFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func model(_ repoID: String, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("models--" + repoID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: folder.appendingPathComponent("weights"))
        return folder
    }

    func testInventoryKeepsOtherModelsOutAndRecognizesMirrorsAndCase() throws {
        let root = try cacheFixture()
        _ = try model("mlx-community/gemma-4-12b-it-4bit", in: root)
        _ = try model("research-mirror/gemma-4-e2b-it-4bit", in: root)
        _ = try model("mlx-community/gemma-4-31b-it-8bit", in: root)
        _ = try model("mlx-community/Llama-unrelated", in: root)
        let repositories = ["mlx-community/gemma-4-12B-it-4bit", "research-mirror/gemma-4-e2b-it-4bit"]
        let entries = ModelCacheInventory.listRefineModels(at: root, repositoryIDs: repositories)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.displayName)), ["Gemma 4 12B (4-bit)", "Gemma 4 E2B (4-bit)"])
        XCTAssertTrue(entries.allSatisfy { $0.bytes == 128 })
    }

    func testInventoryDoesNotFollowModelLinksOrCountSnapshotLinksTwice() throws {
        let root = try cacheFixture()
        let outside = try cacheFixture()
        let repo = "mlx-community/gemma-4-e2b-it-4bit"
        let folder = try model(repo, in: root)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("snapshot"),
                                                   withDestinationURL: folder.appendingPathComponent("weights"))
        let alias = root.appendingPathComponent("models--mlx-community--gemma-4-12b-it-4bit")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let entries = ModelCacheInventory.listRefineModels(at: root,
            repositoryIDs: [repo, "mlx-community/gemma-4-12B-it-4bit"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.bytes, 128)
    }

    func testDeletionRejectsEscapedOrReplacedPathsAndPreservesOtherCaches() throws {
        let root = try cacheFixture()
        let outside = try cacheFixture()
        let repo = "mlx-community/gemma-4-e2b-it-4bit"
        let folder = try model(repo, in: root)
        let external = try model(repo, in: outside)
        let other = try model("mlx-community/gemma-4-31b-it-8bit", in: root)
        let entry = try XCTUnwrap(ModelCacheInventory.listRefineModels(at: root, repositoryIDs: [repo]).first)
        let escaped = ModelCacheInventory.Entry(repoID: repo, displayName: "External", bytes: 128, path: external)
        XCTAssertThrowsError(try ModelCacheInventory.delete(escaped, at: root, repositoryIDs: [repo]))
        let unrelated = ModelCacheInventory.Entry(repoID: repo, displayName: "Unrelated", bytes: 128, path: other)
        XCTAssertThrowsError(try ModelCacheInventory.delete(unrelated, at: root, repositoryIDs: [repo]))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: external)
        XCTAssertThrowsError(try ModelCacheInventory.delete(entry, at: root, repositoryIDs: [repo]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("weights").path))
        try FileManager.default.removeItem(at: folder)
        _ = try model(repo, in: root)
        try ModelCacheInventory.delete(entry, at: root, repositoryIDs: [repo])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }
}
