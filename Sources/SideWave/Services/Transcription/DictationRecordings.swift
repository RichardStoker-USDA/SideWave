// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

@preconcurrency import AVFAudio
import Foundation

/// Optional copies of dictation audio (Settings > Privacy, Advanced view; off by default), so
/// missing or extra words can be checked against what was said by replaying the audio through
/// the same models. Each recording is the microphone audio after channel selection and
/// resampling, as 16 kHz mono 16-bit WAV, in a folder only the user's account can open.
enum DictationRecordings {
    static let enabledKey = "keepSessionAudioRecordings"
    static let maxCount = 100
    static let maxBytes: Int64 = 2 * 1_073_741_824

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func directory(base: URL = AppPaths.applicationSupportDirectory()) -> URL {
        base.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// The file for a session, named like its recovery files (`session_<start time>_<id>.wav`).
    static func url(forSession sessionID: String, in directory: URL = directory()) -> URL {
        directory.appendingPathComponent("\(sessionID).wav")
    }

    /// Saved recordings, newest first.
    static func files(in directory: URL = directory()) -> [(url: URL, bytes: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "wav" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }

    /// Deletes the oldest recordings beyond `maxCount` files or `maxBytes` in total. The newest
    /// one is always kept.
    static func prune(in directory: URL = directory(), maxCount: Int = DictationRecordings.maxCount,
                      maxBytes: Int64 = DictationRecordings.maxBytes) {
        var total: Int64 = 0
        for (index, file) in files(in: directory).enumerated() {
            total += file.bytes
            if index > 0, index >= maxCount || total > maxBytes {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    static func deleteAll(in directory: URL = directory()) {
        for file in files(in: directory) { try? FileManager.default.removeItem(at: file.url) }
    }
}

/// Writes one dictation's audio. Samples arrive on the audio tap thread; writes run on a serial
/// queue so disk I/O never delays the tap.
final class SessionAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sidewave.dictation-recording", qos: .utility)
    private var file: AVAudioFile?
    private let directory: URL

    init?(url: URL) {
        directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        file = f
    }

    func append(_ samples: [Float]) {
        queue.async { [self] in
            guard let file, let buffer = TranscriptionService.makePCMBuffer16k(samples: samples) else { return }
            try? file.write(from: buffer)
        }
    }

    /// Finishes the file, then trims old recordings in its folder.
    func close(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            file = nil
            DictationRecordings.prune(in: directory)
            completion?()
        }
    }
}
