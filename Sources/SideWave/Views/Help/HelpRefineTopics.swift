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
                Text("Refine runs on your Mac as each segment finishes. It removes hesitations and fixes punctuation and grammar in the style of your template. When you finish, it refines whatever is left before pasting. If that final pass can't finish, the text stays on Home and in History instead of being pasted.")
                    .fixedSize(horizontal: false, vertical: true)

                Text("Choose the Template, Refine model, and Output language on Home. Formatting Rules is on Home and in the document window. Settings > Refine prepares models and holds the expert options.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HelpDeepLinkButton(label: "Open Refine Settings", systemImage: "text.badge.checkmark", targetPage: nil, targetSettingsTab: .settingsRefine, spotlightKey: "refine")
                    .padding(.top, 4)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Dictation Mode and where controls live")
                    .font(.headline)
                Text("These controls stay in sync wherever they appear.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Complete runs the streaming draft, Parakeet, and Refine. Basic keeps both speech models and skips Refine. Minimalistic runs only Parakeet, so the preview updates in short batches and its first words appear later.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("In Basic and Minimalistic, gray text still settles to solid when Parakeet confirms a segment; that is recognition, not Refine. Glossaries and word filters still apply.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Basic and Minimalistic turn Refine off and unload its model. Picking a template afterward turns Refine back on; in Minimalistic it runs when you finish. Simple and Advanced view don't change any of this.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HelpSettingLocationRow(icon: "slider.horizontal.3", title: "Dictation Mode", valueMock: "Complete", location: "Dictation tab, or Home in Advanced view > Recognition & refinement")
                HelpSettingLocationRow(icon: "text.badge.checkmark", title: "Refine model", valueMock: "Gemma 4", location: "Home > Refine model, Dictation tab > Refine, or Settings > Refine")
                HelpSettingLocationRow(icon: "text.badge.checkmark", title: "Template", valueMock: "Standard", location: "Home > Template, or Dictation tab > Refine")
                HelpSettingLocationRow(icon: "globe", title: "Output language", valueMock: "As spoken", location: "Home > Output language, or Dictation tab > Refine")
                HelpSettingLocationRow(icon: "pencil", title: "Custom instructions", valueMock: "Edit", location: "Home > Formatting Rules, or the document header")

                HelpAdvancedNote(text: "Advanced view adds the short-session bypass, final pass strategy, and Gemma thinking under Refine > Advanced on the Dictation tab, and Refine cadence in Settings > Refine > Expert.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("One dictation, three templates")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("What you said")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\"So, um, I was thinking we should probably, you know, run the assembly on SCINet, because the lab server keeps, uh, running out of memory.\"")
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
            Text("Gemma 4 E2B. About 3 GB. The lightest and fastest Gemma. It downloads from Hugging Face the first time you pick it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Gemma 4 E4B. About 5.2 GB. Better with longer text; use it with 16 GB of memory or more.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Gemma 4 12B. About 6.8 GB. The largest and slowest Gemma; use it with 24 GB of memory or more.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Apple Intelligence. On Macs that support it. macOS downloads and manages the model.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Switch with Refine model on Home, on the Dictation tab, or in Settings > Refine.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        HelpCard {
            Text("Templates")
                .font(.title3.weight(.semibold))
            Text("Standard, Professional, and Concise refine your words as you speak and paste into your app. Pick one with Template on Home or on the Dictation tab.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Standard. Fixes grammar, punctuation, and transcription errors. Keeps your voice.")
                Text("Professional. Rewrites into professional prose. Fixes grammar, phrasing, and word choice.")
                Text("Concise. Same meaning in fewer words.")
            }
            .font(.callout)
            Text("Email, Instructions, AI Prompt, and Custom are document templates. They format the whole dictation after you finish and show it in the document window, where you can edit and copy it. Start dictating, or choose Open Document. Custom follows your Formatting Rules with no built-in style.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        HelpCard {
            Text("Working with a document")
                .font(.title3.weight(.semibold))
            Text("Change the document type with the Template menu at the top. Each template keeps its current draft, and Recents keeps earlier documents with your edits. Read shows the formatted text; Edit text lets you change it directly.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Your hotkey starts a new document and moves the previous one to Recents. Add dictation continues the open document, and New starts a blank one. To change the document, type under Change this document and choose Apply, or use Speak change. Stop Edit puts the document back and keeps your instruction.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("When automatic appending is off, Activity holds new dictation until you choose Append. Undo reverses the last model edit. If a change can't be applied, the window says why and keeps your instruction.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Output language")
                .font(.title3.weight(.semibold))
            Text("As spoken keeps the language you dictate in. Pick another language to translate as Refine cleans up, such as speaking English and pasting Spanish. Check names, technical terms, code, and numbers before you send a translation.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The languages are English, Spanish, French, German, Italian, Portuguese, Japanese, Korean, and Chinese (Simplified). With Apple Intelligence, the list shows only what your macOS version supports. The larger Gemma models translate complex text better.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("In History, a translated dictation has Literal back-translation, which translates it back word for word with notes on phrases that changed. It is another model's reading, not proof the translation was exact. It runs on your Mac when you ask, and the result is saved with the entry.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Custom instructions")
                .font(.title3.weight(.semibold))
            Text("Formatting Rules holds up to 1,000 characters of your own instructions, used with every template: tone, formatting preferences, or project terms. For Custom, they are the whole instruction.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Bypass Refine on short sessions")
                .font(.title3.weight(.semibold))
            Text("Off by default. When on, ordinary dictation shorter than Minimum words skips the final Refine pass. Document templates still apply their format.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Minimum words can be 5, 10, 20, or 50 (default 10). The cutoff covers the final pass and Rewrite and finish, but Refine still runs on each segment while you speak. It's on the Dictation tab under Refine > Advanced.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Final pass strategy")
                .font(.title3.weight(.semibold))
            Text("How much text Refine checks when you finish. It's on the Dictation tab under Refine > Advanced.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Incremental (default): refines all unfinished text, and can revise up to the last two sentences (64 words) before it.")
                Text("Smart Window: refines the last sentence or two again, using earlier text as context.")
                Text("Full Session: rewrites the whole dictation, which takes longer for long input. Rewrite and finish does the same for one dictation.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        HelpCard {
            Text("If final refinement cannot finish").font(.title3.weight(.semibold))
            Text("SideWave keeps the text on Home and in History instead of pasting it half refined. Resume to try again, or copy the text. With Final refinement pass off, SideWave pastes right away, including words that weren't refined.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Prompt preview")
                .font(.title3.weight(.semibold))
            Text("Prompt preview on the Dictation tab or in Settings > Refine shows what Refine receives: the template, your Formatting Rules, and glossary words and descriptions.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Stopping and cancelling")
                .font(.title3.weight(.semibold))
            Text("New and changed words animate into place as you speak. Escape stops without pasting and keeps the text on Home as a paused dictation. Control-Escape cancels and saves what was captured to History.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Vocabulary and Refine")
                .font(.title3.weight(.semibold))
            Text("Glossaries that are on give Refine each word's spelling, mishearings, and description, up to 30 words and 600 characters of About this glossary text in all, so there's room left for your text. Words with Send hint to Refine off are left out.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Link a glossary to templates from its \u{2026} menu on the Vocabulary tab, and it turns on only with those templates.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Fallbacks")
                .font(.title3.weight(.semibold))
            Text("If Refine can't finish, you keep the recognized text. Ordinary cleanup has a short time limit; document formatting and Gemma thinking have longer ones. When a model fails or a document is too long for it, the document window says so and keeps your text and instruction.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("History")
                .font(.title3.weight(.semibold))
            Text("Expand an entry in History and choose Show earlier stages to compare the recognized text with the refined result.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Privacy")
                .font(.title3.weight(.semibold))
            Text("Both models run on your Mac: Gemma 4 on the GPU through MLX, Apple Intelligence through Apple's Foundation Models framework. Refine never sends text to a server. Text you paste into another app follows that app's privacy rules.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Getting ready")
                .font(.title3.weight(.semibold))
            Text("When you press the shortcut, a small panel says Ready to speak in a moment while the microphone and models start. Speak when the full preview appears. The first start after installing can take a minute while the speech models compile; after five seconds the panel says so.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("Document templates in two passes")
                .font(.title3.weight(.semibold))
            Text("With Refine on, a document template first cleans up your speech as plain prose while you talk. When you finish, the template formats the whole text, and the document window shows progress until it's done. This runs for short dictations too, and when the final pass is off.")
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            Text("AI Prompt")
                .font(.title3.weight(.semibold))
            Text("AI Prompt turns what you say into an XML prompt with sections for the role, task, context, and goals you mention. It always ends with an empty pasted_context block where you can paste code, logs, or documents before sending it to a chat model.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func getRefinedDemoText(for template: String) -> String {
        switch template {
        case "Professional":
            return "I recommend running the assembly on SCINet, as the lab server continues to run out of memory."
        case "Concise":
            return "Run the assembly on SCINet; the lab server keeps running out of memory."
        default:
            return "I was thinking we should run the assembly on SCINet, because the lab server keeps running out of memory."
        }
    }
}

// MARK: - Text Normalization (ITN)

struct HelpTextNormalizationContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What it does")
                    .font(.headline)

                Text("The speech model writes numbers as words. Text normalization rewrites spoken numbers, dates, times, money, and measurements in written form, on every finished segment.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Examples")
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
                Text("Getting the best results")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                                        tipRow("Multi-word numbers", "\"twenty one\" becomes 21, but \"two\" in \"I have two dogs\" stays a word.")
                    tipRow("Currency", "\"five hundred\" becomes 500, and \"five hundred dollars\" becomes $500.")
                    tipRow("Dates", "Say the month, day, and year: \"january fifth twenty twenty five.\"")
                    tipRow("Units", "\"two hundred kilometers\" becomes 200 km.")
                }
            }
        }

        HelpHint("Normalization runs after filler words are removed and before glossary replacements, so a replacement for \"500\" also matches a spoken \"five hundred.\"")

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
