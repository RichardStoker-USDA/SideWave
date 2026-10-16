// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest

@testable import SideWaveKit

/// The kit copy of the ordinal revert stays contract-identical to the
/// original app's (same rows pinned in both suites).
final class ProseOrdinalReverterKitTests: XCTestCase {

    func testDiscourseRevertsPositionalKeeps() {
        XCTAssertEqual(
            ProseOrdinalReverter.revert("the 1st, 2nd, and 3rd in this context"),
            "the first, second, and third in this context")
        XCTAssertEqual(
            ProseOrdinalReverter.revert("she took 2nd place on the 3rd of July"),
            "she took 2nd place on the 3rd of July")
        XCTAssertEqual(
            ProseOrdinalReverter.revert("the 21st century has 5,476,234.7 problems"),
            "the 21st century has 5,476,234.7 problems")
    }
}
