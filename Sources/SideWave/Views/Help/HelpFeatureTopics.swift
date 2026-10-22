// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import SwiftUI

// MARK: - Hotkey Setup

struct HelpHotkeySetupContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The basic flow")
                    .font(.headline)

                HelpHotkeyFlow(keyLabel: appState.hotkeyManager.shortcut.displayString)
                    .padding(.vertical, 2)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How the hotkey behaves")
                    .font(.headline)

                HelpItem(
                    title: "Tap to Toggle",
                    content: "Tap the hotkey to start. Wait for Listening, then speak. Tap again to finish. Recognition and Refine finish before SideWave pastes. Document templates open the result in the document window."
                )

                HelpItem(
                    title: "Smart Push-to-Talk (Hold)",
                    content: "With Tap to Toggle, Hold to Talk chosen on Home, hold the hotkey, wait for Listening, speak, then release to finish. A press counts as a hold after 500 ms, measured from when recording is ready. Held dictation pastes the streaming draft for quick replies; turning on Refine for held dictation adds processing time."
                )

                HelpItem(
                    title: "Rewrite and finish (optional)",
                    content: "Off by default. In Advanced view, turn on Hold to rewrite and finish in Settings > General. Then hold the stop press for half a second and release: SideWave rewrites the whole dictation before sending it. A normal tap refines only the unfinished text."
                )

                HelpItem(
                    title: "Double-tap to paste again",
                    content: "Double-tap the hotkey within 300 ms to paste your last result again without recording."
                )

                HelpAdvancedNote(text: "Advanced view adds Refine and auto-submit for held dictation, and the hold threshold in Settings > Advanced.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Your current hotkey")
                    .font(.headline)
                Text("To change it, click Shortcut on Home or in Settings > General, then press the key or combination you want, such as Right Option or Shift + Tab.")
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ACTIVE TRIGGER")
                            .font(.system(size: 9, weight: .bold))
                            .adaptiveSecondary()
                            .tracking(0.5)
                        Text(appState.hotkeyManager.shortcut.displayString)
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityElement(children: .combine)

                    Spacer()

                    HelpDeepLinkButton(label: "Change Hotkey in Settings", systemImage: "keyboard", targetPage: nil, targetSettingsTab: .settingsGeneral, spotlightKey: "hotkey")
                }
                .padding(Spacing.sm)
                .background(Color.primary.opacity(0.02))
                .continuousCorner(CornerRadius.md)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Choosing a hotkey")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    tipRow("A modifier key on its own, like Right Option or Right Command, works well because most apps don't use it alone.")
                    tipRow("Avoid shortcuts other apps already use, like Command-C, Command-V, or Command-Space.")
                    tipRow("Function keys such as F5 or F13 also work if your keyboard has them.")
                                    }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Combinations")
                    .font(.headline)

                Text("To use a combination, click Shortcut, hold the modifier, and press the key: Shift + Tab, Right Shift + Right Option, or Option + grave (`). Check that macOS or another app doesn't already use it.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                Text("Press Escape while recording a shortcut to keep the current one.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, Spacing.xs)
            Text(text)
                .font(.callout)
                .adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Models

struct HelpModelsContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Live Hardware Memory Scanner
        HelpCard {
            HelpModelsScanner()
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "brain")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Parakeet TDT 0.6B")
                        .font(.headline)
                }

                Text("The main speech model. NVIDIA Parakeet TDT has 600 million parameters and runs on the Apple Neural Engine.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    modelVariant("v2 (English)", "English only. Try it on your own speech before switching.")
                    modelVariant("v3 (Multilingual)", "The default. Handles more languages and accents.")
                }

                Text("Settings > Speech Recognition shows the active model. In Advanced view you can switch between v3, v2, and Parakeet Ultra, a multilingual model with updated weights and a larger download. Each downloads separately.")
                    .font(.caption)
                    .adaptiveSecondary()
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Parakeet Realtime EOU 120M")
                        .font(.headline)
                }

                Text("A smaller streaming model with 120 million parameters. In the Complete and Basic Dictation Modes it runs alongside the main model, reads the audio in 160-millisecond chunks, writes the gray draft, and detects when you stop speaking. The main model confirms or corrects every word before it turns solid. Held dictation pastes this model's text.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "textformat.abc")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Parakeet TDT-CTC 110M")
                        .font(.headline)
                }

                Text("Used for glossaries. It checks your terms against the audio on the live preview about every 1.5 seconds and on each finished segment, which catches names, abbreviations, and jargon the main model misses.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Silero VAD")
                        .font(.headline)
                }

                Text("Voice activity detection. It runs only while you dictate, on the CPU so it doesn't compete with the speech models, and finds the pauses that can end a segment.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    // Gemma's own mark, not the Apple Intelligence symbol
                    // (that glyph is Apple's and may not be recolored or used
                    // to stand in for another vendor's model).
                    Image("GemmaLogo")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    Text("Gemma 4 E2B")
                        .font(.headline)
                }

                Text("Google DeepMind's Gemma 4, about 3 GB on disk. It refines ordinary dictation one segment at a time as you speak, and formats document templates after you finish. It runs on the GPU through MLX. E2B is the lightest Gemma option.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                Text("Gemma 4 E4B (about 5.2 GB) and 12B (about 6.8 GB) are also available. 12B handles complex edits better but uses more memory and is slower; use it with 24 GB of memory or more.")
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "apple.intelligence")
                        .font(.title3)
                        .foregroundStyle(Color.appleIntelligenceGlyphGradient(for: colorScheme))
                        .accessibilityHidden(true)
                    Text("Apple Intelligence")
                        .font(.headline)
                }

                Text("Apple's on-device model, on Macs that support Apple Intelligence. macOS manages and downloads it. Gemma handles longer documents.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Downloads and storage")
                    .font(.headline)

                Text("Speech models download during setup, which lists each file and its size. The glossary model downloads with them. Meeting and Gemma models download from Hugging Face when you first need them. Apple Intelligence comes from macOS. Downloaded models stay on this Mac.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpHint("Home shows whether dictation is ready. Window > Downloads shows transfers in progress, and Settings > Refine can retry a model that failed to prepare.")
    }

    private func modelVariant(_ name: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(name)
                .font(.callout.weight(.medium))
            Text(desc)
                .font(.caption)
                .adaptiveSecondary()
        }
    }
}

/// Reads this Mac's physical unified memory and shows model memory advice
/// that fits the hardware (static readout, no polling).
struct HelpModelsScanner: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let physicalMemoryGB = Double(physicalMemoryBytes) / (1024.0 * 1024.0 * 1024.0)
        let roundedRAM = Int(round(physicalMemoryGB))
        
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac")
                        .font(.headline)
                    Text("Advice based on this Mac's memory:")
                        .font(.caption)
                        .adaptiveSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            HStack(spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("UNIFIED MEMORY")
                        .font(.system(size: 9, weight: .bold))
                        .adaptiveSecondary()
                        .tracking(0.5)
                    
                    Text("\(roundedRAM) GB")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                
                Spacer()
                
                HStack(spacing: 5) {
                    Circle()
                        .fill(roundedRAM <= 8 ? Color.warningAmber : Color.green)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(roundedRAM <= 8 ? "Limited headroom" : (roundedRAM <= 18 ? "Good headroom" : "Plenty of headroom"))
                        .font(.caption.weight(.semibold))
                        .adaptiveSecondary()
                }
            }
            .padding(Spacing.md)
            .background(Color.primary.opacity(0.03))
            .continuousCorner(CornerRadius.lg)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Approximate memory use")
                    .font(.caption.weight(.semibold))
                    .adaptiveSecondary()
                
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    memorySpecRow("macOS and other apps", "Shared memory", "Available memory changes as other apps work.")
                    memorySpecRow("Speech engines", "Varies by model", "The selected recognizer, live preview, and optional vocabulary helper each use memory.")
                    memorySpecRow("Gemma 4 E2B / E4B / 12B weights", "3 / 5.2 / 6.8 GB", "Inference also needs working memory. E2B uses the least; 24 GB or more is recommended for 12B.")
                }
            }
            .padding(.top, Spacing.xs)

            Divider()
                .padding(.vertical, 2)
            
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Advice for this Mac:")
                    .font(.caption.weight(.semibold))
                    .adaptiveSecondary()
                
                if roundedRAM <= 8 {
                    Text("With 8 GB or less, Gemma 4 can push the Mac into swap, which shows up as lag. Pick **Apple Intelligence** as the Refine model, or set the Dictation Mode to **Basic** or **Minimalistic** to skip Refine. Dictation Mode is at the top of the Dictation tab.")
                        .font(.callout)
                        .adaptiveSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                } else if roundedRAM <= 18 {
                    Text("With \(roundedRAM) GB, try the **Complete** Dictation Mode with Gemma 4 E2B. If the Mac slows down, switch to Apple Intelligence or the **Basic** mode.")
                        .font(.callout)
                        .adaptiveSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("With \(roundedRAM) GB, the larger Gemma models are an option. E4B and 12B help with complex writing; E2B is the fastest.")
                        .font(.callout)
                        .adaptiveSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    
    private func memorySpecRow(_ label: String, _ ram: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ram)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 80, alignment: .leading)
            Text(desc)
                .font(.caption)
                .adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

// MARK: - Vocabulary

struct HelpVocabularyContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Glossaries")
                    .font(.headline)

                Text("The Vocabulary tab holds glossaries: named sets of words you turn on and off together. Each word has its spelling, and optionally how it sounds, common mishearings, a category, and context for Refine.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Your glossaries and optional bundles")
                    .font(.headline)

                HelpItem(
                    title: "Optional catalog",
                    content: "SideWave starts with no glossaries. Browse Bundles downloads the catalog from GitHub. A downloaded bundle is read-only and updates when you choose, or once a day if you turn on Update automatically. To edit one, choose Make a Personal Copy; copies never sync. Words you turn off in a bundle stay off after updates. Manage Bundle shows its update history."
                )

                HelpItem(
                    title: "Custom glossaries",
                    content: "Start one with New Glossary, load a file with Import Glossary, or use Create Words from a Description to have your Refine model suggest terms."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What a word does")
                    .font(.headline)

                Text("Click a word to edit it. Two switches set what it does; new words start with both on.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    scopeRow("Replace at dictation", "Replaces the pronunciations and mishearings you listed with your spelling. On its own, it also works for private shortcuts.")
                    scopeRow("Send hint to Refine", "Gives Refine the spelling and context. On its own, use it when recognition spells the word right but Refine needs to know what it means.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Pinning and usage notes")
                    .font(.headline)

                HelpItem(
                    title: "Always include in Refine",
                    content: "Refine gets a pinned word even when you didn't say it, as long as it fits the prompt budget all glossaries share. Pin only a few. Needs Send hint to Refine."
                )

                HelpItem(
                    title: "Usage note",
                    content: "Up to 120 characters telling Refine how to use a word with more than one meaning, such as a name that is also a common word."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Adding words")
                    .font(.headline)

                HelpItem(
                    title: "Add Word",
                    content: "Enter the spelling, how it sounds in ordinary words, mishearings separated by commas, and a category if you like. Refine context holds a description and usage note."
                )

                HelpItem(
                    title: "Import Words from CSV",
                    content: "From a glossary's menu, paste or import many words at once in up to three columns: the word, mishearings separated by |, and a description. Imported words start with both switches on."
                )

                HelpItem(
                    title: "Describe Your Field",
                    content: "Write a few sentences about your work, like \"I study wheat genetics and analyze data in SAS and R.\" Your Refine model suggests terms as a checklist on this Mac. Edit them and save them as a new glossary."
                )

                HelpItem(
                    title: "Speech Profile",
                    content: "Your Refine model reads your dictation history and writes up to 600 characters on how you talk and write. Refine uses it to keep your voice. You can edit it, turn it off, or clear it. It stays on this Mac."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How glossaries reach the models")
                    .font(.headline)

                Text("The CTC model checks your words against the audio on the live preview about every 1.5 seconds and again when each segment finishes. It replaces a word only when your term matches the audio better. A large or ambiguous glossary can still cause wrong replacements, so keep the words you use. With Refine on, up to 30 of the most relevant words with Send hint to Refine also go into the Refine prompt.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Words that sound like everyday phrases")
                    .font(.headline)

                Text("Some names and acronyms sound like everyday phrases: \"SCINet\" sounds like \"sign it.\" A replacement works when the misheard form is something you'd never mean, like \"Zach\" for \"Zak.\" It can't separate true homophones, because the audio is the same.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                Text("For those, turn on only Send hint to Refine. Refine uses the sentence to pick the right form: \"We use SCINet for genome analysis\" keeps SCINet, and \"I'll sign it tomorrow\" keeps sign it. The CTC check still runs for every word, whatever its switches, so turn off a word that causes wrong replacements.")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Good candidates")
                    .font(.headline)

                HelpItem(title: "Names", content: "Colleagues, project leads, authors you cite often.")
                HelpItem(title: "Technical terms", content: "Field-specific words, scientific names, compound terms.")
                HelpItem(title: "Acronyms", content: "SCINet, CRISPR, PCR, API.")
                HelpItem(title: "Project and product names", content: "Internal project names, products, and brands.")
                HelpItem(title: "Shorthand", content: "Lab and field shorthand.")
            }
        }

        HelpHint("The CTC check skips words shorter than 3 characters, which match too easily. Refine still gets them.")

        HelpHint("Refine reads up to 30 words, and up to 600 characters of About this glossary text, across all glossaries that are on. Keep that text short and turn off glossaries you don't need.")

        HelpCard {
            Text("Template linking")
                .font(.title3.weight(.semibold))
            Text("A glossary can be linked to one or more templates. When you switch templates, linked glossaries turn on and glossaries linked to other templates turn off. Unlinked glossaries stay as you set them.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Open a glossary's \u{2026} menu and choose Link to Templates. For example, link a work glossary to Professional so it turns on when you switch to that template.")
                .font(.callout)
                .adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Examples")
                    .font(.headline)
                Text("With these words in a glossary that's on, the CTC check swaps in your spelling when the audio matches:")
                    .font(.callout)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: Spacing.sm) {
                    rescoreExample(heard: "sign it", written: "SCINet")
                    rescoreExample(heard: "fee no type", written: "phenotype")
                    rescoreExample(heard: "crisper", written: "CRISPR")
                }

                Text("The audio check reduces wrong replacements but doesn't prevent them. Replace at dictation applies whenever the text matches, so don't list mishearings that are phrases you also say.")
                    .font(.caption)
                    .adaptiveSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rescoreExample(heard: String, written: String) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Heard")
                    .font(.system(size: 9, weight: .bold))
                    .adaptiveTertiary()
                    .textCase(.uppercase)
                Text(heard)
                    .font(.system(.callout, design: .monospaced))
                    .adaptiveSecondary()
            }
            .frame(width: 120, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.caption)
                .adaptiveTertiary()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Written")
                    .font(.system(size: 9, weight: .bold))
                    .adaptiveTertiary()
                    .textCase(.uppercase)
                Text(written)
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(Spacing.sm)
        .background(.ultraThinMaterial)
        .continuousCorner(CornerRadius.md)
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func scopeRow(_ name: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(name)
                .font(.callout.weight(.medium))
            Text(description)
                .font(.caption)
                .adaptiveSecondary()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
