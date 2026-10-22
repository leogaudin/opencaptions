---
title: "The caption engine"
description: "How the Rust caption engine lays out and draws captions for the browser preview, the export and the iPhone app: scenes, animations, looks, fonts, colour, the C ABI and the render server."
sidebar:
  order: 3
---

# The caption engine

`apps/engine` is one Rust library (rustybuzz shaping, tiny-skia drawing) with three builds:

- **natively**, linked into the render server;
- **to WebAssembly**, drawing the editor preview over the HTML `<video>`;
- **as a static library**, for the iOS app.

**The preview is the export.** It is the same code with the same font files, and its arithmetic is
deterministic (an integer blur, no platform maths), so every build produces byte-identical frames. Nothing else
may draw captions. The [architecture](./architecture.md) page says where the engine sits in the whole system.

The drawing is `src/scene/`:

- `layout.rs` places the words;
- `anim.rs` says what each is doing at a time `t` (and holds `Animation::traits`, each animation's static facts);
- `draw.rs` paints a line in passes (backdrops, glow, shadow, words, bar);
- `pixels.rs` holds the blur and the pixel helpers, `text.rs` the shaping, `renderer.rs` the frame loop and its
  caches;
- `mod.rs` holds the tuning constants and shared types, and `ease.rs` the easing.

## Scenes and captions

- **Scene.** `oc_scene_new` lays out the transcript once for a style and a frame size and returns a handle
  (`oc_scene_free` releases it). `render(t)` then draws one frame, redrawing only the area that changed, and
  reports the band of rows it changed (`oc_changed_top`/`_bottom`; the whole frame after a new scene), so the web
  preview copies and draws just that band while a video plays.
- **Lines.** A line is the transcript's words in reading order, cut every `words_per_line` words, or sooner where
  the speaker paused (`model::cut`, the one rule the scene and the editors' line list share). Words said minutes
  apart never share a caption. A pause is a silence of three times the usual start-to-start time between words in
  that transcript, so it is judged against the speaker's tempo and not a clock (`model::pauses`; the API's copy is
  held to the same cases in `apps/engine/testdata/pauses.json`). A line holds through short gaps and clears in long
  ones. `oc_active_index` is the flat index of the showing line's first word, not its number, because lines are not
  all the same length.
- **Timing offset.** One global nudge of every caption against the audio (`caption_offset_ms`, positive is later,
  times clamp at zero) is part of the scene, so the preview and the export shift identically. The edit calls take it
  too: they report times as shown and write them back unshifted.
- **Subtitle files.** SRT and VTT are written here too (`subtitles.rs`, `oc_subtitles`): a cue is a caption line as
  the scene cuts it, with the offset applied, so a file lines up with the picture. The server answers
  `POST /subtitles` with it, and the iPhone app calls it natively.
- **Position.** `position_x`/`position_y` are the normalized centre of the caption block, clamped so it stays in
  frame. The editor drags the block and hit-tests words using the geometry the engine reports (`active_*`).
  Dragging is magnetic: `snap_axis` pulls the block's start, middle and end to the frame's near margin, its centre
  and its far margin (the margin is 6% of the width, the same distance down as across) when one is within a few
  screen pixels, so a caption can sit centred or flush against either margin whatever its width. The editor passes
  the axis's size, the pull in pixels, the block's length and which part of it `position` holds (the start for
  `align: left`, the end for `right`, else the middle), then draws a guide at the line returned while snapped, so
  every editor snaps the same way.
- **Edits.** Cutting captions, retiming a word edge and editing a word live in the engine (`edit.rs`). A word is
  edited one at a time (renamed, or deleted by clearing it): text of several words is refused, because splitting a
  word would invent timings. The web calls them through WebAssembly, and the phone calls the same code natively.

## Styles

All of a style is the engine's, so the preview and the export agree.

### Animations

There are eighteen. Each is an entry in `Animation::traits` (whether its words sit on a box, how far the effect
reaches past the block, how far a word grows past its slot, whether the word being said takes the highlight
colour) and an arm in `word_state`; the exhaustive matches refuse to compile until a new one has both.

| Animation | What it does |
|---|---|
| `word_highlight` | The word being said turns to the highlight colour. |
| `highlight_box` | The word being said sits on a box. |
| `word_pop` | The word pops past its size. |
| `word_fade` | Each word fades in. |
| `word_sweep` | Karaoke: the highlight fills each word left to right as it is said. A sweep paints each letter once, the highlight on the side it has passed and the plain colour on the rest, so no soft edge of the plain word shows round it. |
| `word_underline` | An underline fills as the word is said. |
| `typewriter` | Typed out letter by letter with a cursor. The steps are whole letters, so a frame changes only when one appears. |
| `none` | Nothing moves: subtitles. |
| `word_bounce` | Bounced up past its size, leaning left and right in turn. |
| `lyric_focus` | Brought into focus out of a dim blur; the words already said stay sharp. |
| `highlight_slide` | Lit by one box that slides from word to word. |
| `line_bar` | A bar under the line fills as the line is spoken. |
| `stickers` | Each word on its own tilted label. |
| `letter_rise` | Its letters rise into place one after another as it is said. One outline per grapheme cluster, grouped by the shaper's cluster index, in reading order; a word in a connected script, where the letters join or reorder, is one cluster and rises as a piece. The word is hidden until its start, and its shadow and glow follow the letters. |
| `word_slam` | Dropped in from 1.7 times its size over 0.12 s with no overshoot, and the whole line is jolted as it lands: a knock of about 3.5% of the font size that dies away over 0.15 s along a fixed direction by the word's place (a polynomial envelope, no sine). The knock is part of the frame's identity. |
| `word_press` | Raised out of the page as it is said: its solid shadow grows from nothing to the full extrusion, and the other words stay flat. |
| `drift` | Brought into focus out of a blur while the whole line pushes in about 6% over its life and bobs by 2% of the font size over 3 s. The line's motion is a transform applied to every word and part of the frame's identity; its wave is a polynomial. The word being said glows brighter, the halo's alpha scaled from 55% to 100%. |
| `blur_in` | Each word comes out of a short blur (0.12 s) as it is said; nothing moves and nothing glows. Drift's entrance alone. |

- The motion is eased with the engine's own arithmetic, never a platform sine, so the builds agree to the byte.
- The line's bar and the sliding box are one shape per line (`Guide`), part of the frame's identity, so a frame is
  redrawn when they move.
- The finished shadow and glow layers are kept while the line's words, jolt and drift are unchanged. A drifting glow
  is laid down three times into its layer once and carried by the line's transform each frame, because rebuilding
  it every frame cost most of the frame.

### Beside the animation

- **Outline.** A stroke around the letters.
- **Shadow.** A blur and an offset. A shadow with no blur is solid and is drawn as an extrusion: the letters carried
  from where they are to the offset a pixel at a time, so it reads as their outline continued. `extrude_shade`
  darkens a solid shadow with depth: its stamps are laid from the back forward, so each pixel takes the colour of the
  nearest stamp that covers it, and the first step is lightened as a lit edge.
- **Glow.** A blurred halo in its own colour, laid down three times to read as light.
- **Upper case.** Drawn, never stored: the transcript is untouched.
- **Italic.** The family's real italic face when it has one; otherwise the upright face sheared by about 11
  degrees, so any font leans and no italic file has to be fetched (`FontBook::styled`).
- **Fill colours.** `fill_colors` paints each word with a vertical gradient from the top of the em box to the
  baseline.
- **Optional fields.** Every field after `shadow_color` is optional with a default of "off", so a style that lacks
  it opens as if it were off.

### Alignment and spacing

`align` is `center`, `left`, `right` or `justify`.

- Rows sit centred, against the block's left edge or against its right edge. `left` and `right` also hold the block
  by that edge (`position_x` is the edge, so a line of other words starts where the last one did), and the clients
  move the block to the edge, or back to the middle, when the alignment changes (`positionOnAlign` on the web,
  `positionX(afterAligning:)` on iOS).
- `letter_spacing` (a share of the font size, after every letter but the last) and `stretch` (a horizontal scale of
  the outlines and advances) reshape any face. Both are applied where the text is shaped, and a default leaves every
  frame unchanged.
- **Justify** cuts rows at 0.55 of the usual width, then scales each row up to the widest row's natural width, at
  most three times, and stacks them with leading of 1.0 of each row's own size. A word's `size` (its row's scale) is
  what every animation uses wherever it would use the font size: the underline's thickness, the cursor, the sliding
  box's corner, a label's radius, the blur of a soft word, how far a letter rises, and the outline, shadow and
  extrusion, so every animation works in a stack.

### Word looks

`Style.variants` (at most six, defined by a preset) are looks a word can wear instead of the style's.

- A `Variant` overrides `font`, `scale`, `italic`, `text_case`, `text_color`, `accent` (the style's highlight colour), `letter_spacing`, `stretch` and
  `box_color` (a square label behind the word), each optional.
- `Word.variant` is an index into them. Absent is the style's own; an index past the end draws as the style's own
  and is kept.
- The layout resolves each word's look once (`look_of`), shapes the word with its own face and tracking, and sits
  every word of a row on one baseline: the row's height is the tallest word's, the baseline the tallest word's
  half-leading, each word using its own face's ascent and descent, and a word's slot is its own line box on that
  baseline.
- A word's `size` is its row's scale times its look's `scale`, so every effect (outline, shadow, glow, extrusion)
  grows with it.
- The editors only choose. `set_variant` sets or clears one word's look; `shuffle_variants` deals the looks to
  every word at random from a seed (half the words keep the style's own look, the rest take the looks evenly, never
  one twice in a row; the same seed deals the same, SplitMix64, so it is identical on every platform). Picking a
  preset with looks and the Shuffle looks button call it. `set_word` and `retime` keep a word's look, and the word
  card shows the word drawn by the engine in each look.

### Highlight colours

`highlight_colors` is a list of one to four hex colours, the first the primary (a row of pickers with a plus and a
remove, on both editors).

- A look that marks each word (the lit word, a box, a label, an underline, the cursor) takes the colours in turn,
  word by word.
- A single shape (the sliding box, the bar) is the primary.
- A sweep runs through all of them as a gradient across the line.

### Presets and tiles

- **Presets** are data (see [Data](./architecture.md#data)). Among them: Purple Punch (a box that slides between
  words), Karaoke, Bold (Montserrat Black, in capitals with a thick black outline carried out into a hard dark
  extrusion with a little shading), Boom (the word being said grows and is drawn over its neighbours), Lyric (soft
  until said, and the line never changes size), Stickers, Plain, Neon, Typewriter, Handwritten (a marker stroke laid
  under the words as they are said), Pop (white letters in an orange outline, the word being said rising on a short
  golden extrusion), Cascade (letters rising one after another), Slam (heavy capitals dropping in), Poster (a stack
  of rows scaled to one width), Title Card (condensed bold serif capitals flush left on a sharp black box) and Editorial (a book serif with looks to mix).
- **Tiles.** The preset tiles, and the choices in the Background and Animation tabs, are drawn by the engine
  (`CaptionEngine.samples`: the same drawing as the preview and the export, in a phone-shaped frame, cropped to the
  band around the caption), so each shows its real font, colours and highlight, each in a scene of its own, so the
  preview's is not disturbed. A background with no opacity is given a visible one when chosen.

## Fonts

- Inter, Poppins (ExtraBold, the default preset's), Montserrat (Black, the Bold preset's), Nimbus Roman (Bold, the
  Title Card's: a clone of Times Bold, AGPL with URW's font exception), Instrument Serif and Barlow Condensed (the
  Editorial preset's) are bundled. Inter is the glyph fallback, so an offline install still draws.
- Any Google Fonts family can be chosen: the API fetches it once, keeps it in the store (`fonts/`), and gives the
  preview and the engine the same file. A bundled face wins over a requested one, and fallback only reaches
  bundled faces.
- The font row opens a list of the fonts in use, each name in its own face (a name-only subset fetched from Google,
  a few KB), and "More fonts" opens the whole Google Fonts catalog (the same one the server lists), searchable.
- Variable fonts are drawn at weight 800.

## Colour

SDR sources render in BT.709. HDR sources (PQ, HLG) are either tone-mapped to SDR or kept HDR at 10-bit BT.2020,
with captions at reference white.

## The C ABI

One C ABI for every caller, prefixed `oc_` and declared in `include/opencaptions_engine.h`. A test keeps the header
and the exports in step.

- Inputs are byte buffers from `oc_alloc`; outputs land in a result buffer.
- Fonts are one book per process and a scene is a handle, so a preview, the tiles and the word card (one
  WebAssembly module on the web page) each hold their own.
- Calls may come from any thread (a Swift actor hops between them) but the caller serializes them.

## The render server

The `opencaptions-engine` binary, built with the crate's `server` feature (`tiny_http`, `ureq`), so the library the
browser and the apps link does not carry its HTTP stack. Its code is `main.rs` and the modules `http` (routes),
`render` (a job), `ffmpeg`, `colour`, `upload` and `progress`.

- **Routes.** `GET /health` (which also reports the engine's render revision), `POST /render` and `POST /subtitles`.
- **Credentials.** `POST /render` takes a presigned read URL for the source and a presigned write URL for the
  output, valid for that render only, so the engine holds no storage credentials. The render worker sends
  `x-engine-token` (`ENGINE_TOKEN`, a credential the two share like the storage keys) and the engine answers 401
  without it; `/health` stays open. It posts progress back, and reads the fonts a transcript's scripts need from
  the API, with a per-job token. The API reaches it through a `RenderBackend` seam (`RENDER_BACKEND`).
- **Checks.** A request is checked before anything is drawn (`SceneInput::check`, shared with the browser and phone
  builds: finite sizes in range, a bounded frame, http(s) addresses only; FFmpeg may open only http(s) too), and an
  empty `ENGINE_TOKEN` is refused at start.
- **Concurrency.** At most `ENGINE_MAX_RENDERS` (4) renders run at once and the rest wait.
- **Pipeline.** Frames are drawn on a thread of their own while the last is written, and only the box the captions
  can ever be in is piped to FFmpeg and laid over the video there (`Scene::overlay_bounds`), a fraction of the
  frame. FFmpeg is killed if the render ends any other way than finishing, and the upload is retried.
