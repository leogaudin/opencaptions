//! The render server: `GET /health`, `POST /render`.
//!
//! A render decodes the source with FFmpeg, draws the caption overlay for every
//! frame, composites and encodes in one FFmpeg pass, then PUTs the file to the
//! presigned URL it was given. It holds no storage credentials: the caller
//! grants exactly one read and one write per job.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
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
    progress_url: Option<String>,
    progress_token: Option<String>,
}

/// Encoder arguments and the pixel format the composite is converted to.
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

fn report(req: &RenderRequest, progress: f32, message: &str) {
    let Some(url) = &req.progress_url else { return };
    let mut call = ureq::post(url)
        .config()
        .timeout_global(Some(Duration::from_secs(2)))
        .build();
    if let Some(token) = &req.progress_token {
        call = call.header("x-job-token", token);
    }
    // Best effort: a missed tick only means the bar waits for the next one.
    let _ = call.send_json(json!({ "progress": progress, "message": message }));
}

/// A stalled read of the source fails after this long instead of hanging a render.
const SOURCE_STALL: &str = "30000000";

/// The source's transfer function as ffprobe names it, empty when unknown.
fn probe_transfer(url: &str) -> String {
    let out = Command::new("ffprobe")
        .args([
            "-v",
            "error",
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

    fn filter(&self, w: u32, h: u32, fps: u32, sdr_pix_fmt: &str) -> String {
        let base =
            format!("[0:v]setpts=PTS-STARTPTS,fps={fps},scale={w}:{h}:flags=lanczos,setsar=1");
        let cap = "[1:v]setpts=PTS-STARTPTS";
        // RGB compositing keeps the overlay at full chroma; the conversion is
        // explicit BT.709 rather than FFmpeg's BT.601 default.
        let sdr = |pre: &str| {
            format!(
                "{base}{pre},format=gbrp[base];{cap}[cap];\
                 [base][cap]overlay=format=gbrp:eof_action=pass,\
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
                 [base][cap]overlay=format=yuv422p10:eof_action=pass,format={pix_fmt}[v]"
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
    let mut renderer = Renderer::new(Scene::new(&book, req.scene.clone()));
    let (w, h) = (renderer.scene().width(), renderer.scene().height());
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
    let colour = Colour::of(&probe_transfer(&req.video_url), enc.hdr_pix_fmt);
    let filter = colour.filter(w, h, req.fps, enc.pix_fmt);
    let mut child = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
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
            &format!("{w}x{h}"),
        ])
        .args(["-framerate", &req.fps.to_string(), "-i", "pipe:0"])
        .args(["-filter_complex", &filter, "-map", "[v]", "-map", "0:a?"])
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
    let mut reported = 0.0;
    for i in 0..frames {
        renderer.render(i as f32 / req.fps as f32);
        // FFmpeg closes the pipe once it has encoded the duration it was asked for.
        if stdin.write_all(renderer.rgba()).is_err() {
            break;
        }
        let progress = (i + 1) as f32 / frames as f32;
        if progress - reported >= 0.05 {
            reported = progress;
            report(
                req,
                progress,
                &format!("Rendering {}%", (progress * 100.0).round()),
            );
        }
    }
    drop(stdin);
    let status = child
        .wait()
        .map_err(|e| format!("ffmpeg did not finish: {e}"))?;
    let errors = errors.join().unwrap_or_default();
    if !status.success() {
        return Err(format!("ffmpeg failed ({status}): {}", errors.trim()));
    }

    report(req, 1.0, "Uploading");
    let file = File::open(&out.0).map_err(|e| e.to_string())?;
    let size = file.metadata().map_err(|e| e.to_string())?.len();
    ureq::put(&req.output_url)
        .header("content-type", enc.content_type)
        .header("content-length", size.to_string())
        .send(ureq::SendBody::from_owned_reader(file))
        .map_err(|e| format!("upload failed: {e}"))?;

    let duration_ms = started.elapsed().as_millis() as u64;
    log(
        "render_complete",
        json!({ "output_key": req.output_key, "frames": frames, "bytes": size, "ms": duration_ms }),
    );
    Ok(
        json!({ "output_key": req.output_key, "frames_rendered": frames, "duration_ms": duration_ms }),
    )
}

fn validate(req: &RenderRequest) -> Result<Encoding, String> {
    let s = &req.scene;
    let in_range = |v: u32, lo: u32, hi: u32| (lo..=hi).contains(&v);
    if !in_range(req.fps, 1, 120) {
        return Err("fps must be between 1 and 120".into());
    }
    if !in_range(s.width, 2, 7680) || !in_range(s.height, 2, 7680) {
        return Err("width and height must be between 2 and 7680".into());
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
    sent.len() == token.len()
        && sent
            .bytes()
            .zip(token.bytes())
            .fold(0, |diff, (a, b)| diff | (a ^ b))
            == 0
}

fn handle(book: &FontBook<'static>, token: &str, mut request: Request) {
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
                        Ok(enc) => render(book, &req, enc).map_or_else(
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
    let Ok(token) = std::env::var("ENGINE_TOKEN") else {
        log("no_token", json!({ "need": "ENGINE_TOKEN" }));
        std::process::exit(1);
    };
    let token = Arc::new(token);
    let server = Server::http(format!("0.0.0.0:{port}")).expect("bind");
    log(
        "listening",
        json!({ "port": port, "families": book.families() }),
    );
    for request in server.incoming_requests() {
        let (book, token) = (Arc::clone(&book), Arc::clone(&token));
        std::thread::spawn(move || handle(&book, &token, request));
    }
}

#[cfg(test)]
mod tests {
    use super::{Colour, token_matches};

    #[test]
    fn only_the_exact_token_is_accepted() {
        assert!(token_matches("s3cret", "s3cret"));
        assert!(!token_matches("", "s3cret"));
        assert!(!token_matches("s3cre", "s3cret"));
        assert!(!token_matches("s3cretx", "s3cret"));
        assert!(!token_matches("S3cret", "s3cret"));
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
            hlg.filter(1080, 1920, 30, "yuv420p")
                .contains("t=arib-std-b67")
        );
        assert_eq!(Colour::of("smpte2084", None).tags()[5], "bt709");
    }
}
