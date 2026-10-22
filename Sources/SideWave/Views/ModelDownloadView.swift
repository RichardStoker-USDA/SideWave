// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Displays model download state: not downloaded, downloading, compiling, ready, error.
/// Has two modes:
/// - `embedded = false` (default): full-size for standalone use (Settings)
/// - `embedded = true`: compact inline for the onboarding step card
struct ModelDownloadView: View {
    var transcriptionService: TranscriptionService
    let version: ModelVersion
    var embedded: Bool = false

    @State private var isDownloading = false

    var body: some View {
        if embedded {
            compactBody
        } else {
            fullBody
        }
    }

    // MARK: - Compact (for onboarding cards)

    private var compactBody: some View {
        Group {
            switch transcriptionService.modelState {
            case .notDownloaded:
                HStack(spacing: Spacing.sm) {
                    Text(version.downloadSizeLabel)
                        .font(.caption)
                        .adaptiveTertiary()
                    Button("Download") {
                        startDownload()
                    }
                    .prominentActionButton()
                    .disabled(isDownloading)
                }

            case .downloading(let progress):
                VStack(spacing: Spacing.xxs) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("Downloading \(version.displayName)\u{2026}")
                            .font(.caption2)
                            .adaptiveSecondary()
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(.caption2, design: .monospaced))
                            .adaptiveTertiary()
                    }
                }
                .accessibilityElement(children: .combine)

            case .downloadingAuxiliary(let model):
                HStack(spacing: Spacing.xs) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Setting up \(model)\u{2026}")
                        .font(.caption2)
                        .adaptiveSecondary()
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)

            case .verifying:
                ProgressView("Checking model files\u{2026}")
                    .controlSize(.small)
                    .font(.caption)

            case .compiling:
                HStack(spacing: Spacing.xs) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Optimizing for your hardware (first time only)\u{2026}")
                        .font(.caption2)
                        .adaptiveSecondary()
                }
                .accessibilityElement(children: .combine)

            case .loading:
                HStack(spacing: Spacing.xs) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading models into memory\u{2026}")
                        .font(.caption2)
                        .adaptiveSecondary()
                }
                .accessibilityElement(children: .combine)

            case .error(let message):
                HStack(spacing: Spacing.xs) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { startDownload() }
                        .disabled(isDownloading)
                    .prominentActionButton()
                }
                .accessibilityElement(children: .combine)

            case .ready:
                // Don't show anything -- the step card's green checkmark is enough
                EmptyView()
            }
        }
    }

    // MARK: - Full size (for Settings or standalone)

    private var fullBody: some View {
        VStack(spacing: Spacing.lg) {
            if !transcriptionService.modelState.isReady {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: Size.iconXXL - 8))
                    .adaptiveSecondary()

                Text("Download Speech Model")
                    .font(.headline)

                Text(version.displayName)
                    .font(.subheadline)
                    .adaptiveSecondary()

                Text("\(version.downloadSizeLabel) speech model, plus support models")
                    .font(.caption)
                    .adaptiveSecondary()
            }

            switch transcriptionService.modelState {
            case .downloading(let progress):
                VStack(spacing: Spacing.sm) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .adaptiveSecondary()
                        .monospacedDigit()
                }
                .frame(maxWidth: 300)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Downloading \(version.displayName), \(Int(progress * 100)) percent")
                if let session = ModelDownloadActivity.shared.session, session.totalBytes > 0 {
                    Text("\(session.downloadedBytes.byteCountText) of \(session.totalBytes.byteCountText)")
                        .font(.caption.monospacedDigit())
                        .adaptiveSecondary()
                }

            case .downloadingAuxiliary(let model):
                VStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading \(model)\u{2026}")
                        .font(.caption)
                        .adaptiveSecondary()
                }
                .accessibilityElement(children: .combine)

            case .verifying:
                ProgressView("Checking model files\u{2026}")
                    .controlSize(.small)
                    .font(.caption)

            case .compiling:
                VStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing models for first use\u{2026}")
                        .font(.caption)
                        .adaptiveSecondary()
                }
                .accessibilityElement(children: .combine)

            case .loading:
                VStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading model\u{2026}")
                        .font(.caption)
                        .adaptiveSecondary()
                }
                .accessibilityElement(children: .combine)

            case .error(let message):
                VStack(spacing: Spacing.sm) {
                    Text("Download failed")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .adaptiveSecondary()
                        .lineLimit(3)

                    Button("Retry") { startDownload() }
                        .disabled(isDownloading)
                    .prominentActionButton()
                }
                .accessibilityElement(children: .combine)

            case .ready:
                VStack(spacing: Spacing.sm) {
                    Label("Model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    if !transcriptionService.auxiliaryModelErrors.isEmpty {
                        VStack(spacing: Spacing.xs) {
                            ForEach(transcriptionService.auxiliaryModelErrors, id: \.self) { err in
                                Text(err)
                                    .font(.caption)
                                    .adaptiveSecondary()
                                    .lineLimit(2)
                            }
                            Button("Retry") {
                                Task { await transcriptionService.retryAuxiliaryDownloads() }
                            }
                            .actionButton()
                        }
                    }
                }

            case .notDownloaded:
                Button("Download") { startDownload() }
                .prominentActionButton()
                .disabled(isDownloading)
            }
        }
        .padding(Spacing.xxl)
    }

    private func startDownload() {
        isDownloading = true
        Task {
            await transcriptionService.downloadModel(version: version)
            isDownloading = false
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Download - Light") {
    ModelDownloadView(transcriptionService: TranscriptionService(), version: .v3)
        .frame(width: 400, height: 300)
        .preferredColorScheme(.light)
}

#Preview("Download - Dark") {
    ModelDownloadView(transcriptionService: TranscriptionService(), version: .v3)
        .frame(width: 400, height: 300)
        .preferredColorScheme(.dark)
}
#endif
