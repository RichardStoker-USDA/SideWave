// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import HuggingFace

/// Lists supported Refine models in the shared Hugging Face cache.
enum ModelCacheInventory {
    struct Entry: Identifiable, Hashable {
        var id: String { path.path }
        let repoID: String
        let displayName: String
        let bytes: Int64
        let path: URL
    }

    static var knownRepositoryIDs: [String] {
        let defaults = DictationFormatterService.Backend.allCases.compactMap(\.huggingFaceRepoID) + [
            "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
        ]
        return Array(Set(defaults + defaults.map(ModelDownloadManager.resolveRepoID)))
    }

    static var hubRoot: URL {
        HubCache.default.cacheDirectory
    }

    static func listRefineModels(at root: URL = hubRoot,
                                 repositoryIDs: [String] = knownRepositoryIDs) -> [Entry] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return [] }

        let supported = Set(repositoryIDs.map { $0.lowercased() })
        return contents.compactMap { url -> Entry? in
            guard let repoID = repositoryID(for: url), supported.contains(repoID.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let bytes = folderBytes(url)
            return Entry(
                repoID: repoID,
                displayName: humanName(for: repoID),
                bytes: bytes,
                path: url
            )
        }.sorted { $0.displayName < $1.displayName }
    }

    static func delete(_ entry: Entry, at root: URL = hubRoot,
                       repositoryIDs: [String] = knownRepositoryIDs) throws {
        // URL resource values from enumeration can be stale after a folder changes.
        let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path.path)
        guard entry.path.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              repositoryID(for: entry.path)?.lowercased() == entry.repoID.lowercased(),
              repositoryIDs.contains(where: { $0.caseInsensitiveCompare(entry.repoID) == .orderedSame }),
              attributes?[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey:
                "This folder is not a supported Refine cache. Refresh the model list and try again."])
        }
        try FileManager.default.removeItem(at: entry.path)
    }

    // MARK: - Helpers

    private static func repositoryID(for url: URL) -> String? {
        let parts = url.lastPathComponent.components(separatedBy: "--")
        guard parts.count == 3, parts[0] == "models", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return parts[1] + "/" + parts[2]
    }

    private static func folderBytes(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let values = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func humanName(for repoID: String) -> String {
        let tail = repoID.split(separator: "/").last.map(String.init) ?? repoID
        switch tail.lowercased() {
        case "gemma-4-12b-it-4bit": return "Gemma 4 12B (4-bit)"
        case "gemma-4-e4b-it-4bit": return "Gemma 4 E4B (4-bit)"
        case "gemma-4-e2b-it-4bit": return "Gemma 4 E2B (4-bit)"
        case "meta-llama-3.1-8b-instruct-4bit": return "Llama 3.1 8B (4-bit, legacy)"
        case "llama-3.2-3b-instruct-4bit": return "Llama 3.2 3B (4-bit, legacy)"
        default: return tail
        }
    }
}
