---
title: "Exporting"
description: "Save a captioned MP4, WebM or ProRes video, SRT, VTT or JSON subtitles, or only the captions on a green screen, in the size and frame rate you choose."
sidebar:
  order: 4
---

# Exporting

## A captioned video

Select **Download**, and choose:

| | Choices |
|---|---|
| **Format** | MP4 (H.264), MP4 (H.265), WebM (VP9), MOV (ProRes) |
| **Size** | 720p, 1080p or 4K (the short side), with the video's own size named by its number. It may be above the original's. |
| **Frame rate** | 30 or 60 fps, with the video's own named by its number. |
| **Background** | **Video** (the captions on the picture), or **Green screen** |

There is no quality slider. A download is a second encoding of your video, so each format is made as good
as its codec does well, and you choose the size with the size and frame rate.

| Format | File | Notes |
|---|---|---|
| MP4 (H.264) | `.mp4` | Plays everywhere. The usual choice. |
| MP4 (H.265) | `.mp4` | Smaller files at the same quality, but not every player or editor reads it. |
| WebM (VP9) | `.webm` | For the web. Slow to encode: expect 5 to 10 times real time on a modern CPU. |
| MOV (ProRes) | `.mov` | For editing. The files are very large: about 220 Mbps, roughly 1 GB per 40 seconds of video. |

A higher frame rate than the original repeats the picture's frames, but the captions are drawn at every
output frame, so their animation is smoother.

The video is made on your server, and the result is kept, so asking for the same thing again is
instant. Anything that changes the output (the words, the style, the timing offset, the format, the size
or the frame rate) is a new file.

## Captions on a green screen

Choose **Green screen** as the background to get only the captions, over solid chroma green and with no
sound. Key the green out in your video editor and lay the captions over any footage. Use ProRes or
H.264 for it.

## Subtitle files

The **Download subtitles** button gives:

- **SRT**, the format nearly every player and platform reads. Each cue is one caption, the lines you see on
  the video and in the timeline (so the **Words per line** setting decides them), and the timing carries the
  caption offset. It has no word timing.
- **VTT** (WebVTT), the same cues with the timing of every word inside them, for players that can highlight
  the word being said.
- **JSON**, the full transcript with the timing and confidence of every word. See
  [Transcript format](../reference/transcript-format.md).

The caption engine writes the SRT and VTT files, the same code that cuts the captions on the video, so they line up with it. On the iPhone and the Mac, the Save sheet has an SRT and a VTT button that share the same files.

## From a script

All of this is available over the [HTTP API](../reference/api.md#export-a-video).
