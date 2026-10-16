# Site design

**Studio signal.** SideWave is a quiet tool at the edge of the screen, so the site is a calm, deep
blue-graphite room where the only saturated color is the app's wave spectrum. Color shows up only
where something is live: the title, the preview captures, the thin signal line between sections,
and the control you're using. Light mode is cool aluminum, never cream.

## Rules

- The title is `WaveTitle.astro`: the wave runs through the letters on WebGPU or WebGL2, with a CSS
  gradient fallback. Keep it.
- Clash Display for the title and section headings. Body text uses the system UI face, the same
  one the app uses on a Mac.
- Every image is the real app, rendered or captured with the staged demo content from
  `Tests/SideWaveTests/SiteScreenshotTests.swift`. No mockups, placeholders, or personal data.
- No cards, eyebrow labels, pill badges, numbered steps, stat counters, hairline spec sheets, glow
  blobs, or gradient text outside the title.
- Section headings settle from the draft gray to full color once, the way dictated words do in the
  preview. That and the signal line are the only scroll effects. Nothing smooth-scrolls, pins, or
  delays input, and Reduce Motion stills all of it.
- Copy is plain and specific, in the voice of the original line: "Dictation that works the way you
  work."
