---
title: "Speech models and providers"
description: "Set up local speech models (Whisper, Parakeet), the OpenAI provider, or another OpenCaptions server as the place your server transcribes, and tune Whisper."
sidebar:
  order: 3
---

# Speech models and providers

What the people using your server can pick in the upload page and in **Re-transcribe** is decided here. For
how to choose between them, see the [transcription guide](../guides/transcription.md).

## Local models

The default provider, `local`, runs a speech model on the machine the stack is on, so no audio leaves it.
Two engines run the models:

- **faster-whisper** (on the CPU, or on an NVIDIA GPU) runs every Whisper size.
- **sherpa-onnx** (on the CPU) runs the other models. Parakeet Ultra (NVIDIA's Parakeet v3 trained further by Moondream), for 25 European languages, is the first.

A model is downloaded the first time someone uses it, from Hugging Face, into the `models` folder next to
the compose file, and it is kept there. To get it ready ahead of time, run one short transcription with it.
The default model is `parakeet-ultra`, set by `DEFAULT_MODEL`. A model that covers only some languages refuses a
recording in another one and says which language it was; the person chooses a model that covers it, and that
model is downloaded then. On a GPU, where Whisper is the fast one, set `DEFAULT_MODEL=large-v3-turbo`: Parakeet
runs on the CPU.

A transcription worker loads the model, does one job, and exits. A model therefore never stays in memory
after its job, and an idle stack uses none of it. The price is a model load per job. If a model is
too big for the machine's memory, pick a smaller one: Whisper Small needs about 1.1 GB, Large v3
about 2.2 GB on top of the rest of the stack, and Parakeet about 1.2 GB. Those
figures come from the [benchmarks](../project/speech-model-benchmarks.md#speed-and-memory-cpu).

Whether a model runs on the GPU is `WHISPER_DEVICE` (`auto` by default); see [GPU acceleration](./gpu.md).

## The OpenAI provider

Set `OPENAI_API_KEY` and the `openai` provider is offered. The audio of each video is sent to the OpenAI
API, and the page says so whenever it is selected. Their data usage policy applies. Without a key, the
option is shown as unavailable ("set OPENAI_API_KEY first").

## Another OpenCaptions server

A machine with no GPU can hand its transcriptions to one that has. On the machine that does the work,
create an API key on its **Account** page. On the machine that sends, set:

```yaml
TRANSCRIPTION_REMOTE_URL: "https://gpu-box.example.com"
TRANSCRIPTION_REMOTE_KEY: "oc_…"
```

The **Transcription service** section of the Account page has a **Test connection** button, and the
upload page then offers "Another OpenCaptions server" with its host named. The audio is sent there, and
deleted there when the job ends; the transcript is kept for `TRANSCRIPTION_RESULT_TTL_H` hours (24) so a
client that was suspended can still collect it.

The address goes through the same check as a video link: a private address (a GPU box on your LAN) is
refused unless its host is in `SSRF_ALLOWED_HOSTS`. Two servers cannot be configured into a loop: a server
that is itself forwarding refuses a request that was already forwarded.

The same API is what the [iPhone app](../guides/iphone-app.md#use-your-own-server-instead) uses.

## How Whisper is run

Whisper is run to find all the speech, not to be fast, and there is nothing to tune: the voice-detection filter is
off (it takes shouting, or speech over loud music, for non-speech, and what it drops is never transcribed, so
whole lines go missing), the no-speech check and a cut for text invented over silence are on, and the beam is 5.
Each value is fixed in the code at what the measurements chose. [Why these
defaults](../project/speech-model-benchmarks.md) has them.
defaults](../project/speech-model-benchmarks.md) has the measurements behind them.
