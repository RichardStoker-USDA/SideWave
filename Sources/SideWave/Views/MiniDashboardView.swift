// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
import TipKit

/// Compact controls sharing the main dictation session state and waveform.
struct MiniDashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage("skipRefine") private var skipRefine = false
    @AppStorage("visualizerColorMode") private var visualizerColorMode = "rainbow"
    @AppStorage("audioSensitivity") private var audioSensitivity = 0.7

    private var outputSummary: String {
        let template = appState.selectedDictationTemplate
        guard appState.dictationCleanupEnabled && !skipRefine else {
            return template.isSpecialty ? "\(template.workspaceTitle) · No refine" : "As spoken"
        }
        let backend = DictationFormatterService.Backend(rawValue: appState.dictationCleanupBackend)
        let model: String
        switch backend {
        case .appleIntelligence, .appleIntelligenceLegacy: model = "Apple Intelligence"
        case .gemma4E2B: model = "Gemma E2B"
        case .gemma4E4B: model = "Gemma E4B"
        case .gemma4_12B: model = "Gemma 12B"
        case nil: model = "Refine"
        }
        return "\(template.workspaceTitle) · \(model)"
    }

    var body: some View {
        MiniDashboardSurface(
            phase: appState.dictationSessionPhase,
            isEditingDocument: appState.isProcessingAgenticEdit,
            hotkey: appState.hotkeyManager.shortcut.displayString,
            elapsed: appState.recordingDuration,
            outputSummary: outputSummary,
            statusDetail: appState.lastDictationError,
            audioLevel: appState.transcriptionService.audioLevel,
            colorMode: visualizerColorMode,
            sensitivity: audioSensitivity,
            isRefining: appState.dictationFormatter.state == .generating,
            backend: appState.dictationFormatter.activeBackend.huggingFaceRepoID == nil ? .appleIntelligence : .gemma,
            reduceMotion: accessibilityReduceMotion || appState.reduceAppMotion,
            onPrimary: {
                switch appState.dictationSessionPhase {
                case .preparing: Task { await appState.handleCancelRecording() }
                case .listening: Task { await appState.handleStopRecording() }
                case .finishing: break
                default:
                    if appState.pendingSessionText != nil { appState.resumePendingSession() }
                    else { appState.handleStartRecording() }
                }
            },
            onExpand: {
                UserDefaults.standard.set("full", forKey: "mainWindowMode")
                appState.requestedPage = .home
                appState.showMainWindow = true
                dismissWindow(id: "mini")
            }
        )
        .onAppear { Task { await MiniFirstOpenTip.opened.donate() } }
        .popoverTip(MiniFirstOpenTip(), arrowEdge: .bottom)
    }
}

struct MiniDashboardSurface: View {
    let phase: DictationSessionPhase
    var isEditingDocument = false
    let hotkey: String
    var elapsed: TimeInterval = 0
    let outputSummary: String
    var statusDetail: String?
    var audioLevel = 0.0
    var colorMode = "rainbow"
    var sensitivity = 0.7
    var isRefining = false
    var backend: RefiningBackendForPalette = .appleIntelligence
    var reduceMotion = false
    let onPrimary: () -> Void
    let onExpand: () -> Void

    var statusTitle: String {
        if isEditingDocument { return "Applying changes" }
        switch phase {
        case .preparing: return "Preparing"
        case .finishing: return "Finishing dictation"
        case .failed: return "Needs attention"
        case .listening:
            let seconds = Int(max(0, elapsed))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .idle, .delivered: return hotkey
        }
    }

    private var primaryLabel: String {
        if isEditingDocument { return "Applying document changes" }
        switch phase {
        case .preparing: return "Cancel preparation"
        case .listening: return "Finish dictation"
        case .finishing: return "Finishing dictation"
        default: return "Start dictation"
        }
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: onPrimary) {
                if phase == .finishing || isEditingDocument {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    Image(systemName: phase == .preparing ? "xmark" : phase == .listening ? "stop.fill" : "mic.fill")
                        .foregroundStyle(.white).font(.callout.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(phase == .listening ? Color.red : Color.accentColor, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .disabled(phase == .finishing || isEditingDocument)
            .help(primaryLabel).accessibilityLabel(primaryLabel)

            AudioWaveVisualizer(audioLevel: phase == .listening ? min(max(audioLevel, 0), 1) : 0,
                colorMode: colorMode, sensitivity: sensitivity, liquidGlass: false,
                isCleanupMode: false, isRefining: isRefining, isWarmingUp: phase == .preparing,
                refiningBackend: backend, isIdleBreathing: phase != .listening && phase != .preparing,
                reduceMotion: reduceMotion)
                .frame(minWidth: 48, maxWidth: .infinity).frame(height: 32).accessibilityHidden(true)

            VStack(alignment: .trailing, spacing: Spacing.xxxs) {
                Text(statusTitle).font(.caption.weight(.medium)).monospacedDigit()
                Text(outputSummary).font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1).frame(maxWidth: 175, alignment: .trailing)
            .help(statusDetail ?? outputSummary)
            .accessibilityElement(children: .combine)

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).help("Open Home").accessibilityLabel("Open Home")
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
        .frame(minWidth: 380, idealWidth: 380, maxWidth: 520, minHeight: 64, idealHeight: 64, maxHeight: 64)
    }
}
