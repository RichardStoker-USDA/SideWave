// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

struct RecentDocumentsView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var documents: [DocumentDraftStore.SavedDocument] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return appState.documentDrafts.recentDocuments.filter {
            query.isEmpty || $0.draft.text.localizedCaseInsensitiveContains(query)
                || $0.draft.additions.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || (DictationFormatterService.Template(rawValue: $0.template)?.workspaceTitle.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent documents").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Open a previous document to continue editing. Your current page is saved before switching.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search documents", text: $search).textFieldStyle(.roundedBorder)
            if documents.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No previous documents" : "No matching documents",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(search.isEmpty ? "Starting a new document keeps the previous one here." : "Try another word or template name."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(documents) { item in
                            Button {
                                appState.restoreSpecialtyDocument(id: item.id)
                                if appState.documentDrafts.persistenceError == nil { dismiss() }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                                        Text("\(DictationFormatterService.Template(rawValue: item.template)?.workspaceTitle ?? "Document") · \(item.draft.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
            if let error = appState.documentDrafts.persistenceError {
                Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 540, height: 460).buttonBorderShape(.capsule)
    }
}

struct DocumentInstructionsView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Formatting rules").font(.title2.weight(.semibold))
            Text("Set the tone, structure, or wording you want. These rules apply to new dictation across templates. Use Change this document for a one-time edit.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("For example: use short bullets, keep all measurements, and preserve technical terms.",
                      text: $appState.dictationCleanupInstructions, axis: .vertical)
                .textFieldStyle(.plain).font(.body).lineLimit(6...10)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                .disabled(appState.isDictationBusy || appState.isProcessingAgenticEdit)
                .accessibilityLabel("Formatting rules")
            HStack {
                Text("\(appState.dictationCleanupInstructions.count) / 1,000 characters")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 500).buttonBorderShape(.capsule)
    }
}

/// One entry in the activity rail's applied-edit log.
struct AppliedAsk: Identifiable {
    let id = UUID()
    let instruction: String
}
