// Copyright (c) 2026 Richard Stoker. Apache License 2.0.
// See LICENSE file for details.

import Foundation

extension InfoTopic {
    static let refine = InfoTopic(title: "How Refine works", icon: "text.badge.checkmark", points: [
        .init(icon: "waveform.badge.magnifyingglass", title: "While you speak",
              body: "Refine fixes grammar and punctuation as each part of your speech finishes. New and changed words animate into place; unchanged words stay still. When you stop, SideWave finishes any pending text before sending it."),
        .init(icon: "hand.tap", title: "Optional full rewrite",
              body: "Turn on Hold to rewrite and finish in Settings > General (Advanced view). Hold the shortcut for half a second when you stop, then release. Recording ends and the whole dictation is rewritten before it's sent."),
        .init(icon: "rectangle.3.group", title: "Templates",
              body: "Standard, Professional, and Concise paste into your app. Email, Instructions, AI Prompt, and Custom open a document you can review, edit, and copy."),
        .init(icon: "cpu", title: "Local models",
              body: "Apple Intelligence uses the model built into macOS. Gemma runs through MLX and needs a separate download. Larger Gemma models use more memory."),
        .init(icon: "lock.shield", title: "Processing and history",
              body: "Recognition and Refine run on this Mac. History keeps local copies for as long as your retention setting allows. Help > Data Transparency lists every download."),
    ])

    static let holdToRewrite = InfoTopic(title: "Hold to rewrite and finish", icon: "circle.dotted", points: [
        .init(icon: "hand.draw", title: "How it works",
              body: "When you stop a dictation, hold the shortcut for half a second, then release. Recording ends, the model rewrites the whole dictation, and SideWave sends the result. Push-to-talk keeps its normal release behavior."),
        .init(icon: "doc.text.magnifyingglass", title: "When to use it",
              body: "Use it when a long dictation needs its structure reconsidered. A normal stop already finishes pending text and rechecks the last sentence."),
        .init(icon: "brain", title: "Gemma thinking",
              body: "If Think before a full rewrite is on in Dictation > Refine > Advanced, Gemma reasons before rewriting, which adds time. Apple Intelligence does a regular full pass."),
        .init(icon: "checkmark.circle", title: "Off by default",
              body: "Turn it on in Settings > General. Press Escape while it's processing to keep the text without sending it."),
    ])

    static let smartPushToTalk = InfoTopic(title: "Smart Push-to-Talk", icon: "hand.tap", points: [
        .init(icon: "hand.point.up.left", title: "Hold to speak",
              body: "Choose Tap or hold next to Shortcut on Home. Hold the shortcut, wait for Listening, speak, then release to finish. A quick tap still starts and stops a longer dictation."),
        .init(icon: "bolt", title: "Fast by default",
              body: "Held dictation pastes the recognized text without a Refine pass. It suits short replies in chat windows, search fields, and AI prompts."),
        .init(icon: "slider.horizontal.3", title: "Options",
              body: "In Advanced view, Home can refine held dictation and press Return or Shift-Return after pasting."),
        .init(icon: "timer", title: "Hold threshold",
              body: "A press counts as a hold after 500 ms, measured from when recording is ready. Change it in Settings > Advanced if quick taps register as holds."),
    ])

    static let doubleTapRepaste = InfoTopic(title: "Double-tap to paste again", icon: "arrow.uturn.right", points: [
        .init(icon: "hand.tap.fill", title: "Quick repeat",
              body: "Press your shortcut twice within 300 ms to paste your last result into the focused field again."),
        .init(icon: "rectangle.on.rectangle", title: "When it helps",
              body: "Reuse the same text in another window without speaking again. SideWave keeps your last result separate from the clipboard."),
        .init(icon: "checkmark.circle", title: "Always available",
              body: "There's no setting for it. It's part of the shortcut."),
    ])

    static let microphoneStandby = InfoTopic(title: "Keep microphone on standby", icon: "mic", points: [
        .init(icon: "bolt", title: "What it does",
              body: "Keeps the selected microphone open between dictations, so recording starts without the 1 to 3 seconds macOS can need to wake an idle audio device."),
        .init(icon: "lock.shield", title: "The microphone indicator",
              body: "macOS shows the orange microphone indicator while standby is on. SideWave discards standby audio as it arrives. Nothing is recorded or saved until you press the shortcut."),
        .init(icon: "person.crop.circle.badge.xmark", title: "Other apps",
              body: "Other apps can't read SideWave's input. Each app needs its own microphone permission and gets its own stream from macOS."),
        .init(icon: "battery.75percent", title: "Power use",
              body: "Standby uses little power, similar to a paused media player."),
        .init(icon: "switch.2", title: "Turning it off",
              body: "Standby ends within a second. The next dictation takes the usual moment to wake the microphone."),
    ])

    static let fixedIntervalRefine = InfoTopic(title: "Fixed-interval refine", icon: "timer", points: [
        .init(icon: "metronome", title: "Timer-based splits",
              body: "Speech is split on a fixed timer (4, 8, or 12 seconds) even while you keep talking, so text refines continuously instead of waiting for pauses."),
        .init(icon: "rectangle.split.3x1", title: "Works with pause detection",
              body: "Pause detection still runs. Whichever boundary comes first is used, and no segment grows past 14.8 seconds."),
        .init(icon: "battery.50percent", title: "Power use",
              body: "Shorter intervals run the model more often and use more power. 8 seconds is balanced; 12 seconds is the lightest."),
        .init(icon: "exclamationmark.bubble", title: "Mid-sentence splits",
              body: "Because the timer doesn't wait for silence, it can split mid-sentence. Refine joins the pieces, but 4-second intervals leave more seams."),
    ])

    static let history = InfoTopic(title: "History", icon: "clock.arrow.circlepath", points: [
        .init(icon: "doc.text", title: "What's saved",
              body: "Each dictation's text, when it happened, and the app it went to. Audio isn't saved in History."),
        .init(icon: "text.alignleft", title: "Titles",
              body: "Entries get a short title from the local model so you can scan quickly. Expand an entry to read all of it."),
        .init(icon: "magnifyingglass", title: "Search",
              body: "Search matches titles, apps, the final text, and earlier stages."),
        .init(icon: "rectangle.expand.vertical", title: "Earlier stages",
              body: "Expand an entry and choose Show earlier stages to compare the live draft and the recognized text with the final result."),
        .init(icon: "clock", title: "Retention",
              body: "Use Keeps history at the bottom of the list, or Settings > Privacy. Older entries are removed automatically."),
        .init(icon: "lock.shield", title: "Stored on this Mac",
              body: "History is a file in SideWave's Application Support folder. It's never uploaded."),
    ])

    static var vocabulary: InfoTopic {
        InfoTopic(title: "Vocabulary", icon: "character.book.closed", points: [
            .init(icon: "character.cursor.ibeam", title: "What it's for",
                  body: "Teach SideWave words it gets wrong: names, products, acronyms, and terms from your field. A word can correct recognition, guide Refine, or both."),
            .init(icon: "books.vertical", title: "Glossaries",
                  body: "A glossary groups related words. Create your own or add bundles from the catalog. Only enabled glossaries are used, and a glossary can turn on automatically with specific templates."),
            .init(icon: "switch.2", title: "Two behaviors per word",
                  body: "Replace at dictation fixes the spelling every time, even with Refine off, and helps recognition pick the word. Send hint to Refine adds the word and its description to Refine's instructions. Most words should use both."),
            .init(icon: "doc.text.magnifyingglass", title: "Glossary and word descriptions",
                  body: "About this glossary describes the whole collection and is sent once per dictation. A word's description is a short hint, sent only when that word appears."),
            .init(icon: "text.book.closed", title: "Describe your field",
                  body: "Describe what you do in plain language and a local model suggests words for you to review. Nothing leaves your Mac."),
            .init(icon: "person.wave.2", title: "Speech profile",
                  body: "Separate from glossaries. A local model reads recent dictation and writes a short description of how you talk, which Refine uses to keep your voice. Edit it or turn it off any time."),
            .init(icon: "gauge", title: "Keep it focused",
                  body: "Enabled glossaries add to Refine's instructions on every pass. Word descriptions are capped at 120 characters and glossary descriptions at \(VocabularyStore.blurbCharCap). Turn off glossaries you aren't using."),
        ])
    }
}
