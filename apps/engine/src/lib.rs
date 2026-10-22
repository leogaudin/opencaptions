//! OpenCaptions caption engine.
//!
//! One library, three builds: natively it is linked by the render server, which
//! draws the overlay for every frame of an export; compiled to WASM it draws the
//! editor preview; as a static library it is the phone app's engine. Same code
//! and same fonts, so the preview is the export.

pub mod edit;
pub mod fonts;
pub mod model;
pub mod scene;
pub mod scripts;
pub mod subtitles;

pub use fonts::FontBook;

/// A number bumped with every change that alters the frames the engine draws (the golden test
/// says when). The API puts it in the name of every render it caches, so a look drawn
/// differently is not served from a file drawn the old way. `src/render_revision.txt` is the
/// one place it is written; the API holds its own copy equal to it with a test.
pub const RENDER_REVISION: &str = include_str!("render_revision.txt");
pub use model::SceneInput;
pub use scene::{Renderer, Scene};

/// The C ABI, the same for every caller: the browser over WASM linear memory,
/// the phone through `include/opencaptions_engine.h`. Plain functions over byte
/// buffers, so neither needs generated bindings.
///
/// Inputs are copied into buffers from `oc_alloc` and owned by the call they are
/// passed to. Calls that produce bytes leave them in a result buffer, read
/// through `oc_result_ptr`/`oc_result_len` and valid until the next call. State
/// (fonts, the scene) is per process, behind locks that make each call atomic:
/// calls may come from any thread, but a caller must serialize them, because the
/// result and frame buffers belong to the last call. (A Swift actor is the iOS
/// caller; actors do not stay on one thread.)
mod abi {
    use std::sync::{Mutex, MutexGuard};

    use serde::Serialize;

    use crate::edit::{self, Edge};
    use crate::model::Transcript;
    use crate::{FontBook, Renderer, Scene, SceneInput};

    static BOOK: Mutex<FontBook<'static>> = Mutex::new(FontBook::new());
    static RENDERER: Mutex<Option<Renderer>> = Mutex::new(None);
    static RESULT: Mutex<Vec<u8>> = Mutex::new(Vec::new());

    /// No call holds two locks at once, so they cannot deadlock. A poisoned lock
    /// means an earlier call panicked; the state is still usable.
    fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
        m.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn set_result(bytes: Vec<u8>) {
        *lock(&RESULT) = bytes;
    }

    /// # Safety
    /// `ptr` must come from `oc_alloc(len)`; ownership moves to the callee.
    unsafe fn take(ptr: *mut u8, len: usize) -> Vec<u8> {
        unsafe { Vec::from_raw_parts(ptr, len, len) }
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn oc_alloc(len: usize) -> *mut u8 {
        let mut v = std::mem::ManuallyDrop::new(vec![0u8; len]);
        v.as_mut_ptr()
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn oc_result_ptr() -> *const u8 {
        lock(&RESULT).as_ptr()
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn oc_result_len() -> usize {
        lock(&RESULT).len()
    }

    /// Fonts live as long as the page, or natively the process: each is added
    /// once and kept, so a native caller adds its fonts once, not per job.
    fn keep(data: Vec<u8>) -> &'static [u8] {
        Box::leak(data.into_boxed_slice())
    }

    /// Register a bundled font; the family name is left in the result buffer.
    /// Returns 0 on failure.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with the font file.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_add_font(ptr: *mut u8, len: usize) -> u32 {
        let data = keep(unsafe { take(ptr, len) });
        let family = lock(&BOOK).add(data);
        match family {
            Some(family) => {
                set_result(family.into_bytes());
                1
            }
            None => 0,
        }
    }

    /// Register a bundled font that is `rank`th of the font files (counting from 0), whenever it
    /// arrives, so it is tried in the order its file name gives it; the family name is left in the
    /// result buffer. Returns 0 on failure.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with the font file.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_add_font_at(ptr: *mut u8, len: usize, rank: u32) -> u32 {
        let data = keep(unsafe { take(ptr, len) });
        let family = lock(&BOOK).add_at(data, rank as usize);
        match family {
            Some(family) => {
                set_result(family.into_bytes());
                1
            }
            None => 0,
        }
    }

    /// Whether a face is registered for the family named by the UTF-8 at `ptr`.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_has_font(ptr: *mut u8, len: usize) -> u32 {
        let name = unsafe { take(ptr, len) };
        let name = String::from_utf8_lossy(&name);
        u32::from(lock(&BOOK).has(&name))
    }

    /// Register a font a style asked for, under the family named by the UTF-8 at
    /// `name_ptr`. Returns 0 if it is not a font.
    ///
    /// # Safety
    /// Both pointers must come from `oc_alloc` with their lengths, filled as described.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_add_requested_font(
        name_ptr: *mut u8,
        name_len: usize,
        ptr: *mut u8,
        len: usize,
    ) -> u32 {
        let name = unsafe { take(name_ptr, name_len) };
        let data = keep(unsafe { take(ptr, len) });
        let name = String::from_utf8_lossy(&name);
        u32::from(lock(&BOOK).add_requested(&name, data))
    }

    /// Lay out a scene from JSON. Returns 0 on failure with the reason in the result buffer.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_set_scene(ptr: *mut u8, len: usize) -> u32 {
        let json = unsafe { take(ptr, len) };
        let refuse = |reason: Vec<u8>| {
            set_result(reason);
            0
        };
        match serde_json::from_slice::<SceneInput>(&json) {
            Err(e) => refuse(e.to_string().into_bytes()),
            Ok(input) => match input.check() {
                Err(reason) => refuse(reason.into_bytes()),
                Ok(()) if lock(&BOOK).is_empty() => refuse(b"no fonts registered".to_vec()),
                Ok(()) => {
                    let scene = Scene::new(&lock(&BOOK), input);
                    *lock(&RENDERER) = Some(Renderer::new(scene));
                    1
                }
            },
        }
    }

    /// Draw the frame at `t` seconds. Returns 1 if it changed since the last call.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_render(t: f32) -> u32 {
        lock(&RENDERER)
            .as_mut()
            .map_or(0, |r| u32::from(r.render(t)))
    }

    /// The current frame: width × height × 4 bytes of straight-alpha RGBA.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_frame_ptr() -> *const u8 {
        lock(&RENDERER)
            .as_ref()
            .map_or(std::ptr::null(), |r| r.rgba().as_ptr())
    }

    /// The active caption block as four little-endian f32 (x, y, w, h) in frame
    /// pixels, left in the result buffer. Returns 0 when no caption shows.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_active_bounds() -> u32 {
        let bounds = lock(&RENDERER).as_ref().and_then(|r| r.active_bounds());
        match bounds {
            Some((x, y, w, h)) => {
                let mut out = Vec::with_capacity(16);
                for v in [x, y, w, h] {
                    out.extend_from_slice(&v.to_le_bytes());
                }
                set_result(out);
                1
            }
            None => 0,
        }
    }

    /// The watermark's rectangle as four little-endian f32 (x, y, w, h) in frame pixels,
    /// left in the result buffer. Returns 0 when there is no watermark.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_watermark_rect() -> u32 {
        let rect = lock(&RENDERER).as_ref().and_then(|r| r.watermark_rect());
        match rect {
            Some((x, y, w, h)) => {
                let mut out = Vec::with_capacity(16);
                for v in [x, y, w, h] {
                    out.extend_from_slice(&v.to_le_bytes());
                }
                set_result(out);
                1
            }
            None => 0,
        }
    }

    /// Magnetism for dragging the caption block along one axis: `edit::snap_axis`, which pulls the block's
    /// start, middle and end to the frame's near margin, centre and far margin. Leaves two little-endian
    /// f32 in the result buffer: the snapped position, then the line it is on (a share of the axis), or -1
    /// when it is free.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_snap_axis(
        position: f32,
        extent: f32,
        anchor: f32,
        size: f32,
        threshold: f32,
        margin: f32,
    ) -> u32 {
        let s = edit::snap_axis(position, extent, anchor, size, threshold, margin);
        let mut out = Vec::with_capacity(8);
        for v in [s.position, s.line.unwrap_or(-1.0)] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        set_result(out);
        1
    }

    /// `oc_snap_axis`, with the two f32 written to `out` instead of the result buffer. It touches no state
    /// the engine holds, so a caller may ask from any thread at any moment, as a drag does on every touch.
    ///
    /// # Safety
    /// `out` must point to room for two f32.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_snap_axis_into(
        position: f32,
        extent: f32,
        anchor: f32,
        size: f32,
        threshold: f32,
        margin: f32,
        out: *mut f32,
    ) {
        let s = edit::snap_axis(position, extent, anchor, size, threshold, margin);
        for (i, v) in [s.position, s.line.unwrap_or(-1.0)].into_iter().enumerate() {
            // SAFETY: the caller gave room for two.
            unsafe { out.add(i).write(v) };
        }
    }

    /// Flat index of the active line's first word (word N of the line is transcript word
    /// `index + N`), or -1 when no caption shows.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_active_index() -> i32 {
        lock(&RENDERER)
            .as_ref()
            .and_then(|r| r.active_first_word())
            .map_or(-1, |i| i as i32)
    }

    /// Each active word's slot as four little-endian f32 (x, y, w, h), left in the
    /// result buffer in line order. Returns the word count.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_active_word_rects() -> u32 {
        let rects = lock(&RENDERER)
            .as_ref()
            .map(|r| r.active_word_rects())
            .unwrap_or_default();
        let mut out = Vec::with_capacity(rects.len() * 16);
        for (x, y, w, h) in &rects {
            for v in [x, y, w, h] {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        set_result(out);
        rects.len() as u32
    }

    /// The first row the last changed frame changed; with `oc_changed_bottom`, the band of
    /// the frame a viewer needs to copy (the whole frame after a new scene).
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_changed_top() -> u32 {
        lock(&RENDERER).as_ref().map_or(0, |r| r.changed_rows().0)
    }

    /// One past the last row the last changed frame changed.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_changed_bottom() -> u32 {
        lock(&RENDERER).as_ref().map_or(0, |r| r.changed_rows().1)
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn oc_frame_width() -> u32 {
        lock(&RENDERER).as_ref().map_or(0, |r| r.scene().width())
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn oc_frame_height() -> u32 {
        lock(&RENDERER).as_ref().map_or(0, |r| r.scene().height())
    }

    /// # Safety
    /// As `take`.
    unsafe fn read_transcript(ptr: *mut u8, len: usize) -> Result<Transcript, String> {
        serde_json::from_slice(&unsafe { take(ptr, len) }).map_err(|e| e.to_string())
    }

    /// Leaves `value` as JSON in the result buffer, or the error text; 1 on success.
    fn respond(value: Result<impl Serialize, String>) -> u32 {
        match value.and_then(|v| serde_json::to_vec(&v).map_err(|e| e.to_string())) {
            Ok(json) => {
                set_result(json);
                1
            }
            Err(e) => {
                set_result(e.into_bytes());
                0
            }
        }
    }

    /// The font families a transcript (JSON) needs that are not bundled (Chinese, Japanese,
    /// Korean, the other Indic and southeast Asian scripts), as a JSON array of Google Fonts
    /// family names, by the transcript's language. The host fetches and registers them and names
    /// them in the scene's `fallback_fonts`. Returns 0 on failure with the reason.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_fallback_fonts(ptr: *mut u8, len: usize) -> u32 {
        respond(unsafe { read_transcript(ptr, len) }.map(|t| t.fallback_families()))
    }

    /// The bundled script faces a transcript (JSON) needs, as a JSON array of `{file, family}`
    /// (Arabic, Hebrew, Devanagari, Thai): the font files a host may fetch only when a caption has
    /// letters of the script. An empty input lists them all. Returns 0 on failure with the reason.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON, or `len` must be 0.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_script_fonts(ptr: *mut u8, len: usize) -> u32 {
        let faces = if len == 0 {
            Ok(crate::scripts::SCRIPT_FACES.iter().collect())
        } else {
            unsafe { read_transcript(ptr, len) }
                .map(|t| crate::scripts::script_faces(t.words().map(|w| w.text.as_str())))
        };
        respond(faces.map(|faces: Vec<&crate::scripts::ScriptFace>| {
            faces
                .iter()
                .map(|f| serde_json::json!({ "file": f.file, "family": f.family }))
                .collect::<Vec<_>>()
        }))
    }

    /// The captions of a transcript (JSON) as a JSON array of
    /// `{from, count, start, end, text}`, times shown with `offset_ms` (the caption
    /// offset). Returns 0 on failure with the reason.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_caption_lines(
        ptr: *mut u8,
        len: usize,
        words_per_line: u32,
        offset_ms: i32,
    ) -> u32 {
        respond(
            unsafe { read_transcript(ptr, len) }
                .map(|t| edit::lines(&t, words_per_line, offset_ms)),
        )
    }

    /// The transcript as a subtitle file, left in the result buffer as a JSON string: SubRip for
    /// `format` 0 and WebVTT for 1. Its cues are the caption lines (as `oc_caption_lines`) with
    /// the caption offset applied. Returns 0 on failure with the reason.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_subtitles(
        ptr: *mut u8,
        len: usize,
        words_per_line: u32,
        offset_ms: i32,
        format: u32,
    ) -> u32 {
        let format = match format {
            0 => Ok(crate::subtitles::Format::Srt),
            1 => Ok(crate::subtitles::Format::Vtt),
            other => Err(format!("unknown subtitle format {other}")),
        };
        respond(format.and_then(|format| {
            unsafe { read_transcript(ptr, len) }
                .map(|t| crate::subtitles::subtitles(&t, words_per_line, offset_ms, format))
        }))
    }

    /// Moves the start (`edge` 0) or end (1) of word `index` to `time` as shown
    /// with `offset_ms`; the edited transcript, in unshifted times, is left as
    /// JSON. Returns 0 on failure with the reason.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_retime_word(
        ptr: *mut u8,
        len: usize,
        index: u32,
        edge: u32,
        time: f32,
        offset_ms: i32,
    ) -> u32 {
        let edge = if edge == 0 { Edge::Start } else { Edge::End };
        respond(
            unsafe { read_transcript(ptr, len) }
                .map(|t| edit::retime(&t, index as usize, edge, time, offset_ms)),
        )
    }

    /// Sets the text of word `index` to the UTF-8 at `text_ptr` (empty removes
    /// the word, several words are refused); the edited transcript is left as
    /// JSON. Returns 0 on failure with the reason.
    ///
    /// # Safety
    /// Both pointers must come from `oc_alloc` with their lengths, filled as described.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_set_word(
        ptr: *mut u8,
        len: usize,
        index: u32,
        text_ptr: *mut u8,
        text_len: usize,
    ) -> u32 {
        let text = unsafe { take(text_ptr, text_len) };
        let text = String::from_utf8_lossy(&text);
        respond(
            unsafe { read_transcript(ptr, len) }
                .and_then(|t| edit::set_word(&t, index as usize, &text)),
        )
    }

    /// Gives word `index` the look `variant` of the style, or the style's own with -1; the edited
    /// transcript is left as JSON. Returns 0 on failure with the reason.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_set_variant(
        ptr: *mut u8,
        len: usize,
        index: u32,
        variant: i32,
    ) -> u32 {
        let variant = u32::try_from(variant).ok();
        respond(
            unsafe { read_transcript(ptr, len) }
                .and_then(|t| edit::set_variant(&t, index as usize, variant)),
        )
    }

    /// Deals each word one of `count` looks (or none) from `seed`: a new transcript, as `oc_set_variant`.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_shuffle_variants(
        ptr: *mut u8,
        len: usize,
        count: u32,
        seed: u32,
    ) -> u32 {
        respond(
            unsafe { read_transcript(ptr, len) }.map(|t| edit::shuffle_variants(&t, count, seed)),
        )
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    /// Every `oc_` name followed by `(` in `src` that follows `marker`.
    fn calls(src: &str, marker: &str) -> BTreeSet<String> {
        src.split(marker)
            .skip(1)
            .filter_map(|s| s.split_once('(').map(|(name, _)| format!("oc_{name}")))
            .filter(|n| {
                n[3..]
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_')
            })
            .collect()
    }

    /// Copies `bytes` into engine memory, as a caller does before each call.
    fn put(bytes: &[u8]) -> (*mut u8, usize) {
        let ptr = super::abi::oc_alloc(bytes.len());
        // SAFETY: `ptr` is a fresh allocation of `bytes.len()` bytes.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len()) };
        (ptr, bytes.len())
    }

    /// The contract callers rely on (a Swift actor hops between threads): state
    /// set by one call is there for the next, whichever thread makes it.
    #[test]
    fn state_set_on_one_thread_is_used_from_another() {
        use super::abi::*;
        let scene = br##"{
            "width": 270, "height": 480,
            "transcript": { "duration": 2.0, "segments": [{ "words": [
                { "text": "hello", "start": 0.0, "end": 1.0 }] }] },
            "style": {
                "font": "Inter", "font_size": 64, "text_color": "#FFFFFF",
                "highlight_colors": ["#7C3AED"], "background": "none",
                "background_color": "#000000", "background_opacity": 0.0,
                "position_x": 0.5, "position_y": 0.84, "animation": "word_highlight",
                "words_per_line": 3, "stroke_width": 0, "stroke_color": "#000000",
                "shadow_blur": 0, "shadow_color": "#00000080"
            }
        }"##;
        std::thread::spawn(move || {
            let (p, n) = put(include_bytes!("../fonts/Inter.ttf"));
            assert_eq!(unsafe { oc_add_font(p, n) }, 1);
            let (p, n) = put(scene);
            assert_eq!(unsafe { oc_set_scene(p, n) }, 1);
        })
        .join()
        .unwrap();
        std::thread::spawn(|| {
            assert_eq!(oc_render(0.5), 1, "the scene is there");
            assert_eq!((oc_frame_width(), oc_frame_height()), (270, 480));
            assert_eq!(oc_active_index(), 0);
            assert!(!oc_frame_ptr().is_null());
        })
        .join()
        .unwrap();
    }

    /// The markers are escaped, so this test's own source never matches them; the
    /// count is a tripwire to update by hand when an export is added.
    #[test]
    fn the_c_header_declares_exactly_the_exports() {
        let exported = calls(include_str!("lib.rs"), "extern \"C\" fn oc_");
        let declared = calls(include_str!("../include/opencaptions_engine.h"), " *oc_")
            .union(&calls(
                include_str!("../include/opencaptions_engine.h"),
                " oc_",
            ))
            .cloned()
            .collect::<BTreeSet<_>>();
        assert_eq!(exported.len(), 28);
        assert_eq!(exported, declared);
    }
}
