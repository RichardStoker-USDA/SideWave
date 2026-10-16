# SideWave

Local dictation for Apple silicon Macs. SideWave transcribes your speech on the Mac, cleans it up
with a local language model, and pastes the result into the app you were working in. It's free and
open source.

Download the latest release from [sidewave.dev](https://sidewave.dev) or the
[releases page](https://github.com/RichardStoker-USDA/SideWave/releases/latest). Open the DMG and
drag SideWave to Applications. Requires macOS 26 or later on an Apple silicon Mac.

## Using it

1. Open SideWave and follow setup. It explains Microphone and Accessibility access before macOS
   asks, then downloads the speech models and shows the real download size and progress.
2. Click into the text field you want to write in.
3. Tap **Right Option** to start, wait for Listening, speak, and tap again to finish. Hold the key
   instead for push-to-talk; release to send.
4. Press **Escape** to stop without sending. The text stays on Home, where you can paste, resume, or
   discard it.

Change the shortcut, template, Refine model, microphone, and destination on Home. Advanced view
adds the expert controls; it changes what's shown, not the engine.

## What it does

- **Recognition**: NVIDIA Parakeet TDT v3 through FluidAudio and Core ML, with a streaming live
  preview while you talk. Parakeet Ultra and the older v2 model are available in Settings.
- **Refine**: Apple Intelligence on Macs that support it, or Gemma 4 E2B, E4B, or 12B through MLX.
  It fixes recognition errors, punctuation, and filler words. If Refine fails or times out, you get
  the recognized text instead.
- **Templates**: Standard, Professional, and Concise paste into your app. Email, Instructions,
  AI Prompt, and Custom open a document window where you can read, edit, and change the result
  by typing or speaking an instruction.
- **Output language**: dictate in one language and have Refine write in another.
- **Vocabulary**: glossaries for names and terms, with replacement aliases and hints for Refine.
  Optional glossary bundles come from the [catalog](glossaries/README.md).
- **History**: recent dictations with the recognized text and earlier stages, kept for 7 days by
  default. Failed or cancelled sessions are saved there, not lost.
- **Meetings** (optional): record a conversation, label up to eight speakers, and write local
  meeting notes.

Experimental features, off by default, add an MCP server so AI agents connected to SideWave can
read your live transcript and speak replies with a local voice.

## Privacy

Recognition, Refine, and meeting notes run on your Mac. SideWave has no accounts and no analytics.
It goes online to download models, to fetch glossary bundles you ask for, and to check for updates
if you allow it. Help > Data Transparency shows each of those requests.

History, vocabulary, documents, and settings stay in your user folder. Text you send to another
app follows that app's privacy rules. See the [privacy policy](https://sidewave.dev/privacy-policy/).

## Building from source

You need Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). `project.yml` is the
project source; regenerate after adding files or changing settings.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project SideWave.xcodeproj -scheme SideWave -configuration Debug test -skipMacroValidation
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Debug builds are named SideWave Dev and use their own bundle ID, so their permissions and data
are separate from the release app.

The repository also holds `SideWave2`, a smaller app built on `SideWaveKit`. It's a reference for
a cleaner architecture and has fewer features. Its tests run as `SideWaveKitTests` in the
`SideWave` scheme.

### Tests that need hardware

The default test run uses fixtures and offscreen rendering. Tests that load real models, use the
microphone or speakers, or download files skip unless you set a flag. Pass these to `xcodebuild` as
`TEST_RUNNER_<flag>=1`, and only on a Mac nobody is using.

| Flag | Runs |
|---|---|
| `SIDEWAVE_LIVE_MODELS` | Speech and Refine models on real audio |
| `SIDEWAVE_ALLOW_MODEL_LOAD_IN_TESTS` | Document editing with a real model; pick one with `SIDEWAVE_REFINE_BACKEND` |
| `SIDEWAVE_LIVE_MIC` | Microphone capture (needs Microphone access for SideWave Dev) |
| `SIDEWAVE_LIVE_AUDIO` | Input device start and teardown; add `SIDEWAVE_LIVE_USB_AUDIO` for USB inputs |
| `SIDEWAVE_LIVE_AUDIO_OUTPUT` | Speaker playback |
| `SIDEWAVE_LIVE_DOWNLOADS` | Network activity recording against real servers |
| `SIDEWAVE_LIVE_MODEL_DOWNLOADS` | Model cache repair on a copy of a downloaded model |
| `SIDEWAVE_LONG_MEETING_TESTS` | Hour-long recording and crash recovery |
| `SIDEWAVE_LIVE_LONG_MEETING` | Notes for a long meeting |

### Releases

`scripts/bump-version.sh` sets the version and build number. `scripts/release.sh` builds, signs
with Developer ID, notarizes, and packages `SideWave.dmg` with a signed Sparkle update entry.
`scripts/publish-release.sh` creates the GitHub release and adds the entry to the appcast.
`scripts/validate_release.py` checks signatures, entitlements, and the published feed.

The site in `site/` is built with Astro into `docs/`, which GitHub Pages serves at sidewave.dev.

## Dependencies

| Package | Version | Used for | License |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.17.7 | Speech recognition, VAD, speaker labels, voice output | Apache 2.0 |
| [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | 3.32.3 | Gemma inference | MIT |
| [Swift Transformers](https://github.com/huggingface/swift-transformers) | 1.3.5 | Tokenizers and chat templates | Apache 2.0 |
| [Swift Hugging Face](https://github.com/huggingface/swift-huggingface) | 0.9.0 | Model downloads | Apache 2.0 |
| [Swift Markdown](https://github.com/swiftlang/swift-markdown) | 0.8.0 | Meeting notes | Apache 2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | Updates | MIT |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | Voice agent server | MIT |

Model weights have their own licenses: Parakeet TDT and Parakeet Ultra use CC-BY-4.0, the live
preview model (Parakeet Realtime EOU) uses the NVIDIA Open Model License, the CTC vocabulary model
uses Apache 2.0, Silero VAD uses MIT, Gemma 4 uses Apache 2.0, and Nemotron 3 diarization uses
OpenMDW-1.1. See [ACKNOWLEDGMENTS](ACKNOWLEDGMENTS) for attribution.

## License

SideWave is licensed under [Apache 2.0](LICENSE). See [ACCEPTABLE_USE.md](ACCEPTABLE_USE.md) for
use terms.

Copyright 2026 Richard Stoker
