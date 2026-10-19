# Changelog

## 0.4.2 (2026-10-19)

### Changed

- The Email template keeps your tone. A quick note stays short and plain, and a formal message
  stays formal, instead of every email turning stiff and formal. A "more formal" change in the
  document window uses natural wording.

### Fixed

- Apple Intelligence emails no longer repeat a sentence as a bullet list or leave a lowercase
  greeting or sign-off.

## 0.4.1 (2026-10-18)

### Fixed

- The Email template no longer copies placeholder list items ("First item") into the email, turns
  a single sentence into a one-item bullet list, or writes "Nil" as the sign-off. Lists stay
  together instead of spreading over blank lines.
- Help is shorter and corrected throughout, including how a failed final Refine keeps your text,
  Control-Escape, and a translation indicator the preview doesn't have.

### Changed

- Settings > About > Acknowledgments lists every model and package SideWave uses, with its
  license and the full license and notice text.

### Security

- swift-crypto 4.5.2 (GHSA-8q93-f6xh-4f6f) and swift-nio 2.104.0 (GHSA-r3rc-9hpw-54v9,
  GHSA-rj37-6j9x-74q6, GHSA-cq87-8r7h-962v).

## 0.4.0 (2026-10-16)

### Removed

- The MCP voice agent: the local MCP server, the `sidewave-mcp` helper, and agent voices. On first
  launch SideWave clears the settings and keychain item they left. Relay (Press Return after
  dictation) stays in Experimental.

### Fixed

- Help matches the app: the panel you see while SideWave gets ready, refine cadence defaults,
  control and menu names, and the vocabulary switches.

## 0.3.0 (2026-10-16)

First public release. Download the DMG from [sidewave.dev](https://sidewave.dev). Later versions
install from SideWave > Check for Updates.

### Added

- Document templates: Email, Instructions, AI Prompt, and Custom open a document window with Read
  and Edit text views, Recents, and changes you type or speak.
- Output language. Dictate in one language and Refine writes in another.
- Gemma 4 E4B and 12B for Refine, alongside E2B and Apple Intelligence. Gemma thinking is
  available for documents in Advanced view.
- Glossary bundles from a public catalog, with manual updates by default and a change history.
  Personal glossaries take pronunciation hints, categories, and notes for Refine.
- Parakeet Ultra as a speech model choice.
- Data Transparency window that lists downloads and update checks.
- Downloads window with sizes and speed, and separate download, compile, and load steps.

### Changed

- Holding the shortcut is push-to-talk: hold to dictate, release to send. The old hold-to-refine
  gesture is now Hold to rewrite and finish in Advanced view, off by default.
- Escape stops a dictation without sending it. The text stays on Home to paste, resume, or discard.
- Simple and Advanced views share one Home screen. Advanced adds expert controls and doesn't
  change the engine.
- Settings and Help use native sidebars with search. Disclosure rows open from anywhere on the row.
- Meeting transcription labels up to eight speakers, resumes after an interruption, and writes
  notes for long meetings in sections.
- Releases are a notarized DMG. SideWave asks once whether to check for updates automatically.

### Fixed

- Stopping during live refinement finishes the remaining text instead of pasting it unrefined.
- Short final words are kept when you stop quickly.
- Failed and cancelled sessions keep their text in History.
- Paste checks the target app again before delivering and won't retry a paste it can't verify,
  so text isn't pasted twice.
- Model downloads repair missing files without replacing the model weights.

### Removed

- Sensitive-information redaction. Its false positives changed ordinary dictation.

## 0.2.0 (2026-04-23)

- Refine with Gemma 4 E2B or Apple Intelligence, with five templates.
- Vocabulary glossaries with replacement aliases and Refine hints, linkable to templates.
- Paste targeting that follows the original text field across window switches.
- Cancelled dictations saved to History.
- Experimental meeting transcription and the compact SideWave Mini window.
- License changed from MIT to Apache 2.0.

## 0.1.0 (2026-04-13)

- First release: local dictation with Parakeet TDT, vocabulary boosting, a live preview, number
  formatting, filler removal, history, and paste to the focused app or a chosen app.
