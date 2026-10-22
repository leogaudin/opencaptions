//! The render server: `GET /health`, `POST /render`, `POST /subtitles`.
//!
//! A render decodes the source with FFmpeg, draws the caption overlay for every
//! frame, composites and encodes in one FFmpeg pass, then PUTs the file to the
//! presigned URL it was given. It holds no storage credentials: the caller
//! grants exactly one read and one write per job.
//!
//! Built with the `server` feature, so the library the phone and the browser use does not carry the
//! HTTP stack. The pieces: `http` (routes), `render` (a job), `ffmpeg`, `colour`, `upload`, `progress`.

mod colour;
mod ffmpeg;
mod http;
mod progress;
mod render;
mod upload;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use opencaptions_engine::FontBook;
use serde_json::json;
use tiny_http::Server;

use crate::http::*;
use crate::render::*;

fn log(event: &str, fields: serde_json::Value) {
    eprintln!("{}", json!({ "event": event, "fields": fields }));
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
    use crate::colour::*;
    use crate::ffmpeg::*;
    use crate::upload::*;
    use opencaptions_engine::{FontBook, Renderer, Scene, SceneInput};
    use serde_json::json;
    use std::io::Write;
    use std::sync::{Arc, Mutex, mpsc};
    use std::time::Duration;
    use tiny_http::{Response, Server};

    fn book() -> FontBook<'static> {
        let mut b = FontBook::new();
        b.add(include_bytes!("../fonts/Inter.ttf")).unwrap();
        b
    }

    #[test]
    fn the_subtitles_route_answers_with_the_file() {
        let body = |format: &str| {
            json!({
                "transcript": { "duration": 2.0, "segments": [{ "words": [
                    { "text": "bonjour", "start": 0.5, "end": 1.0 },
                    { "text": "monde", "start": 1.0, "end": 1.5 }] }] },
                "words_per_line": 3, "caption_offset_ms": 500, "format": format
            })
            .to_string()
        };
        let (status, out) = subtitles(body("srt").as_bytes());
        assert_eq!(status, 200);
        assert_eq!(
            out["text"],
            "1\n00:00:01,000 --> 00:00:02,000\nbonjour monde\n"
        );
        assert_eq!(subtitles(body("ass").as_bytes()).0, 422);
        assert_eq!(subtitles(b"{}").0, 422);
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
    fn a_family_name_is_one_path_segment() {
        assert_eq!(percent_encode("Noto Sans JP"), "Noto%20Sans%20JP");
        assert_eq!(percent_encode("A/b?c"), "A%2Fb%3Fc");
        assert_eq!(percent_encode("Inter-1.0_x~"), "Inter-1.0_x~");
    }

    /// A one-request stand-in for the API's font endpoint: records the path and token it was asked
    /// with, and answers with `body` (a font file, to the engine).
    fn stub_font_endpoint(
        body: &'static [u8],
    ) -> (String, std::sync::mpsc::Receiver<(String, String)>) {
        let server = Server::http("127.0.0.1:0").unwrap();
        let base = format!("http://{}", server.server_addr().to_ip().unwrap());
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for request in server.incoming_requests() {
                let token = request
                    .headers()
                    .iter()
                    .find(|h| h.field.equiv("x-job-token"))
                    .map(|h| h.value.to_string())
                    .unwrap_or_default();
                tx.send((request.url().to_string(), token)).unwrap();
                let _ = request.respond(Response::from_data(body));
            }
        });
        (base, rx)
    }

    #[test]
    fn the_server_fetches_the_fonts_its_transcripts_scripts_need_with_the_jobs_token() {
        let (base, asked) = stub_font_endpoint(include_bytes!("../fonts/Inter.ttf"));
        let mut req = request(json!({
            "font_base_url": format!("{base}/api/v1/jobs/j1/fonts"),
            "progress_token": "secret",
        }))
        .unwrap();
        req.scene.transcript = serde_json::from_value(json!({
            "language": "ja", "duration": 1.0,
            "segments": [{ "words": [{ "text": "こんにちは", "start": 0.0, "end": 0.5 }] }]
        }))
        .unwrap();
        let families = req.scene.transcript.fallback_families();
        assert_eq!(families, vec!["Noto Sans JP".to_string()]);
        // Only the fetching is under test here: the scene and the font book are not rendered.
        let url = format!(
            "{}/{}",
            req.font_base_url.as_deref().unwrap(),
            percent_encode(&families[0])
        );
        let data = fetch_font(&url, req.progress_token.as_deref()).unwrap();
        assert!(!data.is_empty());
        let (path, token) = asked.recv().unwrap();
        assert_eq!(path, "/api/v1/jobs/j1/fonts/Noto%20Sans%20JP");
        assert_eq!(token, "secret");
    }

    #[test]
    fn an_address_that_is_not_http_is_refused_wherever_it_appears() {
        assert!(validate(&request(json!({})).unwrap()).is_ok());
        for patch in [
            json!({ "video_url": "file:///etc/passwd" }),
            json!({ "output_url": "ftp://host/x" }),
            json!({ "font_url": "concat:/etc/passwd" }),
            json!({ "progress_url": "gopher://x" }),
            json!({ "font_base_url": "file:///x" }),
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
