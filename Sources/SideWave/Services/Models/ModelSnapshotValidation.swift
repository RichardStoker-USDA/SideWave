// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import HuggingFace

/// Checks the files that a text model needs before reporting it as installed.
enum ModelSnapshotValidation {
    struct Failure: LocalizedError {
        let files: [String]
        var errorDescription: String? {
            "The model is incomplete or damaged (\(files.joined(separator: ", "))). Retry to resume or repair these files."
        }
    }

    static func cachedSnapshot(repoID: String, revision: String = "main", cache: HubCache = .default) -> URL? {
        guard let id = Repo.ID(rawValue: repoID) else { return nil }
        let commit = cache.resolveRevision(repo: id, kind: .model, ref: revision) ?? revision
        if isCommitRevision(commit) {
            let directory = cache.snapshotsDirectory(repo: id, kind: .model).appendingPathComponent(commit)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return directory
            }
        }
        return cache.cachedFilePath(repo: id, kind: .model, revision: revision, filename: "config.json")?
            .deletingLastPathComponent()
    }

    static func isCommitRevision(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }

    static func invalidFiles(at directory: URL) -> [String] {
        var invalid = Set<String>()
        let config = json(at: directory, name: "config.json")
        if config?["model_type"] as? String == nil { invalid.insert("config.json") }
        let tokenizer = json(at: directory, name: "tokenizer.json")
        if (tokenizer?["model"] as? [String: Any])?["vocab"] == nil { invalid.insert("tokenizer.json") }
        let tokenizerConfig = json(at: directory, name: "tokenizer_config.json")
        if tokenizerConfig == nil { invalid.insert("tokenizer_config.json") }
        let templateURL = directory.appendingPathComponent("chat_template.jinja")
        let template = (try? String(contentsOf: templateURL, encoding: .utf8)) ?? (tokenizerConfig?["chat_template"] as? String)
        if template?.contains("messages") != true { invalid.insert("chat_template.jinja") }

        let indexName = "model.safetensors.index.json"
        let indexURL = directory.appendingPathComponent(indexName)
        let weights: Set<String>
        if FileManager.default.fileExists(atPath: indexURL.path) {
            if let map = json(at: directory, name: indexName)?["weight_map"] as? [String: String], !map.isEmpty {
                weights = Set(map.values)
            } else {
                invalid.insert(indexName)
                weights = []
            }
        } else {
            weights = ["model.safetensors"]
        }
        for name in weights {
            guard isSafeFileName(name) else { invalid.insert(indexName); continue }
            if !validSafetensors(at: directory.appendingPathComponent(name)) { invalid.insert(name) }
        }
        return invalid.sorted()
    }

    static func validate(at directory: URL) throws {
        let files = invalidFiles(at: directory)
        if !files.isEmpty { throw Failure(files: files) }
    }

    /// Remove only files proven invalid. Other weight shards and resumable transfers stay intact.
    static func removeInvalidFiles(_ names: [String], at directory: URL, cacheRoot: URL = HubCache.default.cacheDirectory) throws {
        let root = cacheRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let snapshot = directory.resolvingSymlinksInPath().standardizedFileURL
        guard snapshot.path.hasPrefix(root) else { return }
        for name in names where isSafeFileName(name) {
            let file = snapshot.appendingPathComponent(name)
            // A linked parent must not turn cache repair into an external deletion.
            let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard (parent.path + "/").hasPrefix(root) else { continue }
            let target = file.resolvingSymlinksInPath()
            if target != file, target.standardizedFileURL.path.hasPrefix(root),
               FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.split(separator: "/").contains("..")
    }

    private static func json(at directory: URL, name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func validSafetensors(at url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            try file.seek(toOffset: 0)
            guard let prefix = try file.read(upToCount: 8), prefix.count == 8 else { return false }
            let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            guard length > 1, length < 100_000_000, size > length + 8,
                  let header = try file.read(upToCount: Int(length)), header.count == length,
                  let entries = try JSONSerialization.jsonObject(with: header) as? [String: Any] else { return false }
            var end: UInt64 = 0
            var tensors = 0
            for (key, value) in entries where key != "__metadata__" {
                guard let tensor = value as? [String: Any], let offsets = tensor["data_offsets"] as? [UInt64],
                      offsets.count == 2, offsets[1] >= offsets[0], offsets[1] <= size - length - 8 else { return false }
                end = max(end, offsets[1]); tensors += 1
            }
            return tensors > 0 && end == size - length - 8
        } catch { return false }
    }
}
