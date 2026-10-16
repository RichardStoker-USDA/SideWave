// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Tests for `StreamDeltaResolver`, the pure logic behind the cleanup card's
/// streaming refined-text display. It splits each LLM delta into a stable
/// prefix (already on screen) and a volatile tail (animates in). The critical
/// behavior is the GHOST-TEXT GUARD: the LLM stream is normally a strict
/// append, but if a delta is NOT a strict append of what's on screen, slicing
/// at the old length would strand stale glyphs ("ghost text"), so the resolver
/// must replace wholesale. The brief's #1 visual requirement.
final class StreamDeltaResolverTests: XCTestCase {

    func testCleanAppendPromotesPrefixAndSlicesTail() {
        let r = StreamDeltaResolver.resolve(
            stable: "Hello", volatile: " world", lastLen: 11,
            reduceMotion: false, new: "Hello world and more"
        )
        XCTAssertEqual(r.stable, "Hello world")
        XCTAssertEqual(r.volatile, " and more")
        XCTAssertTrue(r.bumpGeneration, "a clean append should animate the new tail")
        // Invariant: stable + volatile reconstructs the full new value exactly.
        XCTAssertEqual(r.stable + r.volatile, "Hello world and more")
    }

    func testNonAppendDivergenceReplacesWholesale() {
        // The new value is LONGER but does NOT start with what's on screen.
        // Without the guard, the old "Hello world" would be stranded as ghost
        // text ahead of the real content. The resolver must replace wholesale.
        let r = StreamDeltaResolver.resolve(
            stable: "Hello world", volatile: "", lastLen: 11,
            reduceMotion: false, new: "A totally different rewrite of the line"
        )
        XCTAssertEqual(r.stable, "A totally different rewrite of the line")
        XCTAssertEqual(r.volatile, "")
        XCTAssertFalse(r.bumpGeneration)
        XCTAssertEqual(r.stable + r.volatile, "A totally different rewrite of the line",
                       "no ghost text: full value, nothing stranded")
    }

    func testShrinkPromotesWholesale() {
        let r = StreamDeltaResolver.resolve(
            stable: "Hello world", volatile: "", lastLen: 11,
            reduceMotion: false, new: "Hi"
        )
        XCTAssertEqual(r.stable, "Hi")
        XCTAssertEqual(r.volatile, "")
        XCTAssertFalse(r.bumpGeneration)
    }

    func testSameLengthCorrectionPromotesWholesale() {
        // Same length, different content (a same-length token correction).
        let r = StreamDeltaResolver.resolve(
            stable: "teh", volatile: "", lastLen: 3,
            reduceMotion: false, new: "the"
        )
        XCTAssertEqual(r.stable, "the")
        XCTAssertEqual(r.volatile, "")
        XCTAssertFalse(r.bumpGeneration)
    }

    func testReduceMotionAlwaysAtomic() {
        // Reduce Motion: no tail animation ever, always one atomic stable value.
        let r = StreamDeltaResolver.resolve(
            stable: "x", volatile: "y", lastLen: 2,
            reduceMotion: true, new: "x y z"
        )
        XCTAssertEqual(r.stable, "x y z")
        XCTAssertEqual(r.volatile, "")
        XCTAssertFalse(r.bumpGeneration)
    }

    func testNoChangeIsStable() {
        // new == stable + volatile and same length: nothing moves, no bump
        // (so the tail doesn't re-animate when Parakeet re-emits an identical
        // accumulator during a pause).
        let r = StreamDeltaResolver.resolve(
            stable: "Hello", volatile: " world", lastLen: 11,
            reduceMotion: false, new: "Hello world"
        )
        XCTAssertEqual(r.stable, "Hello")
        XCTAssertEqual(r.volatile, " world")
        XCTAssertFalse(r.bumpGeneration)
    }
}
