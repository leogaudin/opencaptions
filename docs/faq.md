---
sidebar_position: 6
title: "FAQ"
description: "Short answers about OpenCaptions, including its cost, its privacy, the languages and speech models it supports, how to host it, and how it is licensed."
---

# FAQ

## What is OpenCaptions?

Free, open-source software that adds animated, word-by-word captions to videos. It transcribes the speech
with a model you choose, such as Whisper, Parakeet or Apple Speech, lets you style and correct every
caption, and exports a captioned video or subtitle files. It runs on your iPhone and on your own server.

## Is it free?

The code is free and open source, and hosting the web editor yourself costs nothing but your own hardware.
The iPhone app is free to use, with an optional one-time Pro purchase and no subscription.
See [Free and Pro](./guides/iphone-app.md#free-and-pro).

## Does it upload my videos?

Not unless you choose to. On the iPhone the speech is transcribed on the device, and when you host
OpenCaptions yourself your videos stay on your own server. There is no tracking and no analytics. The one
thing a server fetches on its own is a font or a model it does not have yet:
[what the server connects to](./self-hosting/security.md#what-the-server-connects-to-by-itself).

## Which languages does it support?

Whisper transcribes about 100 languages, Parakeet 25 European ones, and Apple Speech covers the languages
iOS offers. Captions can be drawn in Latin, Cyrillic, Arabic, Hebrew, Indic, Thai and CJK scripts, and the
interface is available in 13 languages. See [Transcription](./guides/transcription.md).

## How do I host it myself?

With Docker: download one file, start it with a single command, and open the editor in your browser. A GPU is
optional and makes transcription faster. See the [quick start](./getting-started/quick-start.md).

## Which formats can I export?

A captioned video as MP4, WebM or ProRes, subtitle files as SRT or VTT, a JSON transcript, or only the
captions on a green screen to key out in your own video editor. See [Exporting](./guides/exporting.md).

## Which speech model should I use?

Whisper Large v3 Turbo, the default, for the best accuracy across languages. Parakeet v3 when speed matters and
your language is one of its 25. Whisper Small to try things out quickly. The measurements behind this are in the
[benchmarks](./project/speech-model-benchmarks.md).

## Why are some of my words wrong, or missing?

Speech models make mistakes, most often on names, on quiet or overlapping speech, and on speech over loud music.
Fix a word by double-clicking it in the preview. See [Editing](./guides/editing.md), and for missing words
[Troubleshooting](./self-hosting/troubleshooting.md#transcription).

## How is it different from other caption tools?

It is open source and you can run it yourself, so your videos stay with you and there is no subscription. The
iPhone app works on the device, and the preview is the export: one Rust engine draws the captions in the
browser, on the server and on the phone.

## Can I use it from a script or a pipeline?

Yes. Everything the app does is an [HTTP API](./reference/api.md), with API keys.

## Can I translate the captions into another language?

No. OpenCaptions writes down what is said, in the language it is said in, and does not translate it. You can
import subtitles you have translated elsewhere: see [Editing](./guides/editing.md#edit-as-text-and-import-subtitles).

## What is the license?

AGPL-3.0. You can use, study, change and share it. If you run a modified version as a service, you must offer
its users the source code. Contributors accept a [CLA](https://github.com/leogaudin/opencaptions/blob/main/CLA.md)
so that the maintainer can also ship the code where the AGPL cannot go, such as the App Store. Third-party
components keep their own licences, see the
[NOTICE](https://github.com/leogaudin/opencaptions/blob/main/NOTICE) file.

## How do I report a bug or a security problem?

Bugs and ideas go to [GitHub issues](https://github.com/leogaudin/opencaptions/issues). A security problem goes
through the [private vulnerability report](https://github.com/leogaudin/opencaptions/blob/main/SECURITY.md).
