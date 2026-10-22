//! Telling the API how far a render has got.

use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use serde_json::json;

use crate::render::*;

/// Tells the API how far a render has got, from a thread of its own: an answer that takes
/// its two seconds must not hold up the frames. Only the newest report is sent, so a slow
/// API sees fewer calls, never a backlog.
pub(crate) struct Reporter {
    pub(crate) tx: Option<mpsc::Sender<(f32, String)>>,
    pub(crate) thread: Option<JoinHandle<()>>,
}

impl Reporter {
    pub(crate) fn new(req: &RenderRequest) -> Self {
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

    pub(crate) fn send(&self, progress: f32, message: &str) {
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

pub(crate) fn post_progress(url: &str, token: Option<&str>, progress: f32, message: &str) {
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
