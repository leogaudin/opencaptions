---
sidebar_position: 1
title: "Quick start"
description: "Run OpenCaptions on your own computer with one Docker Compose file and one command, then open the editor in your browser."
---

# Quick start

You need [Docker](https://docs.docker.com/get-started/get-docker/) with Compose v2.24 or newer, and
one file. No clone, no build, no configuration.

## 1. Download the compose file

```bash
mkdir opencaptions && cd opencaptions
curl -O https://raw.githubusercontent.com/leogaudin/opencaptions/main/docker-compose.yml
```

## 2. Start it

```bash
docker compose up -d
```

The first start pulls the images (the API image is about 600 MB) and starts eight small services:
the web app, the API, a transcription worker, a render worker, the render engine, Postgres, Redis and
an S3-compatible object store (Garage). It takes a minute or two on a good connection.

## 3. Open the editor

Go to <http://localhost:5173>, create an account, and drop a video in. The account is local to
your instance: nothing is sent anywhere, and the first account is an ordinary user like any other.

:::info The first transcription is slower
A speech model is downloaded the first time you use it, into a `models` folder next to the compose
file, and reused after that. Whisper Large v3 Turbo, the default, is about 1.6 GB. A smaller model
such as Whisper Small (about 480 MB) is a good way to try things out. See
[Transcription](../guides/transcription.md) for the choices.
:::

:::warning Before you share it
The web app listens on every network interface and sign-up is open, so anyone who can reach port
5173 on that machine can make an account and use its processor. On a shared network or a public
host, read [Security](../self-hosting/security.md) first.
:::

## Stop, restart and remove

```bash
docker compose stop        # stop, keeping everything
docker compose up -d       # start again
docker compose down        # remove the containers, keeping your projects
docker compose down -v     # remove the containers AND all projects and accounts
```

Your projects and accounts live in Docker volumes (`postgres_data` and `garage_data`), so
`docker compose down` does not delete them. [Backups](../self-hosting/backups-and-upgrades.md) shows how to
copy them.

## Build from source instead

If you have cloned the repository, `docker compose up -d --build` (or `make up`) builds every image
from the source, and `make watch` adds live reload for development. See
[Contributing](../project/contributing.md).

## Next

- [Your first captions](./your-first-captions.md): a walk through the editor.
- [Installation](../self-hosting/installation.md): requirements, ports, data and updates in detail.
