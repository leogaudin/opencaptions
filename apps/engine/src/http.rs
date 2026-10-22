//! The server's routes: `GET /health`, `POST /subtitles` and `POST /render`, behind `x-engine-token`.

use std::io::Read;

use opencaptions_engine::FontBook;
use serde::Deserialize;
use serde_json::json;
use tiny_http::{Header, Method, Request, Response};

use crate::log;
use crate::render::*;

/// `POST /subtitles`: a transcript as a subtitle file, cut and shifted as the captions are.
#[derive(Deserialize)]
pub(crate) struct SubtitlesRequest {
    pub(crate) transcript: opencaptions_engine::model::Transcript,
    pub(crate) words_per_line: u32,
    #[serde(default)]
    pub(crate) caption_offset_ms: i32,
    pub(crate) format: String,
}

pub(crate) fn subtitles(raw: &[u8]) -> (u16, serde_json::Value) {
    let req = match serde_json::from_slice::<SubtitlesRequest>(raw) {
        Ok(req) => req,
        Err(e) => return error(422, "validation_error", e.to_string()),
    };
    let Some(format) = opencaptions_engine::subtitles::Format::parse(&req.format) else {
        return error(
            422,
            "validation_error",
            format!("unknown subtitle format '{}'", req.format),
        );
    };
    let text = opencaptions_engine::subtitles::subtitles(
        &req.transcript,
        req.words_per_line,
        req.caption_offset_ms,
        format,
    );
    (200, json!({ "text": text }))
}

pub(crate) fn respond(request: Request, status: u16, body: serde_json::Value) {
    let header = Header::from_bytes("content-type", "application/json").expect("static header");
    let response = Response::from_string(body.to_string())
        .with_status_code(status)
        .with_header(header);
    let _ = request.respond(response);
}

pub(crate) fn error(code: u16, kind: &str, detail: String) -> (u16, serde_json::Value) {
    (
        code,
        json!({ "error": kind, "detail": detail, "code": code }),
    )
}

/// Whether the request carries the token the API shares with this server. The comparison
/// looks at every byte, so its time says nothing about how much of a guess was right.
pub(crate) fn authorised(request: &Request, token: &str) -> bool {
    let sent = request
        .headers()
        .iter()
        .find(|h| h.field.equiv("x-engine-token"))
        .map_or("", |h| h.value.as_str());
    token_matches(sent, token)
}

pub(crate) fn token_matches(sent: &str, token: &str) -> bool {
    // No token configured accepts nothing, rather than a request that sent no token either.
    !token.is_empty()
        && sent.len() == token.len()
        && sent
            .bytes()
            .zip(token.bytes())
            .fold(0, |diff, (a, b)| diff | (a ^ b))
            == 0
}

pub(crate) fn handle(book: &FontBook<'static>, token: &str, slots: &Slots, mut request: Request) {
    let (status, body) = match (request.method(), request.url()) {
        (Method::Get, "/health") => (
            200,
            json!({
                "status": "ok",
                "version": env!("CARGO_PKG_VERSION"),
                "render_revision": opencaptions_engine::RENDER_REVISION.trim(),
                "service": "engine",
            }),
        ),
        (Method::Post, "/render") if !authorised(&request, token) => error(
            401,
            "unauthorised",
            "missing or wrong x-engine-token".into(),
        ),
        (Method::Post, "/subtitles") if !authorised(&request, token) => error(
            401,
            "unauthorised",
            "missing or wrong x-engine-token".into(),
        ),
        (Method::Post, "/subtitles") => {
            let mut raw = Vec::new();
            match request.as_reader().take(64 << 20).read_to_end(&mut raw) {
                Err(e) => error(400, "bad_request", e.to_string()),
                Ok(_) => subtitles(&raw),
            }
        }
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
