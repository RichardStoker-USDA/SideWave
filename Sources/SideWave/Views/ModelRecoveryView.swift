// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

/// Model files, transfer progress, and recovery stay visible independently of model loading.
struct ModelRecoveryView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceAppMotion") private var reduceAppMotion = false
    @State private var activity: ModelDownloadActivity
    @State private var countdownStart: Date?
    @State private var showsFiles = false
    @State private var isPointerInside = false
    private let reviewModel: (String?) -> Void
    private let retryModel: ((String) -> Void)?
    private let canRetry: (String) -> Bool

    init(activity: ModelDownloadActivity = .shared,
         reviewModel: @escaping (String?) -> Void = { _ in },
         retryModel: ((String) -> Void)? = nil,
         canRetry: @escaping (String) -> Bool = { _ in false },
         showsFiles: Bool = false) {
        _activity = State(initialValue: activity)
        _showsFiles = State(initialValue: showsFiles)
        self.reviewModel = reviewModel
        self.retryModel = retryModel
        self.canRetry = canRetry
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let session = activity.session {
                        transferHeader(session)
                        transferProgress(session)
                        Text("From huggingface.co. Your dictation stays on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !activity.otherDownloads.isEmpty { otherTransfers }
                        if !session.files.isEmpty { fileDetails(session) }
                        if session.error != nil {
                            Text("Completed files are kept. Retrying preparation checks what is already on this Mac before fetching anything missing.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Label("No downloads right now", systemImage: "arrow.down.circle")
                            .font(.title3.weight(.medium))
                        Text("Models are saved on this Mac after preparation. Data Transparency keeps a history of internet requests.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .buttonBorderShape(.capsule)
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 760,
               minHeight: 250, idealHeight: 330, maxHeight: 620)
        .onHover { isPointerInside = $0 }
        .onChange(of: activity.sessionGeneration) { countdownStart = nil }
        .onChange(of: shouldCloseAutomatically) { _, enabled in
            countdownStart = enabled ? .now : nil
        }
        .onAppear { if shouldCloseAutomatically { countdownStart = .now } }
    }

    private var shouldCloseAutomatically: Bool {
        activity.allTransfersFinished && !showsFiles && !isPointerInside
    }

    private func transferHeader(_ session: ModelDownloadActivity.Session) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: session.error != nil ? "exclamationmark.circle" : session.completedAt != nil ? "checkmark.circle" : "arrow.down.circle")
                .font(.system(size: 29, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.displayName).font(.system(size: 20, weight: .medium, design: .rounded))
                Text(stageTitle(session)).font(.callout).foregroundStyle(.secondary)
                if let error = session.error {
                    Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                } else if session.completedAt != nil {
                    Text("Files are saved. Loading and first-use preparation may continue in the main window.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let detail = session.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func stageTitle(_ session: ModelDownloadActivity.Session) -> String {
        if session.error != nil { return "Preparation needs attention" }
        if session.completedAt != nil { return "Download complete" }
        switch session.stage {
        case .checking: return "Checking model files"
        case .downloading: return "Downloading to this Mac"
        case .verifying: return "Verifying downloaded files"
        }
    }

    private func transferProgress(_ session: ModelDownloadActivity.Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.stage == .checking && session.files.isEmpty && session.completedAt == nil && session.error == nil {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: session.overallFraction).progressViewStyle(.linear)
                    .animation(systemReduceMotion || reduceAppMotion ? nil : .easeOut(duration: 0.25), value: session.overallFraction)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(byteSummary(session)).font(.callout.monospacedDigit())
                Spacer(minLength: 0)
                if session.stage == .downloading && session.error == nil && session.completedAt == nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let rate = activity.transferRate(at: context.date), rate.isFinite, rate > 0 {
                            Text("\(formatBytes(Int64(min(rate, Double(Int64.max / 2)))))/s")
                        } else {
                            Text("Waiting for progress")
                        }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if session.completedAt != nil {
                    Text("100%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if session.baselineBytes > 0 {
                Text("\(formatBytes(session.baselineBytes)) already on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var otherTransfers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other models").font(.caption).foregroundStyle(.secondary)
            ForEach(activity.otherDownloads) { other in
                Button { activity.showSession(other.id) } label: {
                    HStack(spacing: 8) {
                        Text(other.displayName).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(other.error == nil ? stageTitle(other) : "Needs attention").foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func fileDetails(_ session: ModelDownloadActivity.Session) -> some View {
        DisclosureGroup(isExpanded: $showsFiles) {
            VStack(alignment: .leading, spacing: 10) {
                Text(session.repoID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(session.files) { file in
                            HStack(spacing: 8) {
                                Image(systemName: file.isFinished ? "checkmark" : "arrow.down")
                                    .foregroundStyle(.secondary).frame(width: 14)
                                Text(file.id).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(formatBytes(file.downloadedBytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxHeight: 144)
            }
            .padding(.top, 10)
        } label: {
            Text("Files · \(session.files.filter(\.isFinished).count) saved\(session.completedAt == nil ? " so far" : "")")
                .font(.callout).foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(.row)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if activity.allTransfersFinished {
                Button("Download History") { openWindow(id: "data-transparency") }
                    .buttonStyle(.borderless).font(.callout)
            } else {
                Button("Model Settings") {
                    reviewModel(activity.session?.repoID)
                    openWindow(id: "settings")
                }
                .buttonStyle(.borderless).font(.callout)
            }
            Spacer(minLength: 0)
            if shouldCloseAutomatically {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, 10 - Int(context.date.timeIntervalSince(countdownStart ?? context.date)))
                    Text("Closing in \(remaining)s").font(.caption).foregroundStyle(.secondary)
                        .onChange(of: context.date) { _, _ in
                            if remaining == 0, shouldCloseAutomatically {
                                activity.clear()
                                dismissWindow(id: "model-recovery")
                            }
                        }
                }
            }
            if let session = activity.session, session.error != nil,
               let retryModel, canRetry(session.repoID) {
                Button("Retry Preparation") { retryModel(session.repoID) }
                    .buttonStyle(.borderedProminent)
            }
            Button(closeButtonLabel) {
                if activity.allTransfersFinished { activity.clear() }
                else { activity.suppressPresentationForCurrentSession() }
                dismissWindow(id: "model-recovery")
            }
            .buttonStyle(.bordered)
        }
    }

    private var closeButtonLabel: String {
        guard let session = activity.session else { return "Close" }
        if activity.allTransfersFinished || session.error != nil { return "Close" }
        return "Hide"
    }

    private func byteSummary(_ session: ModelDownloadActivity.Session) -> String {
        if session.hasKnownTotal {
            return "\(formatBytes(session.downloadedBytes)) of \(formatBytes(session.totalBytes))"
        }
        if session.downloadedBytes > 0 { return "\(formatBytes(session.downloadedBytes)) saved" }
        return session.completedAt == nil ? "Waiting for file sizes" : "Files saved"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        bytes.byteCountText
    }
}
