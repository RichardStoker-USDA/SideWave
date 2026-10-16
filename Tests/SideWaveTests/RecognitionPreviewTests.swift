// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
import SwiftUI
@testable import SideWave

@MainActor
final class RecognitionPreviewTests: XCTestCase {
    func testDeliveryTextRemainsLegibleInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: CleanupStreamingText(streamText: "Keep the final words visible.",
                isGenerating: false, colorScheme: scheme, reduceMotion: true)
                .frame(width: 500, height: 60).background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: 500, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var readablePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if scheme == .dark ? brightness > 0.8 : brightness < 0.2 { readablePixels += 1 }
                }
            }
            XCTAssertGreaterThan(readablePixels, 100, "The final transcript must contrast with its background")
        }
    }

    func testNativeTextFadeSettlesWithoutReplayingTheWholeTranscript() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let background = scheme == .dark ? Color.black : Color.white
            func content(confirmed: String, draft: String) -> some View {
                RecognitionPreview(confirmed: confirmed, draft: draft, reduceMotion: false)
                    .frame(width: 500, height: 60).background(background).environment(\.colorScheme, scheme)
            }
            let host = NSHostingView(rootView: content(confirmed: "", draft: "Review the report."))
            host.frame = NSRect(x: 0, y: 0, width: 500, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            func pixels(_ name: String) throws -> Data {
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                if let directory = ProcessInfo.processInfo.environment["SIDEWAVE_RENDER_OUTPUT"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("recognition_motion_\(scheme == .dark ? "dark" : "light")_\(name).png"))
                }
                return png
            }
            try await Task.sleep(for: .milliseconds(50))
            let draft = try pixels("draft")
            host.rootView = content(confirmed: "Review the report.", draft: "")
            try await Task.sleep(for: .milliseconds(100))
            let middle = try pixels("confirming")
            try await Task.sleep(for: .milliseconds(550))
            let settled = try pixels("confirmed")
            XCTAssertNotEqual(draft, middle)
            XCTAssertNotEqual(middle, settled)
            host.rootView = content(confirmed: "Review the report.", draft: "")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(settled, try pixels("unchanged"))
        }
    }

    func testOnlyNewlyConfirmedOrChangedWordsFade() {
        let initial = RecognitionPreviewState().updating(confirmed: "Keep these words unchanged.", at: 1)
        let appended = initial.updating(confirmed: "Keep these words unchanged. Add the ending.", at: 5)
        XCTAssertEqual(appended.words.prefix(4).map(\.confirmedAt), initial.words.map(\.confirmedAt))
        XCTAssertTrue(appended.words.suffix(3).allSatisfy { $0.confirmedAt >= 5 })
        let edited = appended.updating(confirmed: "Keep those words unchanged. Add the ending.", at: 10)
        XCTAssertEqual(edited.words[0], appended.words[0])
        XCTAssertEqual(edited.words[2], appended.words[2])
        XCTAssertEqual(edited.words[1].confirmedAt, 10)
        XCTAssertEqual(edited.words.map(\.text).joined(separator: " "), "Keep those words unchanged. Add the ending.")
    }

    func testDeletionsAndRepeatedWordsCannotKeepStaleText() {
        let initial = RecognitionPreviewState().updating(confirmed: "The the first extra words and the last words.", at: 1)
        let next = initial.updating(confirmed: "The first words and the last words.", at: 2)
        XCTAssertEqual(next.words.map(\.text).joined(separator: " "), "The first words and the last words.")
        XCTAssertTrue(next.words.allSatisfy { $0.confirmedAt < 2 })
    }

    func testLongCommitSettlesPromptlyAndStopsSchedulingFrames() {
        let text = (0..<500).map { "word\($0)" }.joined(separator: " ")
        let state = RecognitionPreviewState().updating(confirmed: text, at: 1)
        XCTAssertLessThanOrEqual(state.settledAt, 1.45)
        XCTAssertLessThan(state.frameDates(after: 1).count, 16)
        XCTAssertTrue(state.frameDates(after: 2).isEmpty)
        XCTAssertEqual(state.progress(for: state.words[0], at: 1, reduceMotion: false), 0)
        XCTAssertGreaterThan(state.progress(for: state.words[0], at: 1.1, reduceMotion: false), 0)
        XCTAssertTrue(state.words.allSatisfy { state.progress(for: $0, at: 2, reduceMotion: false) == 1 })
    }

    func testReducedMotionHasNoDelayedWords() {
        let state = RecognitionPreviewState().updating(confirmed: "Show the complete text immediately.", at: 5)
        XCTAssertTrue(state.words.allSatisfy { state.progress(for: $0, at: 5, reduceMotion: true) == 1 })
    }

    func testPreviewWindowIsBoundedWithoutChangingItsTail() {
        let words = (0..<5_000).map { "word\($0)" }
        let state = RecognitionPreviewState().updating(confirmed: words.joined(separator: " "), at: 1)
        XCTAssertEqual(state.words.count, RecognitionPreviewState.wordLimit)
        XCTAssertEqual(state.words.last?.text, words.last)
        XCTAssertTrue(state.updating(confirmed: "", at: 2).words.isEmpty)
    }

    func testUnchangedCommitDoesNotRestartMotion() {
        let state = RecognitionPreviewState().updating(confirmed: "日本語 한국어 العربية café", at: 1)
        XCTAssertEqual(state, state.updating(confirmed: "日本語 한국어 العربية café", at: 5))
        XCTAssertTrue(state.frameDates(after: 5).isEmpty)
    }

    func testParagraphBoundariesSurviveConfirmationWithoutReanimatingWords() {
        let initial = RecognitionPreviewState().updating(confirmed: "First paragraph.", at: 1)
        let updated = initial.updating(confirmed: "First paragraph.\n\nSecond paragraph.", at: 5)
        XCTAssertEqual(updated.words.map { $0.text + $0.separator }.joined(), "First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(updated.words.prefix(2).map(\.confirmedAt), initial.words.map(\.confirmedAt))
    }
}
