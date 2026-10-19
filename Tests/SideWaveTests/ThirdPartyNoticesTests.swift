import XCTest
@testable import SideWave

/// The bundled notices must cover every resolved package, so adding or updating a package without
/// rerunning scripts/third_party_notices.py fails here.
final class ThirdPartyNoticesTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testAppBundleCarriesTheNotices() throws {
        let notices = try XCTUnwrap(ThirdPartyNotices.load(from: .main), "ThirdPartyNotices.json is missing from the app bundle")
        for entry in notices.entries {
            for document in entry.documents {
                XCTAssertFalse(notices.text(for: document).isEmpty, "\(entry.name): empty \(document.file)")
            }
        }
        XCTAssertTrue(notices.entries.allSatisfy { ThirdPartyNotices.groupOrder.contains($0.group) })
    }

    func testEveryResolvedPackageHasANoticeAtItsVersion() throws {
        struct Resolved: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { let version: String? }
                let identity: String
                let state: State
            }
            let pins: [Pin]
        }
        struct Config: Decodable { let excluded: [String: String] }

        let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: root.appendingPathComponent("Package.resolved")))
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: root.appendingPathComponent("scripts/third_party_notices.json")))
        let notices = try JSONDecoder().decode(
            ThirdPartyNotices.self,
            from: Data(contentsOf: root.appendingPathComponent("Sources/SideWave/Resources/ThirdPartyNotices.json"))
        )
        let code = Dictionary(uniqueKeysWithValues: notices.entries.filter { $0.group == "Code" }.map { ($0.id, $0) })

        for pin in resolved.pins where config.excluded[pin.identity] == nil {
            let entry = try XCTUnwrap(code[pin.identity], "\(pin.identity) has no notice; run scripts/third_party_notices.py")
            XCTAssertEqual(entry.version, pin.state.version, "\(pin.identity) notice is for another version")
            XCTAssertFalse(entry.documents.isEmpty, "\(pin.identity) has no license text")
        }
    }
}
