---
title: "Self-hosted Whisper captions with Docker"
description: "Run Whisper or Parakeet on your own machine with Docker to transcribe videos and add animated captions, with no cloud service and no GPU required."
sidebar:
  order: 3
---

# Self-hosted Whisper captions with Docker

OpenCaptions runs speech recognition on your own machine and turns the result into burned-in animated captions or
subtitle files. Nothing leaves the server unless you choose a provider that needs it.

```bash
curl -O https://raw.githubusercontent.com/leogaudin/opencaptions/main/docker-compose.yml
docker compose up -d
```

Images are published for amd64 and arm64, so it runs on a Linux server, a Mac with Apple silicon or a Raspberry Pi.

## Which model

- **Parakeet Ultra**, the default, covers 25 European languages and is fast on a CPU.
- **Whisper** covers about 100 languages, and on a GPU it is the fast one.

The [speech models page](../self-hosting/speech-models.md) lists them, and the
[benchmarks](../project/speech-model-benchmarks.md) show the accuracy and speed we measured, with the method.

## What you get

Word-level timing, a timeline to correct it, [nineteen looks](../guides/styling.md), and
[exports](../guides/exporting.md) to MP4, WebM, ProRes, SRT, VTT and JSON.

## Questions

**Does it need a GPU?**
No. [A GPU](../self-hosting/gpu.md) speeds up transcription, and it is optional.

**Is there an API?**
Yes. Scripts can use it with an API key, and another OpenCaptions server can transcribe for this one.
