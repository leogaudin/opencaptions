---
title: "HTTP API"
description: "Use OpenCaptions from a script. Authenticate with an API key, create a project, transcribe it, and download the captioned video or the subtitles."
sidebar:
  order: 1
---

# HTTP API

Everything the web app does is an HTTP API, and it is the same one your scripts use. Your instance documents
it interactively, with every field and every error, at **`/api/v1/docs`** (for example
`http://localhost:5173/api/v1/docs`; another view is at `/api/v1/redoc`, and the OpenAPI document is
`/api/v1/openapi.json`). This page is the
guide to using it; that one is the reference.

## Authentication

Create an [API key](../self-hosting/accounts.md#api-keys) on the Account page and send it as a bearer token:

```bash
API=http://localhost:5173/api/v1
AUTH="Authorization: Bearer oc_…"
```

A key reaches every endpoint except account management (`/auth` and `/api-keys`), which needs a signed-in
browser. A key can be revoked at any time on the same page.

All paths below are under `/api/v1`, and all bodies are JSON unless a file is uploaded.

## From a video to a captioned video

```bash
# 1. Create a project: upload a file, or pass -F video_url=https://… instead
PROJECT=$(curl -s -H "$AUTH" -F title=episode -F video=@episode.mp4 "$API/projects" | jq -r .id)

# 2. Transcribe. Returns a job; poll it until it is completed
JOB=$(curl -s -H "$AUTH" -X POST "$API/projects/$PROJECT/transcribe" \
  -H 'Content-Type: application/json' -d '{"language":"en"}' | jq -r .id)
curl -s -H "$AUTH" "$API/jobs/$JOB" | jq '.status, .progress'

# 3. Ask for the video. Returns ready=true with a URL, or a job to poll first
curl -s -H "$AUTH" -X POST "$API/projects/$PROJECT/download" \
  -H 'Content-Type: application/json' -d '{"format":"mp4"}'

# 4. Download it
curl -s -H "$AUTH" -o captioned.mp4 "$API/projects/$PROJECT/download/mp4"
```

Each step has more to it, below.

### Create a project

`POST /projects` takes `multipart/form-data` with a `title` and **either** a `video` file **or** a `video_url`,
not both. It returns the project, including its video's size, frame rate and duration. A link is fetched by
the server with [safeguards](../self-hosting/security.md#fetching-a-video-from-a-link).

### Transcribe

`POST /projects/{id}/transcribe` takes:

| Field | |
|---|---|
| `language` | A two-letter code such as `en` or `fr`, or `auto` to detect it. Defaults to `auto`. |
| `provider` | `local`, `openai` or `opencaptions`. Omit it for the server's default. |
| `model` | A model id such as `large-v3-turbo` or `parakeet-ultra`. Omit it for the default. |

`GET /settings` lists the models and languages the server offers. On a server in hosted mode, `provider` and
`model` are fixed and a request that names others is refused.

The response is a **job**. Poll `GET /jobs/{id}`: its `status` is `pending`, `running`, `completed`, `failed` or
`cancelled`, with a `progress` from 0 to 1 and a `message`. `DELETE /jobs/{id}` cancels one. Progress is
also pushed over a WebSocket at `/ws/v1/projects/{id}`, which is what the web app listens to.

### Read and change a project

- `GET /projects` lists your projects (paged), and `GET /projects/{id}` returns one with its transcript and
  style.
- `PATCH /projects/{id}` changes any of `title`, `transcript`, `style_config` and `caption_offset_ms`.
  That is how the editor saves, and how you would restyle a project from a script. The shapes are the
  [transcript format](./transcript-format.md) and the [style](./style.md).
- `DELETE /projects/{id}` deletes the project and every file it has.

### Export a video

`POST /projects/{id}/download` takes:

| Field | |
|---|---|
| `format` | `mp4` (H.264), `mp4-hevc` (H.265), `webm` (VP9) or `mov` (ProRes). |
| `resolution` | The short side in pixels, as a string: `"720"`, `"1080"`, `"2160"`, or `"original"` (the default). |
| `frame_rate` | `"30"`, `"60"` or `"original"` (the default). |
| `green_screen` | `true` for only the captions, on green, with no sound. |

The result is addressed by its content, so the same request is answered at once from the saved file:
`200` with `ready: true` and a `download_url`, or `202` with `ready: false` and a `job_id` to poll. Then
`GET /projects/{id}/download/{format}` with the same `resolution`, `frame_rate` and `green_screen` as query
parameters returns the file. `GET /projects/{id}/exports` lists what a project offers, including its own
size and frame rate.

### Subtitles

These come straight from the transcript, with no processing, and need no job:

```bash
curl -s -H "$AUTH" -o captions.srt  "$API/projects/$PROJECT/export.srt"
curl -s -H "$AUTH" -o captions.vtt  "$API/projects/$PROJECT/export.vtt"
curl -s -H "$AUTH" -o captions.json "$API/projects/$PROJECT/export.json"
```

## Transcription service

This is the API other OpenCaptions components use to have audio transcribed, with no project in between. The
iPhone app is one client, and a server with the `opencaptions` provider is another. You can use it
yourself to put a speech model behind a pipeline.

| Call | |
|---|---|
| `GET /transcription/capabilities` | The API version, the server's name, its models and languages, its limits and how long results are kept. A client refuses a version it does not know. |
| `POST /transcriptions` | Upload audio (anything ffmpeg reads) as `audio`, with a `language` and optionally a `model`. Returns `202` with a `job_id`. |
| `GET /jobs/{id}` | Progress, as for any job. |
| `GET /transcriptions/{id}` | The [transcript](./transcript-format.md), once it is completed (`409` before, `404` after it expires). |
| `DELETE /transcriptions/{id}` | Cancels, and deletes everything of it. |

The audio is deleted when its job ends, and the result is kept for `TRANSCRIPTION_RESULT_TTL_H` hours (24) so a
client that was suspended can still collect it. One user may have `TRANSCRIPTION_MAX_CONCURRENT` jobs
(2) running at once.

## Other endpoints

| | |
|---|---|
| `GET /health` | Liveness, and whether the database, the queue and the storage are reachable. |
| `GET /settings` | What this server offers: providers, models, languages, limits. |
| `GET /fonts` | The fonts known to the server. |
| `GET /api-keys`, `POST /api-keys`, `DELETE /api-keys/{id}` | Manage keys (from a browser session). |

## Errors

Errors are JSON with an HTTP status that means what it says: `400` for a bad request (a missing video, an
unknown format, an unsupported language), `401` and `403` for authentication and permission, `404` for a
project or job that is not yours or does not exist, `413` for an upload over the limit, `415` for a
file that is not a video. Each endpoint's possible errors are in `/api/v1/docs`.
