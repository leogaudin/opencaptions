//! FFmpeg: the source's probe, the process, and the frames piped in. The command itself is the
//! library's (`encode::plan`).

use std::io::Write;
use std::process::{Child, Command, ExitStatus};
use std::sync::mpsc;

use opencaptions_engine::Renderer;
use opencaptions_engine::encode::PROBE_ARGS;
use serde_json::json;

use crate::log;

/// FFmpeg, killed and reaped if the render ends any way but by waiting for it: an error, a
/// panic, a closed connection. Left alone it would go on encoding for nobody.
pub(crate) struct Running(pub(crate) Option<Child>);

impl Running {
    pub(crate) fn wait(mut self) -> std::io::Result<ExitStatus> {
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

/// The protocols FFmpeg and ffprobe may use to open the source. It is a URL a caller gave, and
/// a playlist or container can name another to read: only what a presigned link needs.
pub(crate) const SOURCE_PROTOCOLS: &str = "http,https,tcp,tls,crypto";

/// A stalled read of the source fails after this long instead of hanging a render.
pub(crate) const SOURCE_STALL: &str = "30000000";

/// The source's transfer function as ffprobe names it, empty when unknown.
pub(crate) fn probe_transfer(url: &str) -> String {
    let out = Command::new("ffprobe")
        .args(PROBE_ARGS)
        .args([
            "-protocol_whitelist",
            SOURCE_PROTOCOLS,
            "-rw_timeout",
            SOURCE_STALL,
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

/// Draws the frames on a thread of their own and writes each to `sink` as it is ready, so
/// drawing the next one overlaps FFmpeg taking the last. A few buffers are passed back and
/// forth instead of allocated per frame. Stops when `sink` stops taking bytes (FFmpeg closes
/// the pipe once it has encoded the duration it was asked for).
pub(crate) fn stream_frames(
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
