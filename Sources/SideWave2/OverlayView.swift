// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// The dictation bar: one glass capsule at the bottom of the screen. A
/// living wave carries the session's state, the transcript flows as a
/// single confident stream with a softly settling tail, and one quiet
/// keycap explains the gesture. Pure function of OverlayDisplayState.
struct OverlayView: View {
    let state: OverlayDisplayState

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 13) {
            WaveStrands(mood: waveMood, activityPulse: state.activityPulse)
                .frame(width: 40, height: 22)

            content
                .frame(maxWidth: 470, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            trailing
        }
        .padding(.leading, 17)
        .padding(.trailing, 15)
        .padding(.vertical, 12)
        .background(capsule)
        .padding(12)
        .animation(.spring(duration: 0.32, bounce: 0.18), value: state.phase)
        .animation(.easeInOut(duration: 0.2), value: state.pttEngaged)
    }

    // MARK: Wave mood

    private var waveMood: WaveStrands.Mood {
        switch state.phase {
        case .starting:
            return .calm
        case .live:
            return .listening
        case .finishing(let refining):
            return refining ? .refining(state.refinePalette) : .listening
        case .done(let outcome):
            if case .notice = outcome { return .calm }
            return .settled
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .starting:
            statusText("Listening…")
                .transition(.opacity)

        case .live:
            if state.hasTranscript {
                transcriptLine
            } else if let deviceNotice = state.deviceNotice {
                statusText(deviceNotice)
            } else {
                statusText("Listening…")
            }

        case .finishing(let refining):
            VStack(alignment: .leading, spacing: 1) {
                if refining {
                    shimmerStatus(refineLabel)
                } else {
                    statusText("Finishing…")
                }
                if state.hasTranscript {
                    transcriptLine
                        .opacity(0.62)
                }
            }

        case .done(let outcome):
            doneContent(outcome)
        }
    }

    private var transcriptLine: some View {
        (Text(state.settledText).foregroundStyle(.primary)
            + Text(state.settlingText).foregroundStyle(.secondary))
            .font(.system(size: 13.5))
            .lineLimit(1)
            .truncationMode(.head)
            .contentTransition(.identity)
    }

    private func statusText(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var refineLabel: String {
        switch state.refinePalette {
        case .appleIntelligence: return "Refining with Apple Intelligence…"
        case .gemma: return "Refining with Gemma…"
        }
    }

    /// The refine status wears a slow shine so the wait reads as work.
    private func shimmerStatus(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .overlay {
                LinearGradient(
                    colors: [.clear, shimmerHighlight, .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 70)
                .offset(x: shimmerOffset)
                .mask(
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                )
                .allowsHitTesting(false)
            }
            .task {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    shimmerOffset = 220
                }
            }
    }

    @State private var shimmerOffset: CGFloat = -220

    private var shimmerHighlight: Color {
        scheme == .dark ? .white.opacity(0.65) : .black.opacity(0.35)
    }

    @ViewBuilder
    private func doneContent(_ outcome: OverlayDisplayState.Outcome) -> some View {
        switch outcome {
        case .pasted:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(sideWaveAccent)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                Text("Pasted")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
        case .savedToHistory:
            HStack(spacing: 7) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Saved to history")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
        case .notice(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: Trailing hint

    @ViewBuilder
    private var trailing: some View {
        switch state.phase {
        case .live:
            if state.pttEngaged {
                hintLabel("release to send")
            } else {
                HStack(spacing: 5) {
                    keycap(state.hotkeyGlyph)
                    Text("to stop")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        case .starting, .finishing, .done:
            EmptyView()
        }
    }

    private func hintLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(sideWaveAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(sideWaveAccent.opacity(scheme == .dark ? 0.16 : 0.10))
            )
    }

    /// A quiet keycap, drawn like a key: rounded square, hairline rim,
    /// faint top light.
    private func keycap(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 21)
            .padding(.horizontal, 3)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(.quaternary.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(scheme == .dark ? 0.22 : 0.75),
                                        .white.opacity(0.02),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    )
            )
    }

    // MARK: Chrome

    private var sideWaveAccent: Color {
        scheme == .dark
            ? Color(.sRGB, red: 0.435, green: 0.698, blue: 1.000)
            : Color(.sRGB, red: 0.122, green: 0.373, blue: 0.749)
    }

    private var capsule: some View {
        Capsule(style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                // A whisper of the brand across the top edge.
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                sideWaveAccent.opacity(scheme == .dark ? 0.34 : 0.22),
                                .white.opacity(scheme == .dark ? 0.10 : 0.42),
                                sideWaveAccent.opacity(scheme == .dark ? 0.20 : 0.12),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.42 : 0.20), radius: 20, y: 7)
    }
}
