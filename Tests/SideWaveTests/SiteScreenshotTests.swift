// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import XCTest
@testable import SideWave

/// Writes the demo history and glossaries shown in the website's screenshots, in the app's own
/// file formats, so the real app can be captured with a staged profile instead of anyone's data.
/// Off unless an output folder is set:
///
///   TEST_RUNNER_SIDEWAVE_DEMO_PROFILE=/path/to/folder xcodebuild ... test \
///     -only-testing:SideWaveTests/SiteScreenshotTests/testWriteDemoProfile
@MainActor
final class SiteScreenshotTests: XCTestCase {
    private func folder(from variable: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("Set \(variable) to an output folder")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWriteDemoProfile() throws {
        let folder = try folder(from: "SIDEWAVE_DEMO_PROFILE")
        try JSONEncoder().encode(DemoContent.history()).write(to: folder.appendingPathComponent("history.json"))
        let vocabulary = VocabularyStore(storageURL: folder.appendingPathComponent("vocabulary.json"))
        vocabulary.packs = DemoContent.glossaries()
        XCTAssertTrue(vocabulary.saveUserPacks())
    }
}

/// Fictional people, apps, and work, written to show ordinary use. Nothing here comes from a real
/// person's history.
enum DemoContent {
    static func history(now: Date = Date()) -> [TranscriptionEntry] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            TranscriptionEntry(
                timestamp: ago(2),
                text: "Thanks, that works. Can you send the moisture readings for plots 4 through 9 before Friday's sync? I'd like to compare them with last week's numbers.",
                appName: "Slack",
                rawText: "Thanks, that works. Can you send the moisture readings for plots four through nine before Friday's sync? I'd like to, uh, compare them with last week's numbers.",
                eouText: "thanks that works can you send the moisture readings for plots four through nine before fridays sync id like to uh compare them with last weeks numbers",
                refineBackend: DictationFormatterService.Backend.appleIntelligence.rawValue,
                aiSummary: "Moisture readings before Friday"),
            TranscriptionEntry(
                timestamp: ago(18),
                text: "Hi Dana, the greenhouse will be closed Thursday morning for the irrigation repair. Please plan to collect your samples on Wednesday afternoon instead.",
                appName: "Mail",
                rawText: "Hi Dana, um, the greenhouse will be closed Thursday morning for the irrigation repair, so please plan to collect your samples on Wednesday afternoon instead.",
                eouText: "hi dana um the greenhouse will be closed thursday morning for the irrigation repair so please plan to collect your samples on wednesday afternoon instead",
                refineBackend: DictationFormatterService.Backend.gemma4E4B.rawValue,
                aiSummary: "Greenhouse closed Thursday"),
            TranscriptionEntry(
                timestamp: ago(41),
                text: "Refactor the CSV loader so it streams rows instead of reading the whole file into memory. Keep the public API the same, and add a test that loads a 2 GB fixture.",
                appName: "Terminal",
                rawText: "Refactor the CSV loader so it streams rows instead of reading the whole file into memory. Keep the public API the same and, uh, add a test that loads a two gigabyte fixture.",
                eouText: "refactor the csv loader so it streams rows instead of reading the whole file into memory keep the public api the same and uh add a test that loads a two gigabyte fixture",
                refineBackend: DictationFormatterService.Backend.appleIntelligence.rawValue,
                aiSummary: "Streaming CSV loader"),
            TranscriptionEntry(
                timestamp: ago(66),
                text: "Field trial: soil moisture held steady across the north beds. The drip line on row 12 is leaking again, so flag it for Monday.",
                appName: "Notes",
                rawText: "Field trial, soil moisture held steady across the north beds. The drip line on row twelve is leaking again so flag it for Monday.",
                eouText: "field trial soil moisture held steady across the north beds the drip line on row twelve is leaking again so flag it for monday",
                refineBackend: DictationFormatterService.Backend.appleIntelligence.rawValue,
                aiSummary: "North beds field notes"),
            TranscriptionEntry(
                timestamp: ago(130),
                text: "Running about ten minutes late. Start without me and I'll catch up.",
                appName: "Messages",
                aiSummary: "Running late"),
        ]
    }

    static func glossaries() -> [VocabPack] {
        [
            VocabPack(name: "Field research", description: "Lab and field words for the trial",
                      contextBlurb: "Soil and plant research at a field station: irrigation trials, qPCR assays, and greenhouse schedules.",
                      isEnabled: true, terms: [
                VocabTerm(canonical: "qPCR", aliases: ["cue PCR", "Q P C R"], definition: "Quantitative PCR",
                          category: "Lab", scope: .both),
                VocabTerm(canonical: "evapotranspiration", aliases: ["evapo transpiration"],
                          definition: "Water lost from soil and plants", category: "Agronomy", scope: .both),
                VocabTerm(canonical: "Brassica rapa", aliases: ["brassica rapper"], category: "Species", scope: .both),
                VocabTerm(canonical: "Arabidopsis", aliases: ["arabid opsis"], category: "Species", scope: .both),
                VocabTerm(canonical: "Dana Whitfield", aliases: ["Dana Whitfeld"], definition: "Greenhouse manager",
                          category: "People", scope: .both),
            ]),
            VocabPack(name: "Code review", description: "Project and tool names", isEnabled: false, terms: [
                VocabTerm(canonical: "SwiftUI", aliases: ["swift UI"], category: "Tools", scope: .both),
                VocabTerm(canonical: "MLX", aliases: ["M L X"], category: "Tools", scope: .both),
            ]),
        ]
    }
}
