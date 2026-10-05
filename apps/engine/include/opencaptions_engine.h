/*
 * OpenCaptions caption engine, C ABI.
 *
 * The same functions the browser calls through WebAssembly (apps/engine/src/lib.rs).
 * Build: cargo rustc --release --lib --crate-type staticlib --target aarch64-apple-ios
 *
 * Buffers: copy each input into memory from oc_alloc; the call it is passed to
 * takes ownership. Calls that produce bytes leave them in the result buffer
 * (oc_result_ptr / oc_result_len), valid until the next call. State (fonts, the
 * scene) is per thread: make every call from one thread.
 *
 * JSON is UTF-8 in the API's shapes: SceneInput is {transcript, style, width,
 * height} with Transcript and StyleConfig as in apps/api/app/models/schemas.py.
 * Geometry is little-endian f32 quads (x, y, w, h) in frame pixels.
 */
#ifndef OPENCAPTIONS_ENGINE_H
#define OPENCAPTIONS_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint8_t *oc_alloc(size_t len);
const uint8_t *oc_result_ptr(void);
size_t oc_result_len(void);

/* Fonts. oc_add_font leaves the family name in the result buffer; 0 if not a font. */
uint32_t oc_add_font(uint8_t *ptr, size_t len);
uint32_t oc_has_font(uint8_t *name_ptr, size_t name_len);
uint32_t oc_add_requested_font(uint8_t *name_ptr, size_t name_len, uint8_t *ptr, size_t len);

/* Drawing. oc_set_scene returns 0 with the reason in the result buffer. */
uint32_t oc_set_scene(uint8_t *json_ptr, size_t json_len);
/* Draws the frame at t seconds; 1 if it changed since the last call. */
uint32_t oc_render(float t);
/* frame_width x frame_height x 4 bytes of straight-alpha RGBA. */
const uint8_t *oc_frame_ptr(void);
uint32_t oc_frame_width(void);
uint32_t oc_frame_height(void);

/* The caption showing at the last rendered time. */
int32_t oc_active_index(void);      /* line index, or -1 */
uint32_t oc_active_bounds(void);    /* one quad; 0 when none shows */
uint32_t oc_active_word_rects(void); /* one quad per word; returns the count */

/* Editing: pure functions of a transcript (JSON); 0 on failure with the reason. */
/* Leaves a JSON array of {from, count, start, end, text}. */
uint32_t oc_caption_lines(uint8_t *json_ptr, size_t json_len, uint32_t words_per_line);
/* edge 0 = start, 1 = end. Leaves the edited transcript. */
uint32_t oc_retime_word(uint8_t *json_ptr, size_t json_len, uint32_t index, uint32_t edge,
                        float time);
/* Leaves the edited transcript. */
uint32_t oc_replace_words(uint8_t *json_ptr, size_t json_len, uint32_t from, uint32_t count,
                          uint8_t *text_ptr, size_t text_len);

#ifdef __cplusplus
}
#endif

#endif
