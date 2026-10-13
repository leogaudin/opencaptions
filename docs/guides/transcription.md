---
title: "Transcription"
description: "Where and how OpenCaptions turns speech into words with timing, which speech models it offers (Whisper, Parakeet, Apple Speech), and how to choose the language."
sidebar:
  order: 1
---

# Transcription

Transcription gives every word of the video a start and an end time. You decide three things for each
video, in this order: **where** it happens, with **which speech model**, and in **which language**.
The web app and the iPhone app ask the same two questions: first where and with which model, then the
spoken language.

## Where it happens

| Provider | Where the audio goes | Use it when |
|---|---|---|
| **Local** (the default) | Nowhere. A model runs on the server's own machine. | You want privacy and have a few minutes of CPU, or a GPU. |
| **Another OpenCaptions server** | To the server you name, over its [API](../reference/api.md#transcription-service). | Your laptop has no GPU and a machine of yours has one. |
| **OpenAI** | To the OpenAI API, with your key. | You do not want to run a model at all. Their data policy applies. |

The page says so whenever a provider that sends audio away is selected. The two remote providers
are set up by the person who runs the server: see [Speech models and providers](../self-hosting/speech-models.md).

On the iPhone, the default is the phone itself, and a server of yours is an option in the settings.
See [The iPhone app](./iphone-app.md).

## Speech models

| Model | Languages | Good for |
|---|---|---|
| **Whisper Large v3** | About 100 | The best all-round accuracy. About 1.6 GB on a server, 627 MB on the iPhone. |
| **Whisper Small** | About 100 | Smaller and faster, less accurate. About 480 MB, and a fine first try. |
| **Parakeet Ultra** (default on a server) | 25 European languages | Fast: about 2.5 times quicker than Large v3 on a CPU, a little less accurate. About 0.65 GB. |
| **Apple Speech** | Those iOS offers | The iPhone only, built into iOS 26, with nothing to download. |

The web app and the iPhone app offer the same models. On a server, the first use of a model downloads it.

Parakeet Ultra covers Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French,
German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian,
Russian, Slovak, Slovenian, Spanish, Swedish and Ukrainian. If a recording is in another language, the
server says so and you choose a Whisper model instead.

Accuracy varies by language, and the numbers are in the
[speech model benchmarks](../project/speech-model-benchmarks.md#accuracy-fleurs-test-20-clips-per-language).
In short: Parakeet Ultra is the default for its 25 languages; Whisper Large v3 is the safe choice for the
best accuracy, and for every language Parakeet does not cover.

## The spoken language

Pick the language the video is spoken in from the searchable list, which has a flag for each. The list
follows the model: Parakeet shows its 25, Whisper shows them all. The language you used last is
selected to start with, otherwise your browser's or phone's.

There is no "detect it" choice in the apps: the language is always chosen. (The API still accepts
`auto` for scripts.)

Captions can be drawn in Latin, Cyrillic, Arabic, Hebrew, Indic, Thai and Chinese, Japanese and
Korean scripts. Words in a script the chosen font lacks are drawn with a fallback font.

## What it does with silence and noise

The speech models can invent words over music or noise, or skip a loud stretch altogether. OpenCaptions
decodes the whole recording rather than letting a voice detector cut it, and cuts a line off at a long
silence so invented text does not run on. On the iPhone, a **second pass** re-reads the stretches
where nothing was heard but there is sound, and keeps only what two readings agree on. The
[benchmarks](../project/speech-model-benchmarks.md) explain why.

If a transcript comes back empty, the app says that no speech was found.

## Transcribe again, or bring your own

- **Re-transcribe** (in the editor's toolbar) runs a project again with another model or language. It
  replaces the transcript, so **your word edits are discarded**.
- **Edit as text** opens the transcript as JSON, and **imports a subtitle file** (SRT, WebVTT, with or
  without per-word times, or OpenCaptions JSON). See [Editing](./editing.md#edit-as-text-and-import-subtitles).
