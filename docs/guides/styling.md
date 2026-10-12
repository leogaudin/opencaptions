---
title: "Styling captions"
description: "The thirteen caption looks in OpenCaptions and every setting of the style panel, from fonts and colours to animation, outline and timing."
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
| **Chunky 3D** | Gold gradient letters on a shaded extrusion, pushed in as each word is said. |
| **Cascade** | Plain white type whose letters rise into place one after another as each word is said. |

A preset sets the whole style, so pick it first and adjust after. Selecting one keeps your caption
position, font size and words per line, which belong to your video.

## Text

- **Font**: pick one of the fonts in use, or **More fonts** to search the whole Google Fonts catalogue.
  Inter, Poppins and Montserrat come with the app. Any other font is downloaded from Google Fonts by
  the server the first time it is used, then kept, so the preview and the export use the same file.
  (On a server with no internet, a font that was never fetched falls back to Inter.)
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
**Underline**, **Typewriter**, **Bounce**, **Focus**, **Slide**, **Progress**, **Stickers**, **Press**, **Rise**, or **None**.
Each tile shows the animation on your own caption. **Motion blur** smears the words that move along
their path, the same in the editor and in the download; at 0 every frame is sharp.

## Outline

**Stroke width** for the outline around the letters, a **Shadow** (blur, and how far down and to the
right it falls) and a **Glow** with its own colour. With a shadow that falls but is not blurred (a solid, 3D look),
**Extrusion shading** darkens it with depth.

## Timing

One offset, in milliseconds, that moves every caption earlier or later against the audio. See
[Editing](./editing.md#shift-all-the-captions).

## Position

Drag the caption in the preview while the video is paused. It snaps to the centre lines of the picture.

## Your own looks

The built-in presets are plain data in the repository
([`presets.json`](https://github.com/leogaudin/opencaptions/blob/main/apps/web/src/lib/presets.json)),
shared by the web app, the API and the iPhone app. A new look is an entry there.

## Scripts and fonts

The preview and the export are drawn by one engine with the fonts it finds. Captions in Arabic, Hebrew,
Devanagari, Thai and CJK scripts use a font that has those letters when the chosen font lacks them.
