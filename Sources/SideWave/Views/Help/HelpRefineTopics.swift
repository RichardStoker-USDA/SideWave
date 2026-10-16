// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Refine

struct HelpRefineContent: View {
    @Environment(\.colorScheme) private var colorScheme

    private func templateResult(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(name)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035))
                .continuousCorner(CornerRadius.sm)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("What it does")
                    .font(.title3.weight(.semibold))
                Text("Refine runs on your Mac as recognition segments finish. It removes hesitations and repairs punctuation and grammar according to the chosen template. Finishing may wait for the remaining audio or Refine work; the session shows that state. If Refine fails or times out, recognition text remains available. Enable Hold to rewrite and finish in Advanced view > Settings > General for an optional full-session pass.")
                    .fixedSize(horizontal: false, vertical: true)

                Text("Choose the Template, Refine model, and Output language on Home. Formatting Rules is on Home and in the document header. Settings > Refine manages model preparation and expert options.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HelpDeepLinkButton(label: "Open Refine Settings", systemImage: "text.badge.checkmark", targetPage: nil, targetSettingsTab: .settingsRefine, spotlightKey: "refine")
                    .padding(.top, 4)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Where to Find Each Control")
                    .font(.headline)
                Text("The same choices stay in sync across these controls:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Complete uses a streaming preview, Parakeet confirmation, and the selected Refine model. Basic keeps both speech engines but skips AI refinement. Minimalistic runs only Parakeet and updates the preview in short batches; its first words can appear later than Basic's.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("In Basic and Minimalistic, gray text can still change. It settles to the normal text color when a segment is confirmed. This short fade is recognition feedback, not AI refinement. The audio wave keeps moving and responding to your microphone. Stop waits for the last speech segment before sending it. Vocabulary and enabled word filters still apply.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Choosing Basic or Minimalistic turns Refine off and unloads its model. Choosing a template afterward enables refinement again; Minimalistic applies it when you finish. Simple and Advanced view do not change the speech engines.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HelpSettingLocationRow(icon: "slider.horizontal.3", title: "Dictation Mode", valueMock: "Complete", location: "Dictation tab, or Home > Advanced > Recognition & refinement")
                HelpSettingLocationRow(icon: "text.badge.checkmark", title: "Refine model", valueMock: "Gemma 4", location: "Home > Refine model, Dictation tab > Refine, or Settings > Refine")
                HelpSettingLocationRow(icon: "text.badge.checkmark", title: "Template", valueMock: "Standard", location: "Home > Template, or Dictation tab > Refine")
                HelpSettingLocationRow(icon: "globe", title: "Output language", valueMock: "As spoken", location: "Home > Output language, or Dictation tab > Refine")
                HelpSettingLocationRow(icon: "pencil", title: "Custom instructions", valueMock: "Edit", location: "Home > Formatting Rules, or the document header")

                HelpAdvancedNote(text: "Formatting Rules is available in both views. Advanced adds the short-session bypass, final-pass strategy, and optional Gemma thinking under Dictation > Refine > Advanced. Refine cadence is in Settings > Refine > Expert.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The Same Dictation, Three Templates")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("What you said")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\"So, um, I was thinking that, you know, we should probably use SCINet for scientific research at ARS because, well, it's a very powerful and useful HPC platform, you know?\"")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .continuousCorner(CornerRadius.sm)
                        .fixedSize(horizontal: false, vertical: true)
                }

                templateResult("Standard", getRefinedDemoText(for: "Standard"))
                templateResult("Professional", getRefinedDemoText(for: "Professional"))
                templateResult("Concise", getRefinedDemoText(for: "Concise"))
            }
        }

        HelpCard {
            Text("Pick a model")
                .font(.title3.weight(.semibold))
            Text("Gemma 4 E2B. About 3 GB on disk. The lighter, faster Gemma option. First use downloads the model from Hugging Face; leave memory available for the speech pipeline and other apps.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Gemma 4 E4B. A larger Gemma variant for longer text, about 5.2 GB on disk. Recommended on Macs with 16 GB of RAM or more. First use downloads it from HuggingFace.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Gemma 4 12B. About 6.8 GB on disk. Offers more capacity for complex instructions, with higher memory use and latency. Recommended for 24 GB or more.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Apple Intelligence. Available on supported Macs with macOS 26 or later. macOS manages its model assets. Availability and context capacity are checked at runtime.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Switch models with Refine model on Home, on the Dictation tab under Refine, or in Settings > Refine.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        HelpCard {
            Text("Templates")
                .font(.title3.weight(.semibold))
            Text("Standard, Professional, and Concise refine your words as you speak. Pick one in Home > Template or the Dictation tab. Document templates are available in the same picker.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Standard. Fixes grammar, punctuation, and transcription errors. Keeps your voice.")
                Text("Professional. Rewrites into professional prose. Fixes grammar, phrasing, and word choice.")
                Text("Concise. Same meaning, fewer words. Removes redundancy aggressively.")
            }
            .font(.callout)
            Text("Email, Instructions, AI Prompt, and Custom are document templates that reformat the whole dictation in one post-recording pass. Select them in Home > Template or the Dictation template picker. Start dictating or choose Open Document to open the document preview. It shares the live overlay's text rendering and waveform, then shows the formatted document for editing and copying. Custom hands the model your instructions directly, with no built-in style layer on top.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        HelpCard {
            Text("Working with a document")
                .font(.title3.weight(.semibold))
            Text("Use the template menu at the top to change document type. Each template keeps a current draft. Recents preserves previous documents, including manual edits, pending additions, and unfinished instructions. Read shows formatted text; Edit text lets you change it directly. AI Prompt keeps its XML visible.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Your hotkey starts a new document and saves the previous one in Recents. Choose Add dictation to continue the open document, or New for a blank page. Live dictation fills the page while recording; Show document lets you review the saved draft. After you finish, the same window shows processing feedback and then the result. Type a change under Change this document and choose Apply, or use Speak change. Stop Edit restores the previous document and keeps the instruction for another attempt.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Activity holds pending additions when automatic appending is off. Append adds a saved segment to the page. Copy copies the finished document, and Undo restores the document before the last applied model edit. If a model cannot apply a change, the message stays in this window and your instruction is preserved.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Output language")
                .font(.title3.weight(.semibold))
            Text("As spoken keeps the language you dictate in. Pick a language instead to translate while cleaning up, such as speaking English and pasting Spanish. Refine is instructed to preserve meaning, names, technical terms, code, and numbers. Review translations before sending, especially names, figures, idioms, and technical content.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Nine languages are offered: English, Spanish, French, German, Italian, Portuguese, Japanese, Korean, and Chinese (Simplified). On Apple Intelligence the list is filtered to what your macOS build supports. Larger Gemma models can be useful for complex multilingual text, with more memory use and processing time. Find the picker on Home or the Dictation tab under Refine; a small globe pill on the live panel reminds you when translation is on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Translated dictations get a Literal back-translation action in History. It generates a literal back-translation and notes about localized phrases. This is another model interpretation, not proof that the original translation was exact. It runs on demand, on your Mac, and the result is saved with the entry.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Custom instructions")
                .font(.title3.weight(.semibold))
            Text("Formatting Rules is a shared instructions field of up to 1,000 characters. It applies across templates. Add project jargon, tone rules, or specific formatting preferences. For the Custom template, your instructions are the primary directive and the model follows them directly with no built-in style layer on top.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Bypass Refine on Short Sessions")
                .font(.title3.weight(.semibold))
            Text("Off by default. Enable this only if you want ordinary dictation under the Minimum words threshold to skip the final Refine pass. Document templates still apply their selected format when Refine is on.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Minimum words (5, 10, 20, or 50, default 10) sets the cutoff. Sessions at or above it refine normally. For ordinary dictation, the gate covers both the automatic stop-time pass and the optional Rewrite and finish pass. Document templates still apply to short input, because their structure is part of the selected output. Per-segment auto-refine is unaffected; it still runs on every finalized segment regardless of word count. Find it on the Dictation tab under Refine > Advanced.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Final Refine Strategy")
                .font(.title3.weight(.semibold))
            Text("Sets how much text is checked when you stop. The default revisits the ending and finishes any text that live Refine did not complete. Find it on the Dictation tab under Refine > Advanced:")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Incremental (default): Refines all unfinished text together with the recent sentence boundary. Earlier completed text stays unchanged.")
                Text("Smart Window: Checks the last sentence or two using earlier text as context. Use Incremental when you need every unfinished segment checked.")
                Text("Full Session: Rewrites the entire dictation. Longer input takes more time. The optional Rewrite and finish gesture also requests a full pass.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        HelpCard {
            Text("If final refinement cannot finish").font(.title3.weight(.semibold))
            Text("SideWave keeps the captured text on Home and in History instead of sending incomplete output. Resume to try again, or copy the captured text. Turning Final refinement pass off sends the current text immediately, including any unrefined words.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Prompt preview")
                .font(.title3.weight(.semibold))
            Text("Preview on the Dictation tab or in Settings > Refine shows a sample request with your instructions, Vocabulary hints, and term descriptions. Apple Intelligence uses template instructions and, for some formats, a response schema. Use the preview to check your wording.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Live streaming and cancel")
                .font(.title3.weight(.semibold))
            Text("As you speak, new and changed words animate into place. Unchanged refined words stay settled. Ordinary stop keeps the captured text visible while the ending is checked. If you enable Rewrite and finish and use its hold gesture, the refined text streams in word by word. Press Escape to stop and keep the raw transcript as a pending dictation on Home, without pasting, so you can review it. Ctrl+Escape cancels and throws the dictation away. Neither one pastes, so you stay in control of what lands.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Vocabulary and Refine")
                .font(.title3.weight(.semibold))
            Text("Refine reads from the Vocabulary tab. Each enabled glossary feeds canonical spellings, aliases, and any description text into the Refine prompt so the model knows your terms. The feed is limited to 30 terms and 600 characters of glossary context across all enabled glossaries, to leave room for your text in the model's context. Words with Send hint to Refine off stay out of it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Glossaries can be linked to specific templates so they auto-enable when you switch. This keeps your prompt budget tight: work jargon loads for Professional, but not for Standard or Concise. Link glossaries from a glossary's \u{2026} menu on the Vocabulary tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Fallbacks")
                .font(.title3.weight(.semibold))
            Text("If Refine cannot finish, the recognition text is kept. Ordinary cleanup has a short time limit; document formatting and optional thinking have longer limits. An invalid response, a document that exceeds the model's context, or an unavailable model produces recovery feedback. The document window keeps that message, your text, and any unfinished edit instruction visible.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("History")
                .font(.title3.weight(.semibold))
            Text("Expand an entry in History and choose Show earlier stages to compare saved recognition and Refine results. Available stages depend on how that session was processed.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Privacy")
                .font(.title3.weight(.semibold))
            Text("Both models process text on your Mac. Gemma 4 uses the GPU through MLX; Apple Intelligence uses Apple's Foundation Models framework. Refine does not send prompts or transcripts to a server. Text you paste into another app follows that app's data policy.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Getting ready")
                .font(.title3.weight(.semibold))
            Text("When you press the shortcut, a small panel says Ready to speak in a moment while the microphone and models start. The full preview appears when SideWave is listening; speak then. A cold first start can take a minute while the speech models compile, and the panel says so after five seconds.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Dual-Stage Refinement")
                .font(.title3.weight(.semibold))
            Text("When live Refine is enabled, document templates first clean speech as ordinary prose while you dictate. After you stop, the chosen template formats the complete text. The document window keeps showing progress until that pass finishes. With Refine enabled, this also runs for short dictations and when the ordinary final pass is off. Use Formatting Rules in the document header to set instructions, or Change this document for a follow-up edit.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("AI Prompt XML Format")
                .font(.title3.weight(.semibold))
            Text("The AI Prompt template converts casual thoughts and constraints into a clean, structured XML prompt format containing role, task, context, and goals. It automatically appends a pasted_context block at the bottom of the prompt, indicating exactly where you can insert reference code, logs, or other technical documents before sending the prompt to your LLM.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func getRefinedDemoText(for template: String) -> String {
        switch template {
        case "Professional":
            return "We should adopt the SCINet high-performance computing (HPC) platform for scientific research at the Agricultural Research Service (ARS), given its strong capability and utility."
        case "Concise":
            return "We should use SCINet for scientific research at ARS; it is a highly powerful and useful HPC platform."
        default:
            return "We should use SCINet for scientific research at ARS because it is a very powerful and useful HPC platform."
        }
    }
}

// MARK: - Text Normalization (ITN)

struct HelpTextNormalizationContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What It Does")
                    .font(.headline)

                Text("When you dictate, the speech model outputs words exactly as spoken. Text normalization (ITN) converts spoken-form numbers, dates, times, currency, and measurements into their proper written form. This runs automatically on every finalized segment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What Gets Converted")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    itnExample("Numbers", "twenty one", "21")
                    itnExample("Money", "five dollars and fifty cents", "$5.50")
                    itnExample("Dates", "january fifth twenty twenty five", "January 5, 2025")
                    itnExample("Times", "two thirty pm", "02:30 p.m.")
                    itnExample("Measurements", "two hundred kilometers", "200 km")
                    itnExample("Ordinals", "twenty third", "23rd")
                    itnExample("Decimals", "three point one four", "3.14")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How to Get the Best Results")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    tipRow("Speak naturally", "Just talk normally. The normalizer scans your sentences and converts number patterns it recognizes.")
                    tipRow("Use multi-word numbers", "\"twenty one\" converts to 21, but a standalone \"two\" in \"I have two dogs\" stays as text to avoid false matches.")
                    tipRow("Include currency words", "\"five hundred\" becomes 500, but \"five hundred dollars\" becomes $500 with the dollar sign.")
                    tipRow("Say full date phrases", "\"january fifth twenty twenty five\" works. Month name + day + year gives the best results.")
                    tipRow("Include units", "\"two hundred kilometers\" converts to \"200 km\". The unit name tells the normalizer it's a measurement.")
                }
            }
        }

        HelpHint("Text normalization runs after filler word removal and before Vocabulary substitutions. Your glossary aliases work on the already-normalized text, so an alias for \"500\" would match a spoken \"five hundred\".")

        HelpHint("Single-word numbers like \"two\" or \"five\" are intentionally left as text in sentences to avoid changing phrases like \"a couple of\" or \"the one thing\". Multi-word patterns like \"twenty one\" or \"three hundred\" are converted.")
    }

    private func itnExample(_ category: String, _ spoken: String, _ written: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(category)
                .font(.callout.weight(.medium))
            HStack(spacing: Spacing.sm) {
                Text("\"\(spoken)\"")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(written)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
            }
        }
    }

    private func tipRow(_ title: String, _ detail: String) -> some View {
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
