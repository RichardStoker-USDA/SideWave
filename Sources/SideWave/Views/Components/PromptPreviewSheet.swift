// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import AppKit
import SwiftUI

// MARK: - Prompt Preview Sheet

/// Modal sheet showing the full prompt the cleanup model receives, given the
/// user's current settings. The preview is a snapshot taken at sheet presentation.
struct PromptPreviewSheet: View {
    let previewBuilder: () -> DictationFormatterService.PromptPreview
    let onClose: () -> Void
    @State private var preview: DictationFormatterService.PromptPreview?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let preview {
                content(preview: preview)
            } else {
                // Brief placeholder while snapshot initializes (typically 1 frame)
                Color.clear.frame(width: 640, height: 620)
            }
        }
        .onAppear {
            if preview == nil {
                preview = previewBuilder()
            }
        }
    }

    @ViewBuilder
    private func content(preview: DictationFormatterService.PromptPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Prompt Preview")
                    .font(.headline)
                Text("A sample Refine request using your current settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("SAMPLE DICTATION")
                    .technicalLabel()
                Text(preview.sampleDictation)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("SYSTEM INSTRUCTIONS")
                    .technicalLabel()
                PromptTextContainer(text: preview.systemInstructions)
                    .frame(maxHeight: 110)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("USER PROMPT")
                    .technicalLabel()
                PromptTextContainer(text: preview.userPrompt)
                    .frame(maxHeight: 260)
            }

            Text("Vocabulary and instructions reflect your settings. Apple Intelligence also uses system instructions and a response schema.")
                .settingsCaption()

            SettingsDivider()

            HStack(spacing: Spacing.sm) {
                Button("Copy Prompt") {
                    let combined = """
                    [SYSTEM INSTRUCTIONS]
                    \(preview.systemInstructions)

                    [USER PROMPT]
                    \(preview.userPrompt)
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(combined, forType: .string)
                }
                .actionButton()
                .accessibilityLabel("Copy the full prompt to the clipboard")

                Spacer()

                Button("Close") { onClose() }
                    .prominentActionButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 640, height: 620)
    }
}

/// Subtle inset container for monospaced prompt text. Scrolls internally if
/// content overflows; the parent sheet holds its fixed size.
struct PromptTextContainer: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(
            colorScheme == .dark
                ? Color.white.opacity(0.04)
                : Color.black.opacity(0.035)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.66)
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    }
}

