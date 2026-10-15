---
title: "Style reference"
description: "Every field of an OpenCaptions caption style, with its type, range and default, as the API and the project files use it."
sidebar:
  order: 3
---

# Style reference

A project's `style_config` holds its caption style. It is the same object the editor's style panel edits, and
the same in the API, in the web app and in the iPhone app's project files. Send any subset of it, and the
fields you leave out keep their value. The defaults are the first built-in look, **Purple Punch**.

Colours are `#RRGGBB` hex strings. A few can carry an alpha channel as `#RRGGBBAA`, noted below.

| Field | Type and range | Default | |
|---|---|---|---|
| `font` | A font family name | `Poppins` | Inter, Poppins, Montserrat and Nimbus Roman are bundled. Any other Google Fonts family is fetched once by the server. |
| `font_size` | Integer, 12 to 300 | `64` | The size of the text. |
| `text_color` | Colour | `#FFFFFF` | |
| `highlight_colors` | 1 to 4 colours | `["#7C3AED"]` | What the animation paints with. The first is the main one. See [Styling](../guides/styling.md#text). |
| `animation` | One of the values below | `highlight_slide` | |
| `words_per_line` | Integer, 1 to 10 | `3` | A line also ends where the speaker paused. |
| `word_spacing` | 0 to 1 | `0` | As a fraction of the font size. |
| `text_case` | `none` or `upper` | `none` | |
| `italic` | Boolean | `false` | |
| `background` | `none`, `solid`, `pill` or `square` | `none` | `solid` has rounded corners, `square` sharp ones. |
| `background_color` | Colour | `#000000` | |
| `background_opacity` | 0 to 1 | `0` | |
| `position_x`, `position_y` | 0 to 1 | `0.5`, `0.84` | The caption block across the frame: its centre, or for `left` and `right` alignment its edge. Low and centred is the usual spot. |
| `stroke_width` | 0 to 10 | `0` | The outline around the letters. |
| `stroke_color` | Colour | `#000000` | |
| `shadow_blur` | 0 to 20 | `10` | |
| `shadow_color` | Colour, with optional alpha | `#000000A0` | |
| `shadow_offset_x`, `shadow_offset_y` | -40 to 40 | `0`, `0` | Where the shadow falls. With no blur it is solid and drawn as an extrusion. |
| `glow_blur` | 0 to 40 | `0` | A halo around the letters. `0` is none. |
| `glow_color` | Colour, with optional alpha | `#FFFFFF` | |
| `fill_colors` | 0 to 4 colours | none | A vertical gradient over each word's letters, from the top of the line to the baseline. Empty is `text_color`. |
| `extrude_shade` | 0 to 1 | `0` | How much a solid shadow (an extrusion) darkens from front to back, with a lit edge just behind the letters. Pick a shadow colour that is not black, or there is nothing to darken. |
| `extrude_back` | colour | `#00000000` | The colour an extrusion fades to at its back, from `shadow_color` at the front. Fully transparent for none. |
| `align` | `center`, `left`, `right`, `justify` | `center` | How the rows sit in the block. `left` and `right` also make `position_x` the place of that edge of the block, not its centre, so each line of words starts (or ends) at the same spot. `justify` is a poster: short rows (cut at about half the width), each scaled up (at most three times) to the width of the widest, stacked tight. A style saved with `layout` (`stack`, `line`) is read as `justify` and `center`. |
| `letter_spacing` | -0.2 to 1 | `0` | Extra space after each letter, as a fraction of the font size. Negative tightens. |
| `stretch` | 0.5 to 2 | `1` | How much wider (or narrower, below 1) the letters are drawn than the font has them: `0.79` is a condensed version of any face. |

## Animations

| Value | In the app | Marks the word being said by |
|---|---|---|
| `word_highlight` | Highlight | Changing its colour. |
| `highlight_box` | Box | A box behind it. |
| `word_pop` | Pop | Growing it briefly. |
| `word_fade` | Fade | Fading it in. |
| `word_sweep` | Karaoke | Sweeping the colour across it. |
| `word_underline` | Underline | A marker stroke drawn under it. |
| `typewriter` | Typewriter | Typing words out one at a time. |
| `word_bounce` | Bounce | Bouncing it. |
| `lyric_focus` | Focus | Sharpening and brightening it, with the rest of the line soft and dim. |
| `highlight_slide` | Slide | A single box that slides from word to word. |
| `line_bar` | Progress | A bar that fills along the line. |
| `stickers` | Stickers | A coloured label on each word. |
| `word_press` | Press | Raising it out of the page: its solid shadow grows into an extrusion as it is said, and the other words stay flat. |
| `word_slam` | Slam | Each word hidden until said, then dropping in from 1.7 times its size, the line jolting a little as it lands. |
| `letter_rise` | Rise | Each word hidden until said, its letters then climbing into place one after another. A word in a connected script (Arabic, Hebrew, the Indic scripts, Thai) rises as one piece. |
| `drift` | Drift | Each word hidden until said, then coming into focus out of a blur; the whole line pushes in a little over its life and floats, and the glow of the word being said is brighter than the rest (it needs a `glow_blur`). |
| `none` | None | Nothing: plain captions. |

## Timing offset

`caption_offset_ms` is a field of the project, next to `style_config`, not of the style. It is an integer from
-2000 to 2000, in milliseconds, and shifts every caption against the audio (positive is later). It does not
change the transcript.

## Presets

The eighteen built-in looks are plain data in
[`apps/web/src/lib/presets.json`](https://github.com/leogaudin/opencaptions/blob/main/apps/web/src/lib/presets.json),
each a name and a complete style in this shape. They are shared by the web app, the API's tests and the iPhone
app.
