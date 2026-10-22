// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Shared download UI. Accepts a Foundation `Progress` so we can show bytes,
/// ETA, and phase text straight from the MLX downloader instead of just a
/// percentage.
struct DownloadProgressCard: View {
    let progress: Progress
    let title: String
    var onCancel: (() -> Void)? = nil

    private static let etaFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Downloading \(title)")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(Int(progress.fractionCompleted * 100))%")
                    .font(.caption.monospacedDigit())
                    .adaptiveSecondary()
            }

            ProgressView(value: max(0, min(1, progress.fractionCompleted)))
                .progressViewStyle(.linear)

            HStack(spacing: Spacing.sm) {
                Text(bytesLine)
                    .font(.caption)
                    .adaptiveSecondary()
                Spacer()
                if let eta = etaLine {
                    Text(eta)
                        .font(.caption.monospacedDigit())
                        .adaptiveTertiary()
                }
            }

            if let phase = phaseLine {
                Text(phase)
                    .font(.caption2)
                    .adaptiveTertiary()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("First time only. The model is cached after download.")
                .font(.caption2)
                .adaptiveTertiary()

            if let onCancel {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onCancel)
                        .actionButton()
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: 360)
    }

    private var bytesLine: String {
        let done = progress.completedUnitCount.byteCountText
        guard progress.totalUnitCount > 0 else { return done }
        let total = progress.totalUnitCount.byteCountText
        return "\(done) of \(total)"
    }

    private var etaLine: String? {
        guard let secs = progress.estimatedTimeRemaining, secs.isFinite, secs > 0 else {
            return nil
        }
        return Self.etaFormatter.string(from: secs).map { "\($0) left" }
    }

    /// MLX's hub downloader fills `localizedAdditionalDescription` with "file
    /// N of M" style strings in recent versions. Fall back to nothing if the
    /// downloader doesn't populate it.
    private var phaseLine: String? {
        let s = progress.localizedAdditionalDescription ?? ""
        return s.isEmpty ? nil : s
    }
}
