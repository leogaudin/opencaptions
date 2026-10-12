---
title: "Architecture"
description: "How OpenCaptions is built. The services, how a job flows from upload to download, the Rust caption engine behind the preview and the export, the data, security, and the iPhone app."
sidebar:
  order: 2
---

# Architecture

OpenCaptions turns a video into a captioned one: it transcribes the speech with
word timings, lets you edit and style the captions, and renders them into the
video. It runs as one Docker Compose stack you host yourself, and as a native iOS
app that does the same on the phone, with no server.

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
the two scale on different hardware. A transcription worker handles one job and exits
(`--max-tasks-per-child=1`), so a loaded speech model never outlives its job: an idle stack
holds none of its memory, and a CUDA failure costs one job. The price is a model load per job.

**When a job fails to finish.** Tasks are acknowledged late, so a task a crashed worker held
is handed to another; an API restart therefore says nothing about running work and does not
fail it. At boot only a job that cannot still be working is failed (`services/recovery.py`):
`running` with no change for longer than any task may run, or `pending` for a day (a message
that old is gone). Each task has its own time limits (`core/task_limits.py`): a render's
follow the engine's request timeout, a transcription's the longest video the instance
accepts. A job that is over (`completed`, `failed`, `cancelled`) is never brought back by its
task's late status updates. Progress is published to Redis over one pooled connection per
process (`core/events.py`).

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
4. **Render.** `POST /projects/{id}/download {format, resolution, frame_rate, green_screen}`
   computes a hash of everything that decides the output (transcript, timing offset, style,
   format and its encoder settings, size, fps). If `projects/{id}/renders/{hash}.<ext>` exists
   it is ready at once; otherwise a render job is queued and the SPA polls the job. The cache
   needs no database state: readiness is an existence check. `GET /projects/{id}/exports`
   lists the sizes and rates a project offers (with `source_resolution` and `source_fps`).
   - **Size and rate.** A short side (2160, 1080, 720) and a frame rate (30 or 60, the cap),
     either of which may be above the source's. Both default to `"original"`, the video's own,
     which is what an API client that names nothing gets; the editors never show that word,
     they list the values smallest first with the video's own named by its number. A frame rate
     above the source's repeats the picture's frames, but the captions are drawn at every
     output frame, so their animation is smoother. `resolve_render_inputs` alone turns options
     into the output's size and rate, for every caller.
   - **Green screen.** `green_screen` draws the captions over solid chroma green instead of the
     picture, with no sound, to key out in an editor. It is part of the hash, and the engine
     does not use the video at all.
   - **No quality choice.** A download is a second encoding of the source, so each format is
     made as good as its codec does well (a CRF in `render_formats.py`; ProRes takes a
     profile). The size is chosen with the resolution and frame rate.
   - The web editor has one Download button that opens a dialog (format, size, frame rate,
     background), as the iOS Save sheet does.
5. **Download.** `GET /projects/{id}/download/{format}?resolution=…&frame_rate=…&green_screen=…`.
   Subtitles (SRT, VTT, JSON) are generated from the transcript, without rendering.

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
  size. `render(t)` then draws one frame, redrawing only the area that changed,
  and reports the band of rows it changed (`oc_changed_top`/`_bottom`; the whole
  frame after a new scene), so the web preview copies and draws just that band
  while a video plays.
  Lines are the transcript's words in reading order, cut every `words_per_line`
  words, or sooner where the speaker paused (`model::cut`, the one rule the scene
  and the editors' line list share), so words said minutes apart never share a
  caption. A pause is a silence of three times the usual start-to-start time
  between words in that transcript, so it is judged against the speaker's tempo
  and not a clock (`model::pauses`; the API's copy is held to the same cases in
  `apps/engine/testdata/pauses.json`). A line holds through short gaps and clears in long ones.
  `oc_active_index` is the flat index of the showing line's first word, not its
  number, because lines are no longer all the same length.
- **Timing offset.** One global nudge of every caption against the audio
  (`caption_offset_ms`, positive is later, times clamp at zero) is part of the
  scene, so the preview and the export shift identically. The edit calls take it
  too: they report times as shown and write them back unshifted.
- **Position.** `position_x`/`position_y` are the normalized centre of the
  caption block, clamped so it stays in frame. The editor drags the block and
  hit-tests words using the geometry the engine reports (`active_*`).
  Dragging is magnetic toward the video's centre lines: the engine's `snap_to_centre`
  pulls an axis to 0.5 when the block's centre is within a few screen pixels of it (the
  editor passes the preview's size and the threshold in pixels, then draws a guide line
  while snapped), so every editor snaps the same way.
- **Edits.** Cutting captions, retiming a word edge and editing a word also live
  in the engine (`edit.rs`). A word is edited one at a time (renamed, or deleted
  by clearing it): text of several words is refused, because splitting a word
  would invent timings. The web calls them through WebAssembly, and the phone
  calls the same code natively.
- **Styles.** All of a style is the engine's, so the preview and the export agree.
  - *Sixteen animations:* the word highlighted by colour (`word_highlight`), by a box
    (`highlight_box`), popped (`word_pop`), faded in (`word_fade`), filled left to right as it is
    said (`word_sweep`, karaoke), underlined as it is said (`word_underline`), typed out letter by
    letter with a cursor (`typewriter`; the steps are whole letters, so a frame changes only when
    one appears), none (`none`: subtitles that do not move), bounced up past their size with a
    lean, left and right in turn (`word_bounce`), brought into focus out of a dim blur
    (`lyric_focus`; the words already said stay sharp), lit by one box that slides from word to
    word (`highlight_slide`), lit with a bar under the line that fills as the line is spoken
    (`line_bar`), each set on its own tilted label (`stickers`), its letters rising into place one after another as it is said (`letter_rise`: one outline per grapheme cluster, grouped by the shaper's cluster index, in reading order; a word in a connected script, where the letters join or reorder, is one cluster and rises as a piece; the word is hidden until its start, and its shadow and glow follow the letters), dropped in from twice its size, over 0.12 s with no overshoot, the whole line jolted as it lands (`word_slam`: a knock of about 3.5% of the font size that dies away over 0.15 s along a fixed direction by the word's place, a polynomial envelope and no sine; the knock is part of the frame's identity), and pushed into its solid shadow as it is said (`word_press`: the face sinks along the offset, 70% of the way at most, and the extrusion that is left runs from there to the same back as before). The motion is eased with the
    engine's own arithmetic, never a platform sine, so the builds still agree to the byte. The
    line's bar and the sliding box are one shape per line (`Guide`), part of the frame's
    identity, so a frame is redrawn when they move.
  - *Beside them:* an outline; a shadow with a blur and an offset (a shadow with no blur is solid
    and is drawn as an extrusion, the letters carried from where they are to the offset a pixel
    at a time, so it reads as their outline continued); a glow (a blurred halo in its own colour,
    laid down three times to read as light); upper case (drawn, never stored: the transcript is
    untouched); and italic (the upright face sheared by about 11 degrees, so any font leans and
    no italic file has to be fetched). Every field after `shadow_color` is optional with a
    default of "off", so a style saved before it existed opens unchanged (the exception is
    `motion_blur`, which defaults to 0.5). `fill_colors` paints each word with a vertical gradient
    from the top of the em box to the baseline, and `extrude_shade` darkens a solid shadow with
    depth: its stamps are laid from the back forward, so each pixel takes the colour of the
    nearest stamp that covers it, and the first step is lightened as a lit edge.
  - *Stack layout.* `layout: "stack"` cuts rows at 0.55 of the usual width (a key word alone on its
    own), then scales each row up to the widest row's natural width, at most three times, and
    stacks them with leading of 1.0 of each row's own size. A word's `size` (its emphasis times
    its row's scale) is what every animation uses wherever it used the font size: the underline's
    thickness, the cursor, the sliding box's corner, a label's radius, the blur of a soft word,
    how far a letter rises, and the outline, shadow and extrusion, so every animation works in a
    stack.
  - *Key words.* `model::emphasis` is the one rule the scene and both editors share, held to
    `testdata/emphasis.json`: an explicit `Word.emphasis` wins; otherwise each caption has at most
    one key word, the first with a digit, `%` or a currency sign, or else the longest word if it
    has seven letters or more and is at least one and a half times the caption's median. No word
    lists, so it holds in any language. With `emphasis_scale` above 1 a key word is shaped larger
    and has a row of its own (the rows are of different heights; its outline, shadow and
    extrusion grow with it) and is always in its highlight colour. Emphasis splits rows, never
    captions, so the timeline is unchanged. `edit::set_emphasis` (C ABI `oc_set_emphasis`) sets or
    clears a word's choice, and the lines the editors list carry each word's effective flag.
  - *Motion blur.* When `motion_blur` is above 0, a frame at `t` is the average of eight
    sub-frames drawn at `t - motion_blur/30 · k/7` seconds (the shutter is a share of 1/30 s, so
    the fps does not change the look). If every sub-frame has the same key (nothing moves within
    the shutter), one draw is taken, so still frames cost nothing and are byte-identical to a sharp
    one. Otherwise each is drawn in full, whichever line is up then, and they are summed as
    integers on the premultiplied bytes over the union of their boxes, so a line arriving within
    the shutter ghosts in. The frame's identity is the list of sub-frame keys.
  - *Highlight colours.* `highlight_colors` is a list of one to four hex colours, the first the
    primary (a row of pickers with a plus and a remove, on both editors). A look that marks each
    word (the lit word, a box, a label, an underline, the cursor) takes the colours in turn, word
    by word; a single shape (the sliding box, the bar) is the primary; a sweep runs through all of
    them as a gradient across the line. A style with one colour looks as it always did. Stored
    projects were migrated from the one `highlight_color` (Alembic 0005), and an iPhone project
    saved before the list still opens, its colour first. A sweep paints each letter once, the
    highlight on the side it has passed and the plain colour on the rest, so no soft edge of the
    plain word shows round it.
  - *Presets* are data (see Data). They include Purple Punch (a box that slides between words),
    Karaoke, Bold (Montserrat Black, in capitals with a thick black outline carried out into a hard
    black extrusion), Boom (the word being said grows and is drawn over its neighbours), Lyric
    (soft until said, and the line never changes size), Stickers, Plain, Neon, Typewriter and
    Handwritten (a marker stroke laid under the words as they are said).
  - *Tiles.* The preset tiles, and the choices in the Background and Animation tabs, are drawn by
    the engine (`CaptionEngine.samples`: the same drawing as the preview and the export, in a
    phone-shaped frame, cropped to the band around the caption), so each shows its real font,
    colours and highlight; the scene in use is put back after. A background with no opacity is
    given a visible one when chosen.
- **Fonts.** Inter, Poppins (ExtraBold, the default preset's) and Montserrat (Black, the Bold
  preset's) are bundled; Inter is the glyph fallback, so an offline install still draws. Any
  Google Fonts family can be chosen: the API fetches it once, keeps it in the store (`fonts/`), and
  gives the preview and the engine the same file. A bundled face wins over a requested one, and
  fallback only reaches bundled faces. The font row opens a list of the fonts in use, each name
  in its own face (a name-only subset fetched from Google, a few KB), and "More fonts" opens the
  whole Google Fonts catalog (the same one the server lists), searchable.
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
  engine holds no storage credentials. The render worker sends `x-engine-token`
  (`ENGINE_TOKEN`, a credential the two share like the storage keys) and the engine
  answers 401 to a render without it; `/health` stays open. It posts progress back with a per-job
  token. The API reaches it through a `RenderBackend` seam (`RENDER_BACKEND`).
  A request is checked before anything is drawn (`SceneInput::check`, shared with the browser and
  phone builds: finite sizes in range, a bounded frame, http(s) addresses only; FFmpeg may open
  only http(s) too), and an empty `ENGINE_TOKEN` is refused at start. At most `ENGINE_MAX_RENDERS`
  (4) renders run at once and the rest wait. Frames are drawn on a thread of their own while the
  last is written, and only the box the captions can ever be in is piped to FFmpeg and laid over
  the video there (`Scene::overlay_bounds`), a fraction of the frame. FFmpeg is killed if the
  render ends any other way than finishing, and the upload is retried.

## The editor

The page is the preview beside the style panel, with the **timeline docked
full-width underneath**; on a narrow screen the same pieces stack. One layout is
mounted at a time, so there is one `<video>` and one engine whatever the width.

- **Preview.** The video with the engine's frame drawn over it, fitted to its
  panel. While paused, the caption block can be dragged (it sets `position_x/y`)
  and a word double-clicked to edit: spaces inside it stay (it is still one word), an empty edit deletes it.
  A tap on the picture plays or pauses.
- **Timeline.** A ruler over a video track and a caption track, with the
  playhead across them. Caption blocks are the engine's `lines`; a selected block's
  edges retime through the engine (a caption that touches its neighbour pushes
  the neighbour's edge along, down to a minimum). Blocks are flat clips with a
  hairline between them, so a zoomed-out timeline never turns them into
  overlapping bubbles. The ruler and both tracks seek by click or drag. Ctrl/Cmd + wheel or a pinch zooms around the pointer, the buttons around
  the playhead, and Fit shows the whole video.
- **Transport.** Play/pause, the timecode and mute; Space plays, the arrows step a
  frame.
- **Undo and redo.** Buttons beside the zoom, Ctrl/Cmd+Z and Shift+Ctrl/Cmd+Z. As on
  the phone, each step puts back a snapshot of the transcript, the style and the
  offset (`lib/history.ts`, held by the editor store), and a run of one kind of
  change (a slider, an edge drag) made close together is one step. Loading the
  project starts the history afresh.
- **Edit as text.** A dialog with the transcript as JSON, a word to a line, for what
  the controls do not do yet (splitting or merging segments, retiming many words).
  Applying checks it (`lib/transcriptText.ts`, which names the segment and word that
  are wrong) and replaces the transcript as one undo step. The same dialog imports
  a subtitle file (SRT, WebVTT with or without per-word times, or our JSON): it is
  turned into the same text first, to look over before it is applied.
- **Playback.** The one `<video>` is shared through a context. Its playing time
  never passes through React state: the timeline, playhead and timecode follow the
  element each frame and write to the DOM directly.
- **Autosave.** Edits are saved 800 ms after the last one; there is no Save button.
- **Style panel.** In tabs (Presets, Text, Background, Animation, Outline, Timing) so that no
  page is long, on iOS and the web alike. The preset tiles are a grid that fills the width and
  wraps.

**Look.** The web app and the iOS app share one look (`apps/web/src/index.css` holds the web's
tokens, `Theme` the iOS app's): a white or near-black page, a surface for cards, a stronger one for
controls, the caption highlight yellow as the single accent (a deeper gold where it is text on
white), rounded corners, and the "burned-in subtitle" wordmark. It is light or dark and follows the
system until the user chooses. Projects are a grid of poster cards; in the timeline the selected
caption is yellow and the playhead is the page's ink colour.

## Transcription

The web app and the iPhone app both ask in two steps: where to transcribe and with which model, then
the spoken language, from a searchable list with a flag for each that follows the model (the API says
which languages a model takes: `ModelOption.languages`, null for Whisper, which takes any). There is no
"detect it" choice in either app: a language is always chosen, starting from the last one used, else the
device's or the browser's. The API still accepts `auto` for its other clients.

A provider seam (`app/transcription/`) takes audio and returns a `Transcript`:

- `local`: a model on this machine, run by the engine its entry in `app/services/asr_models.py`
  names. Models download on first use into `models/`.
  - **faster-whisper** (CPU or CUDA) runs the Whisper sizes. The list offers Small, Large v3 Turbo and
    Large v3, the phone's; another size runs when named by an API client or by `WHISPER_MODEL`.
    Everything is decoded: the voice-detection
    filter is off by default (`WHISPER_VAD_FILTER`), because it takes shouting
    and speech over loud music for non-speech and what it drops is never transcribed. The
    no-speech check and a hallucination guard (`WHISPER_*`) stay on. faster-whisper still
    moves on from a window when the model says "no speech after here", leaving some loud
    stretches empty; `WHISPER_FILL_GAPS=true` decodes each long empty stretch again, twice,
    keeping only the words both readings give (`chunking.second_look`). Off by default: it
    costs several times the transcription time on action content ([measurements](./speech-model-benchmarks.md)).
  - **sherpa-onnx** (ONNX Runtime, CPU) runs the other models; Parakeet v3 is the first. It
    cuts the audio into windows at the quietest point (`chunking.py`), never skipping a stretch
    for being "not speech", and decodes a window again in halves when it comes back empty
    though it is not quiet. A model that covers only some languages is never given another:
    the language is identified first (`language_id.py`) when it was not chosen, and a recording
    outside the model's languages goes to the default Whisper model, which the job says.

  Adding a model is adding an entry there (and an engine, if it needs one); nothing above the
  provider seam changes. How the choices were made, with measurements, is in the [speech model benchmarks](./speech-model-benchmarks.md).
- `openai`: the OpenAI API. Audio leaves the machine, so the UI says so whenever
  this provider is active.
- `opencaptions`: another OpenCaptions backend, reached through its transcription
  API (below). `TRANSCRIPTION_REMOTE_URL` and `TRANSCRIPTION_REMOTE_KEY` name it; the
  audio leaves the machine, so the UI names its host. A laptop stack without a GPU
  can hand its transcriptions to one that has.

The provider and model are chosen per job, with the deployment's defaults
preselected. The seam doesn't depend on the model, so any engine that yields
words with timings fits behind it.

A job moves through named stages, each stored on the job as well as broadcast, since a
page opened mid-job reads the database: loading (or first downloading) the model, then
transcribing, whose progress is written down every couple of seconds. Whatever the
provider returns has its segments ended at a pause (`app/transcription/words.py`, the same
tempo-relative rule as the captions'), because with voice detection on (or a model that
decodes in windows) a segment can hold words from either side of a long silence.

### The transcription API

What any OpenCaptions component calls to have speech transcribed on a backend, with no
project in between (`app/api/transcriptions.py`). The result is the `Transcript` every
part of the system already uses, so a caller maps nothing: the iOS app and an instance
with the `opencaptions` provider are two clients of it. Auth is an API key
(`Authorization: Bearer oc_…`), minted on the Account page, which also makes a
`opencaptions://connect?url=…&key=…` link that sets the phone app up.

| Call | |
|---|---|
| `GET /api/v1/transcription/capabilities` | `api_version`, the instance's name, models, languages, limits, retention. A client refuses a version it does not know. |
| `POST /api/v1/transcriptions` | audio (anything ffmpeg reads) + `language` [+ `model`]; returns `202 {job_id}` |
| `GET /api/v1/jobs/{id}` | progress, as for any job |
| `GET /api/v1/transcriptions/{id}` | the `Transcript`, once completed (`409` before, `404` after it expires) |
| `DELETE /api/v1/transcriptions/{id}` | cancel and delete everything of it |

It is asynchronous because a long recording takes minutes on a CPU. The audio is deleted
when its job ends; the result is kept `TRANSCRIPTION_RESULT_TTL_H` (24) hours so a client
that was suspended can still fetch it, and the first request after that time removes what
has expired, so no separate janitor runs. Deleting a job (a phone does, as soon as it has the
transcript) removes its audio and transcript; a job that did work stays as a row with the status
`deleted`, because the account's usage is summed from those rows. A user may have `TRANSCRIPTION_MAX_CONCURRENT`
(2) running. A job has its own owner (`jobs.user_id`), so it needs no project. The
`opencaptions` provider sends an `X-OpenCaptions-Hop` header, and an instance that itself
forwards refuses a request carrying it, so two instances cannot be configured into a loop.
The remote address goes through the same SSRF guard as `video_url`; `SSRF_ALLOWED_HOSTS`
admits a GPU box on the LAN. Sample responses in the iOS package's test fixtures are read by both the API tests and the
app's tests, so neither end can change the contract alone.

## Languages

**The interface** is in English, French, Spanish, German, Polish, Portuguese (Brazil), Italian,
Russian, Turkish, Japanese, Korean, Simplified Chinese and Indonesian. The browser's or the phone's
language is used; the web also has a choice on the Account page and on the sign-in screens.

- **Web.** The English text in the code is the key: `t("Download")`, with `{name}` for values, and
  `locales/<code>.json` holds the others (`lib/i18n.ts`, which loads only the language in use,
  before the first paint). A text without a translation shows in English.
- **iOS.** SwiftUI text and `String(localized:)` are collected in the app's string catalogs
  (`Localizable.xcstrings`, `InfoPlist.xcstrings`), and the Kit has its own for the words it
  produces (errors, what a long job says).
- Tests fail on a text missing in any language or a translation that loses a placeholder
  (`i18n.spec.ts`, `LocalizationTests`). What the server says (its errors, a job's progress) is
  not translated, and neither is the watermark.

**Captions in other scripts.** The engine shapes each word with its own direction and script,
lays a right-to-left line (Hebrew, Arabic) out from the right, and falls back to the bundled Noto
Sans faces for Arabic, Hebrew, Devanagari and Thai. Chinese, Japanese, Korean and the other Asian
scripts need fonts too large to bundle, so the engine says which families a transcript needs
(`scripts.rs`, `oc_fallback_fonts`: Han is drawn in the Japanese, Korean or Chinese face by the
kana, hangul or language) and the host fetches them from Google Fonts as it does a style's own
font, naming them in the scene's `fallback_fonts`. The render server gets them from the API, which
holds a Python copy of the rule held to the same cases (`testdata/script_fonts.json`). Adding a
language means a file or a column of translations in each of those, and its code in the list.

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
service hosts, and per-service overrides. A setting is added to the
`x-oc-env` block, which the API and both kinds of worker share. `check-compose.sh` keeps every
copy of a shared value equal to the others and to `config.py`.

`HOSTED_MODE` is the one switch between running it for yourself and running it
for others. When it is on, the API withholds host details (health, models, device)
and refuses per-job provider or model choices. The SPA only reflects what the API
returns. An entitlement seam (`services/entitlements.py`) is where per-user
limits would plug in.

## iOS app

`apps/ios`. Everything runs on the phone: no server and no accounts (a server is an option, below).
It is a SwiftUI app over three things it does not reimplement.

| Piece | iOS |
|---|---|
| Caption drawing and edits | The same engine crate, as a static library in `OpenCaptionsEngine.xcframework` (device, Apple-silicon simulator, macOS: `apps/engine/scripts/build-apple.sh`). Swift imports the C header through a module map. Only the `oc_*` functions leave the library (`build-apple.sh` makes the rest private), since FluidAudio's own Rust library is linked beside it and a name in both stops the linker. One Swift actor, `CaptionEngine`, makes every call: the engine keeps one scene per process and allows its calls from any thread if they are serialized, which an actor guarantees. |
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) and [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet) (Core ML, Neural Engine), pinned, in their own SwiftPM target so the core tests do not build them; iOS 26's `SpeechTranscriber` beside them. Its result is mapped to the same `Transcript` shape the way the server's local provider does, so transcripts are interchangeable. A `Transcriber` protocol sits in front, so a hosted endpoint can be a second conformance later. |
| Decode, composite, encode | AVAssetReader decodes, the engine draws each overlay, Core Image composites, AVAssetWriter encodes (H.264, or 10-bit HEVC for HDR) with the audio re-encoded as AAC. The picture is baked upright at the size it is shown. |

### Layout

`project.yml` (XcodeGen; the `.xcodeproj` is generated, not committed) describes the app target,
which is SwiftUI views and wiring. Everything testable lives in the local package
`OpenCaptionsKit`: models in the API's shapes, the engine actor, project storage, the editor's
logic, the exporter. The minimum is iOS 18, for the app's scroll and gesture APIs. The app is
universal (iPhone and iPad); the iPhone stays in portrait, as the layout is not drawn for
landscape. iOS is not part of `make ci`: it has its own macOS workflow, and nobody without a Mac
is blocked.

The look is plain SwiftUI with no UI library: `Theme` holds the handful of colours (each a light
and a dark value), the button styles, the card and the wordmark, and the screens draw their own top
bars instead of the system navigation bar (the edge swipe back is put back by hand). Sheets (style,
transcribe, save) use the same surfaces.

### The editor

It mirrors the web one.

- **Preview.** An `AVPlayer` with the engine's frame on a layer above it, redrawn on the player's
  clock. A tap plays or pauses. While paused, a drag moves the caption (snapping to the video's
  centre lines with a guide and a haptic tick, by the engine's rule), a double-tap opens a card to
  edit one word (the keyboard opens with the word selected; spaces inside stay, it is still one
  word), and two fingers pinch the font size.
- **Dragging.** The grab region is the caption's box made at least 48 pt across and 24 pt wider
  all round (`CaptionGestures.dragRegion`), measured from where the finger landed (a pan is only
  recognised after it has moved a little), and it works while the video plays.
- **Timeline.** A ruler over a video track and a caption track, with edge handles that retime
  through the engine. The playhead stays in the middle and the timeline moves under it (the track
  is offset by the playing time, so only a small modifier and the ruler read it, never the tracks).
  A finger dragging anywhere on it scrubs, pausing a playing video, and coasts a little on
  release; a pinch zooms; a tap seeks. It opens at 80 pt per second. Dragging a caption's edge holds the track still, or it would
  move under the finger.
- **Transport and undo.** Play, the time (current over total), mute, undo and redo.
  `EditorModel` records a snapshot (transcript, style, offset) before each change, and a run of one
  kind of change (a slider, an edge) is one step.
- **Layout.** The video takes the screen, with only the compact timeline under it. On a wide
  screen the style controls sit beside the video; on a phone they come up over it as a sheet that
  stops a little over half the screen, low enough to keep the caption in view. Style controls and
  presets are the web's, from the same `presets.json`; the caption offset is the engine's.
- **Autosave** after a quiet moment and when the app leaves the foreground; there is no Save button.
- **Importing.** A picked video is copied somewhere the app owns and then shown (a poster, a name
  that can be changed, its size and length) before it is imported; cancelling throws the copy away.

### Storage

Projects are files, because one process reads and writes them: `Application Support/Projects/<id>/`
holds:

- `project.json`: title, dates, `Transcript`, `StyleConfig` and timing offset, in the API's shapes,
  so a project moves between phone and server unchanged;
- `source.<ext>`: copied in at import, so a project survives the clip being deleted from Photos;
- `renders/`: cached videos named by a hash of what decides their pixels (local to the phone, not
  the server's hash), excluded from backup.

Writes are atomic (a temporary file, then a rename). The project list is a scan of the folder, and
an unreadable project is hidden rather than failing the list. Subtitle files (SRT, VTT) are only
exported by the Docker product. Fonts are the same as the server's: Inter, Poppins and Montserrat
are bundled with the engine's other fonts, in the same order the server loads them, and a style that
names another Google Fonts family fetches it once (TrueType, the weight nearest 800) and keeps it on
disk.

### Speech models

- **The list.** The Whisper sizes WhisperKit publishes (Whisper Small, Large v3 Turbo and Large v3;
  no English-only or superseded ones), Parakeet v3 (FluidAudio, Core ML: faster, 25 European
  languages, offered only for those), and on iOS 26 Apple's own `SpeechTranscriber` (built in,
  nothing to download, a language must be chosen). Each model names the engine that runs it
  (`SpeechModel.engine`) and `LocalTranscriber` routes to it; adding a model is listing it. The
  reasons, with measurements, are in the [speech model benchmarks](./speech-model-benchmarks.md).
- **Downloads.** On demand, into a backup-excluded folder, never bundled. The default is Large v3
  Turbo (the best quality for its size), and a metered connection asks before a download.
- **Loading** a model into memory is the longest wait: the first time on a phone, Core ML prepares
  it for that chip (minutes on an iPhone 14 for the Turbo model), and the system keeps the result,
  so later loads take seconds. The screen says so. Loading starts early and beside the reading of
  the audio: the default model as the app opens (when it is downloaded), any other as soon as it is
  chosen in the Transcribe sheet, while the language is picked. The loaded model stays for the next
  transcription and is let go on a memory warning or when the app leaves the screen.
- **Missed speech** (shown as "Second pass (n of m)…"). Whisper skips a whole 30 s window it
  judges silent, which music and noisy speech trigger, leaving a hole in the captions with good ones
  on either side. After the main pass, every stretch of 6 s or more without words that is not quiet
  (at most 12) is decoded twice without that judgement, the second window shifted, and only the
  words both readings give are kept (`TranscriptGaps`; text invented over music differs between the
  two). On by default on the phone; the server's version is opt-in (`WHISPER_FILL_GAPS`, see the
  [benchmarks](./speech-model-benchmarks.md)).
- **On a server.** Settings → "Where to transcribe" switches between this phone and "My server":
  another OpenCaptions backend, connected by pasting the link the web app makes (or typing the
  address and key) and checked before it is kept. The key is in the Keychain, the address in
  preferences. `ServerTranscriber` is a `Transcriber` like the on-device one: it exports only the
  audio (AAC, about 1 MB a minute), uploads it, follows the job, fetches the `Transcript` and tells
  the server to forget it. The transcribe sheet then lists the server's models and downloads
  nothing. A pairing link opened on the phone asks before it is used, because it decides where the
  audio goes. The upload and the wait happen while the app is open (no background upload yet);
  plain `http` is allowed only to local-network addresses.

### Settings

A second tab holds the appearance (system, light or dark), the default spoken language, the speech
models (each can be downloaded or deleted, with its size on disk), what the app stores (with a button
to clear the cached videos, which can be made again), and about, including a button that shares
`diagnostics.log`: a small log kept on the device with the milestones of the long jobs and any
uncaught exception, so a crash that leaves no report can still be explained.

### Saving

Save opens a sheet first:

- **Format:** H.264, which plays everywhere, or HEVC, about a third smaller.
- **Size:** absolute values, smallest first (720p, 1080p and 4K by the short side), with the video's
  own size among them named by its pixels. Larger than the source too: a 144p video can be saved at
  4K, the picture scaled up and the captions drawn sharp at the size saved.
- **Frame rate:** 30, 60 and the source's own, each by its number. A lower one keeps evenly spaced
  frames; a higher one repeats them while the captions are drawn at each, so they animate smoother.
- **HDR source:** whether it stays HDR (10-bit HEVC) or is tone-mapped to an ordinary SDR video
  before the captions go on.
- **Background:** the video, or a green screen (only the captions over solid green, always SDR, for
  an editor to key out). It is not remembered, so a later save is not captions-only by surprise.

The other choices are remembered. An estimate of the size is shown (from bits per pixel, with HEVC
needing two thirds of H.264's; there is no quality choice, a saved video is made as good as it can
be), and when it would not fit in the free space Save is disabled with a message saying so.
Everything the options decide is part of the file's name (`ExportKey`).

**HDR.** A PQ or HLG source stays HDR: decoded to 10 bits, written as 10-bit HEVC with BT.2020. Core
Image puts sRGB white well above reference white in an HDR signal, so the captions are scaled by a
measured factor per transfer function, and the tests read the output's luma to check where they
land. A saved video's captions land at five times reference white (about 1000 nits in PQ, the top of
the range in HLG): real footage has its walls and skies at about one and a half times reference
white, so captions at twice it were no brighter than the wall behind them and read as dim. The
preview draws an HDR video's captions on a half-float, extended-range layer at four times
(`CaptionFrame.hdrWhiteScale`): that layer shows brighter than the player shows the file, so the two
factors differ to look the same.

### Free and Pro

`Entitlements` (in the Kit) is the one place the tier's limits are written. A free app:

- puts a small watermark on the picture and the saved video. The engine draws it (`watermark` in
  the scene), so the preview and the save carry the same one, and it is part of the saved file's
  name. The iOS preview asks the engine where it is (`oc_watermark_rect`) and keeps it on a layer of
  its own, so dragging or pinching a caption never moves it;
- saves at up to 1080p and 30 fps, and turns an HDR video into an ordinary one;
- locks the styles marked `"pro": true` in `presets.json` (the web ignores the flag) and the Large
  v3 speech model (Large v3 Turbo is free).

The screens lock what the tier lacks and show `ProSheet`; the save also passes its options through
`Entitlements.limit`, so a remembered choice cannot get past a screen. Nothing else is gated: the
engine and the rest are open source. A build from source is Pro; an App Store build (compiled with
`APPSTORE`) starts free until a purchase says otherwise. Pro is a one-time purchase
(`Purchases.swift`, StoreKit 2, only in an App Store build; `Config/Pro.storekit` is the test
configuration the scheme runs with, so a purchase can be tried in Xcode with a test price), and the
Pro sheet shows the store's price. A debug build picks the tier in Settings or with
`OC_TIER=free|pro`, and shows a test price.

### Long jobs

The app asks the user to keep it in the foreground and keeps the screen awake during a download, a
transcription or a save. There is no background processing. Editor models belong to the app, not to
a screen, so a transcription or an autosave in progress carries on when the user goes back to the
project list, where the project's row shows its progress.


## The documentation site

The documentation is plain Markdown in `docs/`, so GitHub shows it as it is, and `apps/docs` builds the same
files into a static site with [Starlight](https://starlight.astro.build) (it lives at `docs.opencaptions.app`).
The site owns no content. Its sidebar is generated from the folders (`apps/docs/astro.config.ts` names a folder's
group, a page's `sidebar.order` frontmatter orders it), so a new page needs no entry anywhere; a new folder needs
one group.

- A page is plain Markdown that GitHub shows as it is: it starts with its own `# Title`, and links another page with a
  relative `.md` link. `apps/docs/plugins/remark-docs.ts` turns those into what the site needs (the page's URL; the
  title drawn by the theme). Links to the code are absolute GitHub URLs. A broken link or anchor fails the build
  (`starlight-links-validator`, and the plugin for a link to a missing file).
- Search is Pagefind: an index built with the site and searched in the browser, so no service and no query
  leaves the page. The site sends no telemetry (`ASTRO_TELEMETRY_DISABLED` in the Dockerfile).
- `apps/docs/Dockerfile` builds it in a container, with the pages as a named context
  (`--build-context docs=docs`, copied to `src/content/docs`, where Starlight reads them), and its `docs-site` stage
  holds only the static files. The `docs` CI job and `make ci` run that build, `make docs-build` writes it to
  `apps/docs/dist`, and `make docs` serves it with live reload.
- It is deployed as static files, like the demo: `publish-docs` deploys the `docs-site` artifact with
  `wrangler deploy` (`apps/docs/wrangler.jsonc`, a Worker named `opencaptions-docs`, a 404 page) on `main`, only when
  `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` are set. The domain is attached to the Worker in the Cloudflare dashboard.

## The public demo

`apps/web` has a second entry, `demo.html` (`src/demo/`, built with `vite.demo.config.ts`), that is
the site at opencaptions.app: static files for a Cloudflare Worker (static assets), no API, no account. It is the
editor's own `CaptionPreview` and `PresetStrip` over one sample clip (it loops), so the captions are drawn by
the same engine (WebAssembly) as in the editor and the download; nothing is drawn twice.

- `src/lib/sources.ts` is the seam: where the preview reads a project's video and a font family.
  The application's default is its API; the demo points them at `demo-public/demo/{clips,fonts}`.
  `disableSaving()` in the editor store keeps edits in the page.
- The clips are data: `demo-public/demo/clips.json` names each clip's video, transcript (the
  API's `Transcript` shape) and credit (shown in the footer; CC BY asks for it). `scripts/make-demo-clip.sh`
  cuts one from a long film (9:16 crop, H.264 + AAC; the current one is 720x1280, 14 s, about 1.4 MB, which Cloudflare serves with range requests like any CDN, so it is not worth a separate bucket). Replacing a clip is replacing its files and the manifest entry; with more than one, the page shows a chip for each.
- The engine's `.wasm` and fonts are not committed: the web Dockerfile's `demo-site` stage builds
  them and the site (`make demo` writes `apps/web/dist-demo`). CI builds that stage on every run and
  `publish-demo` deploys it with `wrangler deploy --assets` on `main`, only when `CLOUDFLARE_API_TOKEN`
  and `CLOUDFLARE_ACCOUNT_ID` are set (the Worker is named `opencaptions`).
- The page is found by what it says, without running script: `src/demo/Landing.tsx` holds its words
  and has no browser-only code, so the build renders it to HTML (`scripts/demo-prerender.ts`, a plugin
  in `vite.demo.config.ts`) and React replaces it when the demo is ready. `src/demo/seo.ts` is the one
  place for the title, description, cards, icons and structured data (written into `<head>` at
  `demo.html`'s `<!--seo-head-->`); its FAQ (`src/demo/faq.ts`) is the text shown on the page.
  The page exists in every language of the interface: English at `/`, the others at `/<code>/`
  (`src/demo/pages.ts`), each prerendered in its language with its own title, description, canonical
  address and `hreflang` links to all the others; the footer links them as plain anchors. The address
  names the language: a visitor at `/` whose browser (or saved choice) is another language is sent to
  that page, and one who picked English stays. A new language is a new `locales/<code>.json` plus its
  entries in `pages.ts` and `sitemap.xml`; the tests fail until all agree.
  Files for crawlers are in `demo-public/`: `robots.txt` (everyone welcome, the AI crawlers named),
  `sitemap.xml`, `llms.txt`, the icons and `site.webmanifest`, and `og.png` (the link preview,
  rebuilt by `scripts/make-og-image.swift`). `tests/unit/demo-seo.test.ts` checks all of it. When the
  App Store link exists, set `APP_STORE_URL` in `links.ts` (the page and the structured data follow)
  and update `llms.txt`.
- The fonts in `demo-public/demo/fonts` are the families the presets use (OFL), fetched once by
  `apps/web/scripts/fetch-demo-fonts.mjs`; a family missing there is drawn in the default face.
- It offers presets only: no upload, no export, no Pro or account feature exists in it to abuse.
  `npm run dev:demo` puts the engine assets in `demo-public/engine` first (`scripts/demo-engine.sh`: cargo, else Docker).

## Licence

AGPL-3.0-only: anyone may self-host or modify it, and a hosted fork must publish
its changes. Contributors accept the [CLA](https://github.com/leogaudin/opencaptions/blob/main/CLA.md), which lets the maintainer
also ship their code where the AGPL can't go, such as the App Store.
