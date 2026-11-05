// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

final class RefineHygieneRulesTests: XCTestCase {
    func testCapitalizesSentenceStartsAndWeekdays() {
        XCTAssertEqual(RefineHygieneRules.restoreCapitals("we met on monday. then we left", after: nil),
                       "We met on Monday. Then we left")
        XCTAssertEqual(RefineHygieneRules.restoreCapitals("and next week we test it.", after: "The readings were back in range."),
                       "And next week we test it.")
        XCTAssertEqual(RefineHygieneRules.restoreCapitals("is it ready? yes, on fridays", after: ""),
                       "Is it ready? Yes, on Fridays")
    }

    func testLeavesContinuationsAbbreviationsAndNamesAlone() {
        // The earlier text didn't end a sentence, so this slice continues it.
        XCTAssertEqual(RefineHygieneRules.restoreCapitals("and logged the pressure", after: "We replaced the fittings"),
                       "and logged the pressure")
        XCTAssertEqual(RefineHygieneRules.restoreCapitals("bring tools, e.g. pliers. wait... and then go at 9 a.m. today", after: "Okay,"),
                       "bring tools, e.g. pliers. Wait... and then go at 9 a.m. today")
        XCTAssertEqual(RefineHygieneRules.restoreCapitals("done. gVisor runs. iPhone too. sidewave.dev is up", after: nil),
                       "Done. gVisor runs. iPhone too. sidewave.dev is up")
        XCTAssertEqual(RefineHygieneRules.restoreCapitals("Keep USDA and NIST.\n\nnew paragraph", after: nil),
                       "Keep USDA and NIST.\n\nNew paragraph")
    }
}
