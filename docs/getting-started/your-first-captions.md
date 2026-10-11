---
sidebar_position: 2
title: "Your first captions"
description: "A walk through the OpenCaptions web editor, from adding a video to saving a captioned one."
---

# Your first captions

This page follows one video through the web app, from the first click to the saved file. It assumes
the [quick start](./quick-start.md) is done and you are signed in at <http://localhost:5173>.

## 1. Add a video

Select **New project** on the home page. Give the project a title, then either:

- **Upload file**: choose a video from your computer, or
- **From URL**: paste an `http://` or `https://` link to a video file. The server downloads it, and
  refuses addresses on your private network (see [Security](../self-hosting/security.md#fetching-a-video-from-a-link)).

A video can be up to 2 GB and an hour long by default. [Configuration](../self-hosting/configuration.md#limits)
shows how to change that.

Select **Next**.

## 2. Choose how to transcribe

The second step has two parts.

**Transcription provider and speech model.** The default, a model on your own machine, needs no
account and uploads nothing. Pick a model from the list: bigger ones are more accurate and slower.
If you are not sure, keep the default, or choose **Whisper Small** for a quick try. The other
providers send the audio to the OpenAI API, or to another OpenCaptions server of yours, and the page
says so whenever one of them is selected. See [Transcription](../guides/transcription.md).

**Spoken language.** Search the list and pick the language the video is spoken in. The list follows
the model: a model that handles fewer languages shows fewer. Your last choice, or your browser's
language, is selected to start with.

Select **Create project**. The video is uploaded and transcribed, and a progress bar shows the stage:
loading the model (downloading it, the first time), then transcribing.

## 3. The editor

When the transcript is ready, the editor opens:

- the **preview** on the left, the video with the captions drawn over it,
- the **style panel** beside it, in tabs,
- the **timeline** underneath, with a track for the video and one for the captions.

Press **Space** to play. Everything you change is saved by itself a moment after the last edit:
there is no Save button.

### Pick a look

The **Presets** tab holds thirteen looks. Select one and the preview changes at once. The other tabs
adjust it: **Text** (font, size, case, colours), **Background**, **Animation**, **Outline** and
**Timing**. See [Styling](../guides/styling.md).

### Fix a word

Pause the video and double-click a word in the preview. Type the correction and press **Enter**
(**Esc** cancels). See [Editing](../guides/editing.md).

### Move the captions

While the video is paused, drag the caption block in the preview. It is pulled towards the centre
lines of the picture, and a guide shows when it is centred.

### Retime a caption

Select a caption block on the timeline and drag one of its edges. If it touches the next caption,
that caption's edge is pushed along.

## 4. Save the result

Select **Download** and choose a format (MP4 with H.264 or H.265, WebM, or ProRes), a size, a frame
rate and a background: the video itself, or a green screen with only the captions, to key out in your
video editor. The file is made on your server and kept, so asking for the same thing twice is instant.

Subtitle files (**SRT**, **VTT** and **JSON**) come from the separate **Download subtitles** button
next to it, and need no processing. See [Exporting](../guides/exporting.md).

## What next

- [Transcription](../guides/transcription.md): which model, which language, which provider.
- [The iPhone app](../guides/iphone-app.md): the same, on the phone.
- [HTTP API](../reference/api.md): do all of this from a script.
