// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import CryptoKit
import Foundation

struct GlossaryCatalog: Codable, Sendable {
    let format: String
    let version: Int
    let glossaries: [Entry]

    struct Entry: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let description: String
        let version: String
        let path: String
        let sha256: String
        let bytes: Int
        let termCount: Int
        let tags: [String]
        var releaseNotes: String? = nil
    }

    static let indexURL = URL(string: "https://raw.githubusercontent.com/RichardStoker-USDA/SideWave/HEAD/glossaries/catalog.json")!

    enum CatalogError: LocalizedError {
        case unavailable, invalid, tooLarge, integrity
        var errorDescription: String? {
            switch self {
            case .unavailable: "The catalog is not available yet. You can create a glossary or import a file."
            case .invalid: "This catalog uses an unsupported format. No glossaries were changed."
            case .tooLarge: "This glossary exceeds the import size limit."
            case .integrity: "The downloaded glossary did not match its catalog entry. Nothing was imported."
            }
        }
    }

    static func decode(_ data: Data) throws -> GlossaryCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.format == "sidewave.glossary.catalog", catalog.version == 1,
              catalog.glossaries.count <= 500,
              Set(catalog.glossaries.map(\.id)).count == catalog.glossaries.count else { throw CatalogError.invalid }
        for entry in catalog.glossaries { _ = try downloadURL(for: entry) }
        return catalog
    }

    static func downloadURL(for entry: Entry) throws -> URL {
        guard entry.id.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) != nil,
              !entry.name.isEmpty, entry.name.count <= 100, !entry.version.isEmpty, entry.version.count <= 80,
              entry.description.count <= 2000, (entry.releaseNotes?.count ?? 0) <= 8000,
              entry.bytes > 0, entry.bytes <= VocabularyStore.maxImportBytes,
              entry.termCount >= 0, entry.termCount <= VocabularyStore.maxTermsPerImportedPack,
              entry.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
              entry.path.hasSuffix(".json"), !entry.path.hasPrefix("/"),
              !entry.path.contains(".."), !entry.path.contains(":"), !entry.path.contains("%"),
              !entry.path.contains("?"), !entry.path.contains("#") else { throw CatalogError.invalid }
        return indexURL.deletingLastPathComponent().appendingPathComponent(entry.path)
    }

    static func verify(_ data: Data, entry: Entry) throws {
        _ = try downloadURL(for: entry)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == entry.bytes, digest == entry.sha256.lowercased() else { throw CatalogError.integrity }
        guard let file = try? JSONDecoder().decode(BundleFile.self, from: data),
              file.format == VocabularyStore.GlossaryFile.formatTag,
              file.version == VocabularyStore.GlossaryFile.currentVersion,
              file.glossaries.count == 1, file.glossaries[0].terms.count == entry.termCount else { throw CatalogError.invalid }
    }

    /// Downloads require valid fields; personal file imports may salvage older formats.
    private struct BundleFile: Decodable {
        let format: String
        let version: Int
        let glossaries: [Glossary]

        struct Glossary: Decodable {
            let name: String
            let description: String?
            let contextBlurb: String?
            let terms: [Term]
        }

        struct Term: Decodable {
            let canonical: String
            let aliases: [String]?
            let definition: String?
            let usageNote: String?
            let pronunciation: String?
            let category: String?
            let priority: Int?
            let scope: Int?
        }
    }

    static func fetchIndex() async throws -> GlossaryCatalog {
        try decode(await fetch(indexURL, limit: 1_048_576, label: "Glossary catalog"))
    }

    static func fetchGlossary(_ entry: Entry) async throws -> Data {
        let data = try await fetch(downloadURL(for: entry), limit: VocabularyStore.maxImportBytes, label: "Optional glossary")
        try verify(data, entry: entry)
        return data
    }

    private static func fetch(_ url: URL, limit: Int, label: String) async throws -> Data {
        await MainActor.run {
            NetworkActivityLog.shared.record(.init(kind: .glossaryDownload, direction: .outgoing,
                host: url.host ?? "", path: url.path, detail: "Checking \(label.lowercased())"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.protocolClasses = configuration.protocolClasses?.filter { $0 != TransparencyURLProtocol.self }
        let session = URLSession(configuration: configuration, delegate: CatalogDownloadPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var data = Data()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw CatalogError.unavailable }
            guard response.expectedContentLength <= limit else { throw CatalogError.tooLarge }
            data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < limit else { throw CatalogError.tooLarge }
                data.append(byte)
            }
        } catch {
            await logTransfer(url, bytes: data.count, label: "\(label) interrupted or unavailable")
            throw error
        }
        await logTransfer(url, bytes: data.count, label: label)
        return data
    }

    private static func logTransfer(_ url: URL, bytes: Int, label: String) async {
        await MainActor.run {
            NetworkActivityLog.shared.recordDownload(kind: .glossaryDownload, host: url.host ?? "",
                path: url.path, bytes: Int64(bytes), detail: label)
        }
    }
}

/// Catalog entries cannot redirect requests or credentials to another service.
private final class CatalogDownloadPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
