// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import SideWave

/// Renders the website's app images with staged demo content, at 2x, in both appearances.
/// Nothing is shown on screen and no personal data is involved. Off unless an output folder is set:
///
///   TEST_RUNNER_SIDEWAVE_SITE_SCREENSHOTS=/path/to/folder xcodebuild ... test \
///     -only-testing:SideWaveTests/SiteScreenshotTests
@MainActor
final class SiteScreenshotTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["SIDEWAVE_SITE_SCREENSHOTS"], !path.isEmpty else {
            throw XCTSkip("Set SIDEWAVE_SITE_SCREENSHOTS to an output folder to render the site images")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func testRenderSiteScreenshots() async throws {
        let defaults = UserDefaults.standard
        let keys = ["showAdvancedControls", "dictationCleanupTemplate", "dictationCleanupEnabled", "dictationCleanupBackend",
                    "skipRefine", "useDualEngineSmartPTT", "useMultiStageRendering", "lastSelectedSettingsTab", "appearance",
                    "overlaySize", "overlayExpanded", "reduceAppMotion", "dictationOutputLanguage", "liquidGlassMode",
                    "dictationOpenSection"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "showAdvancedControls")
        defaults.set("standard", forKey: "dictationCleanupTemplate")
        defaults.set(true, forKey: "dictationCleanupEnabled")
        defaults.set(DictationFormatterService.Backend.appleIntelligence.rawValue, forKey: "dictationCleanupBackend")
        defaults.set(false, forKey: "skipRefine")
        defaults.set(true, forKey: "useDualEngineSmartPTT")
        defaults.set(true, forKey: "useMultiStageRendering")
        defaults.set("settingsGeneral", forKey: "lastSelectedSettingsTab")
        defaults.set("system", forKey: "appearance")
        defaults.set(OverlaySize.standard.rawValue, forKey: "overlaySize")
        defaults.set(false, forKey: "overlayExpanded")
        defaults.set(false, forKey: "reduceAppMotion")
        // Liquid Glass is drawn by the window server, so offscreen stills use the app's solid panel.
        defaults.set(false, forKey: "liquidGlassMode")
        defaults.set("Refine", forKey: "dictationOpenSection")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidewave_site_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let historyURL = folder.appendingPathComponent("history.json")
        try JSONEncoder().encode(DemoContent.history()).write(to: historyURL)
        let history = HistoryStore(storageURL: historyURL)
        let vocabulary = VocabularyStore(storageURL: folder.appendingPathComponent("vocabulary.json"))
        vocabulary.packs = DemoContent.glossaries()

        let state = AppState()
        state.transcriptionService.modelState = .ready
        state.dictationCleanupTemplate = "standard"
        state.dictationCleanupEnabled = true
        state.dictationFormatter.state = .ready
        if let builtIn = state.audioDeviceManager.availableDevices.first(where: { $0.name.contains("MacBook") }) {
            state.audioDeviceManager.selectedDeviceUID = builtIn.uid
        }
        // Home shows the most recent shared entry, so stage one there and take it out afterward.
        let recent = DemoContent.history()[0]
        HistoryStore.shared.addEntry(text: recent.text, appName: recent.appName, rawText: recent.rawText,
                                     eouText: recent.eouText, refineBackend: recent.refineBackend)
        let stagedID = HistoryStore.shared.entries.first?.id
        defer { if let stagedID { HistoryStore.shared.deleteEntry(id: stagedID) } }

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            // AppState starts preparing models on its own, so pin the ready state for each render.
            state.transcriptionService.modelState = .ready
            state.dictationFormatter.state = .ready
            try await render(DictationHomeView(appState: state).environment(state), scheme: scheme,
                             name: "home-\(suffix)", size: CGSize(width: 675, height: 640))
            try await render(DictationView(appState: state).environment(state), scheme: scheme,
                             name: "dictation-\(suffix)", size: CGSize(width: 675, height: 640))
            try await render(VocabularyView(store: vocabulary).environment(state), scheme: scheme,
                             name: "vocabulary-\(suffix)", size: CGSize(width: 675, height: 640))
            try await render(HistoryView(historyStore: history, shortcutDisplay: "Right Option").environment(state),
                             scheme: scheme, name: "history-\(suffix)", size: CGSize(width: 675, height: 640))
            try await render(AppSettingsView().environment(state), scheme: scheme,
                             name: "settings-\(suffix)", size: CGSize(width: 860, height: 620))
        }

        // The document window with an email formatted from dictation.
        state.dictationCleanupTemplate = "emailReady"
        state.specialtyEditedText = DemoContent.email
        for scheme in [ColorScheme.dark, .light] {
            try await render(SpecialtyPreviewView().environment(state), scheme: scheme,
                             name: "document-\(scheme == .dark ? "dark" : "light")", size: CGSize(width: 760, height: 640),
                             settle: 0.6)
        }
        state.specialtyEditedText = ""
        state.dictationCleanupTemplate = "standard"

        // The live preview through one dictation, staged in the same order as a live session:
        // the streaming draft, Parakeet confirming a span, Refine returning it, the draft growing.
        let staged = state.transcriptionService.stagedTranscript
        func confirmAndRefine(draft: String, confirmed: String, refined: String) {
            staged.ingestEouPartial(draft)
            let span = staged.ingestTdtCommitted(confirmed)
            staged.refineSpan(spanID: span, refinedText: refined)
        }
        let first = "Thanks, that works. Can you send the moisture readings for plots 4 through 9 before Friday's sync?"
        let previews: [(name: String, settle: TimeInterval, stage: () -> Void)] = [
            ("preview-listening", 0.5, { staged.reset() }),
            ("preview-draft", 2.0, {
                staged.reset()
                confirmAndRefine(draft: "thanks that works can you send the moisture readings for plots four through nine before fridays sync",
                                 confirmed: "Thanks, that works. Can you send the moisture readings for plots four through nine before Friday's sync?",
                                 refined: first)
                staged.ingestEouPartial("thanks that works can you send the moisture readings for plots four through nine before fridays sync id like to uh compare them")
            }),
            ("preview-refining", 0.35, {
                staged.reset()
                confirmAndRefine(draft: "thanks that works can you send the moisture readings for plots four through nine before fridays sync",
                                 confirmed: "Thanks, that works. Can you send the moisture readings for plots four through nine before Friday's sync?",
                                 refined: first)
            }),
            ("preview-refined", 2.5, {
                staged.reset()
                confirmAndRefine(draft: "thanks that works can you send the moisture readings for plots four through nine before fridays sync",
                                 confirmed: "Thanks, that works. Can you send the moisture readings for plots four through nine before Friday's sync?",
                                 refined: first)
                confirmAndRefine(draft: "thanks that works can you send the moisture readings for plots four through nine before fridays sync id like to uh compare them with last weeks numbers",
                                 confirmed: "I'd like to, uh, compare them with last week's numbers.",
                                 refined: "I'd like to compare them with last week's numbers.")
            }),
        ]
        for preview in previews {
            for scheme in [ColorScheme.dark, .light] {
                preview.stage()
                try await render(DictationOverlayContent(appState: state), scheme: scheme,
                                 name: "\(preview.name)-\(scheme == .dark ? "dark" : "light")",
                                 size: CGSize(width: 540, height: 210), background: .clear, settle: preview.settle)
            }
        }
        staged.reset()
    }

    // MARK: - Rendering

    private func render<V: View>(_ view: V, scheme: ColorScheme, name: String, size: CGSize,
                                 background: Color? = nil, settle: TimeInterval = 0.25) async throws {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        let previous = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previous }

        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(background ?? Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .key))
        host.frame = CGRect(origin: .zero, size: size)
        // A window that is never shown still gets a 2x backing store when its frame sits on a
        // Retina display.
        let retina = NSScreen.screens.first { $0.backingScaleFactor >= 2 }
        let origin = retina.map { CGPoint(x: $0.frame.minX + 20, y: $0.frame.minY + 20) } ?? .zero
        let window = RenderWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }

        // Web views draw outside the layer tree, so take their snapshots and paint them over.
        var webSnapshots: [(NSRect, NSImage)] = []
        for webView in descendants(of: host).compactMap({ $0 as? WKWebView }) where !webView.isHidden && !webView.bounds.isEmpty {
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while ContinuousClock.now < deadline {
                let ready = try? await webView.callAsyncJavaScript(
                    "return (document.querySelector('main')?.innerText ?? '').length > 0 && document.documentElement.dataset.appearance === appearance;",
                    arguments: ["appearance": scheme == .dark ? "dark" : "light"], in: nil, contentWorld: .defaultClient) as? Bool
                if ready == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = try await webView.takeSnapshot(configuration: nil)
            var frame = host.convert(webView.bounds, from: webView)
            if host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
            webSnapshots.append((frame, image))
        }
        if !webSnapshots.isEmpty {
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for (frame, image) in webSnapshots { image.draw(in: frame) }
            NSGraphicsContext.restoreGraphicsState()
        }

        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent(name + ".png"))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}

/// Controls draw their active colors only in the key window, which a hidden window never is.
private final class RenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Fictional people, apps, and work, written to show ordinary use. Nothing here comes from a real
/// person's history.
enum DemoContent {
    static let email = """
    Subject: Greenhouse closed Thursday morning

    Hi Dana,

    The greenhouse will be closed Thursday morning for the irrigation repair. Please plan to collect your samples on Wednesday afternoon instead.

    Let me know if that timing doesn't work for anyone.

    Thanks,
    Jordan
    """

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
