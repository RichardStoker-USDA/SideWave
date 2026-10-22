// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import TipKit
import UniformTypeIdentifiers

// MARK: - Bulk Import Sheet

/// Universal CSV importer for vocabulary words. Each row is one word with
/// up to three columns:
///   1. word              (required, the correct spelling)
///   2. mistranscriptions (optional, pipe-separated alternates)
///   3. description       (optional, short hint for the Refine model)
/// All imported words get scope = .both (Replace at dictation + Refine
/// hint) so they immediately work in both pipelines. Users can flip
/// scope per-word afterward in the Inspector if they want.
struct BulkImportSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let onImport: ([VocabTerm]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var csvText: String = ""
    @State private var parseResult: ParseResult = .empty

    private enum ParseResult {
        case empty
        case parsed(count: Int, terms: [VocabTerm])
        case error(String)
    }

    private static let templateText = """
    word,mistranscriptions,description
    USDA,you ess dee ay | u s d a,Federal agricultural research agency
    Kubernetes,k8s | kates,Container orchestration platform
    React.js,react js | reactjs,JavaScript UI framework by Meta
    """

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Import Words from CSV")
                    .font(.headline)
                Text("Paste a CSV table to add many words at once. Each row becomes one word in the current glossary.")
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Format")
                    .font(.callout.weight(.medium))
                VStack(alignment: .leading, spacing: 2) {
                    importFormatRow(
                        label: "word",
                        body: "Required. The correct spelling exactly as you want it typed."
                    )
                    importFormatRow(
                        label: "mistranscriptions",
                        body: "Optional. Pipe-separated alternates the dictation model might hear. Each one gets replaced with the word above."
                    )
                    importFormatRow(
                        label: "description",
                        body: "Optional. Short hint (up to 120 chars) the Refine model sees when this word appears in your dictation."
                    )
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("CSV")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Paste Template") {
                        csvText = Self.templateText
                        parseResult = Self.parse(csvText)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                TextEditor(text: $csvText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .background(
                        Color.cardBackground(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                            .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
                    )
                    .onChange(of: csvText) { _, newValue in
                        parseResult = Self.parse(newValue)
                    }
            }

            switch parseResult {
            case .empty:
                Text("Paste a header row plus one row per word. Header is optional, rows without one are parsed the same way.")
                    .font(.caption)
                    .adaptiveTertiary()
                    .fixedSize(horizontal: false, vertical: true)
            case .parsed(let count, _):
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Text("\(count) \(count == 1 ? "word" : "words") ready to import")
                        .font(.caption)
                        .adaptiveSecondary()
                }
            case .error(let msg):
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.warningAmber)
                    Text(msg)
                        .font(.caption)
                        .adaptiveSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .actionButton()
                    .keyboardShortcut(.cancelAction)

                Button("Import") {
                    if case .parsed(_, let terms) = parseResult {
                        onImport(terms)
                    }
                    dismiss()
                }
                .prominentActionButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560, height: 540)
    }

    private func importFormatRow(label: String, body: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 130, alignment: .leading)
            Text(body)
                .font(.caption)
                .adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var canImport: Bool {
        if case .parsed(let count, _) = parseResult { return count > 0 }
        return false
    }

    /// Lenient CSV parser. Supports 1–3 columns per row, optional header.
    /// Quoted values aren't handled. Descriptions with commas should be
    /// rewritten to avoid them, since CSV's quoting rules are a UX trap.
    private static func parse(_ text: String) -> ParseResult {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return .empty }

        var terms: [VocabTerm] = []
        var sawError = false

        for (idx, line) in lines.enumerated() {
            let lower = line.lowercased()
            if idx == 0,
               lower.hasPrefix("word,") || lower == "word,mistranscriptions,description"
                || lower.hasPrefix("triggers,") || lower == "triggers,replacement"
            {
                continue
            }
            if line.hasPrefix("#") { continue }

            // Split on commas, max 3 fields. Anything past the second
            // comma is description so a comma-friendly hint works.
            let parts = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }

            guard !parts.isEmpty else { sawError = true; continue }

            // Legacy `triggers,replacement` format detection: if the line
            // contains a pipe and the FIRST column is the trigger list,
            // treat parts[0] as aliases + parts[1] as canonical.
            let legacyFormat = lines.first?.lowercased().hasPrefix("triggers") == true

            let canonical: String
            let aliases: [String]
            let definition: String?

            if legacyFormat, parts.count >= 2 {
                aliases = parts[0].split(separator: "|")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                canonical = parts[1]
                definition = parts.count > 2 ? parts[2] : nil
            } else {
                canonical = parts[0]
                aliases = parts.count > 1
                    ? parts[1].split(separator: "|")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    : []
                definition = parts.count > 2 ? parts[2] : nil
            }

            guard !canonical.isEmpty else { sawError = true; continue }

            let cleanedDef: String?
            if let d = definition?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                cleanedDef = d.count > 120 ? String(d.prefix(120)) : d
            } else {
                cleanedDef = nil
            }

            terms.append(
                VocabTerm(
                    canonical: canonical,
                    aliases: aliases,
                    definition: cleanedDef,
                    priority: 2,
                    scope: .both
                )
            )
        }

        if terms.isEmpty, sawError {
            return .error("Couldn't parse any rows. Expected: word,mistranscriptions,description (last two optional)")
        }
        if terms.isEmpty { return .empty }
        return .parsed(count: terms.count, terms: terms)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the user hits Reset Hints in the app menu. Surfaces in
    /// the dashboard so it can re-arm the tip-settle timer without
    /// requiring a view re-mount.
    static let sideWaveResetHints = Notification.Name("sideWaveResetHints")
}
