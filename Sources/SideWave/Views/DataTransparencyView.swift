// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI
import Charts

/// Local history of app-managed downloads and update checks.
///
/// Surfaced as a top-level window via `SideWave → Data Transparency` in
/// the menu bar. Also linked from the About tab in Settings (lighter
/// summary view there).
struct DataTransparencyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var log: NetworkActivityLog
    @State private var activity = ModelDownloadActivity.shared
    @State private var selectedKindFilter: NetworkActivityLog.EventKind? = nil
    @State private var showClearConfirmation = false
    @State private var selectedEvent: NetworkActivityLog.Event?
    @State private var search = ""

    init(log: NetworkActivityLog = .shared) {
        _log = State(initialValue: log)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    if let session = activity.session, session.hasRealDownload, session.completedAt == nil {
                        liveDownloadCard(session: session)
                    }
                    if let error = log.persistenceError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).adaptiveSecondary()
                    }
                    promiseCard
                    summaryCard
                    activityChart
                    filterRow
                    eventList
                    Spacer(minLength: Spacing.lg)
                }
                .padding(Spacing.xl)
            }
        }
        .frame(minWidth: 580, idealWidth: 580, minHeight: 520, idealHeight: 680)
        .buttonBorderShape(.capsule)
        .sheet(item: $selectedEvent) { event in
            VStack(alignment: .leading, spacing: 16) {
                Text(eventTitle(event)).font(.title2.weight(.semibold))
                Text(event.timestamp.formatted(date: .complete, time: .standard)).font(.callout).adaptiveSecondary()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(event.detail).font(.body).textSelection(.enabled)
                        Text("\(event.host)\(event.path)")
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(event.bytes > 0 ? "Recorded transfer: \(formatBytes(event.bytes))"
                             : event.direction == .outgoing ? "No request body was uploaded."
                             : "Transfer size was not reported for this event.")
                            .font(.caption).adaptiveSecondary()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Done") { selectedEvent = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 520, height: 350).buttonBorderShape(.capsule)
        }
    }

    // MARK: - Live download card

    private func liveDownloadCard(session: ModelDownloadActivity.Session) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Downloading right now")
                        .font(.callout.weight(.semibold))
                    Text("\(session.displayName) · \(session.repoID)")
                        .font(.system(.caption2, design: .monospaced))
                        .adaptiveSecondary()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(Int((session.overallFraction * 100).rounded()))%")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .adaptiveSecondary()
            }
            ProgressView(value: session.overallFraction)
                .tint(Color.accentColor)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: session.overallFraction)
        }
        .padding(Spacing.lg)
        .settingsCardStyle()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Data Transparency")
                    .font(.title3.weight(.semibold))
                Text("Download sources and app-managed network activity, saved on this Mac.")
                    .font(.caption)
                    .adaptiveSecondary()
            }
            Spacer()
            Button {
                showClearConfirmation = true
            } label: {
                Label("Clear History", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .actionButton()
            .controlSize(.small)
            .help("Wipes the on-disk log. New events continue to be recorded.")
            .confirmationDialog(
                "Clear network activity log?",
                isPresented: $showClearConfirmation
            ) {
                Button("Clear", role: .destructive) {
                    log.clear()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This wipes the local log file. Future network events will continue to be recorded automatically.")
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Promise card

    private var promiseCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Speech is processed locally. SideWave sends no usage analytics or automatic crash reports.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Privacy and what is recorded") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                promiseRow(
                    icon: "mic.slash",
                    title: "Speech processing stays on this Mac",
                    body: "Recognition, Refine, and meeting notes run locally. Pasting or exporting shares text with the destination you choose."
                )
                promiseRow(
                    icon: "arrow.down.circle",
                    title: "Outbound is download-only",
                    body: "SideWave fetches local models, optional glossary catalogs, and optional app updates. It sends no usage analytics or automatic crash reports."
                )
                promiseRow(
                    icon: "doc.text.magnifyingglass",
                    title: "A local record you control",
                    body: "Events include the source, time, and known transfer size. History is kept until you clear it. This is an app activity record; a network monitor can independently check traffic from other system processes."
                )
            }
            .padding(.top, 12)
            }
            .font(.callout)
            .disclosureGroupStyle(.row)
        }
        .padding(Spacing.lg)
        .settingsCardStyle()
    }

    private func promiseRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(body)
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        HStack(spacing: Spacing.lg) {
            summaryStat(
                label: "Total events",
                value: "\(log.events.count)",
                icon: "list.number"
            )
            Divider().frame(height: 40)
            summaryStat(
                label: "Downloaded",
                value: formatBytes(log.totalIncomingBytes),
                icon: "arrow.down.circle"
            )
            Divider().frame(height: 40)
            summaryStat(
                label: "Uploaded",
                value: log.totalOutgoingBytes == 0 ? "None" : formatBytes(log.totalOutgoingBytes),
                icon: "arrow.up.circle"
            )
            Spacer()
        }
        .padding(Spacing.lg)
        .settingsCardStyle()
    }

    private func summaryStat(label: String, value: String, icon: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.title3)
                .adaptiveSecondary()
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.caption)
                    .adaptiveSecondary()
            }
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var activityChart: some View {
        if log.events.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Downloads in the last 30 days")
                    .font(.headline)
                if chartBuckets.allSatisfy({ $0.bytes == 0 }) {
                    Text("No download bytes were recorded in this period. Earlier activity is listed below.")
                        .font(.callout).adaptiveSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                Chart(chartBuckets, id: \.day) { bucket in
                    BarMark(
                        x: .value("Day", bucket.day, unit: .day),
                        y: .value("Bytes", bucket.bytes)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(2)
                }
                .frame(height: 120)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) {
                                Text(formatBytes(bytes))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    }
                }
                }
            }
            .padding(Spacing.lg)
            .settingsCardStyle()
        }
    }

    /// Buckets events by day for the activity bar chart.
    private struct DayBucket {
        let day: Date
        let bytes: Int64
    }

    private var chartBuckets: [DayBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var groups: [Date: Int64] = [:]
        for event in log.events where event.timestamp >= start && event.direction == .incoming {
            let day = calendar.startOfDay(for: event.timestamp)
            groups[day, default: 0] += event.bytes
        }
        return (0..<30).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DayBucket(day: day, bytes: groups[day] ?? 0)
        }
    }

    // MARK: - Filter

    private var filterRow: some View {
        HStack(spacing: 12) {
            SearchField("Search activity", text: $search)
            Menu {
                Picker("Activity type", selection: $selectedKindFilter) {
                    Text("All activity").tag(nil as NetworkActivityLog.EventKind?)
                    ForEach(activeKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(Optional(kind))
                    }
                }.pickerStyle(.inline)
            } label: { Text(selectedKindFilter?.displayName ?? "All activity") }
            .fixedSize().accessibilityLabel("Filter activity")
        }
    }

    /// Offer event kinds present in the saved activity.
    private var activeKinds: [NetworkActivityLog.EventKind] {
        Array(Set(log.events.map(\.kind))).sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Event list

    private var eventList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Event log")
                .font(.headline)
            if filteredEvents.isEmpty {
                emptyStateRow
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(filteredEvents.reversed()) { event in
                        eventRow(event)
                        if event.id != filteredEvents.first?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .padding(Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .fill(Color.cardBackground(for: colorScheme))
                )
            }
        }
    }

    private var filteredEvents: [NetworkActivityLog.Event] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return log.events.filter { event in
            (selectedKindFilter == nil || event.kind == selectedKindFilter)
                && (query.isEmpty || "\(event.host)\(event.path) \(event.detail) \(event.kind.displayName)".localizedCaseInsensitiveContains(query))
        }
    }

    private var emptyStateRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "tray")
                .font(.title3)
                .adaptiveSecondary()
            VStack(alignment: .leading, spacing: 2) {
                Text(log.events.isEmpty ? "No saved network activity" : "No matching activity")
                    .font(.callout.weight(.medium))
                Text(log.events.isEmpty
                     ? "New model downloads, glossary catalog requests, and update checks appear here. Clearing this history removes the saved events."
                     : "Try another search or choose All activity.")
                    .font(.caption)
                    .adaptiveSecondary()
            }
            Spacer()
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .fill(Color.cardBackground(for: colorScheme))
        )
    }

    private func eventRow(_ event: NetworkActivityLog.Event) -> some View {
        Button { selectedEvent = event } label: {
        HStack(spacing: Spacing.sm) {
            Image(systemName: event.kind.systemImage)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.xs) {
                    Text(eventTitle(event))
                        .font(.callout.weight(.medium))
                    Text(event.detail)
                        .font(.callout)
                        .adaptiveSecondary()
                        .lineLimit(1)
                }
                Text("\(event.host)\(event.path)")
                    .font(.system(.caption2, design: .monospaced))
                    .adaptiveSecondary()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .adaptiveSecondary()
                if event.bytes > 0 {
                    Text(formatBytes(event.bytes))
                        .font(.caption2.monospacedDigit())
                        .adaptiveSecondary()
                }
            }
            Image(systemName: "chevron.right").font(.caption2).adaptiveSecondary()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
        }.buttonStyle(.plain).help("View full source and transfer details")
    }

    // MARK: - Helpers

    private func eventTitle(_ event: NetworkActivityLog.Event) -> String {
        event.direction == .outgoing ? "Network request" : event.kind.displayName
    }

    private func formatBytes(_ bytes: Int64) -> String { bytes.byteCountText }
}
