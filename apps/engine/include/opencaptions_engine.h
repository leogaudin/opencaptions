/*
 * OpenCaptions caption engine, C ABI.
 *
 * The same functions the browser calls through WebAssembly (apps/engine/src/lib.rs).
 * Build: cargo rustc --release --lib --crate-type staticlib --target aarch64-apple-ios
 *
 * Buffers: copy each input into memory from oc_alloc; the call it is passed to
 * takes ownership. Calls that produce bytes leave them in the result buffer
 * (oc_result_ptr / oc_result_len), valid until the next call. State (fonts, the
 * scene) is per process and each call is atomic, so calls may come from any thread
 * (a Swift actor hops between them) but must be serialized: never two at once, and
 * read a result or frame before making the next call.
 *
 * JSON is UTF-8 in the API's shapes: SceneInput is {transcript, style, width,
 * height, caption_offset_ms} with Transcript and StyleConfig as in
 * apps/api/app/models/schemas.py. caption_offset_ms (default 0) shifts every
 * caption time, positive later, clamped at 0.
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
/* The same for a font that is rank-th (from 0) of the bundled files and may arrive after the others:
 * it is tried in the order its rank gives, as if it had come in its place. */
uint32_t oc_add_font_at(uint8_t *ptr, size_t len, uint32_t rank);
uint32_t oc_has_font(uint8_t *name_ptr, size_t name_len);
uint32_t oc_add_requested_font(uint8_t *name_ptr, size_t name_len, uint8_t *ptr, size_t len);

/* Drawing. A scene is a handle: oc_scene_new lays one out from JSON and returns it, or 0 with the reason
 * in the result buffer, so a preview, a tile and an export each hold their own. The scene calls below take
 * it. Fonts are one book for the process. */
uint32_t oc_scene_new(uint8_t *json_ptr, size_t json_len);
void oc_scene_free(uint32_t scene);
/* Draws the scene's frame at t seconds; 1 if it changed since the last call. */
uint32_t oc_render(uint32_t scene, float t);
/* frame_width x frame_height x 4 bytes of straight-alpha RGBA, valid until the scene is freed. */
const uint8_t *oc_frame_ptr(uint32_t scene);
uint32_t oc_frame_width(uint32_t scene);
uint32_t oc_frame_height(uint32_t scene);
/* The rows top..bottom the last changed frame changed (all of them after a new scene). */
uint32_t oc_changed_top(uint32_t scene);
uint32_t oc_changed_bottom(uint32_t scene);

/* The caption showing at the last rendered time. */
int32_t oc_active_index(uint32_t scene);      /* flat index of the line's first word (word N of it is transcript word index + N), or -1 */
uint32_t oc_active_bounds(uint32_t scene);    /* one quad; 0 when none shows */
uint32_t oc_watermark_rect(uint32_t scene);   /* one quad; 0 without a watermark */
uint32_t oc_active_word_rects(uint32_t scene); /* one quad per word; returns the count */

/* Dragging the caption along one axis: the block's start, middle and end are pulled to the frame's near
 * margin, centre and far margin when within threshold of them. position is where the block is held (a
 * share of the axis) and anchor which part of it that is (0 start, 0.5 middle, 1 end); extent is its length
 * as a share of the axis; size and threshold are in pixels; margin is a share of the axis. Writes two f32 to
 * out: the snapped position, then the line it is on (a share of the axis), or -1 when free. Touches no
 * engine state, so it is safe to call from any thread at any time. */
void oc_snap_axis(float position, float extent, float anchor, float size, float threshold, float margin, float *out);

/* The font families a transcript (JSON) needs that are not bundled (Chinese, Japanese, Korean, other
 * Asian scripts), as a JSON array of Google Fonts names. The host fetches them, registers each with
 * oc_add_requested_font, and names them in the scene's fallback_fonts. 0 on failure. */
uint32_t oc_fallback_fonts(uint8_t *json_ptr, size_t json_len);

/* The bundled script faces (Arabic, Hebrew, Devanagari, Thai) a transcript (JSON) needs, as a JSON
 * array of {file, family}: a host short of room may fetch such a file only when a caption has
 * letters of the script, then register it with oc_add_font_at. Empty input lists them all. 0 on
 * failure. */
uint32_t oc_script_fonts(uint8_t *json_ptr, size_t json_len);

/* Editing: pure functions of a transcript (JSON); 0 on failure with the reason. */
/* Leaves a JSON array of {from, count, start, end, text}; times are as shown, with offset_ms
 * (the caption offset) applied. */
uint32_t oc_caption_lines(uint8_t *json_ptr, size_t json_len, uint32_t words_per_line,
                          int32_t offset_ms);
/* The transcript as a subtitle file, left as a JSON string: format 0 is SubRip, 1 is WebVTT. The cues
 * are the caption lines of oc_caption_lines, with the caption offset applied. */
uint32_t oc_subtitles(uint8_t *json_ptr, size_t json_len, uint32_t words_per_line, int32_t offset_ms,
                      uint32_t format);
/* edge 0 = start, 1 = end. time is as shown (with offset_ms); the edited transcript
 * is left with unshifted times. */
uint32_t oc_retime_word(uint8_t *json_ptr, size_t json_len, uint32_t index, uint32_t edge,
                        float time, int32_t offset_ms);
/* Sets the text of one word, keeping its timing; empty text removes the word, and
 * spaces inside stay (collapsed to one): it is still a single word. Leaves the edited
 * transcript. */
uint32_t oc_set_word(uint8_t *json_ptr, size_t json_len, uint32_t index, uint8_t *text_ptr,
                     size_t text_len);
/* Gives one word the look `variant` of the style (an index into its variants), or the style's own
 * with -1, keeping its text and timing. Leaves the edited transcript. */
uint32_t oc_set_variant(uint8_t *json_ptr, size_t json_len, uint32_t index, int32_t variant);
/* Deals every word one of the style's `count` looks, or its own, at random from `seed`: the same
 * seed gives the same looks, another seed deals again. Text and timing stay. Leaves the edited
 * transcript. */
uint32_t oc_shuffle_variants(uint8_t *json_ptr, size_t json_len, uint32_t count, uint32_t seed);

#ifdef __cplusplus
}
#endif

#endif
