// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import SideWaveKit

struct DownloadRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    /// What was fetched ("Speech model (multilingual, 1120 ms)").
    let component: String
    /// Where it came from; the repos are fixed constants, never dynamic.
    let source: String
    /// True when the loaders reported actual network file transfers;
    /// false means everything loaded from the on-disk cache.
    let networkFetch: Bool
    let durationSeconds: Double
}

/// The transparency ledger: one row per model-preparation run, written
/// from the loaders' own progress reports. SideWave makes no other
/// network requests, so this list IS the app's network activity.
@MainActor
@Observable
final class DownloadLedger {

    private(set) var records: [DownloadRecord] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.sidewave2.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("downloads.json")
        load()
    }

    func record(component: String, source: String, networkFetch: Bool, duration: Duration) {
        let record = DownloadRecord(
            id: UUID(),
            date: Date(),
            component: component,
            source: source,
            networkFetch: networkFetch,
            durationSeconds: Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
        )
        records.insert(record, at: 0)
        if records.count > 100 {
            records.removeLast(records.count - 100)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([DownloadRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
