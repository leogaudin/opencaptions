//! The render server: `GET /health`, `POST /render`.
//!
//! A render decodes the source with FFmpeg, draws the caption overlay for every
//! frame, composites and encodes in one FFmpeg pass, then PUTs the file to the
//! presigned URL it was given. It holds no storage credentials: the caller
//! grants exactly one read and one write per job.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use opencaptions_engine::{FontBook, Renderer, Scene, SceneInput};
use serde::Deserialize;
use serde_json::json;
use tiny_http::{Header, Method, Request, Response, Server};

#[derive(Deserialize)]
struct RenderRequest {
    video_url: String,
    output_url: String,
    output_key: String,
    /// The style's font, when it is not bundled.
    font_url: Option<String>,
    /// The fallback families the scene names (`fallback_fonts`) that are not bundled, each with
    /// where to read it.
    #[serde(default)]
    fallback_font_urls: std::collections::HashMap<String, String>,
    #[serde(flatten)]
    scene: SceneInput,
    fps: u32,
    codec: String,
    crf: Option<u32>,
    pro_res_profile: Option<String>,
    /// Draw the captions over solid chroma green instead of the video, to key out in an editor.
    /// The file has neither the video's picture nor its sound.
    #[serde(default)]
    green_screen: bool,
    progress_url: Option<String>,
    progress_token: Option<String>,
}

/// Encoder arguments and the pixel format the composite is converted to.
#[derive(Debug)]
struct Encoding {
    args: Vec<String>,
    pix_fmt: &'static str,
    /// The 10-bit format to keep an HDR source HDR in, for codecs that can carry
    /// it. H.264 cannot in any widely playable profile, so it is tone-mapped.
    hdr_pix_fmt: Option<&'static str>,
    content_type: &'static str,
}

fn encoding(req: &RenderRequest) -> Result<Encoding, String> {
    let crf = || {
        req.crf
            .map(|c| c.to_string())
            .ok_or(format!("crf is required for {}", req.codec))
    };
    let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    Ok(match req.codec.as_str() {
        "h264" => Encoding {
            args: [
                args(&["-c:v", "libx264", "-preset", "medium", "-crf"]),
                vec![crf()?],
            ]
            .concat(),
            pix_fmt: "yuv420p",
            hdr_pix_fmt: None,
            content_type: "video/mp4",
        },
        "h265" => Encoding {
            args: [
                args(&[
                    "-c:v", "libx265", "-preset", "medium", "-tag:v", "hvc1", "-crf",
                ]),
                vec![crf()?],
            ]
            .concat(),
            pix_fmt: "yuv420p",
            hdr_pix_fmt: Some("yuv420p10le"),
            content_type: "video/mp4",
        },
        "vp9" => Encoding {
            args: [
                args(&["-c:v", "libvpx-vp9", "-row-mt", "1", "-b:v", "0", "-crf"]),
                vec![crf()?],
            ]
            .concat(),
            pix_fmt: "yuv420p",
            hdr_pix_fmt: Some("yuv420p10le"),
            content_type: "video/webm",
        },
        "prores" => {
            let (profile, pix_fmt) = match req.pro_res_profile.as_deref().unwrap_or("hq") {
                "proxy" => ("0", "yuv422p10le"),
                "light" => ("1", "yuv422p10le"),
                "standard" => ("2", "yuv422p10le"),
                "hq" => ("3", "yuv422p10le"),
                "4444" => ("4", "yuv444p10le"),
                "4444-xq" => ("5", "yuv444p10le"),
                other => return Err(format!("unknown ProRes profile {other:?}")),
            };
            Encoding {
                args: args(&["-c:v", "prores_ks", "-profile:v", profile]),
                pix_fmt,
                hdr_pix_fmt: Some(pix_fmt),
                content_type: "video/quicktime",
            }
        }
        other => return Err(format!("unsupported codec {other:?}")),
    })
}

fn audio_args(codec: &str) -> &'static [&'static str] {
    match codec {
        "vp9" => &["-c:a", "libopus", "-b:a", "160k"],
        "prores" => &["-c:a", "pcm_s16le"],
        _ => &["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"],
    }
}

fn log(event: &str, fields: serde_json::Value) {
    eprintln!("{}", json!({ "event": event, "fields": fields }));
}

/// Deletes the temporary output however the render ends.
struct TempFile(PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Tells the API how far a render has got, from a thread of its own: an answer that takes
/// its two seconds must not hold up the frames. Only the newest report is sent, so a slow
/// API sees fewer calls, never a backlog.
struct Reporter {
    tx: Option<mpsc::Sender<(f32, String)>>,
    thread: Option<JoinHandle<()>>,
}

impl Reporter {
    fn new(req: &RenderRequest) -> Self {
        let Some(url) = req.progress_url.clone() else {
            return Self {
                tx: None,
                thread: None,
            };
        };
        let token = req.progress_token.clone();
        let (tx, rx) = mpsc::channel::<(f32, String)>();
        let thread = std::thread::spawn(move || {
            while let Ok(mut latest) = rx.recv() {
                while let Ok(newer) = rx.try_recv() {
                    latest = newer;
                }
                post_progress(&url, token.as_deref(), latest.0, &latest.1);
            }
        });
        Self {
            tx: Some(tx),
            thread: Some(thread),
        }
    }

    fn send(&self, progress: f32, message: &str) {
        if let Some(tx) = &self.tx {
            let _ = tx.send((progress, message.to_owned()));
        }
    }
}

impl Drop for Reporter {
    fn drop(&mut self) {
        self.tx = None;
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn post_progress(url: &str, token: Option<&str>, progress: f32, message: &str) {
    let mut call = ureq::post(url)
        .config()
        .timeout_global(Some(Duration::from_secs(2)))
        .build();
    if let Some(token) = token {
        call = call.header("x-job-token", token);
    }
    // Best effort: a missed tick only means the bar waits for the next one.
    let _ = call.send_json(json!({ "progress": progress, "message": message }));
}

/// FFmpeg, killed and reaped if the render ends any way but by waiting for it: an error, a
/// panic, a closed connection. Left alone it would go on encoding for nobody.
struct Running(Option<Child>);

impl Running {
    fn wait(mut self) -> std::io::Result<ExitStatus> {
        self.0.take().expect("waited once").wait()
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// How many renders run at once; the rest wait their turn. Each holds a few copies of a
/// frame and an FFmpeg that uses every core, so more only makes all of them slower.
struct Slots {
    free: Mutex<usize>,
    freed: Condvar,
}

struct Slot<'a>(&'a Slots);

impl Slots {
    fn new(n: usize) -> Self {
        Self {
            free: Mutex::new(n.max(1)),
            freed: Condvar::new(),
        }
    }

    fn take(&self) -> Slot<'_> {
        let mut free = self.free.lock().unwrap_or_else(|e| e.into_inner());
        while *free == 0 {
            free = self.freed.wait(free).unwrap_or_else(|e| e.into_inner());
        }
        *free -= 1;
        Slot(self)
    }
}

impl Drop for Slot<'_> {
    fn drop(&mut self) {
        *self.0.free.lock().unwrap_or_else(|e| e.into_inner()) += 1;
        self.0.freed.notify_one();
    }
}

/// The protocols FFmpeg and ffprobe may use to open the source. It is a URL a caller gave, and
/// a playlist or container can name another to read: only what a presigned link needs.
const SOURCE_PROTOCOLS: &str = "http,https,tcp,tls,crypto";

/// A stalled read of the source fails after this long instead of hanging a render.
const SOURCE_STALL: &str = "30000000";

/// The source's transfer function as ffprobe names it, empty when unknown.
fn probe_transfer(url: &str) -> String {
    let out = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-protocol_whitelist",
            SOURCE_PROTOCOLS,
            "-rw_timeout",
            SOURCE_STALL,
            "-select_streams",
            "v:0",
        ])
        .args([
            "-show_entries",
            "stream=color_transfer",
            "-of",
            "default=nw=1:nk=1",
            url,
        ])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_owned(),
        // Drawn as SDR: right for most sources, and logged so an HDR one is traceable.
        _ => {
            log(
                "probe_failed",
                json!({ "detail": "colour unknown, rendering as SDR" }),
            );
            String::new()
        }
    }
}

/// How a render treats colour, decided by the source and the output codec.
enum Colour {
    /// SDR in, SDR out: composite in RGB, encode BT.709.
    Sdr,
    /// HDR in, SDR-only codec out: tone-map to BT.709 first, then as SDR.
    ToneMapped,
    /// HDR in, HDR-capable codec out: composite in the source's own BT.2020
    /// space at 10 bits, and keep its transfer function.
    Hdr {
        transfer: String,
        pix_fmt: &'static str,
    },
}

/// Diffuse white in nits: where phones record white (BT.2408), and so where the
/// tone-map pins SDR white.
const SDR_WHITE_NITS: u32 = 203;
/// The scale that puts caption white on that same reference white, measured: it
/// lands within 1% of BT.2408 graphics white in both PQ and HLG.
const CAPTION_NPL: u32 = 160;

impl Colour {
    fn of(transfer: &str, hdr_pix_fmt: Option<&'static str>) -> Self {
        let hdr = matches!(transfer, "smpte2084" | "arib-std-b67");
        match (hdr, hdr_pix_fmt) {
            (false, _) => Self::Sdr,
            (true, None) => Self::ToneMapped,
            (true, Some(pix_fmt)) => Self::Hdr {
                transfer: transfer.into(),
                pix_fmt,
            },
        }
    }

    /// The filter graph. The captions come in as a picture of `band` (x, y, width, height) only,
    /// and are laid over the video there.
    fn filter(
        &self,
        (w, h, fps): (u32, u32, u32),
        band: (u32, u32),
        sdr_pix_fmt: &str,
        green_screen: bool,
    ) -> String {
        let at = format!("x={}:y={}", band.0, band.1);
        let base = if green_screen {
            format!("color=c=0x00FF00:s={w}x{h}:r={fps},setsar=1")
        } else {
            format!("[0:v]setpts=PTS-STARTPTS,fps={fps},scale={w}:{h}:flags=lanczos,setsar=1")
        };
        let cap = "[1:v]setpts=PTS-STARTPTS";
        // RGB compositing keeps the overlay at full chroma; the conversion is
        // explicit BT.709 rather than FFmpeg's BT.601 default.
        let sdr = |pre: &str| {
            format!(
                "{base}{pre},format=gbrp[base];{cap}[cap];\
                 [base][cap]overlay={at}:format=gbrp:eof_action=pass,\
                 scale=out_color_matrix=bt709:out_range=tv,format={sdr_pix_fmt}[v]"
            )
        };
        match self {
            Self::Sdr => sdr(""),
            // Mobius keeps the picture's own brightness and compresses only the
            // highlights above SDR white; Hable darkened mid-tones by a third.
            Self::ToneMapped => sdr(&format!(
                ",zscale=t=linear:npl={SDR_WHITE_NITS},format=gbrpf32le,zscale=p=bt709,\
                 tonemap=mobius:desat=0,zscale=t=bt709:m=bt709:r=tv"
            )),
            // This FFmpeg's overlay has no 10-bit 4:4:4 mode, so it composites at
            // 4:2:2: luma, where text edges live, stays at full resolution.
            Self::Hdr { transfer, pix_fmt } => format!(
                "{base},format=yuv422p10le[base];\
                 {cap},zscale=tin=iec61966-2-1:pin=bt709:min=gbr:rin=pc:\
                 t={transfer}:p=bt2020:m=bt2020nc:r=tv:npl={CAPTION_NPL},format=yuva422p10le[cap];\
                 [base][cap]overlay={at}:format=yuv422p10:eof_action=pass,format={pix_fmt}[v]"
            ),
        }
    }

    fn tags(&self) -> [&str; 6] {
        let (space, primaries, transfer) = match self {
            Self::Sdr | Self::ToneMapped => ("bt709", "bt709", "bt709"),
            Self::Hdr { transfer, .. } => ("bt2020nc", "bt2020", transfer.as_str()),
        };
        [
            "-colorspace",
            space,
            "-color_primaries",
            primaries,
            "-color_trc",
            transfer,
        ]
    }
}

/// The largest font file a render will download; CJK faces run to ~20 MB.
const MAX_FONT_BYTES: u64 = 32 << 20;

fn fetch_font(url: &str) -> Result<Vec<u8>, String> {
    ureq::get(url)
        .config()
        .timeout_global(Some(Duration::from_secs(60)))
        .build()
        .call()
        .map_err(|e| format!("font download failed: {e}"))?
        .body_mut()
        .with_config()
        .limit(MAX_FONT_BYTES)
        .read_to_vec()
        .map_err(|e| format!("font download failed: {e}"))
}

fn render(
    book: &FontBook<'static>,
    req: &RenderRequest,
    enc: Encoding,
) -> Result<serde_json::Value, String> {
    let started = Instant::now();
    let duration = req.scene.transcript.duration.max(1.0 / req.fps as f32);
    // Borrowed for this render only: the bundled faces are shared, the request's
    // own font lives in `font` and is dropped with it.
    let font = match &req.font_url {
        Some(url) if !book.has(&req.scene.style.font) => Some(fetch_font(url)?),
        _ => None,
    };
    // The families the transcript's scripts need, in the order the scene names them. One that
    // cannot be fetched is left out and its letters are drawn as far as the other faces can.
    let mut fallbacks: Vec<(&String, Vec<u8>)> = Vec::new();
    for family in &req.scene.fallback_fonts {
        if book.has(family) {
            continue;
        }
        if let Some(url) = req.fallback_font_urls.get(family) {
            match fetch_font(url) {
                Ok(data) => fallbacks.push((family, data)),
                Err(e) => log(
                    "fallback_font_failed",
                    json!({ "family": family, "error": e }),
                ),
            }
        }
    }
    let mut book = book.clone();
    if let Some(data) = &font
        && !book.add_requested(&req.scene.style.font, data)
    {
        return Err(format!(
            "{} is not a usable font file",
            req.scene.style.font
        ));
    }
    for (family, data) in &fallbacks {
        if !book.add_requested(family, data) {
            log("fallback_font_rejected", json!({ "family": family }));
        }
    }
    let renderer = Renderer::new(Scene::new(&book, req.scene.clone()));
    let (w, h) = (renderer.scene().width(), renderer.scene().height());
    // Only the box the captions can ever be in is sent for each frame, and laid over the
    // video where it belongs: at 1080x1920 that is a few hundred rows of a frame, not all of it.
    let (bx, by, bw, bh) = renderer.scene().overlay_bounds();
    let frames = (duration * req.fps as f32).ceil() as u32;
    let ext = Path::new(&req.output_key)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("mp4");
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let out = TempFile(std::env::temp_dir().join(format!("opencaptions-{nonce}.{ext}")));

    // Composited in RGB so the overlay blends at full chroma, then converted once
    // with an explicit BT.709 matrix rather than FFmpeg's BT.601 default.
    // Green is plain SDR whatever the video was, so there is nothing to probe or tone-map.
    let colour = if req.green_screen {
        Colour::Sdr
    } else {
        Colour::of(&probe_transfer(&req.video_url), enc.hdr_pix_fmt)
    };
    let filter = colour.filter((w, h, req.fps), (bx, by), enc.pix_fmt, req.green_screen);
    let mut child = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-y"])
        .args([
            "-protocol_whitelist",
            SOURCE_PROTOCOLS,
            "-rw_timeout",
            SOURCE_STALL,
            "-i",
            &req.video_url,
        ])
        .args([
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgba",
            "-s",
            &format!("{bw}x{bh}"),
        ])
        .args(["-framerate", &req.fps.to_string(), "-i", "pipe:0"])
        .args(["-filter_complex", &filter, "-map", "[v]"])
        .args(if req.green_screen {
            vec!["-an"]
        } else {
            vec!["-map", "0:a?"]
        })
        .args(["-t", &format!("{duration:.3}")])
        .args(colour.tags())
        .args(&enc.args)
        .args(audio_args(&req.codec))
        .arg(&out.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("could not start ffmpeg: {e}"))?;

    let mut stderr = child.stderr.take().expect("stderr is piped");
    let errors = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = stderr.read_to_string(&mut s);
        s
    });
    let mut stdin = child.stdin.take().expect("stdin is piped");
    let ffmpeg = Running(Some(child));
    let reporter = Reporter::new(req);
    stream_frames(
        renderer,
        (bx, by, bw, bh),
        frames,
        req.fps,
        &mut stdin,
        |progress| {
            reporter.send(
                progress,
                &format!("Rendering {}%", (progress * 100.0).round()),
            );
        },
    );
    drop(stdin);
    let status = ffmpeg
        .wait()
        .map_err(|e| format!("ffmpeg did not finish: {e}"))?;
    let errors = errors.join().unwrap_or_default();
    if !status.success() {
        return Err(format!("ffmpeg failed ({status}): {}", errors.trim()));
    }

    reporter.send(1.0, "Uploading");
    let size = upload(&req.output_url, enc.content_type, &out.0)?;

    let duration_ms = started.elapsed().as_millis() as u64;
    log(
        "render_complete",
        json!({ "output_key": req.output_key, "frames": frames, "bytes": size, "ms": duration_ms }),
    );
    Ok(
        json!({ "output_key": req.output_key, "frames_rendered": frames, "duration_ms": duration_ms }),
    )
}

/// Draws the frames on a thread of their own and writes each to `sink` as it is ready, so
/// drawing the next one overlaps FFmpeg taking the last. A few buffers are passed back and
/// forth instead of allocated per frame. Stops when `sink` stops taking bytes (FFmpeg closes
/// the pipe once it has encoded the duration it was asked for).
fn stream_frames(
    mut renderer: Renderer,
    (bx, by, bw, bh): (u32, u32, u32, u32),
    frames: u32,
    fps: u32,
    sink: &mut impl Write,
    mut progress: impl FnMut(f32),
) {
    const IN_FLIGHT: usize = 3;
    let width = renderer.scene().width() as usize;
    let (full, row) = (bw as usize == width, bw as usize * 4);
    let (ready_tx, ready) = mpsc::sync_channel::<Vec<u8>>(IN_FLIGHT);
    let (spare_tx, spare) = mpsc::channel::<Vec<u8>>();
    for _ in 0..IN_FLIGHT {
        let _ = spare_tx.send(Vec::with_capacity(row * bh as usize));
    }
    std::thread::scope(|scope| {
        scope.spawn(move || {
            for i in 0..frames {
                let Ok(mut buf) = spare.recv() else { return };
                renderer.render(i as f32 / fps as f32);
                buf.clear();
                if full {
                    buf.extend_from_slice(renderer.rgba());
                } else {
                    for y in by as usize..(by + bh) as usize {
                        let start = (y * width + bx as usize) * 4;
                        buf.extend_from_slice(&renderer.rgba()[start..start + row]);
                    }
                }
                if ready_tx.send(buf).is_err() {
                    return;
                }
            }
        });
        let mut reported = 0.0;
        for i in 0..frames {
            let Ok(buf) = ready.recv() else { break };
            if sink.write_all(&buf).is_err() {
                break;
            }
            let _ = spare_tx.send(buf);
            let done = (i + 1) as f32 / frames as f32;
            if done - reported >= 0.05 {
                reported = done;
                progress(done);
            }
        }
        // Whichever side stopped first, the other must too, or the scope never ends.
        drop(ready);
        drop(spare_tx);
    });
}

/// PUTs the file to its presigned link, trying again after a failure that is not the link
/// being refused: a render can take an hour, and a blip at the end must not throw it away.
fn upload(url: &str, content_type: &str, path: &Path) -> Result<u64, String> {
    let size = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
    let mut last = String::new();
    for attempt in 1..=3u64 {
        let file = File::open(path).map_err(|e| e.to_string())?;
        let sent = ureq::put(url)
            .config()
            .timeout_connect(Some(Duration::from_secs(30)))
            .timeout_send_body(Some(Duration::from_secs(2 * 3600)))
            .timeout_recv_response(Some(Duration::from_secs(300)))
            .build()
            .header("content-type", content_type)
            .header("content-length", size.to_string())
            .send(ureq::SendBody::from_owned_reader(file));
        match sent {
            Ok(_) => return Ok(size),
            // A refused or expired link will not be accepted the next time either.
            Err(ureq::Error::StatusCode(code)) if (400..500).contains(&code) => {
                return Err(format!("upload refused ({code})"));
            }
            Err(e) => {
                last = e.to_string();
                log("upload_retry", json!({ "attempt": attempt, "error": last }));
                std::thread::sleep(Duration::from_secs(2 * attempt));
            }
        }
    }
    Err(format!("upload failed: {last}"))
}

fn validate(req: &RenderRequest) -> Result<Encoding, String> {
    if !(1..=120).contains(&req.fps) {
        return Err("fps must be between 1 and 120".into());
    }
    req.scene.check()?;
    // Every address is fetched by this server or by FFmpeg: only http(s), whatever it says.
    let urls = [
        Some(&req.video_url),
        Some(&req.output_url),
        req.font_url.as_ref(),
        req.progress_url.as_ref(),
    ]
    .into_iter()
    .flatten()
    .chain(req.fallback_font_urls.values());
    for url in urls {
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err("every url must be http or https".into());
        }
    }
    encoding(req)
}

fn respond(request: Request, status: u16, body: serde_json::Value) {
    let header = Header::from_bytes("content-type", "application/json").expect("static header");
    let response = Response::from_string(body.to_string())
        .with_status_code(status)
        .with_header(header);
    let _ = request.respond(response);
}

fn error(code: u16, kind: &str, detail: String) -> (u16, serde_json::Value) {
    (
        code,
        json!({ "error": kind, "detail": detail, "code": code }),
    )
}

/// Whether the request carries the token the API shares with this server. The comparison
/// looks at every byte, so its time says nothing about how much of a guess was right.
fn authorised(request: &Request, token: &str) -> bool {
    let sent = request
        .headers()
        .iter()
        .find(|h| h.field.equiv("x-engine-token"))
        .map_or("", |h| h.value.as_str());
    token_matches(sent, token)
}

fn token_matches(sent: &str, token: &str) -> bool {
    // No token configured accepts nothing, rather than a request that sent no token either.
    !token.is_empty()
        && sent.len() == token.len()
        && sent
            .bytes()
            .zip(token.bytes())
            .fold(0, |diff, (a, b)| diff | (a ^ b))
            == 0
}

fn handle(book: &FontBook<'static>, token: &str, slots: &Slots, mut request: Request) {
    let (status, body) = match (request.method(), request.url()) {
        (Method::Get, "/health") => (
            200,
            json!({ "status": "ok", "version": env!("CARGO_PKG_VERSION"), "service": "engine" }),
        ),
        (Method::Post, "/render") if !authorised(&request, token) => error(
            401,
            "unauthorised",
            "missing or wrong x-engine-token".into(),
        ),
        (Method::Post, "/render") => {
            let mut raw = Vec::new();
            match request.as_reader().take(64 << 20).read_to_end(&mut raw) {
                Err(e) => error(400, "bad_request", e.to_string()),
                Ok(_) => match serde_json::from_slice::<RenderRequest>(&raw) {
                    Err(e) => error(422, "validation_error", e.to_string()),
                    Ok(req) => match validate(&req) {
                        Err(e) => error(422, "validation_error", e),
                        Ok(enc) => {
                            // Waits here for a free place; the caller's own timeout is the limit.
                            let _slot = slots.take();
                            render(book, &req, enc)
                        }
                        .map_or_else(
                            |e| {
                                log(
                                    "render_failed",
                                    json!({ "output_key": req.output_key, "error": e }),
                                );
                                error(500, "render_failed", e)
                            },
                            |ok| (200, ok),
                        ),
                    },
                },
            }
        }
        _ => error(
            404,
            "not_found",
            format!("{} {}", request.method(), request.url()),
        ),
    };
    respond(request, status, body);
}

/// The font files directly in `dir`, ordered by name byte-for-byte. Order decides
/// which face wins a glyph fallback, so the web build lists them by the same
/// rule (`LC_ALL=C ls`); a subdirectory would be seen by one and not the other.
fn load_fonts(dir: &Path) -> FontBook<'static> {
    let is_font = |p: &PathBuf| {
        p.is_file()
            && p.extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("ttf") || e.eq_ignore_ascii_case("otf"))
    };
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.path())
                .filter(is_font)
                .collect()
        })
        .unwrap_or_default();
    files.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
    let mut book = FontBook::new();
    for path in files {
        // Loaded once and kept for the life of the server.
        let data = std::fs::read(&path)
            .ok()
            .map(|d| &*Box::leak(d.into_boxed_slice()));
        match data.and_then(|data| book.add(data)) {
            Some(family) => log("font_loaded", json!({ "family": family, "file": path })),
            None => log("font_rejected", json!({ "file": path })),
        }
    }
    book
}

fn main() {
    let port = std::env::var("PORT").unwrap_or_else(|_| "3001".into());
    if std::env::args().nth(1).as_deref() == Some("health") {
        let ok = ureq::get(&format!("http://127.0.0.1:{port}/health"))
            .call()
            .is_ok();
        std::process::exit(if ok { 0 } else { 1 });
    }
    let dir = std::env::var("FONTS_DIR").unwrap_or_else(|_| "/app/fonts".into());
    let book = Arc::new(load_fonts(Path::new(&dir)));
    if book.is_empty() {
        log("no_fonts", json!({ "dir": dir }));
        std::process::exit(1);
    }
    let Some(token) = std::env::var("ENGINE_TOKEN").ok().filter(|t| !t.is_empty()) else {
        log("no_token", json!({ "need": "ENGINE_TOKEN, not empty" }));
        std::process::exit(1);
    };
    let slots = Arc::new(Slots::new(
        std::env::var("ENGINE_MAX_RENDERS")
            .ok()
            .and_then(|n| n.parse().ok())
            .unwrap_or(4),
    ));
    let token = Arc::new(token);
    let server = Server::http(format!("0.0.0.0:{port}")).expect("bind");
    log(
        "listening",
        json!({ "port": port, "families": book.families() }),
    );
    for request in server.incoming_requests() {
        let (book, token, slots) = (Arc::clone(&book), Arc::clone(&token), Arc::clone(&slots));
        std::thread::spawn(move || handle(&book, &token, &slots, request));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn book() -> FontBook<'static> {
        let mut b = FontBook::new();
        b.add(include_bytes!("../fonts/Inter.ttf")).unwrap();
        b
    }

    fn scene() -> SceneInput {
        serde_json::from_value(json!({
            "width": 270, "height": 480,
            "transcript": { "duration": 2.0, "segments": [{ "words": [
                { "text": "hello", "start": 0.0, "end": 0.6 },
                { "text": "there", "start": 0.6, "end": 1.2 }
            ] }] },
            "style": {
                "font": "Inter", "font_size": 48, "text_color": "#FFFFFF",
                "highlight_colors": ["#7C3AED"], "background": "none",
                "background_color": "#000000", "background_opacity": 0.0,
                "position_x": 0.5, "position_y": 0.8, "animation": "word_highlight",
                "words_per_line": 3, "stroke_width": 0, "stroke_color": "#000000",
                "shadow_blur": 0, "shadow_color": "#000000"
            }
        }))
        .unwrap()
    }

    fn request(patch: serde_json::Value) -> serde_json::Result<RenderRequest> {
        let mut value = json!({
            "video_url": "http://garage:3900/v.mp4?sig=1",
            "output_url": "http://garage:3900/o.mp4?sig=1",
            "output_key": "projects/p/renders/h.mp4",
            "fps": 30, "codec": "h264", "crf": 15,
            "width": 270, "height": 480,
            "transcript": serde_json::to_value(scene().transcript).unwrap(),
            "style": {
                "font": "Inter", "font_size": 48, "text_color": "#FFFFFF",
                "highlight_colors": ["#7C3AED"], "background": "none",
                "background_color": "#000000", "background_opacity": 0.0,
                "position_x": 0.5, "position_y": 0.8, "animation": "none",
                "words_per_line": 3, "stroke_width": 0, "stroke_color": "#000000",
                "shadow_blur": 0, "shadow_color": "#000000"
            }
        });
        for (k, v) in patch.as_object().unwrap() {
            value[k] = v.clone();
        }
        serde_json::from_value(value)
    }

    #[test]
    fn only_the_exact_token_is_accepted() {
        assert!(token_matches("s3cret", "s3cret"));
        assert!(!token_matches("", "s3cret"));
        assert!(!token_matches("s3cre", "s3cret"));
        assert!(!token_matches("s3cretx", "s3cret"));
        assert!(!token_matches("S3cret", "s3cret"));
        // A server with no token set would otherwise let in every request that sends none.
        assert!(!token_matches("", ""));
    }

    #[test]
    fn hdr_is_kept_where_the_codec_can_carry_it_and_tone_mapped_where_not() {
        assert!(matches!(
            Colour::of("bt709", Some("yuv420p10le")),
            Colour::Sdr
        ));
        assert!(matches!(Colour::of("", None), Colour::Sdr));
        assert!(matches!(Colour::of("smpte2084", None), Colour::ToneMapped));
        let hlg = Colour::of("arib-std-b67", Some("yuv420p10le"));
        assert_eq!(hlg.tags()[5], "arib-std-b67");
        assert!(
            hlg.filter((1080, 1920, 30), (0, 0), "yuv420p", false)
                .contains("t=arib-std-b67")
        );
        assert_eq!(Colour::of("smpte2084", None).tags()[5], "bt709");
    }

    #[test]
    fn green_screen_replaces_the_video_with_solid_green() {
        let green = Colour::Sdr.filter((1080, 1920, 30), (0, 0), "yuv420p", true);
        assert!(green.starts_with("color=c=0x00FF00:s=1080x1920:r=30"));
        assert!(!green.contains("[0:v]"), "the video picture is not read");
        assert!(green.contains("overlay"), "the captions go over it");
        let plain = Colour::Sdr.filter((1080, 1920, 30), (0, 0), "yuv420p", false);
        assert!(plain.starts_with("[0:v]") && !plain.contains("0x00FF00"));
    }

    #[test]
    fn the_captions_are_laid_over_the_video_where_they_were_cut_from() {
        for colour in [
            Colour::Sdr,
            Colour::ToneMapped,
            Colour::of("smpte2084", Some("yuv420p10le")),
        ] {
            let graph = colour.filter((1080, 1920, 30), (64, 1500), "yuv420p", false);
            assert!(graph.contains("overlay=x=64:y=1500:"), "{graph}");
        }
    }

    #[test]
    fn a_frame_is_the_captions_box_and_nothing_else() {
        let scene = Scene::new(&book(), scene());
        let band = scene.overlay_bounds();
        let (bx, by, bw, bh) = band;
        assert!(
            bw < 270 && bh < 480,
            "a box smaller than the frame: {band:?}"
        );
        let mut reference = Renderer::new(Scene::new(&book(), scene_input()));
        let mut sent = Vec::new();
        stream_frames(Renderer::new(scene), band, 6, 3, &mut sent, |_| {});
        let frame = (bw * bh * 4) as usize;
        assert_eq!(sent.len(), 6 * frame);
        for i in 0..6usize {
            reference.render(i as f32 / 3.0);
            let width = 270usize;
            let want: Vec<u8> = (by as usize..(by + bh) as usize)
                .flat_map(|y| {
                    let start = (y * width + bx as usize) * 4;
                    reference.rgba()[start..start + bw as usize * 4].to_vec()
                })
                .collect();
            assert!(sent[i * frame..(i + 1) * frame] == want[..], "frame {i}");
        }
    }

    fn scene_input() -> SceneInput {
        scene()
    }

    /// A sink that takes `n` writes and then refuses, as a pipe does once FFmpeg is done.
    struct Closes(usize);

    impl Write for Closes {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            if self.0 == 0 {
                return Err(std::io::ErrorKind::BrokenPipe.into());
            }
            self.0 -= 1;
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn drawing_stops_when_the_pipe_does() {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let scene = Scene::new(&book(), scene());
            let band = scene.overlay_bounds();
            // Far more frames than the pipe will take, and more than can be in flight.
            stream_frames(
                Renderer::new(scene),
                band,
                100_000,
                30,
                &mut Closes(2),
                |_| {},
            );
            let _ = tx.send(());
        });
        rx.recv_timeout(Duration::from_secs(20))
            .expect("the stream ended instead of drawing 100,000 frames");
    }

    #[test]
    fn no_more_renders_run_than_there_are_places() {
        let slots = Arc::new(Slots::new(2));
        let running = Arc::new(Mutex::new((0usize, 0usize)));
        let threads: Vec<_> = (0..8)
            .map(|_| {
                let (slots, running) = (Arc::clone(&slots), Arc::clone(&running));
                std::thread::spawn(move || {
                    let _slot = slots.take();
                    {
                        let mut r = running.lock().unwrap();
                        r.0 += 1;
                        r.1 = r.1.max(r.0);
                    }
                    std::thread::sleep(Duration::from_millis(20));
                    running.lock().unwrap().0 -= 1;
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        assert_eq!(running.lock().unwrap().1, 2);
    }

    #[test]
    fn an_address_that_is_not_http_is_refused_wherever_it_appears() {
        assert!(validate(&request(json!({})).unwrap()).is_ok());
        for patch in [
            json!({ "video_url": "file:///etc/passwd" }),
            json!({ "output_url": "ftp://host/x" }),
            json!({ "font_url": "concat:/etc/passwd" }),
            json!({ "progress_url": "gopher://x" }),
            json!({ "fallback_font_urls": { "Noto": "file:///x" } }),
        ] {
            let err = validate(&request(patch.clone()).unwrap()).err().unwrap();
            assert!(err.contains("http"), "{patch}: {err}");
        }
    }

    #[test]
    fn a_style_that_would_panic_the_drawing_is_a_refusal() {
        let mut req = request(json!({})).unwrap();
        req.scene.style.font_size = f32::NAN;
        assert!(validate(&req).unwrap_err().contains("font_size"));
        let mut req = request(json!({})).unwrap();
        req.scene.transcript.duration = f32::INFINITY;
        assert!(validate(&req).unwrap_err().contains("duration"));
    }
}
