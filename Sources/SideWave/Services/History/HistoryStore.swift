// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

enum HistoryRetention: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case ninetyDays = 90
    case never = 0

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .oneDay: return "1 Day"
        case .threeDays: return "3 Days"
        case .sevenDays: return "7 Days"
        case .fourteenDays: return "14 Days"
        case .thirtyDays: return "30 Days"
        case .ninetyDays: return "90 Days"
        case .never: return "Never"
        }
    }
}

enum EntryType: String, Codable {
    case dictation
    case document
    case meeting
    case cancelled
    /// Recovered after a crash: text from a session log and sidecar left on disk because the
    /// previous run never reached cleanup. Shown in History so nothing dictated is lost.
    case recovered
}

/// Literal back-translation of a translated dictation, saved on the entry so it runs once.
/// `literalText` renders the translation word for word in the language the user spoke; `reasoning`
/// explains the choices that weren't literal.
struct BackTranslation: Codable, Equatable {
    let literalText: String
    let reasoning: String
}

struct TranscriptionEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    /// The refined / final pasted text. This is the default surface in
    /// History: what the user actually sent into their target app.
    let text: String
    let appName: String
    let characterCount: Int
    /// Differentiates regular dictation from meeting transcripts in history.
    /// Optional for backward compatibility with existing history files.
    let entryType: EntryType?
    /// TDT text: recognition output with capitalization, punctuation, and vocabulary boosting,
    /// before Refine. Shown under the earlier stages in History. Nil for older entries and
    /// unrefined ones.
    let rawText: String?
    /// Streaming text: what the live recognizer had when each segment finished, with no
    /// punctuation, capitals, or vocabulary boosting. Nil for older entries and single-stage
    /// sessions.
    let eouText: String?
    /// The Refine backend that produced the text ("afm", "gemma4-e2b", "gemma4-e4b"). Nil when
    /// Refine was bypassed, for older entries, and for cancelled ones. Shown as a small logo in
    /// History.
    let refineBackend: String?
    let refinementUsed: Bool?
    /// Links retained recovery files to one history entry across launch retries.
    let recoverySourceID: String?
    let recoveryIncomplete: Bool?

    /// Legacy entries did not distinguish a saved raw stage from an actual refine pass.
    var displayRefineBackend: String? {
        guard refinementUsed ?? hasDistinctRawText else { return nil }
        return refineBackend
    }
    /// Short AI title for the History list, written after the entry is saved: Apple Intelligence
    /// first, Gemma as the fallback, the opening words when neither is loaded. Nil for older
    /// entries.
    var aiSummary: String?
    /// Language code the entry was translated into ("es", "ja"). Nil when the spoken language was
    /// kept, Refine was bypassed, or for older entries. Enables back-translation in History.
    let outputLanguage: String?
    /// Saved back-translation, filled the first time the user opens it. Nil until then and for
    /// untranslated entries.
    var backTranslation: BackTranslation?

    var isMeeting: Bool { entryType == .meeting }

    /// True when the text was translated, so back-translation is offered only then.
    var wasTranslated: Bool {
        DictationFormatterService.OutputLanguage.from(code: outputLanguage) != .matchInput
    }

    /// The output language as a resolved enum, for display + prompt building.
    var outputLanguageValue: DictationFormatterService.OutputLanguage {
        DictationFormatterService.OutputLanguage.from(code: outputLanguage)
    }

    /// True when rawText exists and differs from the final text; shows the earlier stages in
    /// History.
    var hasDistinctRawText: Bool {
        guard let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        return raw != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when eouText exists and differs from rawText.
    var hasDistinctEouText: Bool {
        guard let eou = eouText?.trimmingCharacters(in: .whitespacesAndNewlines), !eou.isEmpty else {
            return false
        }
        let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        return eou != raw
    }

    /// True when ANY earlier stage (EOU or TDT) is available for the
    /// "Show stages" disclosure. Hides the disclosure on legacy / no-
    /// refine entries where there's nothing meaningful to show.
    var hasAnyStageHistory: Bool {
        hasDistinctRawText || hasDistinctEouText
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        text: String,
        appName: String,
        entryType: EntryType? = .dictation,
        rawText: String? = nil,
        eouText: String? = nil,
        refineBackend: String? = nil,
        aiSummary: String? = nil,
        outputLanguage: String? = nil,
        backTranslation: BackTranslation? = nil,
        recoverySourceID: String? = nil,
        recoveryIncomplete: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.appName = appName
        self.characterCount = text.count
        self.entryType = entryType
        self.rawText = rawText
        self.eouText = eouText
        self.refineBackend = refineBackend
        self.refinementUsed = refineBackend != nil
        self.aiSummary = aiSummary
        self.outputLanguage = outputLanguage
        self.backTranslation = backTranslation
        self.recoverySourceID = recoverySourceID
        self.recoveryIncomplete = recoveryIncomplete
    }

    var previewText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 80 {
            return String(trimmed.prefix(77)) + "..."
        }
        return trimmed
    }

    var relativeTimeString: String {
        if abs(timestamp.timeIntervalSinceNow) < 60 { return "Just now" }
        return timestamp.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    var fullDateString: String {
        timestamp.formatted(date: .abbreviated, time: .shortened)
    }
}

@Observable
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private static let maxEntries = 500

    private(set) var entries: [TranscriptionEntry] = []
    private(set) var persistenceError: String?
    private var storageNeedsRecovery = false
    private let generatesTitles: Bool
    var selectedEntryID: UUID?

    private let fileURL: URL
    private let saveQueue = DispatchQueue(label: "com.sidewave.historystore.save", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    init(storageURL: URL, sessionsDirectory: URL? = nil) {
        fileURL = storageURL
        generatesTitles = false
        loadEntries()
        if let sessionsDirectory { recoverLeftoverSessions(in: sessionsDirectory) }
    }

    var storageDirectory: URL { fileURL.deletingLastPathComponent() }

    private init() {
        generatesTitles = true
        UserDefaults.standard.register(defaults: [
            "historyRetentionDays": 7,
            "historyAITitlesEnabled": true,
        ])

        let appDir = AppPaths.applicationSupportDirectory()
        fileURL = appDir.appendingPathComponent("history.json")
        loadEntries()
        // Crash recovery before the 7-day cleanup: session files left by a run that didn't finish
        // cleanly become recovered History entries.
        recoverLeftoverSessions()
        pruneExpiredEntries()
    }

    var selectedEntry: TranscriptionEntry? {
        guard let id = selectedEntryID else { return nil }
        return entries.first { $0.id == id }
    }

    func addEntry(text: String, appName: String, entryType: EntryType = .dictation, rawText: String? = nil, eouText: String? = nil, refineBackend: String? = nil, outputLanguage: String? = nil, recoverySourceID: String? = nil, recoveryIncomplete: Bool? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let trimmedRaw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedRaw: String? = (trimmedRaw?.isEmpty == false) ? trimmedRaw : nil

        let trimmedEou = eouText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedEou: String? = (trimmedEou?.isEmpty == false) ? trimmedEou : nil

        // Only stamp a translation language when refine actually ran and the
        // caller passed a non-"match" code. addEntry's callers already gate on
        // rawForHistory != nil, so an untranslated entry carries nil here.
        let storedOutputLanguage: String? = {
            guard let code = outputLanguage,
                  DictationFormatterService.OutputLanguage.from(code: code) != .matchInput
            else { return nil }
            return code
        }()

        let recoveredIndex = recoverySourceID.flatMap { source in entries.firstIndex { $0.recoverySourceID == source } }
        let previous = recoveredIndex.map { entries[$0] }
        let entry = TranscriptionEntry(
            id: previous?.id ?? UUID(),
            timestamp: previous?.timestamp ?? Date(),
            text: trimmed,
            appName: appName,
            entryType: entryType,
            rawText: storedRaw,
            eouText: storedEou,
            refineBackend: refineBackend,
            aiSummary: previous?.text == trimmed ? previous?.aiSummary : nil,
            outputLanguage: storedOutputLanguage,
            recoverySourceID: recoverySourceID,
            recoveryIncomplete: recoveryIncomplete
        )
        if let recoveredIndex { entries[recoveredIndex] = entry }
        else { entries.insert(entry, at: 0) }

        // Prune oldest entries beyond max
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        pruneExpiredEntries()

        saveEntries()

        // AI title for the History list, generated off the main actor so saving and pasting aren't
        // delayed; setAiSummary writes it back. Skipped when the user turned AI titles off, and the
        // list shows the opening words instead.
        let entryID = entry.id
        let textForSummary = trimmed
        let aiTitlesEnabled = UserDefaults.standard.object(forKey: "historyAITitlesEnabled") as? Bool ?? true
        if generatesTitles && aiTitlesEnabled && entry.aiSummary == nil {
            Task { [weak self] in
                let summary = await HistorySummarizer.summarize(text: textForSummary)
                await MainActor.run {
                    self?.setAiSummary(id: entryID, summary: summary)
                }
            }
        }
    }

    /// Writes the AI title onto an entry and schedules a save. Does nothing if the entry was
    /// deleted in the meantime.
    func setAiSummary(id: UUID, summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[idx].aiSummary != trimmed else { return }
        entries[idx].aiSummary = trimmed
        saveEntries()
    }

    /// Caches an on-demand literal back-translation onto an existing entry so
    /// the sheet never re-runs the model. No-op if the entry was deleted since
    /// the request started. Triggers a debounced save so it survives relaunch.
    func setBackTranslation(id: UUID, _ result: BackTranslation) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[idx].backTranslation != result else { return }
        entries[idx].backTranslation = result
        saveEntries()
    }

    func pruneExpiredEntries() {
        let retentionDays = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        guard retentionDays > 0 else { return } // 0 = never delete

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        let before = entries.count
        entries.removeAll { $0.timestamp < cutoff }

        if entries.count < before {
            saveEntries()
        }
    }

    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        if selectedEntryID == id {
            selectedEntryID = entries.first?.id
        }
        saveEntries()
    }

    func clearAll() {
        entries.removeAll()
        selectedEntryID = nil
        saveEntries()
    }

    func search(query: String) -> [TranscriptionEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }

        let lowercased = trimmed.lowercased()
        return entries.filter { entry in
            entry.text.lowercased().contains(lowercased)
                || entry.appName.lowercased().contains(lowercased)
                || (entry.rawText?.lowercased().contains(lowercased) ?? false)
        }
    }

    private func loadEntries() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
        } catch {
            // Keep the unreadable file before the next save overwrites it: rename it to a dated
            // copy so the data can still be recovered.
            let fm = FileManager.default
            let ts = Int(Date().timeIntervalSince1970)
            let backupURL = fileURL.appendingPathExtension("corrupt-\(ts)")
            do {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
                guard values.isRegularFile == true, values.isReadable == true else { throw error }
                try fm.moveItem(at: fileURL, to: backupURL)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
                persistenceError = "History could not be decoded. The original file is preserved in \(backupURL.lastPathComponent)."
            } catch {
                storageNeedsRecovery = true
                persistenceError = "History could not be read or preserved safely. Existing history will not be overwritten."
            }
            entries = []
        }
    }

    /// Writes any pending save now. Called at quit and by recoverLeftoverSessions before it deletes
    /// its source files. Returns true when the write succeeded. Runs on saveQueue: cancelling a
    /// save that is already running isn't possible, and a direct write could be overwritten by that
    /// older snapshot, bringing back entries deleted just before quitting.
    @discardableResult
    func flush() -> Bool {
        guard !storageNeedsRecovery else { return false }
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = entries
        let url = fileURL
        var success = false
        saveQueue.sync {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                // Set owner-only permissions again: the atomic write replaces the file with a new
                // one that gets default permissions (0644), which would leave history readable by
                // other users.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                success = true
            } catch {
                SWLog.note("[HistoryStore] History flush failed")
            }
        }
        if !success { persistenceError = "History changes could not be saved. Copy your output before quitting." }
        else { persistenceError = nil }
        return success
    }

    /// Recover readable journal lines and snapshots, retaining damaged sources.
    private func recoverLeftoverSessions(in directory: URL? = nil) {
        guard !storageNeedsRecovery else { return }
        let sessionsDir = directory ?? AppPaths.applicationSupportDirectory().appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        var sessions: [String: [String: URL]] = [:]
        for file in files where file.lastPathComponent.hasPrefix("session_") {
            for suffix in [".volatile.tmp", ".volatile", ".jsonl"] where file.lastPathComponent.hasSuffix(suffix) {
                let id = String(file.lastPathComponent.dropLast(suffix.count))
                sessions[id, default: [:]][suffix] = file
                break
            }
        }

        var filesToDelete: [(id: String, hasText: Bool, files: [URL])] = []
        var recoveredCount = 0
        var unreadableCount = 0
        for id in sessions.keys.sorted() {
            guard let sources = sessions[id] else { continue }
            var pieces: [String] = []
            var incomplete = false
            if let url = sources[".jsonl"] {
                do {
                    let content = try Data(contentsOf: url)
                    for line in content.split(separator: 0x0A, omittingEmptySubsequences: true) {
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                              let record = object as? [String: Any], let text = record["text"] as? String else {
                            incomplete = true
                            continue
                        }
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(text) }
                    }
                } catch { incomplete = true }
            }
            // Prefer the newest readable snapshot, including the legacy temporary file.
            let snapshots = [sources[".volatile"], sources[".volatile.tmp"]].compactMap { $0 }.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }
            for snapshot in snapshots {
                do {
                    let text = try String(contentsOf: snapshot, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty && pieces.last?.trimmingCharacters(in: .whitespacesAndNewlines) != text { pieces.append(text) }
                    break
                } catch { incomplete = true }
            }
            let combined = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !combined.isEmpty {
                addEntry(text: combined, appName: "Recovered", entryType: .recovered,
                         recoverySourceID: id, recoveryIncomplete: incomplete)
                recoveredCount += 1
            }
            if incomplete { unreadableCount += 1 }
            else {
                filesToDelete.append((id, !combined.isEmpty, Array(sources.values)))
            }
        }
        // A second crash must not remove the only durable copy.
        guard recoveredCount == 0 || flush() else { return }
        let savedSources = Set(entries.compactMap(\.recoverySourceID))
        for source in filesToDelete where !source.hasText || savedSources.contains(source.id) {
            for url in source.files { try? FileManager.default.removeItem(at: url) }
        }
        if unreadableCount > 0 {
            persistenceError = "Some dictation was only partly recovered. Readable text is in History; original files remain in the sessions folder inside storage."
        }
    }

    private func saveEntries() {
        guard !storageNeedsRecovery else { return }
        // Snapshot entries on main actor, then write on background queue with debounce
        let snapshot = entries
        let url = fileURL

        pendingSave?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                // Restrict file to owner-only read/write
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            } catch {
                Task { @MainActor [weak self] in
                    self?.persistenceError = "History changes could not be saved. Copy your output before quitting."
                }
            }
        }
        pendingSave = workItem
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}
