// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Shown at launch when the orphan scan finds an interrupted meeting (crash,
/// force-quit, or a quit where the user chose to keep the recording). The
/// audio survived on disk; this sheet is how the user decides what happens
/// to it. One meeting at a time; the owner re-presents while more remain.
struct MeetingRecoverySheet: View {
    let orphan: OrphanedMeeting
    /// True when the Meeting tab is available. Resume and transcribe need the tab:
    /// transcribing into a tab
    /// the user can't open would run headless with an unreachable result, so
    /// without the tab the sheet offers Keep for Later / Discard instead.
    let canResume: Bool
    let onResume: () -> Void
    let onTranscribe: () -> Void
    let onDiscard: () -> Void
    let onLater: () -> Void

    @State private var confirmDiscard = false

    private var startedLabel: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: orphan.startedAt)
    }

    private var durationLabel: String {
        let total = Int(orphan.recordedDuration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private var sizeLabel: String { orphan.diskBytes.byteCountText }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("Continue this meeting?")
                        .font(.title3.weight(.semibold))
                    Text("SideWave found a meeting recording that didn't finish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                recoveryRow(label: "Started", value: startedLabel)
                recoveryRow(label: "Recorded", value: durationLabel)
                recoveryRow(label: "On disk", value: sizeLabel)
                if orphan.hasLiveSegments {
                    recoveryRow(label: "Transcript", value: "Partial live transcript saved")
                }
            }
            .padding(Spacing.md)
            .settingsCardStyle()

            Text(canResume
                ? "Continue picks up recording where it left off. Transcribe processes what was captured into a speaker-labeled transcript."
                : "Meetings is currently off. Turn on Show Meetings in Settings > Meetings to transcribe this recording, or keep it for later. Keep for Later asks again next time you open SideWave.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This recording stays on this Mac until you finish processing or discard it. History cleanup does not delete unfinished audio. Keep for Later asks again when you next open SideWave.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: Spacing.sm) {
                Button("Discard", role: .destructive) {
                    confirmDiscard = true
                }
                .actionButton()
                .confirmationDialog(
                    "Discard this recording?",
                    isPresented: $confirmDiscard,
                    titleVisibility: .visible
                ) {
                    Button("Discard Recording", role: .destructive) { onDiscard() }
                    Button("Keep", role: .cancel) {}
                } message: {
                    Text("The \(durationLabel) of recorded audio will be deleted. This can't be undone.")
                }

                Spacer()

                Button("Keep for Later") { onLater() }
                    .actionButton()
                    .keyboardShortcut(.cancelAction)

                if canResume {
                    Button("Continue Recording") { onResume() }
                        .actionButton()

                    Button("Transcribe") { onTranscribe() }
                        .prominentActionButton()
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
        .frame(minHeight: 360)
    }

    private func recoveryRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.callout.weight(.medium))
        }
    }
}
