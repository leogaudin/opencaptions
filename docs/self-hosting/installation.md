---
title: "Installation"
description: "Requirements, what the OpenCaptions Docker Compose stack runs, where your data lives, and how to scale and update it."
sidebar:
  order: 1
---

# Installation

OpenCaptions is one Docker Compose file. Copy it, start it, and everything it needs comes up with
it. The [quick start](../getting-started/quick-start.md) is the short version of this page.

## Requirements

- **Docker** with **Compose v2.24 or newer** (`docker compose version`). On Linux, Docker Engine;
  elsewhere, Docker Desktop.
- **A machine that is on** whenever you want to caption: the stack uses the processor of the machine it
  runs on to transcribe and to make videos. A GPU makes transcription faster but is not needed
  ([GPU acceleration](./gpu.md)).
- **Disk** for the images (the API image is about 600 MB), for the speech models you use (from 145 MB to
  about 3 GB each) and for your videos and their exports.
- **A free port 5173**, the one port the stack publishes.

The images are published for `amd64`, and, with the first release, for `arm64` too, so a Mac with
Apple silicon or a Raspberry Pi can run them.

## Start it

```bash
mkdir opencaptions && cd opencaptions
curl -O https://raw.githubusercontent.com/leogaudin/opencaptions/main/docker-compose.yml
docker compose up -d
```

Open <http://localhost:5173>. That is the whole install: the compose file is self-contained, with no
other file to copy and no environment file to write. Every application setting has a default that is
right for this layout; see [Configuration](./configuration.md) for the few you may want to change.

:::note[Before the first release]
Until v0.1.0 is tagged, the images are the `edge` build of the main branch, which the compose file
uses by default. After the release they are `latest`, and you can pin a version with
`OPENCAPTIONS_VERSION=0.1.0 docker compose up -d`.
:::

## What runs

| Service | Role |
|---|---|
| `web` | The web app, and the **only published port** (`5173`). nginx serves it and passes `/api` and `/ws` to the API, so the browser talks to one address. |
| `api` | The REST and WebSocket API, accounts, and the queue. It brings its own database up to date when it starts. |
| `worker-transcription` | Extracts the audio, runs the speech model, stores the transcript. Handles one job and exits, so a loaded model never outlives its job and an idle stack holds none of its memory. |
| `worker-transcription-gpu` | The same on an NVIDIA GPU, only with the `gpu` profile. |
| `worker-rendering` | Hands the making of a captioned video to the engine and records the result. |
| `engine` | The Rust render server: decodes the video, draws the captions, encodes the result with FFmpeg. |
| `postgres`, `redis`, `garage` | The database, the job queue, and an S3-compatible object store for videos and exports. |

Transcription and rendering run on separate queues, so a backlog of videos being made never holds up
transcription, and each scales on its own.

## Where your data is

| What | Where |
|---|---|
| Accounts, projects, transcripts, styles | The `postgres_data` Docker volume |
| Videos, thumbnails, exports, downloaded fonts | The `garage_data` Docker volume |
| Job queue | The `redis_data` Docker volume |
| Speech models | A `models` folder **next to the compose file** (change it with `MODELS_PATH`) |

`docker compose down` keeps the volumes. `docker compose down -v` deletes them. See
[Backups and upgrades](./backups-and-upgrades.md).

## Scaling

Two settings, given on the command line, set how many workers run:

```bash
OC_RENDERERS=4 OC_CPU_TRANSCRIBERS=2 docker compose up -d
```

`OC_RENDERERS` is the number of render workers (default 1) and `OC_CPU_TRANSCRIBERS` the number of CPU
transcription workers (default 1). A speech model is large, so each transcription worker takes several
GB of memory while it works. The API holds no state of its own, so it can be run more than once, but
bring one up first: it brings the database up to date as it starts.

## Updating

```bash
docker compose pull
docker compose up -d
```

See [Backups and upgrades](./backups-and-upgrades.md) for what to do first.

## Building from source

In a clone of the repository, `docker compose up -d --build` builds every image from the source
instead of pulling it. `docker compose watch` adds live reload for development. The same compose file
does both; paths into the repository appear only in the parts Compose reads when building.
