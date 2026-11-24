---
title: "Burn subtitles into a video, or export SRT and VTT, for free"
description: "Make captions that are part of the picture, or SRT and VTT subtitle files, from the speech in a video: with OpenCaptions, on your iPhone, Mac or your own server."
sidebar:
  order: 7
---

# Burn subtitles into a video, or export SRT and VTT

There are two kinds of subtitles, and which you need decides what to export.

- **Burned-in captions** are part of the picture. They show on every platform and player, and nobody can switch them
  off. This is what short-form video uses.
- **A subtitle file** (SRT or VTT) travels beside the video, and the player draws it. Viewers can turn it off or pick a
  language, and YouTube, Vimeo and most players take it.

OpenCaptions makes both from the same transcript.

## Burn them in

1. Add the video and transcribe it. Every word gets its own timing.
2. Correct any misheard word on the video.
3. Pick a [look](../guides/styling.md), from plain to animated, and place the caption where you want it.
4. Save the video. In the app it is saved as H.264 (or 10-bit HEVC for an HDR video), at the size and frame rate you
   choose. In the web editor you also choose the format: MP4 (H.264 or H.265), WebM or ProRes, at 720p, 1080p or 4K,
   and 30 or 60 frames per second.

## Export a subtitle file

The **Download subtitles** button, or the **…** menu in the app's Save sheet, gives:

- **SRT**, which nearly every player and platform reads. Each cue is one caption, the lines you see on the video. It has
  no timing for individual words.
- **VTT** (WebVTT), the same cues with every word's timing inside, for players that can highlight the word being said.
- **JSON**, the whole transcript with each word's timing and confidence. See
  [Transcript format](../reference/transcript-format.md).

The caption engine that draws the video also writes these files, so they line up with the captions on screen.

## Only the captions

To lay captions over footage in an editor, export them over solid green with no sound and key the green out. See
[green screen captions](./green-screen-captions.md).

## Where it runs

On an iPhone, iPad or Mac, the speech model runs on the device and the video is never uploaded. On a
[server you run yourself](../self-hosting/installation.md), you can also use the Whisper models, and the
[`opencaptions` package](../guides/agents.md) does the same on your computer from the command line or from Claude.

## See also

- [Exporting](../guides/exporting.md), every option.
- [Add captions on your iPhone](./add-captions-on-iphone.md).
