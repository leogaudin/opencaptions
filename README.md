# OpenCaptions

> **Open-source AI captioning. Self-hosted. Docker-first.**

OpenCaptions generates word-level transcriptions of local video files using Whisper-class models, applies animated styled captions (word-by-word highlighting), and exports either a burned-in MP4 or subtitle files (SRT/VTT/JSON).

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![CI](https://github.com/leogaudin/opencaptions/actions/workflows/ci.yml/badge.svg)](https://github.com/leogaudin/opencaptions/actions/workflows/ci.yml)
[![Status](https://img.shields.io/badge/status-pre--v0.1-orange.svg)](#)

⚠️ **Status:** Pre-v0.1, under active construction. APIs and schemas may change without notice until the first tagged release.

![OpenCaptions editor — a video preview with word-level animated captions next to the style panel, over the caption timeline](docs/screenshot.png)

## Why OpenCaptions

No existing OSS tool combines automatic transcription with **animated styled captions** (the kind you see on TikTok/CapCut/Captions.ai). OpenCaptions fills that gap, runs entirely on your own machine, and ships under AGPL-3.0 so it stays open.

## Features (v0.1)

- 🎙 **Word-level transcription** via faster-whisper (local) or OpenAI Whisper API (BYOA)
- 🎨 **Animated styled captions** with 3 built-in presets + full custom panel
- ✏️ **Built-in editor** — a timeline to retime captions, fix a misheard word right on the video, customize style with live preview
- 📤 **Multi-format export** — burned-in MP4, SRT, VTT, JSON
- 🐳 **Docker Compose first** — one command to run the whole stack
- 🔒 **Privacy by design** — no telemetry, no tracking, no phone-home; accounts are local to your instance
- 🍎 **Apple Silicon** — images are multi-arch and run natively on M-series Macs. Local
  transcription is CPU-only there: faster-whisper runs on CTranslate2, which has no
  Metal or CoreML backend. Use the OpenAI provider, or a small model, if speed matters.

## Quick Start

**Run it** — you need only one file. Put [`docker-compose.yml`](docker-compose.yml)
in an empty directory and start it:

```bash
curl -O https://raw.githubusercontent.com/leogaudin/opencaptions/main/docker-compose.yml
docker compose up -d
# Open http://localhost:5173
```

> ⚠️ Pre-built images will be available after the first tagged release and once GHCR packages are set to public. Until then, use a checkout.

**Develop it** — the same file, with `--build` so every image is built from
source instead of pulled:

```bash
git clone https://github.com/leogaudin/opencaptions.git
cd opencaptions
docker compose up -d --build   # or: make up
```

`docker compose watch` (`make watch`) restarts the Python services on each save
and rebuilds the engine and web images when their source changes. `make
rebuild` forces a no-cache rebuild and keeps your data; `make clean` deletes it.

Requires Docker Compose v2.23.1 or newer: the object store's configuration is
embedded in the compose file, which older versions cannot parse.

### Configuration

There is no env file. Every application setting has its default in
[`apps/api/app/core/config.py`](apps/api/app/core/config.py), written for this
topology, so the stack boots with no configuration at all. The compose file names
only what a container cannot infer: the credentials Postgres and the object store
share with the app, the service topology, and per-service overrides.

To change a setting, add it to the `environment:` block of the services that read
it — committed, visible in a diff, and impossible for an untracked file to shadow.

### Verifying a change

`make ci` is the acceptance criterion. It runs everything GitHub CI runs except
publishing — workflow lint, repository guards, backend lint/types/tests, the
generated-types gate, frontend and engine checks, all four image builds
(including the GPU target) and the end-to-end suite.

```bash
make ci           # full gate against committed HEAD
make ci-staged    # HEAD + staged changes, before committing
make ci-static    # fast: skips image builds and e2e
```

It validates a clean snapshot of committed source in pinned containers, under its
own project name so none of your volumes are reachable, on an off-default port —
safe to run while your own stack is up. It needs Docker Compose **v2.24+**.

## API

Everything the app does is an HTTP API, documented interactively at
`/api/v1/docs` on your instance. Create a key on the **Account** page, then:

```bash
API=http://localhost:5173/api/v1
AUTH="Authorization: Bearer oc_…"

# Upload a video (or pass -F video_url=https://… instead of a file)
PROJECT=$(curl -s -H "$AUTH" -F title=episode -F video=@episode.mp4 "$API/projects" | jq -r .id)

# Transcribe, then poll the job until it completes
JOB=$(curl -s -H "$AUTH" -X POST "$API/projects/$PROJECT/transcribe" \
  -H 'Content-Type: application/json' -d '{"language":"auto"}' | jq -r .id)
curl -s -H "$AUTH" "$API/jobs/$JOB" | jq .status

# Render: returns ready=true with a URL, or a job to poll first
curl -s -H "$AUTH" -X POST "$API/projects/$PROJECT/download" \
  -H 'Content-Type: application/json' -d '{"format":"mp4"}'
curl -s -H "$AUTH" -o captioned.mp4 "$API/projects/$PROJECT/download/mp4"
```

A key reaches every endpoint except account management (`/auth`, `/api-keys`),
which needs a signed-in browser, so a leaked key cannot mint more keys or take
over the account. Only a hash of each key is stored; revoke one from the same
page.

## Security

> ⚠️ **The web UI listens on every interface, and signup is open.** Anyone who can reach port 5173 on this machine can create an account and spend its CPU/GPU on transcription and rendering. On a shared network or a public host, close registration by adding `REGISTRATION_ENABLED: "false"` to the `api` service's `environment:` block, firewall the port, or bind it to `127.0.0.1` on the `web` service's `ports:` line.

The shipped defaults are development credentials, not secrets: Postgres is `opencaptions` / `opencaptions` and the bundled Garage object store uses the `S3_ACCESS_KEY` / `S3_SECRET_KEY` written in the compose file. Change them before running anywhere that matters — in every service that names them, which `scripts/check-compose.sh` verifies.

The stack publishes exactly one host port — the web UI, on `0.0.0.0:5173`, so
other devices on your network can use it. Everything else (database, cache, object
store, API, engine) is reachable only over the compose network, because nginx
proxies `/api`, `/ws` and the OpenAPI docs through that single origin.

For anything beyond a trusted network, put a reverse proxy in front to terminate
TLS, and bind the port to `127.0.0.1` so only the proxy can reach it.

See [SECURITY.md](SECURITY.md) for the threat model and how to report a vulnerability.

## GPU Acceleration

GPU mode is not a separate command. Both switches are Compose variables — they
choose which services run, so they are set on the command line rather than in the
compose file:

```bash
COMPOSE_PROFILES=gpu OC_CPU_TRANSCRIBERS=0 docker compose up -d
```

Export them in your shell to make it the default for that machine.

`COMPOSE_PROFILES=gpu` brings up the GPU transcription worker.
`OC_CPU_TRANSCRIBERS=0` suppresses the default CPU worker so jobs only land on
the faster GPU path.

**Requirements:**
- NVIDIA GPU with a CUDA 12-capable driver (`nvidia-smi` should work on the host)
- [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) installed
- The GPU image is substantially larger (~4 GB vs ~600 MB) because it bundles CUDA runtime wheels

The GPU profile builds/pulls a separate image with CUDA libraries and reserves your NVIDIA device for the transcription worker. If GPU detection fails at runtime, the worker falls back to CPU and reports the reason in the health endpoint.

To switch back to CPU, run `docker compose up -d` without them.

## Architecture

- **API:** Python + FastAPI + Celery + Postgres + Redis
- **Engine:** Rust — rustybuzz shaping and tiny-skia drawing. Natively it draws every frame of an
  export and FFmpeg encodes it; compiled to WebAssembly it draws the editor preview, so the
  preview is the export
- **Frontend:** React + TypeScript + Tailwind, built with Vite; Radix for accessible overlays,
  Zustand for app state
- **Storage:** Garage (S3-compatible, self-bootstrapping) bundled; real S3 or any S3-compatible service swappable via env
- **Queue routing:** two named Celery queues (`transcription`, `rendering`) split from day 1

## Project Layout

```
docker-compose.yml          # The whole stack: pulls images, or builds with --build
apps/
  api/                      # FastAPI + Celery workers
  engine/                   # Rust caption engine: render server + WebAssembly preview
  web/                      # React frontend
```

## Documentation

- [Contributing](CONTRIBUTING.md) — dev setup and the acceptance gate
- [Design](docs/DESIGN.md) — how it works, including the planned iOS app
- [Security policy](SECURITY.md) — threat model and vulnerability reporting
- [Third-party notices](NOTICE) — bundled components and their licences

## Self-Hosting

Backup: `make backup` snapshots Postgres + Garage data to `./backups/`.
Restore: `make restore TS=YYYYMMDD-HHMMSS`.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).

If you offer a hosted version of OpenCaptions, AGPL requires you to publish your modifications. This is intentional.

Contributors accept a [CLA](CLA.md) so the maintainer can also ship the code where the AGPL cannot go, such as the App Store.

Third-party components ship under their own licences — see [NOTICE](NOTICE).

## Donations

If OpenCaptions saves you time, consider supporting development:

- [GitHub Sponsors](https://github.com/sponsors/leogaudin)

## Author

Built and maintained by [Leo Gaudin](https://github.com/leogaudin).
