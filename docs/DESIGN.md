# OpenCaptions design

OpenCaptions turns a video into a captioned one: it transcribes the speech with
word timings, lets you edit and style the captions, and renders them into the
video. It runs as one Docker Compose stack you host yourself; a native iOS app
that does the same on the phone is designed below and not built yet.

## Services

```
browser ──▶ web (nginx: SPA + proxy) ──▶ api (FastAPI) ──▶ postgres
                                            │  ▲            redis (Celery broker)
                                            ▼  │ progress   garage (S3 store)
                       worker-transcription ┘  │
                       worker-rendering ──▶ engine (POST /render)
```

| Service | Role |
|---|---|
| `web` | The React SPA, and the only published port (`5173`). nginx proxies `/api` and `/ws` to the API, so the browser talks to one origin. |
| `api` | REST + WebSocket API, auth, enqueueing. Migrations run on boot. |
| `worker-transcription` | Celery queue `transcription`: extract audio, run the provider, store the transcript. `worker-transcription-gpu` is the same image on CUDA, behind the `gpu` profile. |
| `worker-rendering` | Celery queue `rendering`: hands a render to the engine and records the result. Scales on its own (`OC_RENDERERS`). |
| `engine` | The Rust render server: FFmpeg decodes, the engine draws each caption frame, FFmpeg composites and encodes. |
| `postgres`, `redis`, `garage` | Data, broker, and the S3-compatible object store. |

Two queues, because a backlog of renders must never starve transcription, and
the two scale on different hardware.

## A job, end to end

1. **Upload.** `POST /projects` stores the source at `projects/{id}/source.<ext>`,
   probes it (size, fps, duration, rotation, HDR transfer) and makes a thumbnail.
   A URL can be given instead; it is fetched with SSRF checks (http(s) only, every
   resolved address must be public).
2. **Transcribe.** A job on the transcription queue. Progress goes to the
   project's WebSocket. The result is a `Transcript`: segments of words, each with
   `start`, `end` and `confidence`.
3. **Edit.** The SPA edits the transcript and the style and autosaves them with
   `PATCH /projects/{id}`. The preview is drawn by the engine in the browser, and
   every transcript edit is one of the engine's (see below). Words are edited on
   the preview, captions are retimed on the timeline, and nothing else changes
   the transcript.
4. **Render.** `POST /projects/{id}/download {format}` computes a hash of
   everything that decides the output (transcript, timing offset, style, format,
   size, fps). If `projects/{id}/renders/{hash}.<ext>` exists, it is
   ready at once; otherwise a render job is queued and the SPA polls the job.
   The cache needs no database state: readiness is an existence check.
5. **Download.** `GET /projects/{id}/download/{format}`. Subtitles (SRT, VTT,
   JSON) are generated from the transcript, without rendering.

## The caption engine

`apps/engine` is one Rust library (rustybuzz shaping, tiny-skia drawing) with
three builds:

- **natively**, linked into the render server;
- **to WebAssembly**, drawing the editor preview over the HTML `<video>`;
- **as a static library**, for the iOS app.

**The preview is the export.** It is the same code with the same font files, and
its arithmetic is deterministic (an integer blur, no platform maths), so every
build produces byte-identical frames. Nothing else may draw captions.

- **Scene.** `set_scene` lays out the transcript once for a style and a frame
  size. `render(t)` then draws one frame, redrawing only the area that changed.
  Lines are the transcript's words in reading order, cut every `words_per_line`
  words. A line holds through short gaps and clears in long ones.
- **Timing offset.** One global nudge of every caption against the audio
  (`caption_offset_ms`, positive is later, times clamp at zero) is part of the
  scene, so the preview and the export shift identically. The edit calls take it
  too: they report times as shown and write them back unshifted.
- **Position.** `position_x`/`position_y` are the normalized centre of the
  caption block, clamped so it stays in frame. The editor drags the block and
  hit-tests words using the geometry the engine reports (`active_*`).
- **Edits.** Cutting captions, retiming a word edge and editing a word also live
  in the engine (`edit.rs`). A word is edited one at a time (renamed, or deleted
  by clearing it): text of several words is refused, because splitting a word
  would invent timings. The web calls them through WebAssembly, and the phone
  will call the same code natively.
- **Fonts.** Inter is bundled; it is the default and the glyph fallback, so an
  offline install still draws. Any Google Fonts family can be chosen: the API
  fetches it once, keeps it in the store (`fonts/`), and gives the preview and
  the engine the same file. A bundled face wins over a requested one, and
  fallback only reaches bundled faces.
- **Colour.** SDR sources render in BT.709. HDR sources (PQ, HLG) are either
  tone-mapped to SDR or kept HDR at 10-bit BT.2020, with captions at reference
  white.
- **ABI.** One C ABI for every caller, prefixed `oc_` and declared in
  `include/opencaptions_engine.h`. A test keeps the header and the exports in
  step. Inputs are byte buffers from `oc_alloc`; outputs land in a result buffer.
  State is per process, so calls may come from any thread (a Swift actor hops
  between them) but the caller serializes them.
- **Render server.** `POST /render` takes a presigned read URL for the source and
  a presigned write URL for the output, valid for that render only, so the
  engine holds no storage credentials. It posts progress back with a per-job
  token. The API reaches it through a `RenderBackend` seam (`RENDER_BACKEND`).

## The editor

The page is the preview beside the style panel, with the **timeline docked
full-width underneath**; on a narrow screen the same pieces stack. One layout is
mounted at a time, so there is one `<video>` and one engine whatever the width.

- **Preview.** The video with the engine's frame drawn over it, fitted to its
  panel. While paused, the caption block can be dragged (it sets `position_x/y`)
  and a word double-clicked to edit: one word at a time, an empty edit deletes it.
  A tap on the picture plays or pauses.
- **Timeline.** A ruler over a video track and a caption track, with the
  playhead across them. Caption blocks are the engine's `lines`; a selected block's
  edges retime through the engine. The ruler and both tracks seek by click or
  drag. Ctrl/Cmd + wheel or a pinch zooms around the pointer, the buttons around
  the playhead, and Fit shows the whole video.
- **Transport.** Play/pause, the timecode and mute; Space plays, the arrows step a
  frame.
- **Playback.** The one `<video>` is shared through a context. Its playing time
  never passes through React state: the timeline, playhead and timecode follow the
  element each frame and write to the DOM directly.
- **Autosave.** Edits are saved 800 ms after the last one; there is no Save button.

## Transcription

A provider seam (`app/transcription/`) takes audio and returns a `Transcript`:

- `local`: faster-whisper on CPU or CUDA. Models download on first use into
  `models/`. VAD and no-speech thresholds can be tuned (`WHISPER_*`).
- `openai`: the OpenAI API. Audio leaves the machine, so the UI says so whenever
  this provider is active.

The provider and model are chosen per job, with the deployment's defaults
preselected. The seam doesn't depend on the model, so any engine that yields
words with timings fits behind it.

## Data

- **Postgres:** `users`, `projects` (transcript and style as JSON, video
  metadata, timing offset), `jobs` (type, status, progress, message), and
  `api_keys` (hashed).
- **Object store:** everything under `projects/{id}/`, plus `fonts/`. Deleting
  a project deletes its prefix.
- **Types:** Pydantic models in `apps/api` are the single source of truth.
  `api.generated.ts` is generated from the OpenAPI schema and committed, and CI
  fails if it drifts.
  The built-in style presets are data (`apps/web/src/lib/presets.json`), read by
  the web and bundled by the iOS app; a test keeps them valid `StyleConfig`s and
  the first one equal to the API's default.

## Accounts and security

- **Sign-in.** Email and password, with an httpOnly session cookie plus a CSRF
  token. Password reset works over SMTP when it is configured. Auth attempts are
  throttled per account and per source address.
- **API keys.** Bearer keys for scripts and the same API the SPA uses. Managing
  keys and sessions needs a browser session.
- **Isolation.** Every project and job route resolves through an
  ownership check.
- **Exposure.** Only `web` is published. It binds `0.0.0.0`, so phones on the
  same network can use it; put it behind a reverse proxy to expose it further.

## Configuration

There is no env file. `app/core/config.py` holds the defaults for this topology,
so the stack boots with no configuration at all. `docker-compose.yml`, the one
compose file, names only what a container can't infer: shared credentials,
service hosts, and per-service overrides. A setting is changed in the
`environment:` block of the services that read it. `check-compose.sh` keeps every
copy of a shared value equal to the others and to `config.py`.

`HOSTED_MODE` is the one switch between running it for yourself and running it
for others. When it is on, the API withholds host details (health, models, device)
and refuses per-job provider or model choices. The SPA only reflects what the API
returns. An entitlement seam (`services/entitlements.py`) is where per-user
limits would plug in.

## iOS app (designed, not built)

Everything runs on the phone: no server, no accounts. It is a Swift UI over three
things it does not reimplement.

| Piece | iOS |
|---|---|
| Caption drawing and edits | The same engine crate, linked as a static library (`cargo rustc --release --lib --crate-type staticlib --target aarch64-apple-ios`; CI lints that target). Swift imports the C header directly. One Swift actor owns the buffer protocol and serializes the calls, which the engine allows from any thread. |
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML, Neural Engine), mapped once to the same `Transcript` shape, so its transcripts and the server's are interchangeable. |
| Decode, composite, encode | AVFoundation: each engine frame is composited onto the decoded `CVPixelBuffer` with Core Image, then written by `AVAssetWriter`. HDR stays HDR (HEVC 10-bit, captions at reference white). |

**What Swift builds.** The preview is an `AVPlayer` with the engine's frame drawn
on top. The timeline mirrors the web one, using the engine's edit calls. The style
controls and presets mirror the web's.

**Storage.** Projects are files, because one process reads and writes them:
`Application Support/Projects/<id>/` holds:
- `project.json`: title, created date, `Transcript`, `StyleConfig` and timing
  offset, in the API's shapes, so a project moves between phone and server
  unchanged;
- `source.<ext>`: copied in at import, so a project survives the clip being
  deleted from Photos;
- `renders/`: named by the same content hash as the server, and excluded from
  backup.

Writes are atomic (write a temporary file, then rename). The project list is a
scan of the folder, and an unreadable project is hidden rather than failing the
list.

**Models.** The same choice as on the desktop, downloaded on demand and never
bundled. Weights are excluded from backup. First launch defaults to `base`, so an
App Store reviewer can finish a job quickly, and a cellular download asks first.

**Long jobs.** The app asks the user to keep it in the foreground and keeps the
screen awake. There is no background processing.

## Licence

AGPL-3.0-only: anyone may self-host or modify it, and a hosted fork must publish
its changes. Contributors accept the [CLA](../CLA.md), which lets the maintainer
also ship their code where the AGPL can't go, such as the App Store.
