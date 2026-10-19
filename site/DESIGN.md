# Site design

**Said and written.** SideWave turns what you say into what you meant to write. The site uses
that move as its one recurring device: a line as it was spoken, in the overlay's draft gray with
the fillers struck, sits over the same line refined. Everything else stays quiet so the wave title
and the app carry the color.

## Palette

| Role | Light | Dark |
|---|---|---|
| Ground | `#f2f2f2` | `#131315` |
| Raised surface | `#ffffff` | `#1d1d20` |
| Ink | `#151516` | `#f2f2f4` |
| Draft (spoken lines) | `#6e6e74` | `#85858d` |
| Secondary text | `#55555b` | `#a8a8b0` |
| Spectrum | the app's seven system colors, only in the title, the favicon, and refine moments | |

Neutral grays with no warm or blue cast. Never cream, never a tinted near-black with one acid
accent, never a misted silver-to-blue-gray ramp.

## Type

- Clash Display: the title and the refined lines.
- `ui-rounded` (SF Pro Rounded on a Mac): the spoken lines, because the overlay sets live text in it.
- System UI: body text, controls, and docs.
- Monospace only for code.

## Layout

- The hero is centered: the title, the hero line, one Download button, and the Home window
  below them.
- Sections share one orientation: the said/written pair and a short paragraph on the left, the
  app on the right. On phones they stack.
- No cards, icon tiles, eyebrow labels, numbered steps, stat rows, logo strips, testimonials,
  pill badges, hairline dividers, or gradient text outside the title.

## Motion

- The title's shader wave is the page's one moving brand element.
- A refined line settles from draft gray to ink once, with the overlay's color pass, the first
  time it enters view in a session. Reduce Motion shows it settled.
- Nothing pins, smooth-scrolls, or delays input.

## Media

Every image is a window of the running app, captured in light and dark with the staged demo
history and glossaries from `Tests/SideWaveTests/SiteScreenshotTests.swift`. Each keeps its own
macOS shadow, and `src/data/screens.json` holds the shadow widths so the window's edges line up
with the column. No mockups, offscreen renders, placeholders, or personal data.
