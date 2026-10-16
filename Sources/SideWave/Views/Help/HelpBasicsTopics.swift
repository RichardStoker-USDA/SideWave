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
            HelpItem(title: "Tap to start and finish", content: "Use one tap at each end of a dictation. Double-tap to paste the last result again. Choose Tap or hold on Home if you also want to hold the key while speaking and release to finish.")
            HelpItem(title: "Keep unfinished words", content: "Escape stops an ordinary dictation and keeps it as Paused dictation on Home without pasting. Control-Escape discards it. A document keeps its own draft and pending additions.")
            HelpInternalButton(label: "All shortcut behaviors", systemImage: "keyboard", targetSection: .hotkeySetup)
        }

        HelpCard {
            Text("Everyday controls stay on Home").font(.headline)
            HelpItem(title: "Template, Refine model, and Output language", content: "Choose the shape and language of your output. Formatting rules adds your own instructions. Refine preparation is shown below these controls; models run locally after their initial download.")
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
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            heading: "While you speak",
            body: "The full spectrum follows the loudness of your voice. Before recording starts it moves gently in place.",
            isRefining: false,
            isWarmingUp: false,
            backend: .appleIntelligence
        )

        showcaseCard(
            heading: "Getting ready",
            body: "A quiet line while the microphone and models start. Wait for Listening before you speak; the microphone may not be recording yet.",
            isRefining: false,
            isWarmingUp: true,
            backend: .appleIntelligence
        )

        showcaseCard(
            heading: "Refining with Apple Intelligence",
            body: "The colors shift to purple and pink while Apple Intelligence refines part of your dictation.",
            isRefining: true,
            isWarmingUp: false,
            backend: .appleIntelligence
        )

        showcaseCard(
            heading: "Refining with Gemma",
            body: "The colors shift to blue while Gemma refines. The wave keeps reacting to your voice.",
            isRefining: true,
            isWarmingUp: false,
            backend: .gemma
        )

        HelpHint("The colors change only while the model is working. Finishing and document editing also show a written status. With Reduce Motion on, the wave stays still and the status stays visible.")
    }

    @ViewBuilder
    private func showcaseCard(
        heading: String,
        body bodyText: String,
        isRefining: Bool,
        isWarmingUp: Bool,
        backend: RefiningBackendForPalette
    ) -> some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(heading)
                    .font(.headline)
                Text(bodyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 30.0, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let level = reduceMotion ? 0.4 : (0.35 + 0.35 * abs(sin(t * 2.0)))
                    AudioWaveVisualizer(
                        audioLevel: level,
                        colorMode: "rainbow",
                        sensitivity: 0.7,
                        liquidGlass: false,
                        isCleanupMode: false,
                        isRefining: isRefining,
                        isWarmingUp: isWarmingUp,
                        refiningBackend: backend
                    )
                    .accessibilityHidden(true)
                    .frame(height: 56)
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
                Text("The Flow")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    flowStep("1.", "Press the hotkey to start dictating.")
                    flowStep("2.", "The overlay appears with a wave visualizer.")
                    flowStep("3.", "Speak naturally. Live transcription text appears in the overlay as you talk.")
                    flowStep("4.", "With live Refine enabled, the local model cleans up completed segments. As spoken keeps recognition text without a model refinement pass.")
                    flowStep("5.", "Tap the hotkey again to finish. SideWave shows progress while remaining recognition or refinement completes. The optional Rewrite and finish gesture requests a full-session pass.")
                    flowStep("6.", "Ordinary dictation is delivered to the selected app. Document templates show the result in a preview for review, editing, and copying.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Behind the scenes")
                    .font(.headline)

                HelpItem(
                    title: "Audio Capture",
                    content: "SideWave captures audio from your selected input. The chosen engine preset controls whether the streaming preview runs alongside the main recognizer."
                )

                HelpItem(
                    title: "Live Draft (Parakeet EOU 120M)",
                    content: "A dedicated streaming recognizer processes the audio in 160-millisecond chunks and paints the gray draft text in the overlay almost as fast as you speak. It favors speed over accuracy, so the draft can mishear. That's expected. The main transcriber below corrects it as each segment finalizes, which is why gray words sometimes change as they turn white. This model also detects when you've finished an utterance, and Smart Push-to-Talk uses its instant text for the fast paste on release."
                )

                HelpItem(
                    title: "VAD Segmentation",
                    content: "During dictation, Voice Activity Detection (Silero VAD) monitors the audio stream and finds natural pauses in your speech. These pauses become segment boundaries, so the transcription engine processes manageable chunks rather than one long stream."
                )

                HelpItem(
                    title: "Parakeet TDT Transcription",
                    content: "Each audio segment goes through NVIDIA's Parakeet TDT model, a 600-million parameter speech recognition model running on the Apple Neural Engine. It sees the whole segment with full context, so its output is the authority: it confirms the streaming draft's words or replaces them, and only its text moves on to the stages below."
                )

                HelpItem(
                    title: "CTC Vocabulary Boosting",
                    content: "When any Vocabulary glossary is enabled, every entry, regardless of scope, is fed to the CTC 110M model for acoustic-evidence-based boosting. The CTC rescorer scores both your vocabulary terms and the main model's output against the actual audio frames, and only replaces the original word when your term has stronger acoustic evidence. This catches proper nouns, technical jargon, and other words the main model might miss or misspell. Boosting runs on the live preview (throttled to once per ~1.5 seconds) and at every segment finalization, so vocabulary corrections appear in real time."
                )

                HelpItem(
                    title: "Paste",
                    content: "SideWave chooses a delivery method for the target field and checks the result when the app exposes readable text. It can use Accessibility, simulated keys, or clipboard paste. If delivery fails, the output is kept for recovery and manual copying."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Segment Architecture")
                    .font(.headline)

                Text("SideWave doesn't wait until you stop talking to transcribe. Audio is split into segments with a 14.8-second maximum and a 3-second minimum. The Parakeet encoder has a hard limit of 15 seconds per pass, so the 14.8-second ceiling keeps a safety margin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("By default, segment boundaries land at the 14.8-second ceiling rather than on every pause. Natural-pause splitting is off under the Standard cadence, so the live preview doesn't collapse each time you stop to think. Two faster cadences opt into pause-based splits: Faster finalizes after about 3 seconds of silence and Aggressive after about 2 seconds, while document templates use a 5-second pause. You can change this in Settings > Refine, under Expert.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Each segment is transcribed independently. The model does not currently carry context from the previous segment. Within a segment, the model sees all accumulated audio and gets progressively more accurate as you keep speaking. Once recognition finalizes a segment, the speech model starts the next one. Refine may use preceding text as context and can revise the final wording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("If SideWave crashes mid-dictation")
                    .font(.headline)

                Text("Finalized text is written to a local recovery journal, and provisional text is checkpointed about every 1.5 seconds. After an interruption, available text is recovered into History. Journals are removed after history saves successfully. Disk failures or unwritten updates can still leave gaps; copy important text if a storage error appears.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Why the Live Preview Changes")
                    .font(.headline)

                Text("While you're speaking, a polling loop re-transcribes the current segment every 0.4 to 0.8 seconds. Because the model sees more audio on each poll, it may revise earlier words as it gains context. A word that looked like \"their\" with 2 seconds of audio might become \"there\" once the model has 5 seconds. This is normal and expected -- the final result after the full segment is processed is the most accurate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Text Processing Pipeline")
                    .font(.headline)

                Text("When a segment finalizes, the text goes through several processing steps before it becomes part of your final output:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    pipelineStep("1.", "Filler word removal", "Strips \"um\", \"uh\", \"like\", and similar filler words.")
                    pipelineStep("2.", "Text normalization (ITN)", "Converts spoken numbers, dates, times, and currency to written form.")
                    pipelineStep("3.", "Profanity filter", "Replaces profanity with milder alternatives (if enabled).")
                    pipelineStep("4.", "Vocabulary substitutions", "Applies aliases from every enabled glossary whose scope includes substitution.")

                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Processing time / audio time")
                    .font(.headline)

                Text("Advanced view shows processing time divided by audio duration. A value of 0.5x means 10 seconds of audio took 5 seconds to transcribe. Lower values mean faster processing. This measures recognition work, not total time spent downloading, loading, refining, or delivering text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpHint("Home > Advanced shows live segment counts, recognition confidence, and Processing / audio while dictating. The ratio is processing time divided by audio duration; a lower value is faster.")

        HelpCard {
            HelpPipelineDiagram()
        }
    }

    private func flowStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(number)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pipelineStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(number)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
        PipelineStage(id: 2, label: "VAD", title: "Voice Segmentation", description: "Silero VAD finds natural pauses so segments break on complete thoughts."),
        PipelineStage(id: 3, label: "TDT", title: "Parakeet Transcriber", description: "The 600M-parameter model turns each segment into text on the Neural Engine, confirming or correcting the draft."),
        PipelineStage(id: 4, label: "CTC", title: "Vocabulary Boosting", description: "When your terms match the audio better, the CTC model swaps them in."),
        PipelineStage(id: 5, label: "ITN", title: "Text Normalization", description: "Spoken numbers, dates, and currency become their written form."),
        PipelineStage(id: 6, label: "Refine", title: "Language Refine", description: "Gemma 4 or Apple Intelligence trims filler and fixes grammar, segment by segment.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("The Pipeline, Stage by Stage")
                .font(.headline)
            Text("These stages run locally when enabled. Your engine preset, glossaries, and Refine choices determine which stages are used. The streaming preview runs alongside the main recognizer:")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                exampleLine("You say", "so um we should use sign it for scientific research at a r s", color: .secondary)
                exampleLine("Gray draft shows", "so um we should use sign at for scientific research at a rs", color: .secondary)
                exampleLine("TDT confirms", "we should use sign it for scientific research at ARS", color: .primary)
                exampleLine("Vocabulary boost", "\"sign it\" becomes SCINet, it matches the audio better", color: Color.accentColor)
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
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(text)
                .font(.system(.caption, design: .monospaced).weight(bold ? .bold : .regular))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
