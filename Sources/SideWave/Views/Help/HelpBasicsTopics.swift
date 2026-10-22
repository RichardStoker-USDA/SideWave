// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Getting Started

struct HelpGettingStartedContent: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HelpCard {
            Text("Your first dictation").font(.headline)
            step(1, title: "Complete setup", detail: "Open SideWave and follow the readiness steps. Allow Microphone access to record and Accessibility access for the shortcut and text delivery. Prepare the speech model; downloads and first-use preparation show their progress.")
            Divider()
            step(2, title: "Select a template and microphone", detail: "On Home, choose your microphone and Template. Standard, Professional, and Concise refine text for pasting into an app. As spoken skips model refinement. Email, Instructions, AI Prompt, and Custom open a document for review and editing.")
            Divider()
            step(3, title: "Speak, finish, then review", detail: "Place your cursor in the destination app and tap your shortcut. Wait for Listening, then speak. Tap again to finish. SideWave shows processing until your text is ready. Ordinary dictation pastes into the chosen destination; document templates keep the result in the document preview.")
            HelpDeepLinkButton(label: "Open Home", systemImage: "macwindow", targetPage: .home, targetSettingsTab: nil, spotlightKey: nil)
        }

        HelpCard {
            Text("Your shortcut").font(.headline)
            HStack {
                KeyCapRow(displayString: appState.hotkeyManager.shortcut.displayString)
                Spacer()
                HelpDeepLinkButton(label: "Change shortcut", systemImage: "keyboard", targetPage: nil, targetSettingsTab: .settingsGeneral, spotlightKey: "hotkey")
            }
            HelpItem(title: "Tap to start and finish", content: "Use one tap at each end of a dictation. Double-tap to paste the last result again. Choose Tap to Toggle, Hold to Talk beside Shortcut on Home if you also want to hold the key while speaking and release to finish.")
            HelpItem(title: "Keep unfinished words", content: "Escape stops an ordinary dictation and keeps it as Paused dictation on Home without pasting. Control-Escape cancels it and saves what was captured to History. A document keeps its own draft and pending additions.")
            HelpInternalButton(label: "All shortcut behaviors", systemImage: "keyboard", targetSection: .hotkeySetup)
        }

        HelpCard {
            Text("Everyday controls stay on Home").font(.headline)
            HelpItem(title: "Template, Refine model, and Output language", content: "Choose the shape and language of your output. Formatting Rules adds your own instructions. Refine preparation is shown below these controls; models run locally after their initial download.")
            HelpItem(title: "Microphone and Send to", content: "Choose an input and whether ordinary dictation goes to the app focused at the start, at the finish, or to a specific window. Document templates use the document preview.")
            HelpItem(title: "Simple and Advanced", content: "Both use the same layout and keep the same everyday controls. Advanced adds recording, delivery, and pipeline options below recent output. Switching views does not change your model or processing settings.")
        }

        HelpCard {
            Text("Vocabulary, history, and meetings").font(.headline)
            HelpItem(title: "Vocabulary", content: "Create a glossary for names, acronyms, and specialist terms. Add the spelling you want, pronunciations, and phrases to replace. No glossaries are added automatically.")
            HelpDeepLinkButton(label: "Open Vocabulary", systemImage: "character.book.closed", targetPage: .dictionary, targetSettingsTab: nil, spotlightKey: nil)
            Divider()
            HelpItem(title: "History", content: "Find completed dictations, copy output, or expand an entry to compare its available earlier stages. Model names appear only when refinement ran.")
            HelpDeepLinkButton(label: "Open History", systemImage: "clock.arrow.circlepath", targetPage: .history, targetSettingsTab: nil, spotlightKey: nil)
            Divider()
            HelpItem(title: "Meetings", content: "Enable Meetings in Settings to record longer conversations, review speaker labels, and prepare local meeting notes.")
            HelpDeepLinkButton(label: "Meeting settings", systemImage: "person.3", targetPage: nil, targetSettingsTab: .settingsMeetings, spotlightKey: nil)
        }

        HelpCard {
            Text("If setup needs attention").font(.headline)
            Text("A readiness message names the missing permission or model. You can always open Settings from Help, including before setup is complete.")
                .font(.callout).adaptiveSecondary().fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Button("Accessibility Settings") { AppDelegate.openAccessibilitySettings() }
                    Button("Microphone Settings") { AppDelegate.openMicrophoneSettings() }
                }
                VStack(alignment: .leading) {
                    Button("Accessibility Settings") { AppDelegate.openAccessibilitySettings() }
                    Button("Microphone Settings") { AppDelegate.openMicrophoneSettings() }
                }
            }
            .actionButton()
            HelpInternalButton(label: "Troubleshooting", systemImage: "wrench.and.screwdriver", targetSection: .troubleshooting)
        }
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text("\(number)").font(.callout.weight(.semibold)).monospacedDigit()
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.05), in: Circle())
                .accessibilityLabel("Step \(number)")
            HelpItem(title: title, content: detail)
        }
    }
}

// MARK: - Audio Wave Showcase

struct HelpAudioWaveShowcaseContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || appState.reduceAppMotion }

    var body: some View {
        showcaseCard(
            heading: "Getting ready",
            body: "After you press the shortcut, a small panel with a slowly breathing wave says Ready to speak in a moment. The full preview replaces it when SideWave is listening, so start talking then. The first start after installing or updating can take a minute while the speech models compile.",
            style: .gettingReady
        )

        showcaseCard(
            heading: "While you speak",
            body: "The full spectrum follows the loudness of your voice and ripples gently when you pause.",
            style: .listening
        )

        showcaseCard(
            heading: "Refining with Apple Intelligence",
            body: "The colors shift to purple and pink while Apple Intelligence refines part of your dictation. The wave keeps reacting to your voice.",
            style: .refining(.appleIntelligence)
        )

        showcaseCard(
            heading: "Refining with Gemma",
            body: "The colors shift to blue while Gemma refines. The wave keeps reacting to your voice.",
            style: .refining(.gemma)
        )

        showcaseCard(
            heading: "Finishing",
            body: "After you finish, slower ribbons in the Refine model's colors run while the last text is checked, with a written status above them. They no longer follow your voice.",
            style: .finishing
        )

        HelpHint("Home, SideWave Mini, and the document preview show a quiet line in your accent color while models prepare. The refine colors appear only while a model is working. With Reduce Motion on, the wave stays still and the status text stays visible.")
    }

    private enum WaveStyle {
        case gettingReady
        case listening
        case refining(RefiningBackendForPalette)
        case finishing
    }

    @ViewBuilder
    private func showcaseCard(heading: String, body bodyText: String, style: WaveStyle) -> some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(heading)
                    .font(.headline)
                Text(bodyText)
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 30.0, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let level = reduceMotion ? 0.4 : (0.35 + 0.35 * abs(sin(t * 2.0)))
                    switch style {
                    case .gettingReady:
                        AudioWaveVisualizer(audioLevel: 0, colorMode: "rainbow", sensitivity: 0.5, liquidGlass: false,
                                            isIdleBreathing: true, reduceMotion: reduceMotion)
                            .accessibilityHidden(true)
                            .frame(height: 56)
                    case .listening:
                        AudioWaveVisualizer(audioLevel: level, colorMode: "rainbow", sensitivity: 0.7, liquidGlass: false,
                                            reduceMotion: reduceMotion)
                            .accessibilityHidden(true)
                            .frame(height: 56)
                    case .refining(let backend):
                        AudioWaveVisualizer(audioLevel: level, colorMode: "rainbow", sensitivity: 0.7, liquidGlass: false,
                                            isRefining: true, refiningBackend: backend, reduceMotion: reduceMotion)
                            .accessibilityHidden(true)
                            .frame(height: 56)
                    case .finishing:
                        AudioWaveVisualizer(audioLevel: 0, colorMode: "rainbow", sensitivity: 0.7, liquidGlass: false,
                                            isCleanupMode: true, isRefining: true, refiningBackend: .appleIntelligence,
                                            reduceMotion: reduceMotion)
                            .accessibilityHidden(true)
                            .frame(height: 56)
                    }
                }
            }
        }
    }
}

// MARK: - How Dictation Works

struct HelpHowDictationWorksContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("From hotkey to paste")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    flowStep("1.", "Press the hotkey to start dictating.")
                    flowStep("2.", "A small panel appears while SideWave gets ready, then the full preview with the wave.")
                    flowStep("3.", "When the preview shows Listening, speak naturally. Live text appears in the preview as you talk.")
                    flowStep("4.", "With Refine on, the local model cleans up each finished segment. As spoken skips Refine.")
                    flowStep("5.", "Tap the hotkey again to finish. The preview shows progress while the last segment is recognized and refined.")
                    flowStep("6.", "SideWave pastes into the app you chose. Document templates open the result in the document window.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The stages")
                    .font(.headline)

                HelpItem(
                    title: "Audio Capture",
                    content: "SideWave records from the microphone you chose. The Dictation Mode decides whether the streaming draft runs alongside the main recognizer."
                )

                HelpItem(
                    title: "Live Draft (Parakeet EOU 120M)",
                    content: "A streaming recognizer reads the audio in 160-millisecond chunks and writes the gray draft almost as fast as you speak. It trades accuracy for speed, so the draft can mishear. The main transcriber corrects it as each segment finalizes, which is why gray words can change as they turn solid. This model also detects the end of an utterance, and Smart Push-to-Talk pastes its text on release."
                )

                HelpItem(
                    title: "VAD Segmentation",
                    content: "Silero VAD marks speech and pauses in the audio. Depending on the refine cadence, a pause can end a segment, so the transcriber works on short stretches of speech."
                )

                HelpItem(
                    title: "Parakeet TDT Transcription",
                    content: "Each segment goes through NVIDIA Parakeet TDT, a 600-million-parameter model on the Apple Neural Engine. It sees the whole segment, so its text replaces the draft, and only its text moves on to the stages below."
                )

                HelpItem(
                    title: "CTC Vocabulary Boosting",
                    content: "With a glossary turned on, the CTC 110M model scores your terms and the transcriber's words against the audio. It swaps in a term only when the audio matches it better than the original word. This runs on the live preview about every 1.5 seconds and again on each finished segment."
                )

                HelpItem(
                    title: "Paste",
                    content: "SideWave picks a delivery method for the target field: Accessibility, simulated keys, or a clipboard paste. It checks the result when the app exposes its text. If delivery fails, the text is saved to History."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Segments")
                    .font(.headline)

                Text("SideWave doesn't wait until you stop talking to transcribe. Audio is split into segments of at most 14.8 seconds, because the Parakeet encoder handles at most 15 seconds per pass. A pause can end a segment early once it has at least 3 seconds of audio.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                Text("When live Refine runs, the refine cadence decides whether pauses end segments. Standard waits for the 14.8-second ceiling, Faster ends a segment after about 3 seconds of silence, and Aggressive after about 2. Document templates use a 5-second pause. On Macs with 16 GB of memory or more, SideWave starts with Faster plus an 8-second fixed interval, so long stretches of speech get refined before the ceiling. Without live Refine, segments end at pauses of about 3 seconds. Change the cadence in Settings > Refine > Expert, shown in Advanced view.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                Text("Each segment is transcribed on its own; the speech model doesn't carry context from the previous segment. Within a segment it sees all the audio so far, so its text improves as you keep speaking. Refine can use the preceding text as context.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("If SideWave crashes mid-dictation")
                    .font(.headline)

                Text("Finished segments are written to a recovery journal on this Mac, and the segment in progress is saved about every 1.5 seconds. After a crash, SideWave recovers that text into History at the next launch and then deletes the journal. A disk error can still leave gaps.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Why the preview changes")
                    .font(.headline)

                Text("While you speak, SideWave transcribes the current segment again every 0.4 to 0.8 seconds. With more audio, the model can revise earlier words: \"their\" after 2 seconds might become \"there\" after 5. The text for a finished segment is the most accurate.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Text cleanup")
                    .font(.headline)

                Text("Each finished segment goes through these steps before Refine:")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    pipelineStep("1.", "Filler words", "Removes \"um\", \"uh\", \"hmm\", and similar sounds.")
                    pipelineStep("2.", "Text normalization", "Writes spoken numbers, dates, times, and amounts as digits.")
                    pipelineStep("3.", "Profanity filter", "If turned on, masks profanity with asterisks or swaps in milder words.")
                    pipelineStep("4.", "Vocabulary replacements", "Swaps in your spelling for words set to Replace at dictation, in every glossary that's on.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Processing time / audio time")
                    .font(.headline)

                Text("Advanced view shows processing time divided by audio length. At 0.5x, 10 seconds of audio took 5 seconds to transcribe. It counts recognition only, not loading, refining, or pasting.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpHint("Home in Advanced view shows live segment counts, recognition confidence, and Processing / audio while you dictate.")

        HelpCard {
            HelpPipelineDiagram()
        }
    }

    private func flowStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(number)
                .font(.callout.weight(.medium))
                .adaptiveSecondary()
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.callout)
                .adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pipelineStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(number)
                .font(.callout.weight(.medium))
                .adaptiveSecondary()
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PipelineStage: Identifiable {
    let id: Int
    let label: String
    let title: String
    let description: String
}

struct PipelineStageRow: View {
    let stage: PipelineStage

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 24, height: 24)
                Text("\(stage.id + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(stage.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text(stage.title)
                        .font(.callout.weight(.medium))
                }
                Text(stage.description)
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Static, stage-by-stage diagram of the on-device pipeline, with a worked example.
struct HelpPipelineDiagram: View {
    @Environment(\.colorScheme) private var colorScheme

    private let stages = [
        PipelineStage(id: 0, label: "Mic", title: "Audio Capture", description: "Audio enters the pipeline once the microphone is ready. Wait for Listening before speaking."),
        PipelineStage(id: 1, label: "Draft", title: "Streaming Preview", description: "A streaming recognizer shows a gray draft almost immediately. It is a fast first guess that the next stage corrects."),
        PipelineStage(id: 2, label: "VAD", title: "Voice Segmentation", description: "Silero VAD detects speech and the pauses that can end a segment."),
        PipelineStage(id: 3, label: "TDT", title: "Parakeet Transcriber", description: "The 600M-parameter model turns each segment into text on the Neural Engine, confirming or correcting the draft."),
        PipelineStage(id: 4, label: "CTC", title: "Vocabulary Boosting", description: "When your terms match the audio better, the CTC model swaps them in."),
        PipelineStage(id: 5, label: "ITN", title: "Text Normalization", description: "Spoken numbers, dates, and currency become their written form."),
        PipelineStage(id: 6, label: "Refine", title: "Language Refine", description: "Gemma 4 or Apple Intelligence trims filler and fixes grammar, segment by segment.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("The Pipeline, Stage by Stage")
                .font(.headline)
            Text("Every stage runs on this Mac. Your Dictation Mode, glossaries, and Refine settings decide which ones run:")
                .font(.caption)
                .adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { idx, stage in
                    PipelineStageRow(stage: stage)
                        .padding(.vertical, 5)
                    if idx < stages.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(width: 1, height: 8)
                            .padding(.leading, 11)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("A worked example")
                    .font(.caption.weight(.semibold))
                    .adaptiveSecondary()
                exampleLine("You say", "so um we should use sign it for scientific research at a r s", color: .secondary)
                exampleLine("Gray draft shows", "so um we should use sign at for scientific research at a rs", color: .secondary)
                exampleLine("TDT confirms", "we should use sign it for scientific research at ARS", color: .primary)
                exampleLine("Vocabulary check", "\"sign it\" becomes SCINet because the audio matches it better", color: Color.accentColor)
                exampleLine("Refined", "We should use SCINet for scientific research at ARS.", color: .primary, bold: true)
            }
            .padding(Spacing.md)
            .background(.ultraThinMaterial)
            .continuousCorner(CornerRadius.lg)
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    private func exampleLine(_ label: String, _ text: String, color: Color, bold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .adaptiveTertiary()
                .textCase(.uppercase)
            Text(text)
                .font(.system(.caption, design: .monospaced).weight(bold ? .bold : .regular))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
