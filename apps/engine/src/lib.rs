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

pub use fonts::FontBook;
pub use model::SceneInput;
pub use scene::{Renderer, Scene};

/// The C ABI, the same for every caller: the browser over WASM linear memory,
/// the phone through `include/opencaptions_engine.h`. Plain functions over byte
/// buffers, so neither needs generated bindings.
///
/// Inputs are copied into buffers from `oc_alloc` and owned by the call they are
/// passed to. Calls that produce bytes leave them in a result buffer, read
/// through `oc_result_ptr`/`oc_result_len` and valid until the next call. State
/// (fonts, the scene) is per thread: call from one thread.
mod abi {
    use std::cell::RefCell;

    use serde::Serialize;

    use crate::edit::{self, Edge};
    use crate::model::Transcript;
    use crate::{FontBook, Renderer, Scene, SceneInput};

    thread_local! {
        static BOOK: RefCell<FontBook<'static>> = const { RefCell::new(FontBook::new()) };
        static RENDERER: RefCell<Option<Renderer>> = const { RefCell::new(None) };
        static RESULT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    }

    fn set_result(bytes: Vec<u8>) {
        RESULT.with(|r| *r.borrow_mut() = bytes);
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
        RESULT.with(|r| r.borrow().as_ptr())
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn oc_result_len() -> usize {
        RESULT.with(|r| r.borrow().len())
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
        match BOOK.with(|b| b.borrow_mut().add(data)) {
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
        u32::from(BOOK.with(|b| b.borrow().has(&name)))
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
        u32::from(BOOK.with(|b| b.borrow_mut().add_requested(&name, data)))
    }

    /// Lay out a scene from JSON. Returns 0 on failure with the reason in the result buffer.
    ///
    /// # Safety
    /// `ptr` must come from `oc_alloc(len)` and be filled with UTF-8 JSON.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn oc_set_scene(ptr: *mut u8, len: usize) -> u32 {
        let json = unsafe { take(ptr, len) };
        match serde_json::from_slice::<SceneInput>(&json) {
            Ok(input) if !BOOK.with(|b| b.borrow().is_empty()) => {
                let scene = BOOK.with(|b| Scene::new(&b.borrow(), input));
                RENDERER.with(|r| *r.borrow_mut() = Some(Renderer::new(scene)));
                1
            }
            Ok(_) => {
                set_result(b"no fonts registered".to_vec());
                0
            }
            Err(e) => {
                set_result(e.to_string().into_bytes());
                0
            }
        }
    }

    /// Draw the frame at `t` seconds. Returns 1 if it changed since the last call.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_render(t: f32) -> u32 {
        RENDERER.with(|r| {
            r.borrow_mut()
                .as_mut()
                .map_or(0, |r| u32::from(r.render(t)))
        })
    }

    /// The current frame: width × height × 4 bytes of straight-alpha RGBA.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_frame_ptr() -> *const u8 {
        RENDERER.with(|r| {
            r.borrow()
                .as_ref()
                .map_or(std::ptr::null(), |r| r.rgba().as_ptr())
        })
    }

    /// The active caption block as four little-endian f32 (x, y, w, h) in frame
    /// pixels, left in the result buffer. Returns 0 when no caption shows.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_active_bounds() -> u32 {
        RENDERER.with(
            |r| match r.borrow().as_ref().and_then(|r| r.active_bounds()) {
                Some((x, y, w, h)) => {
                    let mut out = Vec::with_capacity(16);
                    for v in [x, y, w, h] {
                        out.extend_from_slice(&v.to_le_bytes());
                    }
                    set_result(out);
                    1
                }
                None => 0,
            },
        )
    }

    /// Index of the active line, or -1 when no caption shows.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_active_index() -> i32 {
        RENDERER.with(|r| {
            r.borrow()
                .as_ref()
                .and_then(|r| r.active_index())
                .map_or(-1, |i| i as i32)
        })
    }

    /// Each active word's slot as four little-endian f32 (x, y, w, h), left in the
    /// result buffer in line order. Returns the word count.
    #[unsafe(no_mangle)]
    pub extern "C" fn oc_active_word_rects() -> u32 {
        RENDERER.with(|r| {
            let rects = r
                .borrow()
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
        })
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn oc_frame_width() -> u32 {
        RENDERER.with(|r| r.borrow().as_ref().map_or(0, |r| r.scene().width()))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn oc_frame_height() -> u32 {
        RENDERER.with(|r| r.borrow().as_ref().map_or(0, |r| r.scene().height()))
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
        assert_eq!(exported.len(), 17);
        assert_eq!(exported, declared);
    }
}
