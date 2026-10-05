//! Layout once, draw per frame.
//!
//! A scene shapes and places every caption line up front; a frame is then only
//! the per-word animation state at time `t` applied to fixed geometry. Every
//! operation is integer or IEEE f32 arithmetic with no platform maths library,
//! which is what makes native and WASM output byte-identical.

use rustybuzz::ttf_parser::{GlyphId, OutlineBuilder};
use rustybuzz::{Face, UnicodeBuffer};
use tiny_skia::{
    Color, FillRule, IntRect, LineCap, LineJoin, Paint, Path, PathBuilder, Pixmap, PixmapPaint,
    Rect, Stroke, Transform,
};

use crate::fonts::FontBook;
use crate::model::{Animation, Background, Rgba, SceneInput, Style, shifted};

/// Style values are tuned against a 1920-tall frame and scaled to the real one.
const REF_HEIGHT: f32 = 1920.0;
const LINE_HEIGHT: f32 = 1.15;
const MAX_WIDTH: f32 = 0.9;
/// A line is held this long past its last word so it does not blink out mid-syllable.
const LINE_HOLD_S: f32 = 0.05;
/// A gap shorter than this keeps the previous line up instead of going blank.
const LINE_GAP_S: f32 = 0.3;
/// A word turns on slightly early and off slightly late, which reads as in sync.
const LEAD_S: f32 = 0.02;
const TRAIL_S: f32 = 0.05;
const COLOUR_S: f32 = 0.08;
const MOTION_S: f32 = 0.12;
const POP: f32 = 0.08;
/// The highlight box springs up from this fraction of its size, overshooting
/// on the way, over BOX_S.
const BOX_FROM: f32 = 0.6;
const BOX_S: f32 = 0.22;

struct Placed {
    start: f32,
    end: f32,
    glyphs: Option<Path>,
    slot: Rect,
}

struct Line {
    start: f32,
    end: f32,
    words: Vec<Placed>,
    /// The caption block, drawn only when there is a background.
    block: Option<Rect>,
    /// The block's rectangle whether or not a background is drawn, for the editor
    /// to hit-test and move the caption.
    anchor: Rect,
    bounds: IntRect,
}

pub struct Scene {
    style: Style,
    width: u32,
    height: u32,
    lines: Vec<Line>,
    block_radius: f32,
    word_radius: f32,
}

/// What one word looks like at a moment: all a frame varies.
#[derive(Clone, Copy, PartialEq)]
struct WordState {
    on: f32,
    scale: f32,
    opacity: f32,
    box_scale: f32,
}

#[derive(PartialEq)]
struct FrameKey(Option<usize>, Vec<WordState>);

struct Sink {
    pb: PathBuilder,
    scale: f32,
    dx: f32,
    dy: f32,
}

impl Sink {
    fn at(&self, x: f32, y: f32) -> (f32, f32) {
        (self.dx + x * self.scale, self.dy - y * self.scale)
    }
}

impl OutlineBuilder for Sink {
    fn move_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.at(x, y);
        self.pb.move_to(x, y);
    }
    fn line_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.at(x, y);
        self.pb.line_to(x, y);
    }
    fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
        let ((x1, y1), (x, y)) = (self.at(x1, y1), self.at(x, y));
        self.pb.quad_to(x1, y1, x, y);
    }
    fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
        let ((x1, y1), (x2, y2), (x, y)) = (self.at(x1, y1), self.at(x2, y2), self.at(x, y));
        self.pb.cubic_to(x1, y1, x2, y2, x, y);
    }
    fn close(&mut self) {
        self.pb.close();
    }
}

/// Glyph outlines for `text` with the pen at the origin on the baseline, and the advance.
fn shape(face: &Face, text: &str, size: f32) -> (Option<Path>, f32) {
    let mut buf = UnicodeBuffer::new();
    buf.push_str(text);
    let glyphs = rustybuzz::shape(face, &[], buf);
    let scale = size / face.units_per_em() as f32;
    let mut sink = Sink {
        pb: PathBuilder::new(),
        scale,
        dx: 0.0,
        dy: 0.0,
    };
    let mut pen = 0i32;
    for (info, pos) in glyphs.glyph_infos().iter().zip(glyphs.glyph_positions()) {
        sink.dx = (pen + pos.x_offset) as f32 * scale;
        sink.dy = -(pos.y_offset as f32) * scale;
        face.outline_glyph(GlyphId(info.glyph_id as u16), &mut sink);
        pen += pos.x_advance;
    }
    (sink.pb.finish(), pen as f32 * scale)
}

fn rounded_rect(r: Rect, radius: f32) -> Option<Path> {
    let (x, y, w, h) = (r.x(), r.y(), r.width(), r.height());
    let rad = radius.min(w / 2.0).min(h / 2.0).max(0.0);
    let k = rad * 0.552_284_8;
    let mut pb = PathBuilder::new();
    pb.move_to(x + rad, y);
    pb.line_to(x + w - rad, y);
    pb.cubic_to(x + w - rad + k, y, x + w, y + rad - k, x + w, y + rad);
    pb.line_to(x + w, y + h - rad);
    pb.cubic_to(
        x + w,
        y + h - rad + k,
        x + w - rad + k,
        y + h,
        x + w - rad,
        y + h,
    );
    pb.line_to(x + rad, y + h);
    pb.cubic_to(x + rad - k, y + h, x, y + h - rad + k, x, y + h - rad);
    pb.line_to(x, y + rad);
    pb.cubic_to(x, y + rad - k, x + rad - k, y, x + rad, y);
    pb.close();
    pb.finish()
}

fn colour(c: Rgba, opacity: f32) -> Color {
    let [r, g, b, a] = c.0;
    let mut out = Color::from_rgba8(r, g, b, a);
    out.apply_opacity(opacity);
    out
}

fn mix(a: Rgba, b: Rgba, k: f32) -> Rgba {
    let lerp = |x: u8, y: u8| (f32::from(x) + (f32::from(y) - f32::from(x)) * k).round() as u8;
    Rgba([0, 1, 2, 3].map(|i| lerp(a.0[i], b.0[i])))
}

fn paint(c: Color) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(c);
    p.anti_alias = true;
    p
}

/// CSS `cubic-bezier(0.4, 1.6, 0.6, 1)`: a fast rise that overshoots, then settles.
fn overshoot(p: f32) -> f32 {
    let bez = |a: f32, b: f32, s: f32| {
        let u = 1.0 - s;
        3.0 * u * u * s * a + 3.0 * u * s * s * b + s * s * s
    };
    let (mut lo, mut hi) = (0.0f32, 1.0f32);
    for _ in 0..24 {
        let mid = 0.5 * (lo + hi);
        if bez(0.4, 0.6, mid) < p {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    bez(1.6, 1.0, 0.5 * (lo + hi))
}

fn linear(p: f32) -> f32 {
    p
}

/// 0 before the word, eased up to 1 while it is spoken, eased back after.
fn pulse(t: f32, w: &Placed, secs: f32, ease: fn(f32) -> f32) -> f32 {
    let at = |edge: f32| ease(((t - edge) / secs).clamp(0.0, 1.0));
    at(w.start - LEAD_S) - at(w.end + TRAIL_S)
}

fn word_state(anim: Animation, w: &Placed, t: f32) -> WordState {
    let on = pulse(t, w, COLOUR_S, linear);
    match anim {
        Animation::WordHighlight => WordState {
            on,
            scale: 1.0,
            opacity: 1.0,
            box_scale: 1.0,
        },
        Animation::HighlightBox => {
            // Grows in with the spring as the word starts, and fades out in place.
            let grow = overshoot(((t - (w.start - LEAD_S)) / BOX_S).clamp(0.0, 1.0));
            WordState {
                on,
                scale: 1.0,
                opacity: 1.0,
                box_scale: BOX_FROM + (1.0 - BOX_FROM) * grow,
            }
        }
        Animation::WordPop => WordState {
            on,
            scale: 1.0 + POP * pulse(t, w, MOTION_S, overshoot),
            opacity: 1.0,
            box_scale: 1.0,
        },
        Animation::WordFade => {
            let at = |edge: f32| ((t - edge) / MOTION_S).clamp(0.0, 1.0);
            let opacity = 0.4 + 0.6 * at(w.start - LEAD_S) - 0.3 * at(w.end + TRAIL_S);
            WordState {
                on: 0.0,
                scale: 1.0,
                opacity,
                box_scale: 1.0,
            }
        }
    }
}

fn scaled(style: &Style, k: f32) -> Style {
    Style {
        font_size: style.font_size * k,
        stroke_width: style.stroke_width * k,
        shadow_blur: style.shadow_blur * k,
        ..style.clone()
    }
}

/// Three box blurs approximate a Gaussian of `sigma`, in integer arithmetic on
/// premultiplied bytes so every target computes the same result.
fn blur(px: &mut Pixmap, sigma: f32) {
    let radius = ((sigma * sigma * 4.0 + 1.0).sqrt() / 2.0).round().max(1.0) as usize;
    let (w, h) = (px.width() as usize, px.height() as usize);
    let data = px.data_mut();
    let mut line = vec![0u32; w.max(h) * 4];
    let span = (2 * radius + 1) as u32;
    let mut pass = |len: usize, at: &dyn Fn(usize) -> usize| {
        for i in 0..len {
            for c in 0..4 {
                line[i * 4 + c] = u32::from(data[at(i) + c]);
            }
        }
        let mut acc = [0u32; 4];
        for i in 0..=radius.min(len - 1) {
            for c in 0..4 {
                acc[c] += line[i * 4 + c];
            }
        }
        for i in 0..len {
            for c in 0..4 {
                data[at(i) + c] = ((acc[c] + span / 2) / span) as u8;
            }
            if i + radius + 1 < len {
                for c in 0..4 {
                    acc[c] += line[(i + radius + 1) * 4 + c];
                }
            }
            if i >= radius {
                for c in 0..4 {
                    acc[c] -= line[(i - radius) * 4 + c];
                }
            }
        }
    };
    for _ in 0..3 {
        for y in 0..h {
            pass(w, &|x| (y * w + x) * 4);
        }
        for x in 0..w {
            pass(h, &|y| (y * w + x) * 4);
        }
    }
}

fn pixel_bounds(r: Rect, margin: f32, width: u32, height: u32) -> IntRect {
    let x0 = (r.left() - margin).floor().max(0.0) as i32;
    let y0 = (r.top() - margin).floor().max(0.0) as i32;
    let x1 = ((r.right() + margin).ceil() as i32)
        .min(width as i32)
        .max(x0 + 1);
    let y1 = ((r.bottom() + margin).ceil() as i32)
        .min(height as i32)
        .max(y0 + 1);
    IntRect::from_ltrb(x0, y0, x1, y1).unwrap_or(IntRect::from_xywh(0, 0, 1, 1).unwrap())
}

impl Scene {
    pub fn new(book: &FontBook, input: SceneInput) -> Self {
        // Encoders need even dimensions; the overlay must match the frame exactly.
        let (width, height) = ((input.width & !1).max(2), (input.height & !1).max(2));
        let k = height as f32 / REF_HEIGHT;
        let style = scaled(&input.style, k);
        let fs = style.font_size;
        let boxed = style.animation == Animation::HighlightBox;
        let (pad_wx, pad_wy) = if boxed {
            (fs * 0.12, fs * 0.06)
        } else {
            (0.0, 0.0)
        };
        let (pad_bx, pad_by) = if style.background == Background::None {
            (0.0, 0.0)
        } else {
            (fs * 0.6, fs * 0.3)
        };
        let primary = book.primary(&style.font);
        let face = book.face(primary);
        let em = fs / face.units_per_em() as f32;
        let (ascent, descent) = (
            f32::from(face.ascender()) * em,
            -f32::from(face.descender()) * em,
        );
        let row_h = LINE_HEIGHT * fs + 2.0 * pad_wy;
        // Half-leading, as CSS does: the face's content area centred in the line box.
        let baseline_in_row = pad_wy + (LINE_HEIGHT * fs - (ascent + descent)) / 2.0 + ascent;
        // A boxed word's padding already separates it from the next, so the boxes
        // sit almost touching instead of adding a whole space on top.
        let base_gap = if boxed {
            fs * 0.04
        } else {
            shape(face, " ", fs).1
        };
        let sep = base_gap + fs * style.word_spacing;
        let max_row = MAX_WIDTH * width as f32 - 2.0 * pad_bx;
        let margin = style.shadow_blur * 3.0 + style.stroke_width + 2.0;

        let offset = input.caption_offset_ms;
        let words: Vec<_> = input.transcript.words().collect();
        let lines = words
            .chunks(style.words_per_line.max(1) as usize)
            .map(|chunk| {
                let shaped: Vec<_> = chunk
                    .iter()
                    .map(|w| shape(book.face(book.for_text(primary, &w.text)), &w.text, fs))
                    .collect();
                let mut rows: Vec<(Vec<usize>, f32)> = vec![];
                for (i, (_, adv)) in shaped.iter().enumerate() {
                    let slot = adv + 2.0 * pad_wx;
                    match rows.last_mut() {
                        Some((row, w)) if *w + sep + slot <= max_row => {
                            row.push(i);
                            *w += sep + slot;
                        }
                        _ => rows.push((vec![i], slot)),
                    }
                }
                let inner_w = rows.iter().map(|r| r.1).fold(0.0, f32::max);
                let (block_w, block_h) = (
                    inner_w + 2.0 * pad_bx,
                    rows.len() as f32 * row_h + 2.0 * pad_by,
                );
                // The block is centred on (position_x, position_y) and clamped so it
                // never leaves the frame, whatever a drag asks for.
                let place = |norm: f32, extent: f32, limit: f32| {
                    (norm * limit - extent / 2.0).clamp(0.0, (limit - extent).max(0.0))
                };
                let x0 = place(style.position_x, block_w, width as f32);
                let y0 = place(style.position_y, block_h, height as f32);
                let mut placed: Vec<Option<Placed>> = (0..chunk.len()).map(|_| None).collect();
                for (r, (row, row_w)) in rows.iter().enumerate() {
                    let top = y0 + pad_by + r as f32 * row_h;
                    let mut x = x0 + pad_bx + (inner_w - row_w) / 2.0;
                    for &i in row {
                        let (glyphs, adv) = &shaped[i];
                        let slot_w = adv + 2.0 * pad_wx;
                        let at = Transform::from_translate(x + pad_wx, top + baseline_in_row);
                        placed[i] = Some(Placed {
                            start: shifted(chunk[i].start, offset),
                            end: shifted(chunk[i].end, offset),
                            glyphs: glyphs.clone().and_then(|p| p.transform(at)),
                            slot: Rect::from_xywh(x, top, slot_w.max(1.0), row_h).unwrap(),
                        });
                        x += slot_w + sep;
                    }
                }
                let block = Rect::from_xywh(x0, y0, block_w.max(1.0), block_h.max(1.0)).unwrap();
                // Room for the pop to grow a word past its slot.
                let grow = inner_w.max(row_h) * POP;
                Line {
                    start: shifted(chunk.first().map_or(0.0, |w| w.start), offset),
                    end: shifted(chunk.last().map_or(0.0, |w| w.end), offset),
                    words: placed.into_iter().flatten().collect(),
                    block: (style.background != Background::None).then_some(block),
                    anchor: block,
                    bounds: pixel_bounds(block, margin + grow, width, height),
                }
            })
            .collect();
        let block_radius = match style.background {
            Background::Pill => f32::MAX,
            _ => 12.0 * k,
        };
        Self {
            word_radius: fs * 0.14,
            block_radius,
            style,
            width,
            height,
            lines,
        }
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    fn active_line(&self, t: f32) -> Option<usize> {
        let ls = &self.lines;
        ls.iter()
            .position(|l| t >= l.start && t <= l.end + LINE_HOLD_S)
            .or_else(|| ls.iter().rposition(|l| t > l.end && t < l.end + LINE_GAP_S))
    }

    fn key(&self, t: f32) -> FrameKey {
        let line = self.active_line(t);
        let states = line.map_or(vec![], |i| {
            self.lines[i]
                .words
                .iter()
                .map(|w| word_state(self.style.animation, w, t))
                .collect()
        });
        FrameKey(line, states)
    }

    fn draw(&self, canvas: &mut Pixmap, line: &Line, states: &[WordState]) {
        let s = &self.style;
        let pivot = |w: &Placed, st: &WordState| {
            let (cx, cy) = (
                w.slot.x() + w.slot.width() / 2.0,
                w.slot.y() + w.slot.height() / 2.0,
            );
            Transform::from_translate(-cx, -cy)
                .post_scale(st.scale, st.scale)
                .post_translate(cx, cy)
        };
        if let Some(path) = line.block.and_then(|b| rounded_rect(b, self.block_radius)) {
            let p = paint(colour(s.background_color, s.background_opacity));
            canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
        }
        if s.animation == Animation::HighlightBox {
            for (w, st) in line.words.iter().zip(states).filter(|(_, st)| st.on > 0.0) {
                if let Some(path) = rounded_rect(w.slot, self.word_radius) {
                    let p = paint(colour(s.highlight_color, st.on * st.opacity));
                    let grow = WordState {
                        scale: st.box_scale,
                        ..*st
                    };
                    canvas.fill_path(&path, &p, FillRule::Winding, pivot(w, &grow), None);
                }
            }
        }
        let stroke = (s.stroke_width > 0.0).then(|| Stroke {
            width: s.stroke_width,
            line_join: LineJoin::Round,
            line_cap: LineCap::Round,
            ..Stroke::default()
        });
        // Stroke under fill, so a thick outline grows outward instead of eating the letter.
        let ink = |px: &mut Pixmap, path: &Path, fill: Color, edge: Color, at: Transform| {
            if let Some(stroke) = &stroke {
                px.stroke_path(path, &paint(edge), stroke, at, None);
            }
            px.fill_path(path, &paint(fill), FillRule::Winding, at, None);
        };
        let (bx, by) = (line.bounds.x(), line.bounds.y());
        let local = |at: Transform| at.post_translate(-bx as f32, -by as f32);
        let layer = || Pixmap::new(line.bounds.width(), line.bounds.height());

        if s.shadow_blur > 0.0
            && let Some(mut shadow) = layer()
        {
            let solid = Rgba([
                s.shadow_color.0[0],
                s.shadow_color.0[1],
                s.shadow_color.0[2],
                255,
            ]);
            for (w, st) in line.words.iter().zip(states) {
                if let Some(path) = &w.glyphs {
                    let c = colour(solid, st.opacity);
                    ink(&mut shadow, path, c, c, local(pivot(w, st)));
                }
            }
            blur(&mut shadow, s.shadow_blur / 2.0);
            let p = PixmapPaint {
                opacity: f32::from(s.shadow_color.0[3]) / 255.0,
                ..PixmapPaint::default()
            };
            canvas.draw_pixmap(bx, by, shadow.as_ref(), &p, Transform::identity(), None);
        }

        for (w, st) in line.words.iter().zip(states) {
            let Some(path) = &w.glyphs else { continue };
            let fill = match s.animation {
                Animation::WordHighlight | Animation::WordPop => {
                    mix(s.text_color, s.highlight_color, st.on)
                }
                Animation::HighlightBox | Animation::WordFade => s.text_color,
            };
            let (fill, edge) = (colour(fill, 1.0), colour(s.stroke_color, 1.0));
            if st.opacity >= 1.0 {
                ink(canvas, path, fill, edge, pivot(w, st));
            } else if let Some(mut group) = layer() {
                // Composited as one group, like CSS opacity, so the stroke under
                // the fill does not show through a translucent letter.
                ink(&mut group, path, fill, edge, local(pivot(w, st)));
                let p = PixmapPaint {
                    opacity: st.opacity,
                    ..PixmapPaint::default()
                };
                canvas.draw_pixmap(bx, by, group.as_ref(), &p, Transform::identity(), None);
            }
        }
    }
}

/// Renders a scene frame by frame into straight-alpha RGBA, touching only the
/// pixels a caption occupies and skipping frames identical to the last.
pub struct Renderer {
    scene: Scene,
    canvas: Pixmap,
    rgba: Vec<u8>,
    last: Option<FrameKey>,
    dirty: Option<IntRect>,
}

fn rows(r: IntRect, width: u32) -> impl Iterator<Item = std::ops::Range<usize>> {
    let (x0, x1, w) = (r.x() as usize, r.right() as usize, width as usize);
    (r.y() as usize..r.bottom() as usize).map(move |y| (y * w + x0) * 4..(y * w + x1) * 4)
}

impl Renderer {
    pub fn new(scene: Scene) -> Self {
        let (w, h) = (scene.width, scene.height);
        Self {
            canvas: Pixmap::new(w, h).expect("frame dimensions are validated and non-zero"),
            rgba: vec![0; (w * h * 4) as usize],
            scene,
            last: None,
            dirty: None,
        }
    }

    /// Bring the frame to time `t`; returns whether any pixel changed.
    pub fn render(&mut self, t: f32) -> bool {
        let key = self.scene.key(t);
        if self.last.as_ref() == Some(&key) {
            return false;
        }
        let width = self.scene.width;
        if let Some(r) = self.dirty.take() {
            for span in rows(r, width) {
                self.canvas.data_mut()[span.clone()].fill(0);
                self.rgba[span].fill(0);
            }
        }
        if let Some(i) = key.0 {
            let line = &self.scene.lines[i];
            self.scene.draw(&mut self.canvas, line, &key.1);
            let src = self.canvas.data();
            for span in rows(line.bounds, width) {
                for (o, p) in self.rgba[span.clone()]
                    .chunks_exact_mut(4)
                    .zip(src[span].chunks_exact(4))
                {
                    let a = u32::from(p[3]);
                    if a == 0 {
                        o.fill(0);
                        continue;
                    }
                    for c in 0..3 {
                        o[c] = ((u32::from(p[c]) * 255 + a / 2) / a) as u8;
                    }
                    o[3] = p[3];
                }
            }
            self.dirty = Some(line.bounds);
        }
        self.last = Some(key);
        true
    }

    /// The active caption block as (x, y, w, h) in frame pixels, for the editor to
    /// hit-test and drag. `None` when no caption shows at the last rendered time.
    pub fn active_bounds(&self) -> Option<(f32, f32, f32, f32)> {
        let line = &self.scene.lines[self.active_index()?];
        let r = line.anchor;
        Some((r.x(), r.y(), r.width(), r.height()))
    }

    /// Index of the active line among all lines, so the editor can map a word
    /// back to the transcript (word N of line L is flat word `L * words_per_line + N`).
    pub fn active_index(&self) -> Option<usize> {
        self.last.as_ref()?.0
    }

    /// Each active word's slot as (x, y, w, h) in frame pixels, in line order, for
    /// the editor to pick the word under a double-click.
    pub fn active_word_rects(&self) -> Vec<(f32, f32, f32, f32)> {
        self.active_index().map_or_else(Vec::new, |i| {
            self.scene.lines[i]
                .words
                .iter()
                .map(|w| (w.slot.x(), w.slot.y(), w.slot.width(), w.slot.height()))
                .collect()
        })
    }

    /// The current frame: width × height × 4 bytes of straight-alpha RGBA.
    pub fn rgba(&self) -> &[u8] {
        &self.rgba
    }

    pub fn scene(&self) -> &Scene {
        &self.scene
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn book() -> FontBook<'static> {
        let mut b = FontBook::new();
        for font in [
            // A subset of Anton that draws only "helo": a face missing most glyphs.
            &include_bytes!("../testdata/anton-subset.ttf")[..],
            include_bytes!("../fonts/Inter.ttf"),
        ] {
            b.add(font).unwrap();
        }
        b
    }

    fn input(animation: &str, words: &[(&str, f32, f32)], words_per_line: u32) -> SceneInput {
        let words: Vec<_> = words.iter().map(|(t, s, e)| json_word(t, *s, *e)).collect();
        serde_json::from_value(serde_json::json!({
            "width": 1080, "height": 1920,
            "transcript": { "duration": 10.0, "segments": [{ "words": words }] },
            "style": {
                "font": "Inter", "font_size": 64, "text_color": "#FFFFFF",
                "highlight_color": "#7C3AED", "background": "none",
                "background_color": "#000000", "background_opacity": 0.0,
                "position_x": 0.5, "position_y": 0.84, "animation": animation,
                "words_per_line": words_per_line, "word_spacing": 0,
                "stroke_width": 2, "stroke_color": "#000000",
                "shadow_blur": 8, "shadow_color": "#00000080"
            }
        }))
        .unwrap()
    }

    fn json_word(t: &str, s: f32, e: f32) -> serde_json::Value {
        serde_json::json!({ "text": t, "start": s, "end": e })
    }

    const WORDS: &[(&str, f32, f32)] = &[
        ("one", 0.0, 0.5),
        ("two", 0.5, 1.0),
        ("three", 1.0, 1.5),
        ("four", 3.0, 3.5),
    ];

    #[test]
    fn colours_parse_with_and_without_alpha() {
        assert_eq!(Rgba::parse("#7C3AED"), Some(Rgba([0x7C, 0x3A, 0xED, 255])));
        assert_eq!(Rgba::parse("#00000080"), Some(Rgba([0, 0, 0, 0x80])));
        assert_eq!(Rgba::parse("7C3AED"), None);
        assert_eq!(Rgba::parse("#7C3AE"), None);
    }

    #[test]
    fn fonts_register_under_their_own_family_and_fall_back() {
        let b = book();
        assert_eq!(b.families(), ["Anton", "Inter"]);
        assert_eq!(b.primary("anton"), 0);
        assert_eq!(
            b.primary("No Such Face"),
            1,
            "falls back to the default face"
        );
        // The Anton subset cannot draw Cyrillic and Inter can, so the word moves to Inter.
        assert_eq!(b.for_text(0, "hello"), 0);
        assert_eq!(b.for_text(0, "привет"), 1);
    }

    #[test]
    fn a_requested_font_is_found_by_name_but_never_a_fallback() {
        let mut b = book();
        let lobster = include_bytes!("../fonts/Inter.ttf");
        assert!(b.add_requested("Lobster", lobster));
        assert_eq!(b.primary("lobster"), 2);
        assert_eq!(b.families(), ["Anton", "Inter"]);
        assert_eq!(
            b.for_text(0, "привет"),
            1,
            "falls back to bundled Inter, not the request"
        );
        let mut first = book();
        first.add_requested("Inter", lobster);
        assert_eq!(
            first.primary("Inter"),
            1,
            "a bundled family wins over a request"
        );
    }

    #[test]
    fn the_highlight_box_springs_in_past_full_size_then_settles() {
        let scene = Scene::new(&book(), input("highlight_box", WORDS, 3));
        let w = &scene.lines[0].words[1];
        let at = |t: f32| word_state(Animation::HighlightBox, w, t).box_scale;
        assert!(at(0.49) < 0.7, "starts small");
        assert!(
            (0..30)
                .map(|i| at(0.5 + i as f32 * 0.01))
                .fold(0.0, f32::max)
                > 1.02,
            "overshoots"
        );
        assert!((at(0.9) - 1.0).abs() < 1e-3, "settles at full size");
    }

    #[test]
    fn overshoot_starts_at_zero_ends_at_one_and_overshoots() {
        assert!(overshoot(0.0).abs() < 1e-4);
        assert!((overshoot(1.0) - 1.0).abs() < 1e-4);
        assert!(
            (0..=100)
                .map(|i| overshoot(i as f32 / 100.0))
                .fold(0.0, f32::max)
                > 1.05
        );
    }

    #[test]
    fn lines_follow_speech_hold_briefly_and_clear_in_long_gaps() {
        let scene = Scene::new(&book(), input("word_highlight", WORDS, 3));
        assert_eq!(scene.lines.len(), 2);
        assert_eq!(scene.active_line(0.2), Some(0));
        assert_eq!(scene.active_line(1.52), Some(0), "held past the last word");
        assert_eq!(scene.active_line(1.7), Some(0), "short gap keeps the line");
        assert_eq!(scene.active_line(2.5), None, "long gap clears");
        assert_eq!(scene.active_line(3.2), Some(1));
    }

    #[test]
    fn the_caption_offset_moves_every_line_and_clamps_at_the_start() {
        let at = |offset_ms: i32| {
            let mut i = input("word_highlight", WORDS, 3);
            i.caption_offset_ms = offset_ms;
            Scene::new(&book(), i)
        };
        let later = at(500);
        assert_eq!(later.active_line(0.2), None, "first line not yet showing");
        assert_eq!(later.active_line(0.7), Some(0));
        assert_eq!(later.active_line(3.7), Some(1));
        let earlier = at(-2000);
        assert_eq!(
            earlier.lines[0].start, 0.0,
            "clamped at the start, never negative"
        );
        assert_eq!(earlier.active_line(1.2), Some(1), "line two is at 1.0");
        let none = at(0);
        assert_eq!(
            (none.lines[0].start, none.lines[1].start),
            (0.0, 3.0),
            "zero changes nothing"
        );
    }

    #[test]
    fn long_lines_wrap_inside_the_frame() {
        let long: Vec<_> = (0..10)
            .map(|i| ("extraordinarily", i as f32, i as f32 + 1.0))
            .collect();
        let scene = Scene::new(&book(), input("word_highlight", &long, 10));
        let line = &scene.lines[0];
        let rows: std::collections::BTreeSet<_> =
            line.words.iter().map(|w| w.slot.y() as i32).collect();
        assert!(rows.len() > 1, "wrapped onto several rows");
        assert!(
            line.words
                .iter()
                .all(|w| w.slot.left() >= 0.0 && w.slot.right() <= 1080.0)
        );
    }

    #[test]
    fn highlight_box_reserves_its_padding_so_words_never_touch() {
        let scene = Scene::new(&book(), input("highlight_box", WORDS, 3));
        let w = &scene.lines[0].words;
        assert!(w[0].slot.right() < w[1].slot.left());
    }

    #[test]
    fn the_active_word_changes_the_frame_and_steady_frames_are_reused() {
        let mut r = Renderer::new(Scene::new(&book(), input("highlight_box", WORDS, 3)));
        assert!(r.render(0.3));
        let first = r.rgba().to_vec();
        assert!(first.iter().any(|&b| b != 0), "something was drawn");
        assert!(!r.render(0.31), "nothing animates mid-word");
        assert!(r.render(0.75));
        assert_ne!(first, r.rgba(), "the box moved to the next word");
        assert!(r.render(2.5));
        assert!(
            r.rgba().iter().all(|&b| b == 0),
            "a cleared frame is fully transparent"
        );
    }

    #[test]
    fn the_active_caption_bounds_track_the_rendered_line() {
        let mut r = Renderer::new(Scene::new(&book(), input("word_highlight", WORDS, 3)));
        assert_eq!(r.active_bounds(), None, "nothing rendered yet");
        r.render(0.3);
        let (x, y, w, h) = r.active_bounds().expect("a line shows at 0.3s");
        assert!(w > 0.0 && h > 0.0);
        assert!(
            x >= 0.0 && y >= 0.0 && x + w <= 1080.0 && y + h <= 1920.0,
            "stays in frame"
        );
        r.render(2.5); // a long gap: no caption
        assert_eq!(r.active_bounds(), None);
    }

    #[test]
    fn active_words_are_reported_in_line_order_and_in_frame() {
        let mut r = Renderer::new(Scene::new(&book(), input("word_highlight", WORDS, 3)));
        r.render(0.3);
        assert_eq!(r.active_index(), Some(0));
        let rects = r.active_word_rects();
        assert_eq!(rects.len(), 3, "one, two, three");
        // Left to right, non-overlapping, inside the frame.
        for pair in rects.windows(2) {
            assert!(pair[0].0 < pair[1].0);
        }
        assert!(
            rects
                .iter()
                .all(|(x, _, w, _)| *x >= 0.0 && x + w <= 1080.0)
        );
    }

    #[test]
    fn position_places_and_clamps_the_block() {
        let bounds = |x: f32, y: f32| {
            let mut i = input("word_highlight", WORDS, 3);
            i.style.position_x = x;
            i.style.position_y = y;
            let mut r = Renderer::new(Scene::new(&book(), i));
            r.render(0.3);
            r.active_bounds().unwrap()
        };
        let (lx, _, _, _) = bounds(0.0, 0.5);
        assert_eq!(lx, 0.0, "pinned to the left edge, not off-screen");
        let (cx, cy, cw, ch) = bounds(0.5, 0.5);
        assert!(
            (cx + cw / 2.0 - 540.0).abs() < 1.0 && (cy + ch / 2.0 - 960.0).abs() < 1.0,
            "centred"
        );
    }

    #[test]
    fn every_animation_draws() {
        for anim in ["word_highlight", "highlight_box", "word_pop", "word_fade"] {
            let mut r = Renderer::new(Scene::new(&book(), input(anim, WORDS, 3)));
            r.render(0.6);
            assert!(r.rgba().iter().any(|&b| b != 0), "{anim} drew nothing");
        }
    }
}
