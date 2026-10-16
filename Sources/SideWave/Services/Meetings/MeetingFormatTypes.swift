// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - Format Types

enum MeetingFormat: String, CaseIterable, Identifiable {
    case minutes = "Meeting Minutes"
    case actionItems = "Action Items"
    case summary = "Summary"
    case keyDecisions = "Key Decisions"
    case fullReport = "Full Report"
    case custom = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .minutes: return "doc.text"
        case .actionItems: return "checklist"
        case .summary: return "text.justify.left"
        case .keyDecisions: return "lightbulb"
        case .fullReport: return "doc.richtext"
        case .custom: return "pencil"
        }
    }

    /// UserDefaults key for the persisted `.custom` format instructions.
    /// Mirrors dictation's custom-template instructions; capped at
    /// `customInstructionsCharLimit` at the use sites.
    static let customInstructionsKey = "meetingCustomFormatInstructions"
    static let customInstructionsCharLimit = 1000

    /// Added to every format's system prompt so the model keeps speaker labels as given, whether
    /// automatic ("Speaker 1") or names the user assigned.
    private static let speakerLabelRule = """
    Speaker labels in the transcript, whether generic ("Speaker 1", "Speaker 2") or named ("Alice", "Bob"), are authoritative. Use those exact labels when attributing quotes, decisions, and action items. Do not invent names for generic labels. Do not collapse two different speakers into one.
    """

    var systemPrompt: String {
        switch self {
        case .minutes:
            return """
            You are a professional meeting minutes formatter. Given a speaker-labeled transcript, produce clean, well-structured meeting minutes. Include:
            - Date and duration at the top
            - List of participants (from speaker labels)
            - Discussion topics organized by subject
            - Decisions made
            - Action items with owners
            - Next steps
            Use clear headers and bullet points. Be concise but capture all key points. Do not add information not in the transcript.
            """
        case .actionItems:
            return """
            You are an action item extractor. Given a speaker-labeled transcript, identify every action item, task, commitment, or follow-up mentioned. For each item provide:
            - The action to be taken
            - Who is responsible (use speaker labels if names aren't given)
            - Any deadline or timeframe mentioned
            - Context (brief note on why)
            Format as a numbered list. Only include items that are actual commitments or tasks, not general discussion points.
            """
        case .summary:
            return """
            You are a meeting summarizer. Given a speaker-labeled transcript, produce a concise executive summary. Include:
            - One paragraph overview of what was discussed
            - Key topics covered (2-3 sentences each)
            - Main outcomes and conclusions
            Keep it under 500 words. Focus on what matters, skip small talk and pleasantries.
            """
        case .keyDecisions:
            return """
            You are a decision tracker. Given a speaker-labeled transcript, identify every decision, agreement, or conclusion reached during the meeting. For each:
            - State the decision clearly
            - Note who proposed or agreed to it
            - Include any conditions or caveats mentioned
            Format as a numbered list. Only include actual decisions, not proposals that were discussed but not agreed upon.
            """
        case .fullReport:
            return """
            You are a meeting report writer. Given a speaker-labeled transcript, produce a complete narrative report of the meeting. Include:
            - A short overview paragraph (what the meeting covered and who took part)
            - Detailed discussion of each topic, in the order it came up, attributing points to the speakers who raised or drove them
            - Decisions reached, with who agreed
            - Action items with owners and any deadlines mentioned
            - Open questions or unresolved points
            Write in clear prose with section headers. Be thorough but do not pad or repeat. Do not add information that isn't in the transcript.
            """
        case .custom:
            // The service overrides this with the user's stored instructions
            // via customFullSystemPrompt(instructions:); this keeps the enum's
            // prompt accessors total for the empty-instructions case.
            return "Format the speaker-labeled transcript into a clear, well-structured document following the user's instructions."
        }
    }

    /// Full system prompt used by the meeting formatter. Appends the shared
    /// speaker-label rule so attributions survive formatting regardless of
    /// which `MeetingFormat` the user picked.
    var fullSystemPrompt: String {
        systemPrompt + "\n\n" + Self.speakerLabelRule
    }

    /// System prompt for the Custom format: the user's instructions as the main directive, like
    /// dictation's Custom template, plus the speaker-label rule. Uses a neutral directive when
    /// there are no instructions yet.
    static func customFullSystemPrompt(instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let directive: String
        if trimmed.isEmpty {
            directive = "Format the speaker-labeled transcript into a clear, well-structured document. Use headers and bullet points where they help."
        } else {
            directive = """
            Follow these instructions as your primary directive when formatting the speaker-labeled transcript. They take priority over any default structure:

            \(trimmed)
            """
        }
        return directive + "\n\n" + speakerLabelRule
    }
}

// MARK: - Formatter State

enum FormatterState: Equatable {
    case idle
    /// Copies the byte counts into the case so SwiftUI sees each progress update as a change; a
    /// shared Progress reference would always compare equal.
    case downloading(completedBytes: Int64, totalBytes: Int64, progress: Progress)
    case loading
    /// `note` carries a stage hint shown while `output` is still empty (e.g.
    /// the map-reduce "Working through the transcript in sections" progress).
    /// Cleared to nil once real output starts streaming.
    case generating(output: String, note: String?)
    case complete(output: String)
    case error(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .loading, .generating: true
        default: false
        }
    }

    static func == (lhs: FormatterState, rhs: FormatterState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case let (.downloading(aCompleted, aTotal, _), .downloading(bCompleted, bTotal, _)):
            return aCompleted == bCompleted && aTotal == bTotal
        case (.loading, .loading): return true
        case let (.generating(aOut, aNote), .generating(bOut, bNote)):
            return aOut == bOut && aNote == bNote
        case (.complete(let a), .complete(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Meeting Formatter Backend

/// Local meeting formatter choices. Gemma runs in-process; Apple Intelligence
/// availability and context size are managed by macOS.
enum MeetingFormatterBackend: String, CaseIterable, Identifiable, Sendable {
    case gemma4E2B = "gemma4-e2b"
    case gemma4E4B = "gemma4-e4b"
    case gemma4_12B = "gemma4-12b"
    case appleIntelligence = "apple-intelligence"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma4E2B: return "Gemma 4 E2B"
        case .gemma4E4B: return "Gemma 4 E4B"
        case .gemma4_12B: return "Gemma 4 12B"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }

    /// MLX registry config for the Gemma backends. Nil for Apple Intelligence
    /// because AFM is OS-provided and has no HF registry entry.
    var registryConfig: ModelConfiguration? {
        switch self {
        case .gemma4E2B: return LLMRegistry.gemma4_e2b_it_4bit
        case .gemma4E4B: return LLMRegistry.gemma4_e4b_it_4bit
        case .gemma4_12B: return ModelConfiguration(id: "mlx-community/gemma-4-12B-it-4bit", extraEOSTokens: ["<turn|>"])
        case .appleIntelligence: return nil
        }
    }

    var diskSize: String {
        switch self {
        case .gemma4E2B: return "3 GB"
        case .gemma4E4B: return "5.2 GB"
        case .gemma4_12B: return "6.8 GB"
        case .appleIntelligence: return "0 GB"
        }
    }

    var description: String {
        switch self {
        case .gemma4E2B: return "Lighter model. Fast, good for short meetings."
        case .gemma4E4B: return "Balanced speed and meeting notes."
        case .gemma4_12B: return "Larger model for complex notes. Slower; 24 GB+ recommended."
        case .appleIntelligence: return "Free, ships with macOS. Best for short meetings."
        }
    }

    /// Transcript character limit for Apple Intelligence, from the live context window (4,096
    /// tokens on macOS 26, 8,192 where macOS 27 supports it). The window minus about 600 tokens for
    /// output, at 3.5 characters per token, the same conservative rate as `estimatedTokens`, so the
    /// UI check and the service agree. Computed per call because the window is queried at runtime.
    static var afmTranscriptCharLimit: Int {
        Int(Double(DictationFormatterService.afmContextSize() - 600) * 3.5)
    }

    /// Usable context in tokens. Gemma transcripts past about 70% of it switch to map-reduce
    /// instead of one oversized prompt. Gemma's model card lists 128K, but 16K matches dictation
    /// Refine and keeps time to first token bounded. Apple Intelligence is queried live and refuses
    /// transcripts that don't fit instead of using map-reduce.
    var contextTokenCap: Int {
        switch self {
        case .gemma4E2B, .gemma4E4B, .gemma4_12B: return 16_384
        case .appleIntelligence: return DictationFormatterService.afmContextSize()
        }
    }

    /// True when this backend's weights are already downloaded, to prefer a local Gemma model over
    /// a first-run download. Apple Intelligence availability is checked separately.
    var isDownloaded: Bool {
        guard let config = registryConfig else { return true } // AFM
        // HF stores each repo as models--{org}--{repo}/snapshots/{commit}/…
        let folderName = "models--" + config.name.replacingOccurrences(of: "/", with: "--")
        let snapshots = HubCache.default.cacheDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let fm = FileManager.default
        guard let commits = try? fm.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil
        ) else { return false }
        return commits.contains(where: Self.isCompleteSnapshot)
    }

    static func isCompleteSnapshot(_ directory: URL) -> Bool {
        func hasFile(_ name: String) -> Bool {
            let url = directory.appendingPathComponent(name).standardizedFileURL
            guard url.path.hasPrefix(directory.standardizedFileURL.path + "/") else { return false }
            guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
        guard ["config.json", "tokenizer.json", "tokenizer_config.json"].allSatisfy(hasFile) else { return false }
        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            guard let data = try? Data(contentsOf: index),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weights = json["weight_map"] as? [String: String], !weights.isEmpty else { return false }
            return Set(weights.values).allSatisfy { $0.hasSuffix(".safetensors") && hasFile($0) }
        }
        return hasFile("model.safetensors")
    }
}

// MARK: - Hardware Detection

enum HardwareCapability {
    case insufficient  // < 16 GB
    case capable       // >= 16 GB

    static var current: HardwareCapability {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let gb = totalRAM / (1024 * 1024 * 1024)
        return gb < 16 ? .insufficient : .capable
    }

    /// Backends this Mac can run. Apple Intelligence runs outside SideWave's memory, so it's
    /// offered on every Mac when available. Gemma loads several gigabytes into SideWave, so it
    /// needs 16 GB.
    var availableBackends: [MeetingFormatterBackend] {
        switch self {
        case .insufficient: return [.appleIntelligence]
        case .capable: return MeetingFormatterBackend.allCases
        }
    }

    /// True when at least one formatting backend is available. Apple
    /// Intelligence is always a candidate, so meeting formatting is offered on
    /// every Mac (an 8 GB Apple Intelligence Mac still formats via AFM).
    var isSupported: Bool { !availableBackends.isEmpty }
}
