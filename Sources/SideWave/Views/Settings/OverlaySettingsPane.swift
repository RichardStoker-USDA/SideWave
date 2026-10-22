// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

enum RefineAnimationStyle: String, CaseIterable, Identifiable {
    case crystalline = "Crystalline"
    case magical = "Magical"
    case cascade = "Cascade"
    case glow = "Glow"
    case sweep = "Sweep"
    case pulse = "Pulse"
    case instant = "Instant"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .crystalline: "A light sweep marks words as they settle, without moving them."
        case .magical: "Words settle in order with a small rise and a change in weight."
        case .cascade: "Words arrive in order from just above the line."
        case .glow: "A brief highlight marks newly refined words."
        case .sweep: "A left-to-right fade from gray to the normal text color."
        case .pulse: "A soft brightness wave rolls across the words."
        case .instant: "Text changes from draft to final without a transition."
        }
    }
}

struct OverlaySettingsPane: View {
    @Bindable var appState: AppState
    @AppStorage("overlaySize") private var overlaySizeRaw = OverlaySize.standard.rawValue
    @AppStorage("customOverlayWidth") private var customOverlayWidth: Double = 500
    @AppStorage("textDisplayMode") private var textDisplayMode = "standard"
    @AppStorage("visualizerColorMode") private var visualizerColorMode = "rainbow"
    @AppStorage("refineAnimationStyle") private var refineAnimationStyle = RefineAnimationStyle.sweep.rawValue
    @AppStorage("liquidGlassMode") private var liquidGlassMode = true
    @AppStorage("audioSensitivity") private var audioSensitivity = 0.7
    @State private var previewWorkItem: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }

    var body: some View {
        SettingsCard("Size and position") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("Size").font(.callout)
                    Spacer()
                    Button("Show Preview") { showPreview() }
                        .actionButton()
                        .controlSize(.small)
                }
                GlassSegmentedPicker(selection: $overlaySizeRaw,
                                     segments: OverlaySize.allCases.map { .init($0.rawValue, tag: $0.rawValue) },
                                     expands: true,
                                     accessibilityLabel: "Preview size")
                    .onChange(of: overlaySizeRaw) { _, newValue in
                        if let size = OverlaySize(rawValue: newValue) { customOverlayWidth = size.width }
                        showPreview()
                    }
            }
            SettingsDivider()
            SettingsRow(label: "Width") {
                HStack(spacing: Spacing.sm) {
                    Slider(value: $customOverlayWidth, in: 300...700, step: 10) { _ in showPreview() }
                    .frame(width: 200)
                    .accessibilityLabel("Preview width")
                    .accessibilityValue("\(Int(customOverlayWidth)) points")
                    Text("\(Int(customOverlayWidth)) pt")
                        .font(.callout.monospacedDigit()).adaptiveSecondary()
                        .frame(width: 52, alignment: .trailing)
                }
            }
            SettingsDivider()
            HStack(alignment: .firstTextBaseline) {
                Text("Drag the preview to move it. Right-click it to lock its position.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.md)
                Button("Reset Position") {
                    DictationOverlayController.shared.resetPosition()
                    showPreview()
                }
                .actionButton()
                .controlSize(.small)
                .help("Move the preview back to the bottom center of the main display")
            }
        }

        SettingsCard("Appearance") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Text style").font(.callout)
                GlassSegmentedPicker(selection: $textDisplayMode,
                                     segments: [.init("Standard", tag: "standard"),
                                                .init("Cinematic", tag: "cinematic", isEnabled: !reduceMotion)],
                                     expands: true,
                                     accessibilityLabel: "Text style")
                Text(reduceMotion ? "Cinematic needs motion. Turn off Reduce Motion to use it."
                     : textDisplayMode == "standard" ? "Plain scrolling text."
                     : "Text scrolls back in perspective, in gold on a dark star field.")
                    .settingsCaption()
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Wave color").font(.callout)
                GlassSegmentedPicker(selection: $visualizerColorMode,
                                     segments: [.init("Spectrum", tag: "rainbow"), .init("Accent Color", tag: "accent")],
                                     expands: true,
                                     accessibilityLabel: "Wave color")
                    .onChange(of: visualizerColorMode) { _, _ in showPreview() }
            }
            SettingsDivider()
            SettingsRow(label: "Refine animation") {
                ChoiceMenu(title: "Refine animation", value: refineAnimationStyle, selection: $refineAnimationStyle) {
                    ForEach(RefineAnimationStyle.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .fixedSize()
            }
            Text((RefineAnimationStyle(rawValue: refineAnimationStyle) ?? .sweep).summary)
                .settingsCaption()
            SettingsDivider()
            SettingsRow(label: "Wave sensitivity") {
                HStack(spacing: Spacing.sm) {
                    Slider(value: $audioSensitivity, in: 0...1)
                        .frame(width: 200)
                        .accessibilityLabel("Wave sensitivity")
                        .accessibilityValue("\(Int(audioSensitivity * 100)) percent")
                    Text("\(Int(audioSensitivity * 100))%")
                        .font(.callout.monospacedDigit()).adaptiveSecondary()
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Text("How strongly the wave reacts to your voice. It doesn't affect recognition.")
                .settingsCaption()
            SettingsDivider()
            SettingsToggleRow("Liquid Glass background",
                              caption: "Uses the macOS glass material behind the preview.",
                              isOn: $liquidGlassMode)
        }
    }

    /// Shows the preview for three seconds, unless dictation keeps it open.
    private func showPreview() {
        previewWorkItem?.cancel()
        DictationOverlayController.shared.show(appState: appState)
        let hide = DispatchWorkItem { [weak appState] in
            guard let appState, !appState.transcriptionService.isRecording else { return }
            DictationOverlayController.shared.hide()
        }
        previewWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: hide)
    }
}
