//! What the server fetches and sends over HTTP: fonts it is told to read, and the finished file.

use std::fs::File;
use std::path::Path;
use std::time::Duration;

use serde_json::json;

use crate::log;

/// The largest font file a render will download; CJK faces run to ~20 MB.
pub(crate) const MAX_FONT_BYTES: u64 = 32 << 20;

/// A family name as one path segment of a URL.
pub(crate) fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

pub(crate) fn fetch_font(url: &str, token: Option<&str>) -> Result<Vec<u8>, String> {
    let mut call = ureq::get(url);
    if let Some(token) = token {
        call = call.header("x-job-token", token);
    }
    call.config()
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

/// PUTs the file to its presigned link, trying again after a failure that is not the link
/// being refused: a render can take an hour, and a blip at the end must not throw it away.
pub(crate) fn upload(url: &str, content_type: &str, path: &Path) -> Result<u64, String> {
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
