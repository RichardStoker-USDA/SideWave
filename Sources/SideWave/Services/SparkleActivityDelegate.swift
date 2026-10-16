// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import Sparkle

/// Bridges Sparkle's updater lifecycle into `NetworkActivityLog` so every
/// outbound update check and download surfaces in the transparency window.
///
/// Without this, Sparkle's traffic was invisible to users — even though the
/// privacy contract advertised update checks as one of the two outbound
/// reasons SideWave makes any network requests at all.
///
/// The delegate is wired into `SPUStandardUpdaterController` at startup;
/// SPM-installed Sparkle calls back on the main actor (declared
/// `NS_SWIFT_UI_ACTOR` on the protocol).
@MainActor
final class SparkleActivityDelegate: NSObject, SPUUpdaterDelegate {
    private let log = NetworkActivityLog.shared

    func updaterShouldSendProfile(_ updater: SPUUpdater) -> Bool { false }

    // MARK: - Appcast lifecycle

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let (host, path) = Self.split(updater.feedURL)
        log.record(.init(
            kind: .appUpdateCheck,
            direction: .incoming,
            host: host,
            path: path,
            bytes: 0,
            detail: "Checked appcast (\(appcast.items.count) item\(appcast.items.count == 1 ? "" : "s"))"
        ))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        // No record needed beyond didFinishLoadingAppcast; avoid double
        // logging the same network round trip.
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let (host, path) = Self.split(updater.feedURL)
        log.record(.init(
            kind: .appUpdateCheck,
            direction: .incoming,
            host: host,
            path: path,
            bytes: 0,
            detail: "Found update \(item.versionString)"
        ))
    }

    // MARK: - Download lifecycle

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let url = request.url ?? item.fileURL
        let (host, path) = Self.split(url)
        log.record(.init(
            kind: .appUpdateDownload,
            direction: .outgoing,
            host: host,
            path: path,
            bytes: 0,
            detail: "Requesting \(item.versionString)"
        ))
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let (host, path) = Self.split(item.fileURL)
        log.record(.init(
            kind: .appUpdateDownload,
            direction: .incoming,
            host: host,
            path: path,
            bytes: Int64(item.contentLength),
            detail: "Downloaded \(item.versionString)"
        ))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        let (host, path) = Self.split(item.fileURL)
        log.record(.init(
            kind: .appUpdateDownload,
            direction: .incoming,
            host: host,
            path: path,
            bytes: 0,
            detail: "Failed: \(error.localizedDescription)"
        ))
    }

    // MARK: - Helpers

    /// Best-effort URL split. Returns ("unknown", "/") if the URL is nil or
    /// missing a host so the transparency view still gets a row instead of
    /// silently dropping the event.
    private static func split(_ url: URL?) -> (host: String, path: String) {
        guard let url else { return ("unknown", "/") }
        let host = url.host ?? "unknown"
        let path = url.path.isEmpty ? "/" : url.path
        return (host, path)
    }
}
