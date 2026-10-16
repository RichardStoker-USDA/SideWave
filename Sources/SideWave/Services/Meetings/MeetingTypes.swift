// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Accelerate
@preconcurrency import AVFAudio
import FluidAudio
import Foundation

// MARK: - Meeting Transcription State

enum MeetingState: Equatable {
    case idle
    case recording(duration: TimeInterval)
    case processing(stage: ProcessingStage)
    case complete
    case error(String)

    enum ProcessingStage: Equatable, Sendable {
        case preparingModels
        case diarizing(method: String)
        case transcribing
        case merging

        var description: String {
            switch self {
            case .preparingModels: return "Preparing models"
            case .diarizing(let method): return "Identifying speakers\(method.isEmpty ? "" : " (\(method))")"
            case .transcribing: return "Transcribing audio"
            case .merging: return "Building transcript"
            }
        }
    }
}

enum MeetingError: LocalizedError {
    case busy
    case noAudio
    case microphoneUnavailable
    case invalidAudio
    case invalidSpeakerOutput
    case modelsNotReady

    var errorDescription: String? {
        switch self {
        case .busy: return "A meeting is already in progress."
        case .noAudio: return "No audio was captured for this meeting."
        case .microphoneUnavailable: return "Enable microphone access in SideWave and finish any microphone test before recording a meeting."
        case .invalidSpeakerOutput: return "Speaker detection returned incomplete data. The recording is kept so you can try again."
        case .modelsNotReady: return "Prepare the meeting models before processing audio."
        case .invalidAudio: return "The meeting audio could not be read completely. The recording is kept for recovery."
        }
    }
}

// MARK: - Meeting Transcript Types

struct MeetingSegment: Identifiable, Codable, Sendable {
    let id: UUID
    let speakerId: String
    let speakerLabel: String
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(id: UUID = UUID(), speakerId: String, speakerLabel: String, text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }

    var formattedTimeRange: String {
        let start = Self.formatTimestamp(startTime)
        let end = Self.formatTimestamp(endTime)
        return "\(start) - \(end)"
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct MeetingTranscript: Codable, Identifiable {
    let id: UUID
    /// Segments from the last speaker detection. Mutable so detection can run again without losing
    /// the meeting.
    var segments: [MeetingSegment]
    /// Display name per speaker id. Mutable so rediarize + rename can persist.
    var speakerNames: [String: String]
    let duration: TimeInterval
    let timestamp: Date
    /// Saved AI-formatted output (so users don't have to regenerate).
    /// Key = format name ("Meeting Minutes", "Action Items", etc.), Value = generated text.
    var savedFormats: [String: String]
    /// Format keys generated before the most recent rediarize. The Results/Format
    /// UI shows a subtle "generated before speaker re-detection" note and offers
    /// regenerate; outputs are never auto-deleted.
    var staleFormats: Set<String>
    var isPartial: Bool

    init(id: UUID = UUID(), segments: [MeetingSegment], speakerNames: [String: String], duration: TimeInterval, timestamp: Date, isPartial: Bool = false) {
        self.id = id
        self.segments = segments
        self.speakerNames = speakerNames
        self.duration = duration
        self.timestamp = timestamp
        self.savedFormats = [:]
        self.staleFormats = []
        self.isPartial = isPartial
    }

    private enum CodingKeys: String, CodingKey {
        case id, segments, speakerNames, duration, timestamp, savedFormats, staleFormats, isPartial
    }

    /// Tolerant decode: transcripts written before `staleFormats` existed (and any
    /// other newly-optional field) still load with sane defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        segments = try c.decode([MeetingSegment].self, forKey: .segments)
        speakerNames = (try? c.decodeIfPresent([String: String].self, forKey: .speakerNames)) ?? [:]
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        savedFormats = (try? c.decodeIfPresent([String: String].self, forKey: .savedFormats)) ?? [:]
        staleFormats = (try? c.decodeIfPresent(Set<String>.self, forKey: .staleFormats)) ?? []
        isPartial = (try? c.decodeIfPresent(Bool.self, forKey: .isPartial)) ?? false
    }

    var plainText: String {
        let content = segments.map { segment in
            let name = speakerNames[segment.speakerId] ?? segment.speakerLabel
            return "[\(segment.formattedTimeRange)] \(name): \(segment.text)"
        }.joined(separator: "\n\n")
        return isPartial ? "Partial transcript recovered from live recording. Some speech may be missing.\n\n" + content : content
    }

    var summaryLine: String {
        let speakerCount = Set(segments.map(\.speakerId)).count
        let durationStr = MeetingSegment.formatTimestamp(duration)
        if !hasSpeech { return "No speech detected, \(durationStr)" }
        return (isPartial ? "Partial: " : "") + "\(speakerCount) speaker\(speakerCount == 1 ? "" : "s"), \(durationStr), \(segments.count) segment\(segments.count == 1 ? "" : "s")"
    }

    var segmentSpeakerSummary: String {
        let count = Set(segments.map(\.speakerId)).count
        return "\(segments.count) segment\(segments.count == 1 ? "" : "s") from \(count) speaker\(count == 1 ? "" : "s")"
    }

    var formattingSource: String {
        "Meeting date: \(formattedDate)\nDuration: \(MeetingSegment.formatTimestamp(duration))\n\n" + plainText
    }

    var hasSpeech: Bool {
        segments.contains { $0.text.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    var formattedDate: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: timestamp)
    }
}

// MARK: - Meeting model preparation state

/// Meeting model preparation. `.notPrepared` also covers local loading and compiling, shown as a
/// spinner without download wording. `.downloading` is a real fetch with a progress bar. New
/// Meeting is available once `.ready`.
enum MeetingModelsState: Equatable {
    case notPrepared
    case downloading(progress: Double)
    case ready
    case error(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Progress signal from the off-main model preparation. `.preparing` keeps the
/// spinner (local load/compile); `.downloading` drives the real progress bar.
/// Both carry a human `detail` line for the provisioning status readout.
enum MeetingPrepProgress: Sendable {
    case preparing(detail: String)
    case downloading(fraction: Double, detail: String)
}

// MARK: - Off-main pipeline value types (Sendable)

/// A merged speaker interval used for attribution.
struct MeetingDiarSeg: Sendable {
    let speakerId: String
    let start: Double
    let end: Double
}

/// A speaker-attributed segment carrying raw (un-normalized) transcript text.
/// The @MainActor service runs the dictation text pipeline over `rawText` to
/// produce the final `MeetingSegment` (the pipeline helpers are MainActor-bound).
struct MeetingRawSegment: Sendable {
    let speakerId: String
    let start: Double
    let end: Double
    let rawText: String
}

/// Result of a batch (or finalized-live) pass. `words` and `tokenTimings` are
/// retained so a later rediarize can skip ASR and re-align the same words.
struct MeetingBatchResult: Sendable {
    let rawSegments: [MeetingRawSegment]
    let speakerCount: Int
    let duration: Double
    let words: [String]
    let tokenTimings: [TokenTiming]
}
