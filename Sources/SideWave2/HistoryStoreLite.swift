// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import SideWaveKit

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let rawText: String
    let finalText: String
    let refined: Bool
    let appName: String
    let durationSeconds: Double
}

/// Minimal on-disk history: newest first, capped, one JSON file under
/// this app's Application Support directory. The full history feature
/// set (search, retention tiers, redaction review) returns with its
/// module; the shape here matches so entries migrate forward.
@MainActor
@Observable
final class HistoryStoreLite {

    private(set) var entries: [HistoryEntry] = []
    private let limit: Int
    private let fileURL: URL

    init(limit: Int = 200) {
        self.limit = limit
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.sidewave2.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func record(outcome: SessionOutcome, appName: String) {
        guard !outcome.finalText.isEmpty || !outcome.rawTranscript.isEmpty else { return }
        let entry = HistoryEntry(
            id: UUID(),
            date: Date(),
            rawText: outcome.rawTranscript,
            finalText: outcome.finalText,
            refined: outcome.refined,
            appName: appName,
            durationSeconds: Double(outcome.duration.components.seconds)
                + Double(outcome.duration.components.attoseconds) / 1e18
        )
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        save()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        // Owner-only: entries hold the user's dictated words.
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
