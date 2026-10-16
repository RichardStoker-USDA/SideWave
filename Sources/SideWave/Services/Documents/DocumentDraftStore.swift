// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import Observation

/// Current and recent local documents. Transitions save atomically before replacing the page.
@MainActor
@Observable
final class DocumentDraftStore {
    struct Draft: Codable, Equatable {
        var id = UUID()
        var text: String
        var additions: [String] = []
        var instruction: String = ""
        var updatedAt = Date()

        var hasContent: Bool { !text.isEmpty || !additions.isEmpty || !instruction.isEmpty }

        init(text: String) { self.text = text }

        private enum CodingKeys: String, CodingKey { case id, text, additions, instruction, updatedAt }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            text = try values.decode(String.self, forKey: .text)
            additions = try values.decodeIfPresent([String].self, forKey: .additions) ?? []
            instruction = try values.decodeIfPresent(String.self, forKey: .instruction) ?? ""
            updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        }
    }

    struct SavedDocument: Codable, Identifiable, Equatable {
        var template: String
        var draft: Draft
        var id: UUID { draft.id }
        var title: String {
            let content = draft.text.isEmpty ? draft.additions.joined(separator: " ") : draft.text
            return content.split(whereSeparator: \.isNewline).first.map { String($0.prefix(100)) } ?? "Untitled document"
        }
    }

    private struct Snapshot: Codable {
        var documents: [String: Draft]
        var recentDocuments: [SavedDocument]
    }

    private var documents: [String: Draft] = [:]
    private(set) var recentDocuments: [SavedDocument] = []
    private let storageURL: URL
    private let isPersistent: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var canPersist = true
    @ObservationIgnored private var recoveryNotice: String?
    private(set) var persistenceError: String?
    private(set) var isSaving = false

    init(storageURL: URL? = nil, isPersistent: Bool = true) {
        self.storageURL = storageURL ?? AppPaths.applicationSupportDirectory().appendingPathComponent("document_drafts.json")
        self.isPersistent = isPersistent
        guard isPersistent, FileManager.default.fileExists(atPath: self.storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: self.storageURL)
            if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                documents = snapshot.documents
                recentDocuments = snapshot.recentDocuments.sorted { $0.draft.updatedAt > $1.draft.updatedAt }
            } else if let drafts = try? JSONDecoder().decode([String: Draft].self, from: data) {
                documents = drafts
            } else {
                documents = try JSONDecoder().decode([String: String].self, from: data)
                    .mapValues { Draft(text: $0) }
            }
        } catch {
            let preserved = self.storageURL.appendingPathExtension("corrupt-" + UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: self.storageURL, to: preserved)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preserved.path)
                recoveryNotice = "The saved document could not be read. Its original file is preserved as \(preserved.lastPathComponent)."
            } catch {
                canPersist = false
                recoveryNotice = "The saved document could not be read or preserved safely. Copy new work before closing SideWave."
            }
            persistenceError = recoveryNotice
        }
    }

    func draft(for template: String) -> Draft { documents[template] ?? Draft(text: "") }
    func text(for template: String) -> String { draft(for: template).text }

    func save(_ text: String, for template: String, additions: [String]? = nil, instruction: String? = nil) {
        var draft = draft(for: template)
        draft.text = text
        if let additions { draft.additions = additions }
        if let instruction { draft.instruction = instruction }
        guard documents[template] != draft else { return }
        draft.updatedAt = .now
        documents[template] = draft
        guard isPersistent, canPersist else { return }
        isSaving = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.flush()
        }
    }

    /// Keep the previous page in Recents, including manual edits and pending additions.
    @discardableResult
    func startNewDocument(for template: String) -> Bool {
        transition {
            archiveCurrent(for: template)
            documents[template] = Draft(text: "")
        }
    }

    @discardableResult
    func restoreDocument(id: UUID) -> SavedDocument? {
        guard let saved = recentDocuments.first(where: { $0.id == id }) else { return nil }
        guard transition({
            recentDocuments.removeAll { $0.id == id }
            archiveCurrent(for: saved.template)
            documents[saved.template] = saved.draft
        }) else { return nil }
        return saved
    }

    private func archiveCurrent(for template: String) {
        guard let draft = documents[template], draft.hasContent else { return }
        recentDocuments.removeAll { $0.id == draft.id }
        recentDocuments.insert(SavedDocument(template: template, draft: draft), at: 0)
    }

    private func transition(_ change: () -> Void) -> Bool {
        let previous = Snapshot(documents: documents, recentDocuments: recentDocuments)
        change()
        guard flush() else {
            documents = previous.documents
            recentDocuments = previous.recentDocuments
            return false
        }
        return true
    }

    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        isSaving = false
        guard isPersistent else { return true }
        guard canPersist else { return false }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Snapshot(documents: documents, recentDocuments: recentDocuments))
            try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            persistenceError = recoveryNotice
            return true
        } catch {
            persistenceError = "This document could not be saved. Copy it now and check free disk space."
            return false
        }
    }
}
