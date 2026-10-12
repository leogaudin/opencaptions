---
title: "Configuration"
description: "How to change OpenCaptions settings, and the settings that exist, with their defaults."
sidebar:
  order: 2
---

# Configuration

There is no environment file. Every application setting has a default that is written for the compose
layout, so the stack starts with no configuration at all. The compose file names only what a container
cannot work out for itself: the credentials the database and the object store share with the app, the
layout of the services, and a few per-service overrides.

## Changing a setting

Add it to the `x-oc-env` block near the top of `docker-compose.yml`. The `api` and both kinds of worker
share that block, so a setting added there reaches all of them:

```yaml
x-oc-env: &oc-env
  POSTGRES_USER: ${POSTGRES_USER:-opencaptions}
  # … the lines that are already there …
  REGISTRATION_ENABLED: "false"
```

A setting is a name in capitals, the same as the lower-case name in `config.py` and in the tables
below. Values that are not text go in quotes (`"false"`, `"4"`). Then apply it with `docker compose up -d`.

Keeping a setting in the compose file, rather than in a hidden file, keeps it visible in a diff and
impossible for a forgotten file to override. Do not add a separate `environment:` block to the `api`
service: it would replace the shared one instead of adding to it.

Two settings are not application settings. They choose which services run, so they are given on the
command line: `COMPOSE_PROFILES=gpu` and `OC_CPU_TRANSCRIBERS`. See [GPU acceleration](./gpu.md) and
[Scaling](./installation.md#scaling).

## Accounts and access

| Setting | Default | |
|---|---|---|
| `REGISTRATION_ENABLED` | `true` | Whether anyone can create an account. Turn it off once yours exist. |
| `HOSTED_MODE` | `false` | `true` when you run it for other people: the API then withholds host details (health, models, device) and refuses a per-job choice of provider or model. |
| `SESSION_COOKIE_SECURE` | `false` | Set `true` behind HTTPS. |
| `PUBLIC_BASE_URL` | empty | The address people use. Password-reset links are built from it. |
| `CORS_ORIGINS` | `http://localhost:5173` | Where the page is served from, if not that address. |
| `AUTH_THROTTLE_MAX_ATTEMPTS` | `5` | Sign-in attempts per account within `AUTH_THROTTLE_WINDOW_S` (15 minutes). |
| `AUTH_IP_THROTTLE_MAX_ATTEMPTS` | `50` | Attempts per source address within `AUTH_IP_THROTTLE_WINDOW_S` (5 minutes). Loose on purpose, so an office behind one address is never locked out. |

## Email

Password reset by email turns on when a host is set. See [Accounts](./accounts.md#password-reset).

| Setting | Default | |
|---|---|---|
| `SMTP_HOST` | empty | The mail server. Empty means no reset by email. |
| `SMTP_PORT` | `587` | |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | empty | |
| `SMTP_FROM` | the username | The sender address. |
| `SMTP_USE_TLS` | `true` | |

## Transcription

| Setting | Default | |
|---|---|---|
| `TRANSCRIPTION_PROVIDER` | `local` | `local`, `openai` or `opencaptions`. The default selected in the app. |
| `WHISPER_MODEL` | `large-v3-turbo` | The default Whisper model. |
| `WHISPER_DEVICE` | `auto` | `auto`, `cpu`, `cuda` or `cuda:0`. |
| `WHISPER_COMPUTE_TYPE` | `int8` | |
| `ASR_THREADS` | `0` | Threads for the models that are not Whisper. `0` uses every core available. |
| `OPENAI_API_KEY` | empty | Needed for the `openai` provider. |
| `TRANSCRIPTION_REMOTE_URL`, `TRANSCRIPTION_REMOTE_KEY` | empty | Another OpenCaptions server and an API key from it, for the `opencaptions` provider. |
| `INSTANCE_NAME` | `OpenCaptions` | The name this server gives other apps that connect to it. |
| `TRANSCRIPTION_RESULT_TTL_H` | `24` | Hours a finished transcript is kept for a client to fetch. |
| `TRANSCRIPTION_MAX_CONCURRENT` | `2` | Transcription jobs one user may have running at once through the transcription API. |

The `WHISPER_*` tuning settings (voice filter, hallucination guard, second look) are explained in
[Speech models and providers](./speech-models.md#tuning-whisper).

## Limits

| Setting | Default | |
|---|---|---|
| `MAX_UPLOAD_SIZE_MB` | `2048` | The largest video accepted. The web container's nginx also caps uploads at 2 GB: to go higher, build the `web` image from source with a larger `client_max_body_size` in `apps/web/nginx.conf`. |
| `MAX_VIDEO_DURATION_S` | `3600` | The longest video accepted, in seconds. |
| `SSRF_ALLOWED_HOSTS` | empty | Hosts the server may fetch from even though they resolve to private addresses. See [Security](./security.md#fetching-a-video-from-a-link). |

## Storage and services

The defaults match the compose file's own services (`postgres`, `redis`, `garage`, `engine`), so you
normally leave these alone. To use an S3 store you already have, set the S3 endpoint and credentials
(an empty endpoint means AWS S3), and to use an external database or Redis, set `POSTGRES_HOST`,
`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` and `REDIS_URL`.

| Setting | Default | |
|---|---|---|
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | `opencaptions` | The database credentials. See [Security](./security.md#the-default-credentials). |
| `ENGINE_TOKEN` | a development token | What the render server requires of the API. Change it on any exposed host. |
| `LOG_LEVEL` | `INFO` | |

The single source of truth for every setting and its default is
[`apps/api/app/core/config.py`](https://github.com/leogaudin/opencaptions/blob/main/apps/api/app/core/config.py).
A check in the repository keeps the compose file's copies of shared values equal to each other and to
that file.
