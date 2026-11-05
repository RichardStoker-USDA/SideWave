// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Each Refine model's download size, the memory it holds while refining, and whether it fits this
/// Mac, with the model suggested for it. Memory is read when the view appears and when the model
/// or its state changes.
struct RefineModelFitView: View {
    @Bindable var appState: AppState
    @State private var memory: RefineModelFit.Memory?
    @State private var appleIntelligence: DictationFormatterService.AFMAvailability = .available

    private typealias Backend = DictationFormatterService.Backend

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let memory {
                let suggestion = suggestion(for: memory)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.lg, verticalSpacing: Spacing.xs) {
                    GridRow {
                        Text("Model")
                        Text("Download").gridColumnAlignment(.trailing)
                        Text("While refining").gridColumnAlignment(.trailing)
                        Text("On this Mac")
                    }
                    .font(.caption)
                    .adaptiveSecondary()
                    .accessibilityHidden(true)
                    ForEach(Backend.availableBackends) { backend in
                        row(backend, memory: memory, suggested: backend == suggestion)
                    }
                }
                Text(summary(memory: memory))
                    .settingsCaption()
                    .fixedSize(horizontal: false, vertical: true)
                if let selected = Backend(rawValue: appState.dictationCleanupBackend),
                   let note = RefineModelFit.note(for: selected, memory: memory, suggestion: suggestion) {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: refreshKey) {
            let own = appState.dictationFormatter.loadedModelMemoryBytes
            memory = RefineModelFit.currentMemory(ownModelBytes: own)
            appleIntelligence = DictationFormatterService.currentAFMAvailability()
            Task.detached(priority: .utility) { RefineModelFit.recordSample(ownModelBytes: own) }
        }
    }

    private var refreshKey: String {
        "\(appState.dictationCleanupBackend) \(appState.dictationFormatter.state)"
    }

    private func suggestion(for memory: RefineModelFit.Memory) -> Backend {
        RefineModelFit.suggested(memory: memory, chip: HardwareDetector.chipFamily(),
                                 appleIntelligenceAvailable: appleIntelligence == .available)
    }

    @ViewBuilder
    private func row(_ backend: Backend, memory: RefineModelFit.Memory, suggested: Bool) -> some View {
        let verdict = RefineModelFit.verdict(for: backend, memory: memory)
        let status = statusText(verdict)
        GridRow {
            Text(backend.displayName)
                .fontWeight(suggested ? .medium : .regular)
            Text(backend.downloadBytes.map(RefineModelFit.gigabytes) ?? "None")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
            Text(backend.workingBytes.map(RefineModelFit.memoryText) ?? "In macOS")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
            HStack(spacing: Spacing.xxs) {
                Image(systemName: statusSymbol(verdict))
                    .adaptiveSecondary()
                    .accessibilityHidden(true)
                Text(suggested ? "\(status), suggested" : status)
                    .fontWeight(suggested ? .medium : .regular)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(backend, status: status, suggested: suggested))
    }

    private func statusText(_ verdict: RefineModelFit.Verdict) -> String {
        switch verdict {
        case .comfortable: return "Fits"
        case .tight: return "Tight"
        case .tooLarge: return "Too large"
        case .system:
            switch appleIntelligence {
            case .available: return "Available"
            case .unavailable(_, let kind):
                return kind == .appleIntelligenceNotEnabled ? "Turned off" : "Unavailable"
            }
        }
    }

    private func statusSymbol(_ verdict: RefineModelFit.Verdict) -> String {
        switch verdict {
        case .comfortable: return "checkmark.circle"
        case .tight: return "exclamationmark.circle"
        case .tooLarge: return "xmark.circle"
        case .system: return appleIntelligence == .available ? "checkmark.circle" : "minus.circle"
        }
    }

    private func accessibilityText(_ backend: Backend, status: String, suggested: Bool) -> String {
        var parts = [backend.displayName]
        if let download = backend.downloadBytes {
            parts.append("\(RefineModelFit.gigabytes(download)) download")
        } else {
            parts.append("no download")
        }
        if let working = backend.workingBytes {
            parts.append("uses about \(RefineModelFit.memoryText(working)) while refining")
        } else {
            parts.append("runs in macOS")
        }
        parts.append(status)
        if suggested { parts.append("suggested for this Mac") }
        return parts.joined(separator: ", ")
    }

    private func summary(memory: RefineModelFit.Memory) -> String {
        let total = RefineModelFit.memoryText(memory.total)
        let now = RefineModelFit.memoryText(memory.availableNow)
        let usual = memory.typicallyAvailable.map {
            ", and usually \(RefineModelFit.memoryText(min($0, memory.availableNow))) or more while you dictate"
        } ?? ". SideWave learns how much is usually free as you dictate"
        return "This Mac has \(total) of memory, \(now) free now\(usual). E2B refines fastest, E4B catches more nuance, and 12B suits long documents but is slower."
    }
}
