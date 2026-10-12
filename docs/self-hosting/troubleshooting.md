---
title: "Troubleshooting"
description: "Fixes for the problems most often met when running OpenCaptions with Docker, from a stack that will not start to a transcription that never finishes."
sidebar:
  order: 8
---

# Troubleshooting

## Look at the logs first

```bash
docker compose ps                         # which services are up, and healthy
docker compose logs -f api                # the API
docker compose logs -f worker-transcription
docker compose logs -f worker-rendering engine
```

The health endpoint answers whether the database, the queue and the storage are reachable, and which device
transcription runs on:

```bash
curl -s http://localhost:5173/api/v1/health
```

## The stack will not start

**`docker compose` says the file is invalid, or a key is unknown.** The compose file needs Compose
**v2.24 or newer**. Check `docker compose version`, and update Docker if it is older.

**Port 5173 is already in use.** Something else is on it. Stop that, or change the left-hand number of the
`web` service's `ports:` line (`"0.0.0.0:8080:5173"`).

**A service is "unhealthy" on the first start.** The first start creates the database and the storage's key and
bucket, and the API waits for them. Give it a minute, then check `docker compose ps` again. If one stays
unhealthy, read its log.

## Transcription

**It takes a long time the first time.** The speech model is being downloaded. The upload page shows the stage:
"loading the model", then "transcribing". A smaller model downloads and runs faster. See
[Transcription](../guides/transcription.md).

**The model cannot be downloaded.** The server needs to reach Hugging Face. On a server with no internet,
copy a `models` folder from a machine that has downloaded the model.

**It runs out of memory and the job fails.** The model is too big for the machine. Pick a smaller one: see the
memory figures in [Speech models](./speech-models.md#local-models).

**Words are missing in a loud or musical stretch.** The speech models sometimes skip loud stretches. See
[Tuning Whisper](./speech-models.md#tuning-whisper): `WHISPER_FILL_GAPS` re-reads them at a cost in time. The
iPhone app does this on its own.

**Words are invented over music or silence.** The same settings guard against it
(`WHISPER_HALLUCINATION_SILENCE_S`).

**The transcript is empty.** The model found no speech. Try another model, or check that the video's sound
is not silent.

**The GPU is not used.** Check `device` in the health response. See [GPU acceleration](./gpu.md#if-the-gpu-is-not-found).

## Videos

**A video is refused.** The defaults are 2 GB and one hour: see [Limits](./configuration.md#limits).

**A link does not work.** Only `http` and `https` links to a video **file** are accepted, and an address on your
own network is refused. See [Security](./security.md#fetching-a-video-from-a-link).

**The preview does not play the video.** The preview plays what your browser can decode, and a format it cannot read (HEVC in some browsers, for
example) shows an error. The server decodes with FFmpeg, so it does not depend on this.

**The download takes a while.** A captioned video is encoded on the server, so a long video takes time, and
WebM (VP9) is the slowest, at 5 to 10 times real time. The first download of a given set of options takes
the time; the same options again are instant.

## Accounts

**I forgot the password and email is not set up.** See [Password reset](./accounts.md#password-reset).

**Sign-up is closed and I need an account.** An administrator sets `REGISTRATION_ENABLED` back to `true`, or
creates it by briefly opening registration. See [Accounts](./accounts.md).

## Starting over

```bash
docker compose down -v     # DELETES every project and account
docker compose up -d
```

If you only want to rebuild the services with the same data, `docker compose down` then `up -d` is enough.

## Still stuck

[Open an issue](https://github.com/leogaudin/opencaptions/issues) with what you did, what you saw, and the
logs of the service that complained. Please do not post an API key, and report a security problem
[privately](https://github.com/leogaudin/opencaptions/blob/main/SECURITY.md).
