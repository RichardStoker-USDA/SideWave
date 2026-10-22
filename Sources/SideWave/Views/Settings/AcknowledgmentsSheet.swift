// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

/// The models and code SideWave uses, read from ThirdPartyNotices.json. scripts/third_party_notices.py
/// writes that file from Package.resolved and copies each project's license files verbatim.
struct ThirdPartyNotices: Decodable {
    struct Entry: Decodable, Identifiable, Hashable {
        let id: String
        let group: String
        let name: String
        let by: String
        let purpose: String
        let license: String
        let url: String
        let licenseURL: String?
        let note: String?
        let version: String?
        let documents: [Document]
    }

    struct Document: Decodable, Hashable {
        let title: String
        let license: String
        let file: String
        let text: String
    }

    let entries: [Entry]
    let texts: [String: String]

    static let groupOrder = ["Speech models", "Language models", "Code"]

    static func load(from bundle: Bundle = .main) -> ThirdPartyNotices? {
        guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThirdPartyNotices.self, from: data)
    }

    func text(for document: Document) -> String { texts[document.text] ?? "" }
}

struct AcknowledgmentsSheet: View {
    var initialSelection: ThirdPartyNotices.Entry.ID?
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ThirdPartyNotices.Entry.ID?
    @State private var query = ""
    @State private var pendingURL: String?
    private let notices = ThirdPartyNotices.load()

    var body: some View {
        VStack(spacing: 0) {
            if let notices {
                HStack(spacing: 0) {
                    sidebar(notices).frame(width: 264)
                    Divider()
                    detail(notices).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Acknowledgments Unavailable", systemImage: "doc.questionmark",
                                       description: Text("The notices file is missing from this build. The same list is at sidewave.dev/acknowledgments."))
            }
            Divider()
            HStack {
                Text("Each license is copied from the project at the version SideWave uses.")
                    .font(.caption).adaptiveSecondary()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
        }
        .frame(width: 960, height: 640)
        .onAppear { if selection == nil { selection = initialSelection ?? notices?.entries.first?.id } }
        .alert("Open This Link?", isPresented: Binding(get: { pendingURL != nil }, set: { if !$0 { pendingURL = nil } }),
               presenting: pendingURL) { url in
            Button("Cancel", role: .cancel) { pendingURL = nil }
            Button("Open in Browser") {
                if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                pendingURL = nil
            }
        } message: { url in
            Text("This opens in your default browser:\n\(url)")
        }
    }

    // MARK: - Sidebar

    private func sidebar(_ notices: ThirdPartyNotices) -> some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            List(selection: $selection) {
                ForEach(ThirdPartyNotices.groupOrder, id: \.self) { group in
                    let entries = filtered(notices).filter { $0.group == group }
                    if !entries.isEmpty {
                        Section(group) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name).font(.callout).lineLimit(1)
                                    Text(entry.license).font(.caption).adaptiveSecondary().lineLimit(1)
                                }
                                .padding(.vertical, 2)
                                .tag(entry.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filtered(notices).isEmpty {
                    Text("No matches").font(.callout).adaptiveSecondary()
                }
            }
        }
    }

    private func filtered(_ notices: ThirdPartyNotices) -> [ThirdPartyNotices.Entry] {
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return notices.entries }
        return notices.entries.filter { entry in
            let haystack = [entry.name, entry.by, entry.license, entry.purpose] + entry.documents.map(\.title)
            return words.allSatisfy { word in haystack.contains { $0.localizedCaseInsensitiveContains(word) } }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ notices: ThirdPartyNotices) -> some View {
        if let entry = notices.entries.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(entry.name).font(.title2.weight(.semibold))
                        Text(entry.version.map { "\(entry.by) \u{00B7} Version \($0)" } ?? entry.by)
                            .font(.callout).adaptiveSecondary()
                    }
                    Text(entry.purpose).font(.body).fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: Spacing.lg, verticalSpacing: Spacing.xs) {
                        GridRow {
                            Text("License").adaptiveSecondary()
                            Text(entry.license).textSelection(.enabled)
                        }
                        GridRow {
                            Text(entry.documents.isEmpty ? "Model" : "Source").adaptiveSecondary()
                            linkButton(entry.url)
                        }
                        if let licenseURL = entry.licenseURL, licenseURL != entry.url, entry.documents.isEmpty {
                            GridRow {
                                Text("License text").adaptiveSecondary()
                                linkButton(licenseURL)
                            }
                        }
                    }
                    .font(.callout)
                    if let note = entry.note {
                        Text(note).font(.callout).adaptiveSecondary()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(entry.documents.filter { $0.title == entry.name }, id: \.self) { document in
                        LicenseText(document: document, text: notices.text(for: document), isOwn: true)
                    }
                    let included = entry.documents.filter { $0.title != entry.name }
                    if !included.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Included in \(entry.name)").font(.title3.weight(.semibold))
                            Text("Code from these projects is compiled into \(entry.name), under their own licenses.")
                                .font(.callout).adaptiveSecondary()
                        }
                        .padding(.top, Spacing.sm)
                        ForEach(included, id: \.self) { document in
                            LicenseText(document: document, text: notices.text(for: document), isOwn: false)
                        }
                    }
                }
                .padding(Spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(entry.id)
        } else {
            Text("Select an item").font(.callout).adaptiveSecondary()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func linkButton(_ url: String) -> some View {
        Button { pendingURL = url } label: {
            HStack(spacing: Spacing.xxs) {
                Text(url.replacingOccurrences(of: "https://", with: "")).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.up.right").font(.caption2)
            }
        }
        .buttonStyle(.link)
        .help(url)
    }
}

/// One license or notice file, shown as the project wrote it.
private struct LicenseText: View {
    let document: ThirdPartyNotices.Document
    let text: String
    let isOwn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(isOwn ? kind : document.title).font(.headline)
                if !isOwn {
                    Text("\(document.license) \u{00B7} \(fileName)").font(.caption).adaptiveSecondary()
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this text")
                .accessibilityLabel("Copy \(fileName)")
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .adaptiveSecondary()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
    }

    private var fileName: String { (document.file as NSString).lastPathComponent }

    private var kind: String { fileName.uppercased().hasPrefix("NOTICE") ? "Notice" : "License" }
}
