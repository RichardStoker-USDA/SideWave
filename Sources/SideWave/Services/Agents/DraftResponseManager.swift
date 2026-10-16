// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

// MARK: - Draft Response Manager

/// Holds a speculative TTS response submitted by an agent via MCP.
/// The agent pre-computes a reply while the user is still dictating,
/// and SideWave queues it after dictation if the final words still match.
@Observable
@MainActor
final class DraftResponseManager {

    // MARK: - Types

    enum DraftOutcome: String {
        case pending    // Draft submitted, waiting for dictation to end
        case used       // Draft matched final transcript and was consumed
        case discarded  // Final transcript diverged too far, draft dropped
        case expired    // Draft timed out (user kept talking too long)
        case cancelled  // Recording was cancelled, draft dropped
    }

    struct Draft {
        let id: String
        let text: String
        let transcriptSnapshot: String
        let submittedAt: Date
        var outcome: DraftOutcome = .pending
    }

    // MARK: - State

    /// The current draft, if any. Only one draft can be active at a time;
    /// submitting a new one replaces the previous.
    private(set) var currentDraft: Draft?

    /// History of recent draft outcomes so the agent can poll status.
    /// Keyed by draft ID. Capped at 20 entries, evicting oldest first.
    private(set) var outcomeLog: [String: DraftOutcome] = [:]

    /// Draft IDs in finalize order. Parallel to `outcomeLog` so the cap evicts
    /// the oldest entry rather than an arbitrary Dictionary key (which could
    /// drop a just-finalized outcome an agent is about to poll).
    private var outcomeOrder: [String] = []

    /// Drafts older than this are auto-expired. Prevents stale responses
    /// from firing if the user pauses for a long time mid-dictation.
    var maxDraftAge: TimeInterval = 30.0

    // MARK: - Submit

    /// Agent submits a pre-computed response. Returns the draft ID.
    @discardableResult
    func submit(text: String, transcriptSnapshot: String) -> String {
        // Replace any existing draft (mark old one as discarded)
        if let old = currentDraft, old.outcome == .pending {
            finalize(draftID: old.id, outcome: .discarded)
        }

        let id = UUID().uuidString
        let draft = Draft(
            id: id,
            text: text,
            transcriptSnapshot: transcriptSnapshot,
            submittedAt: Date()
        )
        currentDraft = draft
        print("[DraftResponse] Submitted draft \(id.prefix(8))... (\(text.count) chars, snapshot: \(transcriptSnapshot.count) chars)")
        return id
    }

    // MARK: - Consume

    /// Called by handleStopRecording. Returns the draft text if it's valid
    /// against the final transcript, otherwise nil.
    func consumeIfValid(finalTranscript: String) -> String? {
        guard let draft = currentDraft, draft.outcome == .pending else {
            return nil
        }

        // Check age
        if Date().timeIntervalSince(draft.submittedAt) > maxDraftAge {
            finalize(draftID: draft.id, outcome: .expired)
            currentDraft = nil
            print("[DraftResponse] Draft \(draft.id.prefix(8))... expired (age > \(maxDraftAge)s)")
            return nil
        }

        // Word overlap can miss negation, changed numbers, or reordered instructions.
        if Self.transcriptsMatch(draft.transcriptSnapshot, finalTranscript) {
            finalize(draftID: draft.id, outcome: .used)
            currentDraft = nil
            print("[DraftResponse] Draft \(draft.id.prefix(8))... USED")
            return draft.text
        } else {
            finalize(draftID: draft.id, outcome: .discarded)
            currentDraft = nil
            print("[DraftResponse] Draft \(draft.id.prefix(8))... discarded (transcript changed)")
            return nil
        }
    }

    // MARK: - Cancel / Clear

    /// Called when recording is cancelled (escape key). Drops any pending draft.
    func cancelPending() {
        guard let draft = currentDraft, draft.outcome == .pending else { return }
        finalize(draftID: draft.id, outcome: .cancelled)
        currentDraft = nil
        print("[DraftResponse] Draft \(draft.id.prefix(8))... cancelled")
    }

    /// Called when a new recording session starts. Clear stale state.
    func resetForNewSession() {
        if let draft = currentDraft, draft.outcome == .pending {
            finalize(draftID: draft.id, outcome: .discarded)
        }
        currentDraft = nil
    }

    // MARK: - Status Query

    /// Agent polls this to check what happened to its draft.
    func outcomeFor(draftID: String) -> DraftOutcome? {
        if let current = currentDraft, current.id == draftID {
            return current.outcome
        }
        return outcomeLog[draftID]
    }

    // MARK: - Internals

    private func finalize(draftID: String, outcome: DraftOutcome) {
        if outcomeLog[draftID] == nil {
            outcomeOrder.append(draftID)
        }
        outcomeLog[draftID] = outcome

        // Cap log size, evicting oldest first so a freshly finalized outcome
        // survives long enough for the agent to poll it.
        while outcomeOrder.count > 20 {
            let oldest = outcomeOrder.removeFirst()
            outcomeLog.removeValue(forKey: oldest)
        }
    }

    /// Ignore presentation changes, retaining word order, negation, numbers and signs.
    static func transcriptsMatch(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().replacingOccurrences(of: "’", with: "'")
                .split(whereSeparator: \.isWhitespace)
                .map {
                    var word = $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
                    while let last = word.last, ".,!?;:".contains(last) { word.removeLast() }
                    return word
                }
                .filter { !$0.isEmpty }
        }
        let first = words(a)
        return !first.isEmpty && first == words(b)
    }
}
