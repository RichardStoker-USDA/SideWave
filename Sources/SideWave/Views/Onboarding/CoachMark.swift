// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

struct CoachMark: View {
    let step: TutorialStep
    let currentStepIndex: Int
    let totalSteps: Int
    let hotkeyDisplayString: String
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SideWave basics")
                Spacer()
                Text("\(currentStepIndex + 1) of \(totalSteps)").monospacedDigit()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(step.title, systemImage: step.icon)
                        .font(.system(size: 21, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(resolvedBody)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hints = step.keyboardHints, !hints.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                                HStack(spacing: 12) {
                                    Text(hint.label).foregroundStyle(.secondary)
                                    Spacer()
                                    HStack(spacing: 3) {
                                        ForEach(Array(resolvedKeySegments(hint.keys).enumerated()), id: \.offset) { _, segment in
                                            KeyCapView(key: segment)
                                        }
                                    }
                                }
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().padding(.bottom, 18)
            HStack(spacing: 12) {
                Button("Close Tutorial", action: onSkip)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 12)
                Button("Back", action: onBack)
                    .actionButton()
                    .disabled(currentStepIndex == 0)
                Button(currentStepIndex < totalSteps - 1 ? "Next" : "Done", action: onNext)
                    .prominentActionButton()
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: CoachMarkSize.width, height: CoachMarkSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tutorial step \(currentStepIndex + 1) of \(totalSteps): \(step.title)")
    }

    // MARK: - Hotkey Substitution

    private var resolvedBody: String {
        step.body.replacingOccurrences(of: "{hotkey}", with: hotkeyDisplayString)
    }

    /// Parse key string into keycap segments, substituting {hotkey} first
    private func resolvedKeySegments(_ keys: String) -> [String] {
        let resolved = keys.replacingOccurrences(of: "{hotkey}", with: hotkeyDisplayString)
        return parseKeySegments(resolved)
    }

    /// Parse a key string like "\u{2318}\u{21E7}R" into individual segments for keycaps.
    /// Recognizes modifier symbols, standalone words, and special keys.
    private func parseKeySegments(_ keys: String) -> [String] {
        let modifiers: Set<Character> = [
            "\u{2318}", // Cmd
            "\u{21E7}", // Shift
            "\u{2325}", // Option
            "\u{2303}", // Control
        ]

        // Handle "+" separated compound keys like "\u{2318}+Click"
        if keys.contains("+") && !keys.hasPrefix("+") {
            return keys.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        // Handle space-separated tokens like "Escape" or "hotkey x2"
        if keys.contains(" ") && !keys.contains("(") {
            let parts = keys.components(separatedBy: " ").filter { !$0.isEmpty }
            if parts.count > 1 {
                // A modifier-side qualifier ("Left"/"Right") belongs to the
                // glyph it precedes, so "Right ⌥" renders as one keycap instead
                // of splitting into a word-keycap plus a symbol-keycap.
                let sideWords: Set<String> = ["Left", "Right"]
                var merged: [String] = []
                var index = 0
                while index < parts.count {
                    if sideWords.contains(parts[index]), index + 1 < parts.count {
                        merged.append(parts[index] + " " + parts[index + 1])
                        index += 2
                    } else {
                        merged.append(parts[index])
                        index += 1
                    }
                }
                var segments: [String] = []
                for part in merged {
                    // A merged side segment already carries its space and is a
                    // finished keycap label; don't recurse and re-split it.
                    if part.contains(" ") {
                        segments.append(part)
                    } else {
                        segments.append(contentsOf: parseKeySegments(part))
                    }
                }
                return segments
            }
        }

        var segments: [String] = []
        var remaining = ""

        for char in keys {
            if modifiers.contains(char) {
                if !remaining.isEmpty {
                    segments.append(remaining)
                    remaining = ""
                }
                segments.append(String(char))
            } else {
                remaining.append(char)
            }
        }

        if !remaining.isEmpty {
            segments.append(remaining)
        }

        return segments.isEmpty ? [keys] : segments
    }

}

