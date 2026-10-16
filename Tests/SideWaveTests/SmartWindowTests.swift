// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

@MainActor
final class SmartWindowTests: XCTestCase {

    var appState: AppState!

    override func setUp() {
        super.setUp()
        appState = AppState()
    }

    override func tearDown() {
        appState = nil
        super.tearDown()
    }

    func testEmptyInput() {
        let (prior, tail) = appState.splitSmartWindow("")
        XCTAssertNil(prior)
        XCTAssertEqual(tail, "")
        
        let (prior2, tail2) = appState.splitSmartWindow("   \n  ")
        XCTAssertNil(prior2)
        XCTAssertEqual(tail2, "")
    }

    func testShortInputNoBoundaries() {
        let text = "hello world this is a short dictation session"
        let (prior, tail) = appState.splitSmartWindow(text)
        XCTAssertNil(prior)
        XCTAssertEqual(tail, text)
    }

    func testSentenceBoundaryWithLongTail() {
        let text = "This is the first sentence. And this is the second sentence which has more than three words."
        let (prior, tail) = appState.splitSmartWindow(text)
        XCTAssertEqual(prior, "This is the first sentence.")
        XCTAssertEqual(tail, "And this is the second sentence which has more than three words.")
    }

    func testSentenceBoundaryWithShortTailTriggersSecondBoundary() {
        let text = "This is the first sentence. This is the second. Yes."
        let (prior, tail) = appState.splitSmartWindow(text)
        XCTAssertEqual(prior, "This is the first sentence.")
        XCTAssertEqual(tail, "This is the second. Yes.")
    }

    func testSentenceBoundaryWithShortTailNoSecondBoundary() {
        let text = "Hello world. Yes."
        let (prior, tail) = appState.splitSmartWindow(text)
        XCTAssertNil(prior)
        XCTAssertEqual(tail, "Hello world. Yes.")
    }

    func testQuotesAndParenthesesBoundaries() {
        let text = "She said, \"hello world.\" (This is inside parentheses.) We are testing boundary checks."
        let (prior, tail) = appState.splitSmartWindow(text)
        XCTAssertEqual(prior, "She said, \"hello world.\" (This is inside parentheses.)")
        XCTAssertEqual(tail, "We are testing boundary checks.")
    }

    func testFallbackToWordCountForLongText() {
        // Create 35 words without sentence terminators
        let words = Array(repeating: "word", count: 35)
        let text = words.joined(separator: " ")
        
        let (prior, tail) = appState.splitSmartWindow(text)
        XCTAssertNotNil(prior)
        
        let priorWords = prior?.split(separator: " ") ?? []
        let tailWords = tail.split(separator: " ")
        
        XCTAssertEqual(priorWords.count, 5)
        XCTAssertEqual(tailWords.count, 30)
        XCTAssertEqual(tailWords.first, "word")
    }
}
