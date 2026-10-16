// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import CryptoKit
import XCTest
@testable import SideWave

final class GlossaryCatalogTests: XCTestCase {
    func testEmptyCatalogIsValid() throws {
        let data = Data(#"{"format":"sidewave.glossary.catalog","version":1,"glossaries":[]}"#.utf8)
        XCTAssertTrue(try GlossaryCatalog.decode(data).glossaries.isEmpty)
    }

    func testCatalogCannotRedirectDownloadsOutsideItsDirectory() {
        for path in ["../secret.json", "https://example.com/words.json", "/words.json", "%2e%2e/words.json"] {
            let entry = GlossaryCatalog.Entry(id: "test", name: "Test", description: "", version: "1",
                path: path, sha256: String(repeating: "a", count: 64), bytes: 100, termCount: 1, tags: [])
            XCTAssertThrowsError(try GlossaryCatalog.downloadURL(for: entry))
        }
    }

    func testIntegrityAndTermCountAreCheckedBeforeImport() throws {
        let data = Data(#"{"format":"sidewave.glossary","version":1,"glossaries":[{"name":"Example","terms":[{"canonical":"phenotype"}]}]}"#.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = GlossaryCatalog.Entry(id: "test", name: "Test", description: "", version: "1",
            path: "test.json", sha256: digest, bytes: data.count, termCount: 1, tags: [])
        XCTAssertNoThrow(try GlossaryCatalog.verify(data, entry: entry))
        XCTAssertThrowsError(try GlossaryCatalog.verify(data + Data(" ".utf8), entry: entry))
    }

    func testDownloadedBundlesCannotSilentlyDiscardMalformedFields() {
        let invalid = [
            #"{"glossaries":[{"name":"Example","terms":[]}]}"#,
            #"{"format":"sidewave.glossary","version":1,"glossaries":[{"name":"Example","terms":[{}]}]}"#,
            #"{"format":"sidewave.glossary","version":1,"glossaries":[{"name":"Example","terms":"invalid"}]}"#,
            #"{"format":"sidewave.glossary","version":1,"glossaries":[{"name":"Example","terms":[{"canonical":"sample","aliases":4}]}]}"#
        ]
        for json in invalid {
            let data = Data(json.utf8)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            for termCount in [0, 1] {
                let entry = GlossaryCatalog.Entry(id: "test", name: "Test", description: "", version: "1",
                    path: "test.json", sha256: digest, bytes: data.count, termCount: termCount, tags: [])
                XCTAssertThrowsError(try GlossaryCatalog.verify(data, entry: entry))
            }
        }
    }
}
