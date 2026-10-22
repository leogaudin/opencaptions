//! A render: its request and the checks on it, the places that bound how many run at once, and the
//! pipeline from source to uploaded file.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Condvar, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use opencaptions_engine::{FontBook, Renderer, Scene, SceneInput};
use serde::Deserialize;
use serde_json::json;

use crate::colour::*;
use crate::ffmpeg::*;
use crate::log;
use crate::progress::*;
use crate::upload::*;

#[derive(Deserialize)]
pub(crate) struct RenderRequest {
    pub(crate) video_url: String,
    pub(crate) output_url: String,
    pub(crate) output_key: String,
    /// The style's font, when it is not bundled.
    pub(crate) font_url: Option<String>,
    /// Where the API serves a font by family (`{font_base_url}/{family}`), read with the job's
    /// token (`progress_token`): the families the transcript's scripts need, which this server works
    /// out itself (`scripts::fallback_families`), when they are not bundled.
    pub(crate) font_base_url: Option<String>,
    #[serde(flatten)]
    pub(crate) scene: SceneInput,
    pub(crate) fps: u32,
    pub(crate) codec: String,
    pub(crate) crf: Option<u32>,
    pub(crate) pro_res_profile: Option<String>,
    /// Draw the captions over solid chroma green instead of the video, to key out in an editor.
    /// The file has neither the video's picture nor its sound.
    #[serde(default)]
    pub(crate) green_screen: bool,
    pub(crate) progress_url: Option<String>,
    pub(crate) progress_token: Option<String>,
}

/// Deletes the temporary output however the render ends.
pub(crate) struct TempFile(PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// How many renders run at once; the rest wait their turn. Each holds a few copies of a
/// frame and an FFmpeg that uses every core, so more only makes all of them slower.
pub(crate) struct Slots {
    pub(crate) free: Mutex<usize>,
    pub(crate) freed: Condvar,
}

pub(crate) struct Slot<'a>(&'a Slots);

impl Slots {
    pub(crate) fn new(n: usize) -> Self {
        Self {
            free: Mutex::new(n.max(1)),
            freed: Condvar::new(),
        }
    }

    pub(crate) fn take(&self) -> Slot<'_> {
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

pub(crate) fn render(
    book: &FontBook<'static>,
    req: &RenderRequest,
    enc: Encoding,
) -> Result<serde_json::Value, String> {
    let started = Instant::now();
    let duration = req.scene.transcript.duration.max(1.0 / req.fps as f32);
    // Borrowed for this render only: the bundled faces are shared, the request's
    // own font lives in `font` and is dropped with it.
    let font = match &req.font_url {
        Some(url) if !book.has(&req.scene.style.font) => Some(fetch_font(url, None)?),
        _ => None,
    };
    // The families the transcript's scripts need (Chinese, Japanese, Korean...), in the order the
    // scene names them. One that cannot be fetched is left out and its letters are drawn as far as
    // the other faces can.
    let mut scene = req.scene.clone();
    let families = scene.transcript.fallback_families();
    let mut fallbacks: Vec<(&String, Vec<u8>)> = Vec::new();
    for family in &families {
        if book.has(family) {
            continue;
        }
        if let Some(base) = &req.font_base_url {
            let url = format!("{}/{}", base.trim_end_matches('/'), percent_encode(family));
            match fetch_font(&url, req.progress_token.as_deref()) {
                Ok(data) => fallbacks.push((family, data)),
                Err(e) => log(
                    "fallback_font_failed",
                    json!({ "family": family, "error": e }),
                ),
            }
        }
    }
    scene.fallback_fonts = families.clone();
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
    let renderer = Renderer::new(Scene::new(&book, scene));
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

pub(crate) fn validate(req: &RenderRequest) -> Result<Encoding, String> {
    if !(1..=120).contains(&req.fps) {
        return Err("fps must be between 1 and 120".into());
    }
    req.scene.check()?;
    // Every address is fetched by this server or by FFmpeg: only http(s), whatever it says.
    let urls = [
        Some(&req.video_url),
        Some(&req.output_url),
        req.font_url.as_ref(),
        req.font_base_url.as_ref(),
        req.progress_url.as_ref(),
    ]
    .into_iter()
    .flatten();
    for url in urls {
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err("every url must be http or https".into());
        }
    }
    encoding(req)
}
