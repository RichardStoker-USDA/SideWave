// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

struct AboutSettingsPane: View {
    @Bindable var appState: AppState
    @State private var pendingURL: String?
    @State private var sheet: Sheet?

    private enum Sheet: String, Identifiable {
        case license, acknowledgments
        var id: String { rawValue }
    }

    var body: some View {
        SettingsCard {
            HStack(spacing: Spacing.lg) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("SideWave").font(.title2.weight(.semibold))
                    Text("Version \(SideWaveApp.appVersion) (\(SideWaveApp.appBuild))")
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("On-device dictation for macOS").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            SettingsDivider()
            VStack(spacing: Spacing.xxs) {
                AboutLinkRow(icon: "globe", label: "Website", url: "https://sidewave.dev", customSymbol: false) { pendingURL = $0 }
                AboutLinkRow(icon: "logo.github.circle.fill", label: "Source code",
                             url: "https://github.com/RichardStoker-USDA/SideWave", customSymbol: true) { pendingURL = $0 }
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) \u{00B7} \(Self.chipName())")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: Spacing.lg) {
                    Button("License") { sheet = .license }.buttonStyle(.link)
                    Button("Acknowledgments") { sheet = .acknowledgments }.buttonStyle(.link)
                }
                .font(.caption)
                Text("Copyright 2026 Richard Stoker. Apache License 2.0.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("Open This Link?", isPresented: Binding(get: { pendingURL != nil }, set: { if !$0 { pendingURL = nil } }),
               presenting: pendingURL) { url in
            Button("Cancel", role: .cancel) { pendingURL = nil }
            Button("Open in Browser") {
                if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                pendingURL = nil
            }
        } message: { url in
            Text("This opens in your default browser:\n\(url)")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .license: LicenseSheet()
            case .acknowledgments: AcknowledgmentsSheet()
            }
        }

        SettingsCard("Updates") {
            if appState.supportsAppUpdates {
                SettingsToggleRow("Check for updates automatically",
                                  caption: "SideWave asks once before checking. Checks read the release feed at sidewave.dev and send nothing about you or your Mac.",
                                  isOn: Binding(get: { appState.updaterController.updater.automaticallyChecksForUpdates },
                                                set: { appState.updaterController.updater.automaticallyChecksForUpdates = $0 }))
                HStack {
                    Button("Check for Updates Now") { appState.updaterController.updater.checkForUpdates() }
                        .actionButton()
                        .disabled(!appState.updaterController.updater.canCheckForUpdates)
                    Spacer()
                }
            } else {
                Text("Development builds update by rebuilding. Signed releases can update from here.")
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Apple silicon reports its chip through hw.chip; brand_string is the Intel path.
    static func chipName() -> String {
        for key in ["machdep.cpu.brand_string", "hw.chip", "hw.model"] {
            var size = 0
            sysctlbyname(key, nil, &size, nil, 0)
            guard size > 0 else { continue }
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname(key, &buffer, &size, nil, 0)
            let value = String(cString: buffer)
            if !value.isEmpty { return value }
        }
        return "Unknown Mac"
    }
}

/// A project link with a hover state. Opening goes through a confirmation
/// that shows the destination first.
private struct AboutLinkRow: View {
    let icon: String
    let label: String
    let url: String
    let customSymbol: Bool
    let onOpen: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        Button { onOpen(url) } label: {
            HStack(spacing: Spacing.sm) {
                (customSymbol ? Image(icon) : Image(systemName: icon))
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                Text(label).font(.callout)
                Spacer()
                Text(url.replacingOccurrences(of: "https://", with: ""))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(isHovered ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel("\(label): \(url)")
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Apache License 2.0").font(.headline)
            Text("Copyright 2026 Richard Stoker").font(.subheadline).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                Text("""
                Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

                http://www.apache.org/licenses/LICENSE-2.0

                Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480, height: 360)
    }
}

private struct AcknowledgmentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let entries: [(name: String, detail: String, license: String)] = [
        ("NVIDIA Parakeet TDT v3 (0.6B)", "Speech recognition model by NVIDIA.", "CC-BY-4.0"),
        ("Parakeet Ultra", "Multilingual post-training by Moondream; Core ML conversion by FluidInference.", "CC-BY-4.0"),
        ("NVIDIA Parakeet Realtime EOU 120M", "Streaming speech model for the live preview by NVIDIA; Core ML conversion by FluidInference.", "the NVIDIA Open Model License"),
        ("Nemotron 3 Diarization", "Eight-speaker model by NVIDIA; Core ML conversion by FluidInference.", "OpenMDW-1.1"),
        ("FluidAudio", "Swift SDK for on-device audio models by FluidInference.", "Apache License 2.0"),
        ("Silero VAD v6", "Voice activity detection.", "MIT"),
        ("CTC 110M", "Encoder used for vocabulary boosting.", "Apache License 2.0"),
        ("Sparkle", "Software updates for macOS apps.", "MIT"),
        ("MLX Swift LM", "Language model inference on Apple silicon.", "MIT"),
        ("swift-huggingface and swift-transformers", "Model downloads and tokenizers for Gemma.", "Apache License 2.0"),
        ("Swift Markdown and cmark-gfm", "Rendering for documents and meeting notes.", "Apache 2.0 with Runtime Library Exception; BSD-2-Clause and MIT"),
        ("Gemma 4 E2B, E4B, and 12B", "Local language models by Google DeepMind.", "Apache License 2.0"),
        ("NeMo Text Processing", "Number, date, and currency formatting, included through FluidAudio.", "Apache License 2.0"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Acknowledgments").font(.headline)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(entries, id: \.name) { entry in
                        VStack(alignment: .leading, spacing: Spacing.xxxs) {
                            Text(entry.name).font(.callout.weight(.medium))
                            Text("\(entry.detail) Licensed under \(entry.license).")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560, height: 560)
    }
}
