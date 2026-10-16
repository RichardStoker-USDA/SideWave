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
                Text("The Basic Flow")
                    .font(.headline)

                HelpHotkeyFlow(keyLabel: appState.hotkeyManager.shortcut.displayString)
                    .padding(.vertical, 2)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How the Hotkey Behaves")
                    .font(.headline)

                HelpItem(
                    title: "Tap to Toggle",
                    content: "Tap your global hotkey to start recording. Wait for Listening, then speak. Tap again to finish. The remaining recognition and any enabled refinement finish before delivery. Document templates keep the result in their preview."
                )

                HelpItem(
                    title: "Smart Push-to-Talk (Hold)",
                    content: "With Tap or hold enabled, hold the hotkey, wait for Listening, speak, then release to finish. The default threshold is 500 ms after recording becomes ready, not after key-down. Smart Push-to-Talk uses the streaming recognizer for quick replies; optional held-dictation Refine can add processing time."
                )

                HelpItem(
                    title: "Rewrite and finish (optional)",
                    content: "Off by default. Enable Hold to rewrite and finish in Advanced view > Settings > General. Hold the stop press for half a second, then release to end recording, rewrite the whole dictation, and send it. A normal stop finishes pending text and checks the recent sentence boundary."
                )

                HelpItem(
                    title: "Double-Tap to Re-Paste",
                    content: "Double-tap your hotkey quickly (within 300ms) to paste your last result again without recording anything new. Handy for repeating an entry across forms or windows."
                )

                HelpAdvancedNote(text: "Choose Tap or hold beside Shortcut on Home to enable Smart Push-to-Talk. Advanced adds held-dictation refinement and auto-submit controls. The hold threshold is in Settings > Advanced.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Your Current Hotkey")
                    .font(.headline)
                Text("This is the trigger SideWave is listening for right now. To change it, open Settings > General > Hotkey, click the recorder field, and press the key or combination you want (Option, Cmd + Space, Shift + Tab, and so on):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ACTIVE TRIGGER")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
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
                Text("Choosing a Good Hotkey")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    tipRow("Modifier keys alone work great (Right Option, Right Command, etc.) since most apps don't bind them solo.")
                    tipRow("Avoid common shortcuts like Cmd+C, Cmd+V, or Cmd+Space that other apps or Spotlight already use.")
                    tipRow("Function keys (F5, F13, etc.) are another safe choice if your keyboard has them.")
                    tipRow("If your hotkey conflicts with another app, just change it in Settings.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Adding a Modifier")
                    .font(.headline)

                Text("If you want a modifier key (Shift, Control, Command, Option) as part of your hotkey instead of using a single key alone, the recorder captures it automatically. Open Settings > General > Hotkey, click the field, then HOLD the modifier you want and press the key together. Examples include Shift + Tab, Right Shift + Right Option, and Option + grave (`). Check that the combination is not already assigned in macOS or another app. The recorded combination is shown back to you using the standard macOS glyphs (⇧ ⌃ ⌥ ⌘).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Press Escape during recording to cancel without changing the existing shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpHint("Choose Tap or hold on Home to use either gesture. Live Refine and full-session Refine depend on your refinement settings. Document templates finish in their preview.")
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, Spacing.xs)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
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

                Text("The main transcription model. NVIDIA's Parakeet TDT has 600 million parameters and uses a Token-and-Duration Transducer architecture with a bidirectional encoder. It runs on the Apple Neural Engine for fast inference.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    modelVariant("v2 (English-only)", "English-only alternative. Compare results on your own speech before changing the recognition model.")
                    modelVariant("v3 (Multilingual)", "Supports multiple languages. Default choice. Slightly slower than v2 but handles a wider range of accents and mixed-language input.")
                }

                Text("Settings > Speech Recognition shows the active model. Advanced view offers Parakeet v3, multilingual Ultra, and legacy v2. Each has its own download. V3 remains the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Text("A second, smaller Parakeet recognizer (NVIDIA's 120-million parameter realtime end-of-utterance model) that runs alongside the main transcriber when the dual-engine pipeline is enabled. It processes audio in 160-millisecond chunks, paints the gray draft text in the overlay, and detects when you've finished speaking. Because it trades accuracy for speed, its draft is provisional by design; the main transcriber confirms or corrects every word before anything turns white. Smart Push-to-Talk's instant paste on release comes from this model's text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                    Text("CTC 110M")
                        .font(.headline)
                }

                Text("A smaller 110-million parameter model used for vocabulary boosting during finalization. When you stop dictating, the CTC model re-scores the transcription with your enabled Vocabulary terms weighted more heavily. This catches proper nouns, abbreviations, and jargon that the main model might not get right on its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

                Text("Voice Activity Detection model. Active only during dictation (after you press the hotkey) to detect when you're speaking vs. silent. It's a small, efficient model that runs on the CPU to avoid contention with the Neural Engine. VAD drives the automatic segment splitting, finding natural pauses in your speech so the transcription engine can process audio in sensible chunks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

                Text("Google DeepMind's Gemma 4 language model, about 3 GB on disk. Powers the Refine feature: as you dictate, this model fixes grammar, removes filler words, and applies your chosen template. One segment at a time, automatically. Runs on the GPU through MLX. E2B is the lighter Gemma option; speed and available memory depend on this Mac and other running apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Gemma 4 E4B (about 5.2 GB) and 12B (about 6.8 GB) are also available. The 12B model offers more capacity for complex edits, uses more memory, and can be slower. At least 24 GB of memory is recommended for 12B.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Text("Apple's on-device foundation model is available on supported Macs with macOS 26 or later. macOS manages its assets and may need to download them before first use. SideWave checks availability and context capacity at runtime. Gemma offers a larger working budget for long documents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Download and Storage")
                    .font(.headline)

                Text("Speech recognition models download during setup. The download view lists the files and byte counts for the selected models; optional streaming, vocabulary, voice activity, and meeting models have their own downloads. Gemma downloads separately from HuggingFace. Apple Intelligence uses assets managed by macOS, which may still need to download in System Settings. Downloaded models are cached between launches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpHint("Home shows session readiness. Refine preparation appears below the Home controls, and Downloads shows active transfers and verification. Settings > Refine includes retry and model choices.")
    }

    private func modelVariant(_ name: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(name)
                .font(.callout.weight(.medium))
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    Text("System Hardware Scan")
                        .font(.headline)
                    Text("SideWave checked this Mac's unified memory so the advice below matches your hardware:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            HStack(spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SCANNED PHYSICAL MEMORY")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                    
                    Text("\(String(format: "%.1f", physicalMemoryGB)) GB Unified Memory")
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
                        .foregroundStyle(.secondary)
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
                Text("Memory use estimates:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                
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
                    .foregroundStyle(.secondary)
                
                if roundedRAM <= 8 {
                    Text("Your Mac has 8 GB (or less) of unified memory. Running the full local Gemma 4 model can push past that and start paging to SSD, which shows up as lag. Set the Dictation Mode to **Basic** or **Minimalistic** (at the top of the Dictation tab, also under Home > Advanced > Recognition & refinement) to skip the local GPU refine step, or pick **Apple Intelligence** as your Refine model. macOS manages its memory; it still uses system resources.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if roundedRAM <= 18 {
                    Text("With \(roundedRAM) GB of unified memory you're in a good spot for the **Complete** Dictation Mode. Parakeet TDT (on the Neural Engine) and Gemma 4 (on the GPU) can run together. Other apps and large documents still affect available memory and response time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("At \(roundedRAM) GB, larger local models are an option. E2B favors lower memory use; E4B and 12B can help with more complex writing. Other apps, model context, and recording length still affect response time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
                Text("The Short Version")
                    .font(.headline)

                Text("Open the Vocabulary tab in the main window. Inside, entries are grouped into glossaries. A glossary is a labeled bundle of terms you can turn on and off together. Each entry has a spelling, optional pronunciation and common mistranscriptions, an optional category, and context for Refine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Your glossaries and optional bundles")
                    .font(.headline)

                HelpItem(
                    title: "Optional catalog",
                    content: "SideWave starts without bundled glossaries. Browse bundles downloads the GitHub catalog; search stays local. Download a bundle to subscribe to its read-only words. Updates are manual unless you enable daily checks for that bundle. Make a personal copy to edit a glossary, or open a word to copy it or turn it off locally. Personal copies never sync, and locally disabled words stay disabled after updates. Manage bundle shows update history. Transfers appear in Data Transparency."
                )

                HelpItem(
                    title: "Custom glossaries",
                    content: "Use New glossary to create a collection, import a glossary file, or create words from a description with your selected local Refine model. Your existing custom glossaries are preserved."
                )

                HelpItem(
                    title: "My Corrections",
                    content: "If you upgraded from an earlier version, your previous entries were migrated here automatically as Auto-correct entries. It's a regular Custom glossary, edit as you wish."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Entry Scope")
                    .font(.headline)

                Text("Click a word to edit it. Replace at dictation applies the pronunciation and mistranscriptions as replacements. Send hint to Refine gives the model the spelling and context. These switches are independent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    scopeRow("Auto-correct + Refine context", "Replaces the misheard word every time AND feeds it into the Refine prompt. The default for new entries.")
                    scopeRow("Auto-correct only", "Applies the text replacement but doesn't get sent to the Refine model. Good for private aliases or snippet triggers.")
                    scopeRow("Refine context only", "Skips the text replacement and only hints the Refine model. Useful when spelling is fine but the model needs to know about the term.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Pin and Usage Note")
                    .font(.headline)

                HelpItem(
                    title: "Always include in Refine",
                    content: "Pins a high-value term so Refine always sees it, even when you didn't say it in that dictation. Keep this to a few key terms, since every enabled glossary shares one prompt budget. Needs Send hint to Refine turned on."
                )

                HelpItem(
                    title: "Usage note",
                    content: "A short note (up to 120 characters) that tells the Refine model how to use a term when it has more than one meaning. Handy for a name that doubles as a common word."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Adding Terms")
                    .font(.headline)

                HelpItem(
                    title: "Add Word",
                    content: "Enter the spelling, pronunciation in ordinary words, comma-separated mistranscriptions, and optional category. The Refine context disclosure holds a description and usage note."
                )

                HelpItem(
                    title: "Bulk Import",
                    content: "Paste or import many entries at once. CSV format with three columns: word, mistranscriptions (pipe-separated), and an optional description. Every imported word starts with both scopes on. Click a word afterward to edit its behavior."
                )

                HelpItem(
                    title: "Describe (on-device generation)",
                    content: "Write a plain-English paragraph about your work (\"I'm an agricultural data scientist at USDA focusing on wheat genetics with tools like SAS and R\"). A local model extracts candidate terms and shows them as a checklist. Review, edit, and save them into a new glossary. It runs on this Mac with the selected Gemma or Apple Intelligence model."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How It Works Behind the Scenes")
                    .font(.headline)

                Text("During dictation, the Parakeet TDT model drives the live overlay preview. Vocabulary boosting now runs in two places: throttled live-preview rescoring (about once every 1.5 seconds) so corrections appear in real time, and a final pass when each segment finalizes at a VAD pause or the 14.8s ceiling. The CTC rescorer is acoustic. It only replaces the model's output when your vocabulary term actually matches the audio frames better than the original word, to reduce false replacements. A large or ambiguous glossary can still reduce accuracy; keep only terms you use and check the result. If Refine is on, the canonical term plus its description is also included in the prompt sent to the Refine model, so it knows how to spell and use the term in output.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Words that sound like real phrases")
                    .font(.headline)

                Text("Some terms you'd want to add (proper nouns, acronyms) share their pronunciation with everyday phrases. \"SCINet\" sounds like \"sign it\", \"Slack\" sounds like \"slack\", and so on. Aliases work great when the misheard form is something you'd never legitimately say (\"Zach\" as a misspelling of \"Zak\"). They don't work for true homophones because the recognizer can't tell from audio alone which one you meant.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Recommended approach for true homophones: add the term with the \"Refine context only\" scope. The Refine model gets told about your term, and it uses the surrounding sentence to pick the right form (\"We use SCINet for genome analysis\" reads as SCINet; \"I'll sign it tomorrow\" reads as sign it). Acoustic boosting still applies because every active vocabulary entry now feeds the CTC rescorer regardless of scope, but the rescorer only triggers when the audio matches the term. Acoustic scoring can still confuse similar sounds; review replacements and disable terms that cause errors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Good Candidates")
                    .font(.headline)

                HelpItem(title: "People's Names", content: "Colleagues, project leads, authors you cite often.")
                HelpItem(title: "Technical Terms", content: "Domain-specific vocabulary, scientific names, compound terms.")
                HelpItem(title: "Abbreviations & Acronyms", content: "SCINet, CRISPR, PCR, API, etc.")
                HelpItem(title: "Project Codenames", content: "Internal project names, product names, brand names.")
                HelpItem(title: "Jargon & Shorthand", content: "Lab terminology, field-specific shorthand.")
            }
        }

        HelpHint("Terms shorter than 3 characters are skipped by CTC boosting because very short strings cause too many false matches. They still count for Refine hints.")

        HelpHint("Refine has a term and character budget (roughly 30 terms and 600 chars of description across every enabled glossary), so keep descriptions tight. Enable only glossaries that are relevant to your work.")

        HelpCard {
            Text("Template linking")
                .font(.title3.weight(.semibold))
            Text("Each glossary can be linked to one or more Refine templates. When you switch templates on Home or the Dictation tab, linked glossaries auto-enable and glossaries linked to other templates auto-disable. Unlinked glossaries stay under manual control.")
                .fixedSize(horizontal: false, vertical: true)
            Text("To link a glossary, open its ellipsis menu and choose Link to Templates. Check the templates you want it active for. For example, link your work jargon glossary to Professional so it loads automatically when you switch to that style.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What Boosting Looks Like")
                    .font(.headline)
                Text("With a term in an enabled glossary, the CTC model checks the audio and swaps the misheard word for your spelling, but only when the sound actually matches. A few examples:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: Spacing.sm) {
                    rescoreExample(heard: "sign it", written: "SCINet")
                    rescoreExample(heard: "fee no type", written: "phenotype")
                    rescoreExample(heard: "crisper", written: "CRISPR")
                }

                Text("Acoustic evidence reduces false replacements, but it is not a guarantee. Text aliases apply more directly, so avoid common phrases that you also use literally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rescoreExample(heard: String, written: String) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Heard")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(heard)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Written")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
