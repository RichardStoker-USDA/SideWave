// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation
import MLXLMCommon
import MLXHuggingFace
import MLXLLM
import Tokenizers

/// Validate the actual chat template before a loaded model becomes available for dictation.
struct ModelTokenizerLoader: TokenizerLoader {
    struct Failure: LocalizedError {
        let directory: URL
        let files: [String]
        var errorDescription: String? {
            "The model's language files could not be loaded. Retry to repair the download. Your dictation is preserved."
        }
    }

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer: any MLXLMCommon.Tokenizer
        do { tokenizer = try await #huggingFaceTokenizerLoader().load(from: directory) }
        catch {
            try Task.checkCancellation()
            throw Failure(directory: directory, files: ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja"])
        }
        do {
            let tokens = try tokenizer.applyChatTemplate(
                messages: [["role": "system", "content": "Edit the user's text."],
                           ["role": "user", "content": "The recording is ready."]],
                tools: nil, additionalContext: ["enable_thinking": false])
            guard !tokens.isEmpty else { throw Failure(directory: directory, files: []) }
        } catch {
            throw Failure(directory: directory, files: ["tokenizer_config.json", "chat_template.jinja"])
        }
        return tokenizer
    }

    /// Repair an unreadable tokenizer or template once, retaining model weights.
    static func loadContainer(
        from downloader: any Downloader, configuration: ModelConfiguration,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> ModelContainer {
        do {
            return try await LLMModelFactory.shared.loadContainer(from: downloader, using: Self(),
                configuration: configuration, progressHandler: progressHandler)
        } catch let failure as Failure {
            try Task.checkCancellation()
            try ModelSnapshotValidation.removeInvalidFiles(failure.files, at: failure.directory)
            return try await LLMModelFactory.shared.loadContainer(from: downloader, using: Self(),
                configuration: configuration, progressHandler: progressHandler)
        }
    }
}
