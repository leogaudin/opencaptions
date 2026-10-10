# OpenCaptions design

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
4. **Render.** `POST /projects/{id}/download {format, resolution, frame_rate, green_screen}`
   computes a hash of everything that decides the output (transcript, timing
   offset, style, format and its encoder settings, size, fps). The options are
   the iOS Save sheet's: a short side (2160, 1080, 720), which may be above
   the source's, and a frame rate (30 or 60, the cap), which may be above the
   source's. Both default to `"original"`, the video's own, which is what an API client that names
   nothing gets; the editors never show that word, they list the values smallest first with
   the video's own named by its number (`GET /exports` gives `source_resolution` and `source_fps` for it).
   A frame rate above the source's repeats the picture's frames, but the captions are drawn at every
   output frame, so their animation is smoother. `green_screen` draws the captions over solid
   chroma green instead of the picture, with no sound, to key out in an editor (it is part
   of the hash, and the engine does not use the video at all). There is no quality choice: a download is a second encoding of the
   source, so each format is made as good as its codec does well (a CRF in
   `render_formats.py`; ProRes takes a profile), and the size is chosen with the
   resolution and frame rate. `resolve_render_inputs` alone turns options into
   the output's size and rate, for every caller. If
   `projects/{id}/renders/{hash}.<ext>` exists, it is ready at once; otherwise a
   render job is queued and the SPA polls the job. The cache needs no database
   state: readiness is an existence check. `GET /projects/{id}/exports` lists
   the sizes and rates a project offers. The web editor has one Download button
   that opens a dialog (format, size, frame rate, background), as the iOS Save sheet does.
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
  will call the same code natively.
- **Look.** An immersive look in the manner of Edits and Instagram and in the desktop's spirit, in
light or dark (it follows the system, or is chosen from the home screen): the wordmark is the
desktop's solid "burned-in subtitle" block, inverted with the interface, and the caption
highlight yellow is the only accent. It is plain SwiftUI with no UI library: `Theme` holds the
handful of colours (each a light and a dark value), the button styles, the card and the
wordmark, and the screens draw their own top bars instead of the system navigation bar (the
edge swipe back is put back by hand). Sheets (style, transcribe, save) use the same surfaces.

**Settings.** A second tab holds the appearance (system, light or dark), the default spoken
language, the speech models (each can be downloaded or deleted, with its size on disk), what the app
stores (with a button to clear the cached videos, which can be made again), and about, including a
button that shares `diagnostics.log`: a small log kept on the device with the milestones of the long
jobs and any uncaught exception, so a crash that leaves no report can still be explained.

**Transcribing on a server.** Settings → "Where to transcribe" switches between this phone and
"My server": another OpenCaptions backend, connected by pasting the link the web app makes
(or typing the address and key) and checked before it is kept. The key is in the Keychain, the
address in preferences. `ServerTranscriber` is a `Transcriber` like the on-device one: it exports
only the audio (AAC, about 1 MB a minute), uploads it, follows the job, fetches the
`Transcript` and tells the server to forget it. The transcribe sheet then lists the server's
models and downloads nothing. A pairing link opened on the phone asks before it is used,
because it decides where the audio goes. The upload and the wait happen while the app is
open (no background upload yet); plain `http` is allowed only to local-network addresses.

**Presets and fonts.** The preset tiles are drawn by the engine (`CaptionEngine.samples`: the same
drawing as the preview and the export, in a phone-shaped frame, cropped to the band around the
caption), so each shows its real font, colours and highlight; the scene in use is put back after.
The tiles are a grid that fills the width and wraps, on iOS and the web alike.
The style panel, on iOS and the web alike, is in tabs (Presets, Text, Background, Animation,
Outline, Timing) so that no page is long. The Background and Animation tabs show their choices
as tiles drawn the same way, in the caption's current look (a background with no opacity is
given a visible one when chosen). On iOS the style sheet stops at a little over half the
screen, so the video stays in view while it is edited.
**What a style can do.** All of it is the engine's, so the preview and the export agree. Thirteen
animations: the word highlighted by colour (`word_highlight`), by a box (`highlight_box`), popped
(`word_pop`), faded in (`word_fade`), filled left to right as it is said (`word_sweep`, karaoke),
underlined as it is said (`word_underline`) and typed out letter by letter with a cursor
(`typewriter`; the steps are whole letters, so a frame changes only when one appears), none
(`none`: subtitles that do not move), bounced up past their size with a lean, left and right in turn
(`word_bounce`), brought into focus out of a dim blur (`lyric_focus`, the words already said stay sharp),
lit by one box that slides from word to word (`highlight_slide`), lit with a bar under the line that
fills as the line is spoken (`line_bar`) and each set on its own tilted label (`stickers`). The
motion is eased with the engine's own arithmetic, never a platform sine, so the two builds still
agree to the byte. The line's bar and the sliding box are one shape per line (`Guide`), part of the
frame's identity, so a frame is redrawn when they move. Beside them: an outline, a shadow with a blur and an offset (a shadow with no blur is solid and is drawn as an
extrusion, the letters carried from where they are to the offset a pixel at a time, so it reads
as their outline continued), a glow (a blurred halo in its own colour, laid down three times to read as
light), upper case (drawn, never stored: the transcript is untouched) and italic (the upright face sheared
by about 11 degrees, so any font leans and no italic file has to be fetched). Every field after
`shadow_color` is optional with a default of "off", so a style saved before it existed opens unchanged.
The highlight is a list, `highlight_colors` (one to four hex colours, the first the primary; on both
editors a row of pickers with a plus and a remove). Each animation uses it by one rule: a look that marks
each word (the lit word, a box, a label, an underline, the cursor) takes the colours in turn, word by word;
a single shape (the sliding box, the bar) is the primary; a sweep runs through all of them as a gradient
across the line. A style with one colour looks exactly as before. Stored projects were migrated from the
one `highlight_color` (Alembic 0005), and an iPhone project saved before the list still opens, its colour
first. A sweep paints each letter once, the highlight on
the side it has passed and the plain colour on the rest, so no soft edge of the plain word shows round it.
The built-in presets that use them are Purple Punch (a box that slides between words), Karaoke, Bold
(Montserrat Black, bundled with the engine, in capitals with a thick black outline carried out into a
hard black extrusion), Boom, Lyric, Documentary,
Gradient, Stickers, Plain (subtitles that do not move), Neon, Typewriter, Handwritten and Elegant.
The font row opens a list of the fonts in use, each name in its own face (a name-only subset
fetched from Google, a few KB), and "More fonts" opens the whole Google Fonts catalog (the same
one the server lists), searchable. The caption itself is always drawn by the engine.

**Missed speech.** Whisper skips a whole 30 s window it judges silent, which music and noisy
speech trigger, leaving a hole in the captions with good ones on either side. After the main
pass, every stretch of 12 s or more without words is decoded again without that judgement
(`TranscriptGaps`), and the result is kept only if it looks like speech (a few words, not one
line repeated).

**Importing.** A picked video is copied somewhere the app owns and then shown (a poster, a name that
can be changed, its size and length) before it is imported; cancelling throws the copy away.

**Fonts.** Inter, Poppins (ExtraBold, the default preset's) and Montserrat (Black, the Bold preset's) are bundled;
  Inter is the glyph fallback, so an offline install still draws. Any Google Fonts family can be chosen: the API
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
  engine holds no storage credentials. The render worker sends `x-engine-token`
  (`ENGINE_TOKEN`, a credential the two share like the storage keys) and the engine
  answers 401 to a render without it; `/health` stays open. It posts progress back with a per-job
  token. The API reaches it through a `RenderBackend` seam (`RENDER_BACKEND`).

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

**Look.** The web app and the iOS app share one look (`apps/web/src/index.css` holds the web's
tokens, `Theme` the iOS app's): a white or near-black page, a surface for cards, a stronger one for
controls, the caption highlight yellow as the single accent (a deeper gold where it is text on
white), rounded corners, and the desktop's "burned-in subtitle" wordmark. It is light or dark and
follows the system until the user chooses. Projects are a grid of poster cards; in the timeline the
selected caption is yellow and the playhead is the page's ink colour.

## Transcription

A provider seam (`app/transcription/`) takes audio and returns a `Transcript`:

- `local`: faster-whisper on CPU or CUDA. Models download on first use into
  `models/`. VAD and no-speech thresholds can be tuned (`WHISPER_*`).
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
provider returns is then cleaned up in one place (`app/transcription/words.py`): a mark
Whisper split off its word ("*rires" and "*") is joined back, and a segment is ended at a
pause (the same tempo-relative rule as the captions'), because with voice detection on
Whisper decodes the speech with the silences cut out and can put words from either side
of a long one in a segment.

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

## iOS app

`apps/ios`. Everything runs on the phone: no server, no accounts. It is a SwiftUI
app over three things it does not reimplement.

| Piece | iOS |
|---|---|
| Caption drawing and edits | The same engine crate, as a static library in `OpenCaptionsEngine.xcframework` (device, Apple-silicon simulator, macOS: `apps/engine/scripts/build-apple.sh`). Swift imports the C header through a module map. One Swift actor, `CaptionEngine`, makes every call: the engine keeps one scene per process and allows its calls from any thread if they are serialized, which an actor guarantees. |
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML, Neural Engine), pinned, in its own SwiftPM target so the core tests do not build it. Its result is mapped to the same `Transcript` shape the way the server's local provider does, so transcripts are interchangeable. A `Transcriber` protocol sits in front, so a hosted endpoint can be a second conformance later. |
| Decode, composite, encode | AVAssetReader decodes, the engine draws each overlay, Core Image composites, AVAssetWriter encodes (H.264, or 10-bit HEVC for HDR) with the audio re-encoded as AAC. The picture is baked upright at the size it is shown. |

**Layout.** `project.yml` (XcodeGen; the `.xcodeproj` is generated, not committed)
describes the app target, which is SwiftUI views and wiring. Everything testable
lives in the local package `OpenCaptionsKit`: models in the API's shapes, the engine
actor, project storage, the editor's logic, the exporter. The minimum is iOS 18, for
the app's scroll and gesture APIs; the app is universal (iPhone and iPad), and the iPhone stays in portrait: the layout is not drawn for landscape yet, which the iPad has. iOS is not
part of `make ci`: it has its own macOS workflow, and nobody without a Mac is blocked.

**The editor** mirrors the web one. The preview is an `AVPlayer` with the engine's
frame on a layer above it, redrawn on the player's clock; a tap plays or pauses, and
while paused a drag moves the caption (snapping to the video's centre lines with a
guide and a haptic tick, by the engine's rule) and a double-tap opens a card to edit one word (the keyboard opens with the word selected; spaces inside stay, it is still one word), and two fingers pinch the font size. The timeline
has a ruler over a video track and a caption track, and edge handles that retime through
the engine. The playhead stays in the middle and the timeline moves under it (the track is
offset by the playing time, so only a small modifier and the ruler read it, never the
tracks): a finger dragging anywhere on it scrubs, pausing a playing video, and coasts a
little on release, a pinch zooms, and a tap seeks. It opens at 80 pt per second, and Fit
zooms out until the whole video spans half the view, so it is all in view wherever the
playhead is. Dragging a caption's edge holds the track still, or it would move under the
finger. The transport row has play, the time (current over total), mute, Fit, and undo and
redo: `EditorModel` records a snapshot (transcript, style, offset) before each change, and
a run of one kind of change (a slider, an edge) is one step. The video takes the screen, with only the compact timeline under it; on a wide
screen the style controls sit beside the video, on a phone they come up over it as a
sheet that rests low enough to keep the caption in view. Style
controls and presets are the web's, from the same `presets.json`; the caption offset
is the engine's. Edits autosave after a quiet moment and when the app leaves the
foreground; there is no Save button.

**Fonts.** Inter, Poppins and Montserrat are bundled with the engine's other fonts, in the same order the
server loads them. A style that names another Google Fonts family fetches it once,
as the server does (TrueType, the weight nearest 800), and keeps it on disk.

**Storage.** Projects are files, because one process reads and writes them:
`Application Support/Projects/<id>/` holds:
- `project.json`: title, dates, `Transcript`, `StyleConfig` and timing offset, in the
  API's shapes, so a project moves between phone and server unchanged;
- `source.<ext>`: copied in at import, so a project survives the clip being deleted
  from Photos;
- `renders/`: cached videos named by a hash of what decides their pixels (local to
  the phone, not the server's hash), excluded from backup.

Writes are atomic (a temporary file, then a rename). The project list is a scan of
the folder, and an unreadable project is hidden rather than failing the list.
Subtitle files (SRT, VTT) are only exported by the Docker product.

**Models.** The desktop's ids, limited to what WhisperKit publishes and to a short list:
Tiny, Base, Small, Large v3 Turbo and Large v3 (no English-only or superseded ones).
They are downloaded on demand into a backup-excluded folder and never bundled. The
default is Large v3 Turbo (the best quality for its size), and a metered connection
asks before a download. Loading a model into memory is the longest wait (the first time on a phone
Core ML prepares it for that chip, minutes on an iPhone 14 for the Turbo model, and the system keeps the
result, so later loads take seconds; the screen says so), so a model starts loading as soon as it is
downloaded, the default one, when
it is downloaded, starts loading as the app opens, any other as soon as it is chosen in the Transcribe
sheet (while the language is picked), and it runs beside the
reading of the audio; the loaded model stays for the next transcription and is let go on a memory
warning or when the app leaves the screen.

**Languages.** The interface is in English, French, Spanish, German, Polish, Portuguese (Brazil), Italian,
Russian, Turkish, Japanese, Korean, Simplified Chinese and Indonesian (the browser's or the
phone's language is used; the web has a choice on the Account page and on the sign-in screens).
On the web the English text in the code is the key: `t("Download")`, with `{name}` for values, and
`locales/<code>.json` holds the others (`lib/i18n.ts`); a text without a translation shows in
English. On iOS, SwiftUI text and `String(localized:)` are collected in the app's string catalogs
(`Localizable.xcstrings`, `InfoPlist.xcstrings`), and the Kit has its own for the words it
produces (errors, what a long job says). Tests fail on a text missing in any language or a
translation that loses a placeholder (`i18n.spec.ts`, `LocalizationTests`). What the server
says (its errors, a job's progress) is not translated, and neither is the watermark. Captions in
other scripts: the engine shapes each word with its own direction and script, lays a right-to-left
line (Hebrew, Arabic) out from the right, and falls back to the bundled Noto Sans faces for
Arabic, Hebrew, Devanagari and Thai. Chinese, Japanese, Korean and the other Asian scripts need
fonts too large to bundle, so the engine says which families a transcript needs
(`scripts.rs`, `oc_fallback_fonts`: Han is drawn in the Japanese, Korean or Chinese face by the
kana, hangul or language) and the host fetches them from Google Fonts as it does a style's own
font, naming them in the scene's `fallback_fonts`. The render server gets them from the API,
which holds a Python copy of the rule held to the same cases (`testdata/script_fonts.json`). Adding a
language means a file or a column of translations in each of those, and its code in the list.

**Free and Pro.** `Entitlements` (in the Kit) is the one place the tier's limits are written: a free
app puts a small watermark on the picture and the saved video (drawn by the engine, `watermark` in the
scene, so the preview and the save carry the same one, and part of the saved file's name; the iOS preview asks the engine where it is, `oc_watermark_rect`, and keeps it on a layer of its own so that dragging or pinching a caption never moves it), saves
at up to 1080p and 30 fps, turns an HDR video into an ordinary one, locks the styles marked
`"pro": true` in `presets.json` (the web ignores the flag) and the Large v3 speech model (Large v3
Turbo is free). The screens lock what the tier lacks and show `ProSheet`; the save also passes its
options through `Entitlements.limit`, so a remembered choice cannot get past a screen. Nothing
else is gated: the engine and the rest are open source. A build from source is Pro; an App Store
build (compiled with `APPSTORE`) starts free until a purchase (StoreKit, not built yet) says
otherwise. Pro is a one-time purchase (`Purchases.swift`, StoreKit 2, only in an App Store
build; `Config/Pro.storekit` is the test configuration the scheme runs with, so a purchase can
be tried in Xcode with a test price); the Pro sheet shows the store's price. A debug build
picks the tier in Settings or with `OC_TIER=free|pro`, and shows a test price.

**HDR.** A PQ or HLG source stays HDR: decoded to 10 bits, written as 10-bit HEVC
with BT.2020. Core Image puts sRGB white well above reference white in an HDR
signal, so the captions are scaled by a measured factor per transfer function, and
the tests read the output's luma to check where they land. A saved video's captions land at
five times reference white (about 1000 nits in PQ, the top of the range in HLG): real footage
has its walls and skies at about one and a half times reference white, so captions at twice it
were no brighter than the wall behind them and read as dim. The preview draws an HDR video's
captions on a half-float, extended-range layer at four times (`CaptionFrame.hdrWhiteScale`):
that layer shows brighter than the player shows the file, so the two factors differ to look
the same.

**Save options.** Save opens a sheet first: the format (H.264, which plays everywhere, or HEVC, about a
third smaller), the size (absolute values, smallest first, such as 720p, 1080p and 4K by the short side, with the video's own size among them named by its pixels, and larger than the source too:
a 144p video can be saved at 4K, the picture scaled up and the captions drawn sharp at the size saved), the frame rate (30 and 60 and the source's own, each by its number: a lower one keeps evenly spaced frames, a higher
one repeats them while the captions are drawn at each, so they animate smoother) and, for an HDR source, whether it stays HDR (10-bit HEVC) or is tone-mapped down to an
ordinary SDR video before the captions go on, and the background (the video, or a green screen: only the
captions over solid green, always SDR, for an editor to key out; it is not remembered, so a later save is
not captions only by surprise). The other choices are remembered, and an estimate of the
size is shown (from bits per pixel, with HEVC needing two thirds of H.264's; there is no quality
choice, a saved video is made as good as it can be), and when it would not fit in the free space Save is disabled with a message saying so. Everything the options decide is part of the file's name (`ExportKey`).

**Dragging the caption.** The grab region is the caption's box made at least 48 pt across
and 24 pt wider all round (`CaptionGestures.dragRegion`), measured from where the finger
landed (a pan is only recognised after it has moved a little), and it works while the
video plays.

**Long jobs.** The app asks the user to keep it in the foreground and keeps the
screen awake during a download, a transcription or a save. There is no background
processing.
Editor models belong to the app, not to a screen, so a transcription or an autosave in
progress carries on when the user goes back to the project list, where the project's row
shows its progress.

## Licence

AGPL-3.0-only: anyone may self-host or modify it, and a hosted fork must publish
its changes. Contributors accept the [CLA](../CLA.md), which lets the maintainer
also ship their code where the AGPL can't go, such as the App Store.
