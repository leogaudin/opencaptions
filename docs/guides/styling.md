---
title: "Styling captions"
description: "The nineteen caption looks in OpenCaptions and every setting of the style panel, from fonts and colours to animation, outline and timing."
sidebar:
  order: 3
---

# Styling captions

A caption's look is a **style**: a font, colours, a background, an animation and where it sits. The
**Presets** tab starts you from a finished look, and the other tabs change any part of it. The preview
redraws as you move a control, and the export uses exactly the same drawing.

## The looks

| Look | What it does |
|---|---|
| **Purple Punch** | A coloured box slides from word to word as it is said. The default. |
| **Bold** | Heavy type, each word popping as it is said. |
| **Plain** | Clean captions with no animation. |
| **Karaoke** | The colour sweeps across each word as it is spoken. |
| **Paper** | The word being said is highlighted. |
| **Boom** | Big, bouncing words in a display font. |
| **Lyric** | The line is soft and dim until each word is reached, then sharp. Nothing moves. |
| **Stickers** | Each word on its own coloured label. |
| **Cinema** | A serif face with words fading in. |
| **Terminal** | A monospaced, highlighted look. |
| **Neon** | A glowing neon face. |
| **Typewriter** | Words typed out one at a time. |
| **Handwritten** | A handwriting face with a marker stroke drawn under each word. |
| **Pop** | White letters with an orange outline that, as each word is said, rise out of the page on a short golden extrusion, with a soft dark shadow to read against any picture. |
| **Poster** | Tall condensed capitals stacked into a block, every row as wide as the widest, the word being said in red. |
| **Slam** | Heavy capitals dropping in, the line knocked down a little as each lands. |
| **Cascade** | Plain white type whose letters rise into place one after another as each word is said. |
| **Title Card** | Tall, condensed capitals in a bold serif, flush left on a sharp black rectangle with a faint white glow, as on a film title card. |
| **Editorial** | A book serif, flush left, each word coming out of a short blur. Its looks are dealt to the words at random (**Shuffle looks** deals again), and you can pick another for any word: a tiny italic for the small words, an italic serif or a heavy sans in the highlight colour for the ones that matter. |

A preset sets the whole style, so pick it first and adjust after. Selecting one keeps your caption
position, font size and words per line, which belong to your video.

## Text

- **Font**: pick one of the fonts in use, or **More fonts** to search the whole Google Fonts catalogue.
  Inter, Poppins, Montserrat and Nimbus Roman come with the app. Any other font is downloaded from Google Fonts by
  the server the first time it is used, then kept, so the preview and the export use the same file.
  (On a server with no internet, a font that was never fetched falls back to Inter.)
- **Alignment**: **Left**, **Center** or **Right** (rows sit against that side of the block, and on the left or
  right the block is held by that edge, so every line starts in the same place), or **Justify** (a poster: short
  rows, each scaled to the same width).
- **Letter spacing** and **Stretch**: space the letters further apart or closer, and draw them wider or narrower
  (below 1 is condensed). Together they make a bold serif into a tall, tight title face.
- **Fill**: a plain colour, or a gradient of two to four colours from the top of the letters to the bottom.
- **Font size**, **Letter case** (normal or uppercase) and **Slant** (upright or italic).
- **Text color** and **Highlight colors**: a list of one to four colours. The first is the main one.
  A look that marks each word (the lit word, a box, a label, an underline) takes the colours in turn,
  a single shape (the sliding box, the progress bar) uses the first, and a sweep runs through all
  of them. Add a colour with **+**, remove one with **×** (the first cannot be removed).
- **Words per line**: how many words are shown together. A line also ends where the speaker paused.
- **Word spacing**.

## Background

The box behind the caption: **None**, **Solid** or **Pill**, with its **color** and **opacity**.

## Animation

Choose how the words are marked as they are said: **Highlight**, **Box**, **Pop**, **Fade**, **Karaoke**,
**Underline**, **Typewriter**, **Bounce**, **Focus**, **Slide**, **Progress**, **Stickers**, **Press**, **Rise**, **Slam**, **Drift**, or **None**.
Each tile shows the animation on your own caption.

## Outline

**Stroke width** for the outline around the letters, a **Shadow** (blur, and how far down and to the
right it falls) and a **Glow** with its own colour. With a shadow that falls but is not blurred (a solid, 3D look),
**Extrusion shading** darkens it with depth. The glow is drawn beneath the shadow, so with both it surrounds the extrusion too.

## Timing

One offset, in milliseconds, that moves every caption earlier or later against the audio. See
[Editing](./editing.md#shift-all-the-captions).

## Position

Drag the caption in the preview while the video is paused. It snaps to the centre lines of the picture, and to a margin on each side.

## Your own looks

The built-in presets are plain data in the repository
([`presets.json`](https://github.com/leogaudin/opencaptions/blob/main/apps/web/src/lib/presets.json)),
shared by the web app, the API and the iPhone app. A new look is an entry there.

## Scripts and fonts

The preview and the export are drawn by one engine with the fonts it finds. Captions in Arabic, Hebrew,
Devanagari, Thai and CJK scripts use a font that has those letters when the chosen font lacks them.
