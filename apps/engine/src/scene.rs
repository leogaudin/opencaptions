//! Layout once, draw per frame.
//!
//! A scene shapes and places every caption line up front; a frame is then only
//! the per-word animation state at time `t` applied to fixed geometry. Every
//! operation is integer or IEEE f32 arithmetic with no platform maths library,
//! which is what makes native and WASM output byte-identical.

use rustybuzz::ttf_parser::{GlyphId, OutlineBuilder};
use rustybuzz::{Face, UnicodeBuffer};
use tiny_skia::{
    Color, FillRule, GradientStop, IntRect, LineCap, LineJoin, LinearGradient, Mask, Paint, Path,
    PathBuilder, Pixmap, PixmapPaint, Point, Rect, SpreadMode, Stroke, Transform,
};

use crate::fonts::FontBook;
use crate::model::{Animation, Background, Rgba, SceneInput, Style, TextCase, shifted};

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
/// How far an italic leans: the shear of the upright face (about 11 degrees).
const ITALIC_SKEW: f32 = 0.2;
/// A typed word takes this share of its time to appear (at least 0.08 s, at most 0.6 s of it).
const TYPE_SHARE: f32 = 0.8;
/// The halo of a glow is laid down this many times to read as light, not as a smudge.
const GLOW_PASSES: usize = 3;
/// The shortest a word is taken to take to say, so a word with no length still sweeps.
const MIN_SAID_S: f32 = 0.08;
const MAX_TYPING_S: f32 = 0.6;
/// The watermark is drawn in the application's default face.
/// How far a bounced word rises past its size, and how far it leans (degrees), left and right in turn.
const BOUNCE: f32 = 0.28;
const BOUNCE_TILT: f32 = 5.0;
/// A label's lean (degrees) and how far the word being said lifts it.
const STICKER_TILT: f32 = 3.0;
const STICKER_LIFT: f32 = 0.12;
/// Lyric focus: how dim and how soft (a share of the font size) a word is before it is said, and
/// how much larger the word being said is.
const FOCUS_DIM: f32 = 0.35;
const FOCUS_BLUR: f32 = 0.05;
const FOCUS_SCALE: f32 = 0.06;
/// How long the sliding box takes to cross to the next word.
const SLIDE_S: f32 = 0.18;
/// The line bar: its distance under the line and its thickness, as shares of the font size.
const BAR_GAP: f32 = 0.12;
const BAR_THICK: f32 = 0.07;

const MARK_FAMILY: &str = "Inter";
const MARK_OPACITY: f32 = 0.85;

struct Placed {
    start: f32,
    end: f32,
    glyphs: Option<Path>,
    slot: Rect,
    /// Where the letters begin and how wide they run, inside the slot, and the baseline they sit on.
    ink_x: f32,
    ink_w: f32,
    baseline: f32,
    /// How many letters (for the typewriter's steps).
    chars: usize,
    /// Its place in the transcript, which decides which way it leans.
    index: usize,
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

/// A watermark: the picture of it and where it goes in the frame.
struct Mark {
    rect: IntRect,
    pixmap: Pixmap,
}

pub struct Scene {
    mark: Option<Mark>,
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
    /// How much of the word is filled, underlined or typed, 0 to 1 (the sweeping animations).
    fill: f32,
    /// How far the word is turned, in degrees.
    tilt: f32,
    /// How out of focus the word is, 0 to 1.
    soften: f32,
}

impl WordState {
    /// A word at rest: unmoved, unlit, fully shown.
    const STEADY: Self = Self {
        on: 0.0,
        scale: 1.0,
        opacity: 1.0,
        box_scale: 1.0,
        fill: 0.0,
        tilt: 0.0,
        soften: 0.0,
    };
}

/// A shape that belongs to the line and not to a word (the sliding box, the bar), at a moment:
/// its rectangle (x, y, width, height) and how visible it is.
#[derive(Clone, Copy, PartialEq)]
struct Guide {
    rect: [f32; 4],
    alpha: f32,
}

#[derive(PartialEq)]
struct FrameKey(Option<usize>, Vec<WordState>, Option<Guide>);

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
    // Direction, script and language from the text itself: Arabic and Hebrew run right to left,
    // and Arabic and the Indic scripts join and reorder their letters.
    buf.guess_segment_properties();
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

/// Which way the word at `index` leans: left, then right, in turn.
fn lean(w: &Placed) -> f32 {
    if w.index.is_multiple_of(2) { -1.0 } else { 1.0 }
}

/// How much of the way to a word's start the clock is: 0 before it, 1 from it on, kept after.
fn reached(t: f32, w: &Placed, secs: f32) -> f32 {
    ((t - (w.start - LEAD_S)) / secs).clamp(0.0, 1.0)
}

fn word_state(anim: Animation, w: &Placed, t: f32) -> WordState {
    let on = pulse(t, w, COLOUR_S, linear);
    let steady = WordState::STEADY;
    match anim {
        Animation::None | Animation::HighlightSlide => steady,
        Animation::WordHighlight => WordState { on, ..steady },
        Animation::HighlightBox => {
            // Grows in with the spring as the word starts, and fades out in place.
            let grow = overshoot(((t - (w.start - LEAD_S)) / BOX_S).clamp(0.0, 1.0));
            WordState {
                on,
                box_scale: BOX_FROM + (1.0 - BOX_FROM) * grow,
                ..steady
            }
        }
        Animation::WordPop => WordState {
            on,
            scale: 1.0 + POP * pulse(t, w, MOTION_S, overshoot),
            ..steady
        },
        Animation::WordFade => {
            let at = |edge: f32| ((t - edge) / MOTION_S).clamp(0.0, 1.0);
            let opacity = 0.4 + 0.6 * at(w.start - LEAD_S) - 0.3 * at(w.end + TRAIL_S);
            WordState { opacity, ..steady }
        }
        Animation::WordSweep | Animation::WordUnderline => WordState {
            fill: ((t - w.start) / (w.end - w.start).max(MIN_SAID_S)).clamp(0.0, 1.0),
            ..steady
        },
        Animation::Typewriter => {
            // Letter by letter: the steps are whole letters, so a frame only changes when one appears.
            let typing = (w.end - w.start).clamp(MIN_SAID_S, MAX_TYPING_S) * TYPE_SHARE;
            let typed = ((t - w.start) / typing).clamp(0.0, 1.0);
            let letters = w.chars.max(1) as f32;
            WordState {
                on,
                fill: (typed * letters).ceil() / letters,
                ..steady
            }
        }
        Animation::WordBounce => {
            let lift = pulse(t, w, MOTION_S, overshoot);
            WordState {
                on,
                scale: 1.0 + BOUNCE * lift,
                tilt: lean(w) * BOUNCE_TILT * lift,
                ..steady
            }
        }
        Animation::LyricFocus => {
            // Soft and dim until said; the word being said is sharp, bright and larger; a word already
            // said stays sharp and readable.
            let lit = pulse(t, w, MOTION_S, linear);
            let said = reached(t, w, MOTION_S);
            WordState {
                on: lit,
                scale: 1.0 + FOCUS_SCALE * lit,
                opacity: FOCUS_DIM + (1.0 - FOCUS_DIM) * (0.6 * said + 0.4 * lit),
                soften: 1.0 - said,
                ..steady
            }
        }
        Animation::LineBar => WordState {
            opacity: 0.35 + 0.65 * reached(t, w, MOTION_S),
            ..steady
        },
        Animation::Stickers => WordState {
            scale: 1.0 + STICKER_LIFT * pulse(t, w, MOTION_S, overshoot),
            tilt: lean(w) * STICKER_TILT,
            ..steady
        },
    }
}

/// How far a word grows past its slot at most, as a share of the line: room the line's bounds keep.
fn lift(anim: Animation) -> f32 {
    match anim {
        Animation::WordBounce => BOUNCE,
        Animation::Stickers => STICKER_LIFT,
        Animation::LyricFocus => FOCUS_SCALE,
        _ => POP,
    }
}

/// Outline, shadow and glow values are tuned on letters up to this size (every built-in look is). Past
/// it they grow with the letters, so a caption at 200 keeps the weight of one at 100 instead of
/// going thin; below it they stay as set, which keeps every saved look exactly as it was.
const EFFECTS_REF_SIZE: f32 = 100.0;

fn scaled(style: &Style, k: f32) -> Style {
    let e = k * (style.font_size / EFFECTS_REF_SIZE).max(1.0);
    Style {
        font_size: style.font_size * k,
        stroke_width: style.stroke_width * e,
        shadow_blur: style.shadow_blur * e,
        shadow_offset_x: style.shadow_offset_x * e,
        shadow_offset_y: style.shadow_offset_y * e,
        glow_blur: style.glow_blur * e,
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

/// The watermark as a small picture in white with a soft shadow, placed in the top right corner.
fn watermark(book: &FontBook, text: &str, width: u32, height: u32) -> Option<Mark> {
    if text.trim().is_empty() {
        return None;
    }
    let size = (height as f32 * 0.018).max(8.0);
    let face = book.face(book.primary(MARK_FAMILY));
    let (glyphs, advance) = shape(face, text, size);
    let glyphs = glyphs?;
    let margin = (size * 0.6).ceil();
    let (w, h) = (
        (advance + 2.0 * margin).ceil() as u32,
        (size * 1.5 + 2.0 * margin).ceil() as u32,
    );
    // Not in a frame too small to hold it.
    if w + 2 > width || h + 2 > height {
        return None;
    }
    let edge = height as f32 * 0.035;
    let x = (width as f32 - edge - advance - margin).max(0.0) as i32;
    let y = (edge - margin * 0.5).max(0.0) as i32;
    let rect = IntRect::from_xywh(x, y, w.min(width - x as u32), h.min(height - y as u32))?;
    let mut pixmap = Pixmap::new(rect.width(), rect.height())?;
    let at = Transform::from_translate(margin, margin + size);
    if let Some(mut shadow) = Pixmap::new(rect.width(), rect.height()) {
        shadow.fill_path(&glyphs, &paint(Color::BLACK), FillRule::Winding, at, None);
        blur(&mut shadow, size * 0.12);
        let p = PixmapPaint {
            opacity: 0.7,
            ..PixmapPaint::default()
        };
        pixmap.draw_pixmap(0, 0, shadow.as_ref(), &p, Transform::identity(), None);
    }
    let white = colour(Rgba([255, 255, 255, 255]), MARK_OPACITY);
    pixmap.fill_path(&glyphs, &paint(white), FillRule::Winding, at, None);
    Some(Mark { rect, pixmap })
}

/// Whether the words read right to left: most of their letters are Hebrew or Arabic.
fn is_right_to_left<'a>(words: impl Iterator<Item = &'a str>) -> bool {
    let (mut rtl, mut letters) = (0u32, 0u32);
    for c in words.flat_map(str::chars).filter(|c| c.is_alphabetic()) {
        letters += 1;
        if matches!(c as u32,
            0x0590..=0x05FF | 0x0600..=0x06FF | 0x0750..=0x077F | 0x08A0..=0x08FF | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF)
        {
            rtl += 1;
        }
    }
    rtl * 2 > letters
}

fn overlaps(a: IntRect, b: IntRect) -> bool {
    a.x() < b.right() && b.x() < a.right() && a.y() < b.bottom() && b.y() < a.bottom()
}

/// Copies `r` of a premultiplied frame into straight-alpha RGBA.
fn unpremultiply(src: &[u8], out: &mut [u8], r: IntRect, width: u32) {
    for span in rows(r, width) {
        for (o, p) in out[span.clone()]
            .as_chunks_mut::<4>()
            .0
            .iter_mut()
            .zip(src[span].as_chunks::<4>().0.iter())
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
        let boxed = matches!(
            style.animation,
            Animation::HighlightBox | Animation::HighlightSlide | Animation::Stickers
        );
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
        let fallbacks: Vec<usize> = input
            .fallback_fonts
            .iter()
            .filter_map(|family| book.find(family))
            .collect();
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
        let reach = |dx: f32, dy: f32| dx.abs().max(dy.abs());
        // What a caption's drawing reaches past its block: the soft edges of a shadow and a glow, the
        // shadow's offset, an outline, and an italic's lean over the top corner.
        let margin = style.shadow_blur * 3.0
            + reach(style.shadow_offset_x, style.shadow_offset_y)
            + style.glow_blur * 3.0
            + style.stroke_width
            + if style.italic { fs * ITALIC_SKEW } else { 0.0 }
            + match style.animation {
                // The soft words' blur, a turned word's corners, the bar under the line.
                Animation::LyricFocus => fs * FOCUS_BLUR * 3.0,
                Animation::WordBounce | Animation::Stickers => fs * 0.15,
                Animation::LineBar => fs * (BAR_GAP + BAR_THICK + 0.05),
                _ => 0.0,
            }
            + 2.0;

        let offset = input.caption_offset_ms;
        let words: Vec<_> = input.transcript.words().collect();
        let lines = words
            .chunks(style.words_per_line.max(1) as usize)
            .enumerate()
            .map(|(c, chunk)| {
                let texts: Vec<String> = chunk
                    .iter()
                    .map(|w| match style.text_case {
                        TextCase::Upper => w.text.to_uppercase(),
                        TextCase::None => w.text.clone(),
                    })
                    .collect();
                let lean = Transform::from_row(1.0, 0.0, -ITALIC_SKEW, 1.0, 0.0, 0.0);
                let shaped: Vec<_> = texts
                    .iter()
                    .map(|text| {
                        let (glyphs, advance) = shape(
                            book.face(book.for_text(primary, &fallbacks, text)),
                            text,
                            fs,
                        );
                        let glyphs = if style.italic {
                            glyphs.and_then(|p| p.transform(lean))
                        } else {
                            glyphs
                        };
                        (glyphs, advance)
                    })
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
                let right_to_left = is_right_to_left(chunk.iter().map(|w| w.text.as_str()));
                for (r, (row, row_w)) in rows.iter().enumerate() {
                    let top = y0 + pad_by + r as f32 * row_h;
                    let mut x = x0 + pad_bx + (inner_w - row_w) / 2.0;
                    // In a right-to-left line the first word is the rightmost.
                    let order: Vec<usize> = if right_to_left {
                        row.iter().rev().copied().collect()
                    } else {
                        row.clone()
                    };
                    for i in order {
                        let (glyphs, adv) = &shaped[i];
                        let slot_w = adv + 2.0 * pad_wx;
                        let at = Transform::from_translate(x + pad_wx, top + baseline_in_row);
                        placed[i] = Some(Placed {
                            start: shifted(chunk[i].start, offset),
                            end: shifted(chunk[i].end, offset),
                            glyphs: glyphs.clone().and_then(|p| p.transform(at)),
                            slot: Rect::from_xywh(x, top, slot_w.max(1.0), row_h).unwrap(),
                            ink_x: x + pad_wx,
                            ink_w: *adv,
                            baseline: top + baseline_in_row,
                            chars: texts[i].chars().count(),
                            index: c * style.words_per_line.max(1) as usize + i,
                        });
                        x += slot_w + sep;
                    }
                }
                let block = Rect::from_xywh(x0, y0, block_w.max(1.0), block_h.max(1.0)).unwrap();
                // Room for the pop to grow a word past its slot.
                let grow = inner_w.max(row_h) * lift(style.animation);
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
            mark: input
                .watermark
                .as_deref()
                .and_then(|text| watermark(book, text, width, height)),
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
        let guide = line.and_then(|i| self.guide(&self.lines[i], t));
        FrameKey(line, states, guide)
    }

    /// The sliding box or the line bar at `t`, for the animations that have one.
    fn guide(&self, line: &Line, t: f32) -> Option<Guide> {
        match self.style.animation {
            Animation::HighlightSlide => {
                let words = &line.words;
                let at = words.iter().rposition(|w| t >= w.start - LEAD_S)?;
                let (from, to) = (&words[at.saturating_sub(1)], &words[at]);
                let travel = overshoot(((t - (to.start - LEAD_S)) / SLIDE_S).clamp(0.0, 1.0));
                let lerp = |a: f32, b: f32| a + (b - a) * travel;
                let (a, b) = (from.slot, to.slot);
                Some(Guide {
                    rect: [
                        lerp(a.x(), b.x()),
                        lerp(a.y(), b.y()),
                        lerp(a.width(), b.width()),
                        lerp(a.height(), b.height()),
                    ],
                    // It fades in under the first word and is simply there after.
                    alpha: reached(t, &words[0], COLOUR_S),
                })
            }
            Animation::LineBar => {
                let done =
                    ((t - line.start) / (line.end - line.start).max(MIN_SAID_S)).clamp(0.0, 1.0);
                let a = line.anchor;
                let fs = self.style.font_size;
                Some(Guide {
                    rect: [
                        a.x(),
                        a.bottom() + fs * BAR_GAP,
                        a.width() * done,
                        (fs * BAR_THICK).max(2.0),
                    ],
                    alpha: 1.0,
                })
            }
            _ => None,
        }
    }

    fn draw(&self, canvas: &mut Pixmap, line: &Line, states: &[WordState], guide: Option<Guide>) {
        let s = &self.style;
        let pivot = |w: &Placed, st: &WordState| {
            let (cx, cy) = (
                w.slot.x() + w.slot.width() / 2.0,
                w.slot.y() + w.slot.height() / 2.0,
            );
            Transform::from_translate(-cx, -cy)
                .post_scale(st.scale, st.scale)
                .post_rotate(st.tilt)
                .post_translate(cx, cy)
        };
        if let Some(path) = line.block.and_then(|b| rounded_rect(b, self.block_radius)) {
            let p = paint(colour(s.background_color, s.background_opacity));
            canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
        }
        if s.animation == Animation::HighlightSlide
            && let Some(g) = guide
            && let Some(path) = Rect::from_xywh(g.rect[0], g.rect[1], g.rect[2], g.rect[3])
                .and_then(|r| rounded_rect(r, self.word_radius))
        {
            let p = paint(colour(s.primary(), g.alpha));
            canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
        }
        if s.animation == Animation::Stickers {
            for (w, st) in line.words.iter().zip(states) {
                if let Some(path) = rounded_rect(w.slot, self.word_radius * 1.6) {
                    let p = paint(colour(s.highlight(w.index), 1.0));
                    canvas.fill_path(&path, &p, FillRule::Winding, pivot(w, st), None);
                }
            }
        }
        if s.animation == Animation::HighlightBox {
            for (w, st) in line.words.iter().zip(states).filter(|(_, st)| st.on > 0.0) {
                if let Some(path) = rounded_rect(w.slot, self.word_radius) {
                    let p = paint(colour(s.highlight(w.index), st.on * st.opacity));
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
        let ink_with = |px: &mut Pixmap, path: &Path, fill: &Paint, edge: Color, at: Transform| {
            if let Some(stroke) = &stroke {
                px.stroke_path(path, &paint(edge), stroke, at, None);
            }
            px.fill_path(path, fill, FillRule::Winding, at, None);
        };
        let ink = |px: &mut Pixmap, path: &Path, fill: Color, edge: Color, at: Transform| {
            ink_with(px, path, &paint(fill), edge, at);
        };
        let (bx, by) = (line.bounds.x(), line.bounds.y());
        let local = |at: Transform| at.post_translate(-bx as f32, -by as f32);
        let layer = || Pixmap::new(line.bounds.width(), line.bounds.height());

        let solid = |c: Rgba| Rgba([c.0[0], c.0[1], c.0[2], 255]);
        let opacity = |c: Rgba| f32::from(c.0[3]) / 255.0;
        let has_offset = s.shadow_offset_x != 0.0 || s.shadow_offset_y != 0.0;
        if (s.shadow_blur > 0.0 || has_offset)
            && let Some(mut shadow) = layer()
        {
            // A soft shadow is the letters once, moved and blurred. A hard one is the letters carried
            // from where they are to the offset, a pixel at a time, so it reads as their outline
            // extended (an extrusion) and not as a second copy behind them.
            let steps = if s.shadow_blur > 0.0 {
                1
            } else {
                (s.shadow_offset_x.abs().max(s.shadow_offset_y.abs()).ceil() as usize).clamp(1, 96)
            };
            for (w, st) in line.words.iter().zip(states) {
                if let Some(path) = &w.glyphs {
                    let c = colour(solid(s.shadow_color), st.opacity);
                    for step in 1..=steps {
                        let along = step as f32 / steps as f32;
                        let at = pivot(w, st)
                            .post_translate(s.shadow_offset_x * along, s.shadow_offset_y * along);
                        ink(&mut shadow, path, c, c, local(at));
                    }
                }
            }
            if s.shadow_blur > 0.0 {
                blur(&mut shadow, s.shadow_blur / 2.0);
            }
            let p = PixmapPaint {
                opacity: opacity(s.shadow_color),
                ..PixmapPaint::default()
            };
            canvas.draw_pixmap(bx, by, shadow.as_ref(), &p, Transform::identity(), None);
        }
        if s.glow_blur > 0.0
            && let Some(mut halo) = layer()
        {
            for (w, st) in line.words.iter().zip(states) {
                if let Some(path) = &w.glyphs {
                    let c = colour(solid(s.glow_color), st.opacity);
                    ink(&mut halo, path, c, c, local(pivot(w, st)));
                }
            }
            blur(&mut halo, s.glow_blur / 2.0);
            let p = PixmapPaint {
                opacity: opacity(s.glow_color),
                ..PixmapPaint::default()
            };
            for _ in 0..GLOW_PASSES {
                canvas.draw_pixmap(bx, by, halo.as_ref(), &p, Transform::identity(), None);
            }
        }

        // What of a word's letters shows, as a layer cut off at `x`: from the left edge of the
        // letters to there (typing), or the whole of it with the colour over only that much (filling).
        let cut = |x: f32| {
            let mut mask = Mask::new(line.bounds.width(), line.bounds.height())?;
            let edge = Rect::from_ltrb(
                0.0,
                0.0,
                (x - bx as f32).max(0.0),
                line.bounds.height() as f32,
            )?;
            mask.fill_path(
                &PathBuilder::from_rect(edge),
                FillRule::Winding,
                false,
                Transform::identity(),
            );
            Some(mask)
        };
        // What a sweep paints with: the one highlight colour, or a run through all of them across the
        // whole line, so each word is a different part of it.
        let sweep = || -> Paint<'static> {
            let colours = &s.highlight_colors;
            let run = (colours.len() > 1).then(|| {
                let last = (colours.len() - 1) as f32;
                let stops: Vec<_> = colours
                    .iter()
                    .enumerate()
                    .map(|(i, c)| GradientStop::new(i as f32 / last, colour(*c, 1.0)))
                    .collect();
                LinearGradient::new(
                    Point::from_xy(line.anchor.x(), 0.0),
                    Point::from_xy(line.anchor.right().max(line.anchor.x() + 1.0), 0.0),
                    stops,
                    SpreadMode::Pad,
                    Transform::identity(),
                )
            });
            match run.flatten() {
                Some(shader) => Paint {
                    shader,
                    anti_alias: true,
                    ..Paint::default()
                },
                None => paint(colour(s.primary(), 1.0)),
            }
        };
        for (w, st) in line.words.iter().zip(states) {
            let Some(path) = &w.glyphs else { continue };
            let fill = match s.animation {
                Animation::WordHighlight
                | Animation::WordPop
                | Animation::WordBounce
                | Animation::LyricFocus => mix(s.text_color, s.highlight(w.index), st.on),
                Animation::None
                | Animation::HighlightBox
                | Animation::HighlightSlide
                | Animation::LineBar
                | Animation::Stickers
                | Animation::WordFade
                | Animation::WordSweep
                | Animation::WordUnderline
                | Animation::Typewriter => s.text_color,
            };
            let (fill, edge) = (colour(fill, 1.0), colour(s.stroke_color, 1.0));
            if s.animation == Animation::WordSweep && st.fill > 0.0 {
                // Each letter is painted once: the highlight on the side the sweep has passed, the
                // plain colour on the rest. Painting the highlight over a finished plain word would
                // leave the plain word's soft edge showing round it, a pale fringe.
                let (on, at) = (sweep(), pivot(w, st));
                if st.fill >= 1.0 {
                    ink_with(canvas, path, &on, edge, at);
                } else if let (Some(mut passed), Some(mut ahead), Some(mask)) =
                    (layer(), layer(), cut(w.ink_x + w.ink_w * st.fill))
                {
                    ink_with(&mut passed, path, &on, edge, local(at));
                    passed.apply_mask(&mask);
                    ink(&mut ahead, path, fill, edge, local(at));
                    let mut rest = mask;
                    rest.invert();
                    ahead.apply_mask(&rest);
                    let p = PixmapPaint::default();
                    for half in [&passed, &ahead] {
                        canvas.draw_pixmap(bx, by, half.as_ref(), &p, Transform::identity(), None);
                    }
                }
                continue;
            }
            let typed = s.animation == Animation::Typewriter;
            if typed && st.fill <= 0.0 {
                continue;
            }
            if st.opacity >= 1.0 && st.soften <= 0.0 && !(typed && st.fill < 1.0) {
                ink(canvas, path, fill, edge, pivot(w, st));
            } else if let Some(mut group) = layer() {
                // Composited as one group, like CSS opacity, so the stroke under
                // the fill does not show through a translucent letter.
                ink(&mut group, path, fill, edge, local(pivot(w, st)));
                if typed && let Some(mask) = cut(w.ink_x + w.ink_w * st.fill) {
                    group.apply_mask(&mask);
                }
                if st.soften > 0.0 {
                    blur(&mut group, st.soften * s.font_size * FOCUS_BLUR);
                }
                let p = PixmapPaint {
                    opacity: st.opacity,
                    ..PixmapPaint::default()
                };
                canvas.draw_pixmap(bx, by, group.as_ref(), &p, Transform::identity(), None);
            }
            match s.animation {
                Animation::WordUnderline if st.fill > 0.0 => {
                    let thick = (s.font_size * 0.075).max(2.0);
                    let rule = Rect::from_xywh(
                        w.ink_x,
                        w.baseline + s.font_size * 0.1,
                        (w.ink_w * st.fill).max(1.0),
                        thick,
                    );
                    if let Some(path) = rule.and_then(|r| rounded_rect(r, thick / 2.0)) {
                        let p = paint(colour(s.highlight(w.index), 1.0));
                        canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
                    }
                }
                Animation::Typewriter if st.on > 0.0 => {
                    // The cursor sits where the next letter goes, for as long as the word is being said.
                    let width = (s.font_size * 0.07).max(2.0);
                    let cursor = Rect::from_xywh(
                        w.ink_x + w.ink_w * st.fill,
                        w.baseline - s.font_size * 0.78,
                        width,
                        s.font_size * 0.92,
                    );
                    if let Some(path) = cursor.and_then(|r| rounded_rect(r, width / 4.0)) {
                        let p = paint(colour(s.highlight(w.index), st.on));
                        canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
                    }
                }
                _ => {}
            }
        }
        if s.animation == Animation::LineBar
            && let Some(g) = guide
            && let Some(path) = Rect::from_xywh(g.rect[0], g.rect[1], g.rect[2], g.rect[3])
                .and_then(|r| rounded_rect(r, g.rect[3] / 2.0))
        {
            let p = paint(colour(s.primary(), g.alpha));
            canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
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
    /// The rows the last `render` changed, `top..bottom`: all of them the first time.
    changed: (u32, u32),
}

fn rows(r: IntRect, width: u32) -> impl Iterator<Item = std::ops::Range<usize>> {
    let (x0, x1, w) = (r.x() as usize, r.right() as usize, width as usize);
    (r.y() as usize..r.bottom() as usize).map(move |y| (y * w + x0) * 4..(y * w + x1) * 4)
}

impl Renderer {
    pub fn new(scene: Scene) -> Self {
        let (w, h) = (scene.width, scene.height);
        let mut renderer = Self {
            canvas: Pixmap::new(w, h).expect("frame dimensions are validated and non-zero"),
            rgba: vec![0; (w * h * 4) as usize],
            scene,
            last: None,
            dirty: None,
            changed: (0, 0),
        };
        renderer.draw_mark();
        renderer
    }

    /// The watermark onto the frame (which must be clear where it goes), and into the RGBA.
    fn draw_mark(&mut self) {
        let Some(mark) = &self.scene.mark else { return };
        let (x, y) = (mark.rect.x(), mark.rect.y());
        self.canvas.draw_pixmap(
            x,
            y,
            mark.pixmap.as_ref(),
            &PixmapPaint::default(),
            Transform::identity(),
            None,
        );
        unpremultiply(
            self.canvas.data(),
            &mut self.rgba,
            mark.rect,
            self.scene.width,
        );
    }

    /// Clears the watermark's place, to draw it again once what overlapped it is drawn.
    fn clear_mark(&mut self) {
        let Some(mark) = &self.scene.mark else { return };
        for span in rows(mark.rect, self.scene.width) {
            self.canvas.data_mut()[span.clone()].fill(0);
            self.rgba[span].fill(0);
        }
    }

    /// Bring the frame to time `t`; returns whether any pixel changed.
    pub fn render(&mut self, t: f32) -> bool {
        let key = self.scene.key(t);
        if self.last.as_ref() == Some(&key) {
            return false;
        }
        let width = self.scene.width;
        // A new scene's first frame is all new to whoever shows it; after that, only the rows
        // cleared and drawn. Showing just those is what keeps a playing preview cheap.
        let mut changed = if self.last.is_none() {
            Some((0, self.scene.height))
        } else {
            None
        };
        let mut grow = |r: IntRect| {
            let (top, bottom) = (r.y() as u32, r.bottom() as u32);
            changed = Some(changed.map_or((top, bottom), |(t, b)| (t.min(top), b.max(bottom))));
        };
        // The watermark is drawn again, over whatever it overlaps, when a caption clears or draws
        // where it is; otherwise it is left as it is.
        let mark = self.scene.mark.as_ref().map(|m| m.rect);
        let mut redraw_mark = false;
        if let Some(r) = self.dirty {
            grow(r);
            redraw_mark |= mark.is_some_and(|m| overlaps(r, m));
        }
        if let Some(i) = key.0 {
            let bounds = self.scene.lines[i].bounds;
            grow(bounds);
            redraw_mark |= mark.is_some_and(|m| overlaps(bounds, m));
        }
        if let (true, Some(m)) = (redraw_mark, mark) {
            grow(m);
        }
        self.changed = changed.unwrap_or((0, 0));
        if let Some(r) = self.dirty.take() {
            for span in rows(r, width) {
                self.canvas.data_mut()[span.clone()].fill(0);
                self.rgba[span].fill(0);
            }
        }
        if redraw_mark {
            self.clear_mark();
        }
        if let Some(i) = key.0 {
            let line = &self.scene.lines[i];
            self.scene.draw(&mut self.canvas, line, &key.1, key.2);
            unpremultiply(self.canvas.data(), &mut self.rgba, line.bounds, width);
            self.dirty = Some(line.bounds);
        }
        if redraw_mark {
            self.draw_mark();
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

    /// Where the watermark sits as (x, y, w, h) in frame pixels, for an editor that moves the
    /// captions about and must keep the mark in place. `None` without one.
    pub fn watermark_rect(&self) -> Option<(f32, f32, f32, f32)> {
        let r = self.scene.mark.as_ref()?.rect;
        Some((
            r.x() as f32,
            r.y() as f32,
            r.width() as f32,
            r.height() as f32,
        ))
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
    /// The rows the last `render` that returned true changed, as `top..bottom`.
    pub fn changed_rows(&self) -> (u32, u32) {
        self.changed
    }

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
                "highlight_colors": ["#7C3AED"], "background": "none",
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
        assert_eq!(b.for_text(0, &[], "hello"), 0);
        assert_eq!(b.for_text(0, &[], "привет"), 1);
    }

    #[test]
    fn a_requested_font_is_found_by_name_but_never_a_fallback() {
        let mut b = book();
        let lobster = include_bytes!("../fonts/Inter.ttf");
        assert!(b.add_requested("Lobster", lobster));
        assert_eq!(b.primary("lobster"), 2);
        assert_eq!(b.families(), ["Anton", "Inter"]);
        assert_eq!(
            b.for_text(0, &[], "привет"),
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

    /// `input` with some style fields changed.
    fn styled(animation: &str, words: &[(&str, f32, f32)], patch: serde_json::Value) -> SceneInput {
        let base = input(animation, words, 3);
        let mut style = serde_json::to_value(serde_json::json!({
            "font": "Inter", "font_size": 64, "text_color": "#FFFFFF",
            "highlight_colors": ["#FF0000"], "background": "none",
            "background_color": "#000000", "background_opacity": 0.0,
            "position_x": 0.5, "position_y": 0.5, "animation": animation,
            "words_per_line": 3, "stroke_width": 0, "stroke_color": "#000000",
            "shadow_blur": 0, "shadow_color": "#00000000"
        }))
        .unwrap();
        for (k, v) in patch.as_object().unwrap() {
            style[k] = v.clone();
        }
        let mut value = serde_json::json!({
            "width": base.width, "height": base.height,
            "transcript": serde_json::to_value(&base.transcript).unwrap_or_default(),
        });
        value["style"] = style;
        serde_json::from_value(value).unwrap()
    }

    /// The columns and rows with any ink in a frame: (left, right, top, bottom).
    fn extent(renderer: &Renderer, width: usize) -> Option<(usize, usize, usize, usize)> {
        let rgba = renderer.rgba();
        let mut found: Option<(usize, usize, usize, usize)> = None;
        for (i, px) in rgba.chunks(4).enumerate() {
            if px[3] > 0 {
                let (x, y) = (i % width, i / width);
                found = Some(match found {
                    None => (x, x, y, y),
                    Some((l, r, t, b)) => (l.min(x), r.max(x), t.min(y), b.max(y)),
                });
            }
        }
        found
    }

    fn drawn(patch: serde_json::Value, at: f32) -> Option<(usize, usize, usize, usize)> {
        let scene = Scene::new(
            &book(),
            styled("word_highlight", &[("hello", 0.0, 1.0)], patch),
        );
        let mut renderer = Renderer::new(scene);
        renderer.render(at);
        extent(&renderer, 1080)
    }

    #[test]
    fn a_sweep_fills_the_word_as_it_is_said_and_keeps_it() {
        let scene = Scene::new(&book(), input("word_sweep", WORDS, 3));
        let w = &scene.lines[0].words[1];
        let at = |t: f32| word_state(Animation::WordSweep, w, t).fill;
        assert_eq!(at(0.4), 0.0, "not said yet");
        assert!((at(0.75) - 0.5).abs() < 0.01, "half way through the word");
        assert_eq!(at(1.4), 1.0, "and it stays filled after");
        let underline = Scene::new(&book(), input("word_underline", WORDS, 3));
        let w = &underline.lines[0].words[1];
        assert!((word_state(Animation::WordUnderline, w, 0.75).fill - 0.5).abs() < 0.01);
    }

    #[test]
    fn typed_words_appear_a_letter_at_a_time_and_none_before_they_start() {
        let scene = Scene::new(&book(), input("typewriter", &[("three", 1.0, 1.5)], 3));
        let w = &scene.lines[0].words[0];
        let at = |t: f32| word_state(Animation::Typewriter, w, t).fill;
        assert_eq!(at(0.9), 0.0);
        let steps: Vec<f32> = (0..40).map(|i| at(1.0 + i as f32 * 0.01)).collect();
        assert!(
            steps
                .iter()
                .all(|f| (f * 5.0 - (f * 5.0).round()).abs() < 1e-4),
            "whole letters"
        );
        assert_eq!(at(1.5), 1.0, "all of it once typed");
        assert!(steps.windows(2).all(|p| p[0] <= p[1]), "never untyped");
    }

    #[test]
    fn upper_case_is_drawn_not_stored() {
        let word = [("hello", 0.0, 1.0)];
        let lower = Scene::new(
            &book(),
            styled("word_highlight", &word, serde_json::json!({})),
        );
        let upper = Scene::new(
            &book(),
            styled(
                "word_highlight",
                &word,
                serde_json::json!({ "text_case": "upper" }),
            ),
        );
        assert!(upper.lines[0].words[0].slot.width() > lower.lines[0].words[0].slot.width());
    }

    #[test]
    fn outlines_and_shadows_keep_their_weight_as_the_letters_grow() {
        let effects = |font_size: u32| {
            let patch = serde_json::json!({
                "font_size": font_size, "stroke_width": 10, "shadow_blur": 4,
                "shadow_offset_x": 8, "shadow_offset_y": 10, "glow_blur": 20
            });
            let s = scaled(
                &styled("word_highlight", &[("a", 0.0, 1.0)], patch).style,
                1.0,
            );
            // Each relative to the letters, so what a viewer sees as weight.
            [
                s.stroke_width,
                s.shadow_blur,
                s.shadow_offset_x,
                s.shadow_offset_y,
                s.glow_blur,
            ]
            .map(|v| v / s.font_size)
        };
        let at_100 = effects(100);
        for (big, small) in effects(200).into_iter().zip(at_100) {
            assert!((big - small).abs() < 1e-4, "{big} against {small}");
        }
        let at_300 = effects(300);
        assert!(at_300.iter().zip(at_100).all(|(a, b)| (a - b).abs() < 1e-4));
        // Smaller letters are left as they were set, so no saved look changes.
        let small = scaled(
            &styled(
                "word_highlight",
                &[("a", 0.0, 1.0)],
                serde_json::json!({ "font_size": 50, "stroke_width": 10 }),
            )
            .style,
            1.0,
        );
        assert_eq!(small.stroke_width, 10.0);
    }

    #[test]
    fn a_hard_shadow_is_the_letters_carried_to_the_offset() {
        let plain = drawn(serde_json::json!({}), 0.5).unwrap();
        let solid = serde_json::json!({
            "shadow_offset_x": 20, "shadow_offset_y": 20, "shadow_blur": 0,
            "shadow_color": "#000000FF"
        });
        let shadowed = drawn(solid, 0.5).unwrap();
        assert!(shadowed.1 >= plain.1 + 8, "reaches right of the letters");
        assert!(shadowed.3 >= plain.3 + 8, "and below them");
    }

    #[test]
    fn a_glow_reaches_around_the_letters() {
        let plain = drawn(serde_json::json!({}), 0.5).unwrap();
        let glow = serde_json::json!({ "glow_blur": 30, "glow_color": "#00FFFFFF" });
        let lit = drawn(glow, 0.5).unwrap();
        assert!(
            lit.0 + 8 <= plain.0 && lit.1 >= plain.1 + 8,
            "a halo past the letters"
        );
    }

    #[test]
    fn an_italic_leans_over_the_right_edge() {
        let upright = drawn(serde_json::json!({}), 0.5).unwrap();
        let leaning = drawn(serde_json::json!({ "italic": true }), 0.5).unwrap();
        assert!(
            leaning.1 > upright.1,
            "the top of the last letter leans out"
        );
        assert_eq!(
            (leaning.2, leaning.3),
            (upright.2, upright.3),
            "the same height"
        );
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
    fn a_word_with_a_space_in_it_is_drawn_as_one_wider_word() {
        let book = book();
        let one = Scene::new(&book, input("word_highlight", &[("hello", 0.0, 0.5)], 3));
        let spaced = Scene::new(
            &book,
            input("word_highlight", &[("hello world", 0.0, 0.5)], 3),
        );
        assert_eq!(spaced.lines[0].words.len(), 1, "one word, not two");
        assert!(spaced.lines[0].words[0].slot.width() > one.lines[0].words[0].slot.width() * 1.5);
        let mut renderer = Renderer::new(spaced);
        assert!(renderer.render(0.2), "it draws");
        assert!(renderer.rgba().iter().any(|b| *b != 0));
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
    fn a_frame_reports_the_rows_it_changed_and_no_others_differ() {
        let mut r = Renderer::new(Scene::new(&book(), input("word_pop", WORDS, 3)));
        let row = (1080 * 4) as usize;
        assert!(r.render(0.3));
        assert_eq!(
            r.changed_rows(),
            (0, 1920),
            "a new scene's first frame is all new"
        );
        // A word popping in, the next one, then nothing showing: each time, the rows outside the
        // band are exactly as they were, so a viewer copying only the band shows the frame.
        for t in [0.52, 1.03, 100.0] {
            let before = r.rgba().to_vec();
            assert!(r.render(t), "{t} changes something");
            let (top, bottom) = r.changed_rows();
            assert!(top < bottom && bottom <= 1920);
            assert!(
                bottom - top < 1920 / 2,
                "a caption's band, not the frame: {top}..{bottom}"
            );
            let after = r.rgba();
            assert_eq!(before[..top as usize * row], after[..top as usize * row]);
            assert_eq!(
                before[bottom as usize * row..],
                after[bottom as usize * row..]
            );
        }
    }

    fn marked(animation: &str, x: f64, y: f64) -> SceneInput {
        let mut i = input(animation, WORDS, 3);
        i.style.position_x = x as f32;
        i.style.position_y = y as f32;
        i.watermark = Some("Made with OpenCaptions".into());
        i
    }

    fn inked(rgba: &[u8]) -> usize {
        rgba.as_chunks::<4>().0.iter().filter(|p| p[3] != 0).count()
    }

    #[test]
    fn a_watermark_is_in_the_corner_of_every_frame_and_only_there() {
        let mut plain = Renderer::new(Scene::new(&book(), input("word_pop", WORDS, 3)));
        plain.render(100.0);
        assert_eq!(inked(plain.rgba()), 0, "nothing without one");

        let mut r = Renderer::new(Scene::new(&book(), marked("word_pop", 0.5, 0.84)));
        assert!(r.render(100.0), "the first frame is a frame");
        let rows = (1080 * 4) as usize;
        let first = r.rgba().to_vec();
        let ink = inked(&first);
        assert!(ink > 100, "a mark is drawn: {ink} pixels");
        // Top right quarter only.
        for (i, p) in first.as_chunks::<4>().0.iter().enumerate() {
            if p[3] != 0 {
                let (x, y) = (i % 1080, i / 1080);
                assert!(x > 540 && y < 480, "inked at {x},{y}");
            }
        }
        // A caption comes and goes elsewhere: the mark is left as it was.
        r.render(0.6);
        assert!(inked(r.rgba()) > ink, "caption and mark");
        r.render(100.0);
        assert_eq!(first, r.rgba(), "back to the mark alone, exactly");
        assert_eq!(rows, 1080 * 4);
    }

    #[test]
    fn a_caption_over_the_watermark_does_not_erase_it_or_leave_it_doubled() {
        // The caption is at the top right, where the mark is.
        let mut r = Renderer::new(Scene::new(&book(), marked("word_pop", 0.8, 0.04)));
        r.render(100.0);
        let alone = r.rgba().to_vec();
        r.render(0.6);
        assert_ne!(alone, r.rgba(), "the caption is drawn");
        let mut fresh = Renderer::new(Scene::new(&book(), marked("word_pop", 0.8, 0.04)));
        fresh.render(0.6);
        assert_eq!(
            fresh.rgba(),
            r.rgba(),
            "the same frame however it was reached"
        );
        r.render(100.0);
        assert_eq!(alone, r.rgba(), "and the mark alone again, not thickened");
    }

    #[test]
    fn the_watermarks_rectangle_is_reported_and_holds_all_its_ink() {
        let plain = Renderer::new(Scene::new(&book(), input("word_pop", WORDS, 3)));
        assert_eq!(plain.watermark_rect(), None);

        let mut r = Renderer::new(Scene::new(&book(), marked("word_pop", 0.5, 0.2)));
        r.render(100.0);
        let (x, y, w, h) = r.watermark_rect().expect("a rectangle");
        let (fw, fh) = (r.scene.width as usize, r.scene.height as usize);
        for (i, p) in r.rgba().as_chunks::<4>().0.iter().enumerate() {
            let (px, py) = ((i % fw) as f32, (i / fw) as f32);
            let inside = px >= x && px < x + w && py >= y && py < y + h;
            assert!(
                inside || p[3] == 0,
                "ink outside the rectangle at {px},{py}"
            );
        }
        assert!(x + w <= fw as f32 && y + h <= fh as f32);
    }

    #[test]
    fn no_mark_in_a_frame_too_small_for_it() {
        let mut i = marked("word_pop", 0.5, 0.5);
        i.width = 40;
        i.height = 40;
        let mut r = Renderer::new(Scene::new(&book(), i));
        r.render(100.0);
        assert_eq!(inked(r.rgba()), 0);
    }

    fn book_with_scripts() -> FontBook<'static> {
        let mut b = book();
        for font in [
            &include_bytes!("../fonts/NotoSansArabic.ttf")[..],
            include_bytes!("../fonts/NotoSansHebrew.ttf"),
            include_bytes!("../fonts/NotoSansDevanagari.ttf"),
            include_bytes!("../fonts/NotoSansThai.ttf"),
        ] {
            b.add(font).unwrap();
        }
        b
    }

    fn word_xs(words: &[(&str, f32, f32)]) -> Vec<f32> {
        let mut r = Renderer::new(Scene::new(
            &book_with_scripts(),
            input("word_pop", words, 3),
        ));
        r.render(0.5);
        assert!(r.rgba().iter().any(|&b| b != 0), "something is drawn");
        r.active_word_rects().iter().map(|rect| rect.0).collect()
    }

    #[test]
    fn right_to_left_lines_run_from_the_right_and_left_to_right_ones_do_not() {
        let latin = word_xs(&[("one", 0.0, 0.4), ("two", 0.4, 0.8), ("three", 0.8, 1.2)]);
        assert!(latin[0] < latin[1] && latin[1] < latin[2], "{latin:?}");
        let arabic = word_xs(&[("مرحبا", 0.0, 0.4), ("بكم", 0.4, 0.8), ("جميعا", 0.8, 1.2)]);
        assert!(arabic[0] > arabic[1] && arabic[1] > arabic[2], "{arabic:?}");
        let hebrew = word_xs(&[("שלום", 0.0, 0.4), ("לכולם", 0.4, 0.8), ("היום", 0.8, 1.2)]);
        assert!(hebrew[0] > hebrew[1] && hebrew[1] > hebrew[2], "{hebrew:?}");
    }

    #[test]
    fn scripts_the_default_face_lacks_are_drawn_with_the_bundled_ones() {
        let book = book_with_scripts();
        let inter = book.primary("Inter");
        for text in ["مرحبا", "שלום", "नमस्ते", "สวัสดี"] {
            let face = book.for_text(inter, &[], text);
            assert_ne!(face, inter, "{text} needs another face");
            let ink = |t: &str| {
                let mut r = Renderer::new(Scene::new(
                    &book,
                    input("word_highlight", &[(t, 0.0, 1.0)], 3),
                ));
                r.render(0.5);
                r.rgba()
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .filter(|p| p[3] != 0)
                    .count()
            };
            assert!(ink(text) > 500, "{text} is drawn, not left out");
        }
    }

    #[test]
    fn a_named_fallback_font_draws_what_the_style_font_lacks() {
        // Only what the scene names is tried before the bundled faces: here the Arabic face is
        // registered the way a fetched font is, not bundled.
        let arabic: &'static [u8] = include_bytes!("../fonts/NotoSansArabic.ttf");
        let mut b = book();
        assert!(b.add_requested("Noto Sans Arabic", arabic));
        let named = b.find("Noto Sans Arabic").unwrap();
        let primary = b.primary("Anton");
        assert_eq!(
            b.for_text(primary, &[], "مرحبا"),
            primary,
            "nothing names it"
        );
        assert_eq!(b.for_text(primary, &[named], "مرحبا"), named);
        assert_eq!(
            b.for_text(primary, &[named], "helo"),
            primary,
            "the style's font still wins"
        );
        let frame = |fallbacks: &[&str]| {
            let mut i = input("word_highlight", &[("مرحبا", 0.0, 1.0)], 3);
            i.fallback_fonts = fallbacks.iter().map(|f| f.to_string()).collect();
            let mut r = Renderer::new(Scene::new(&b, i));
            r.render(0.5);
            r.rgba().to_vec()
        };
        assert_ne!(
            frame(&["Noto Sans Arabic"]),
            frame(&[]),
            "the named font is the one drawn with"
        );
    }

    #[test]
    fn a_bounced_word_rises_past_its_size_and_leans_left_then_right() {
        let scene = Scene::new(&book(), input("word_bounce", WORDS, 3));
        let [one, two] = [&scene.lines[0].words[0], &scene.lines[0].words[1]];
        let (a, b) = (
            word_state(Animation::WordBounce, one, 0.25),
            word_state(Animation::WordBounce, two, 0.75),
        );
        assert!(a.scale > 1.2 && b.scale > 1.2, "both are larger while said");
        assert!(a.tilt < 0.0 && b.tilt > 0.0, "and lean opposite ways");
        assert_eq!(
            word_state(Animation::WordBounce, two, 0.0).tilt,
            0.0,
            "not before"
        );
    }

    #[test]
    fn lyric_focus_is_soft_until_said_sharp_while_said_and_readable_after() {
        let scene = Scene::new(&book(), input("lyric_focus", WORDS, 3));
        let w = &scene.lines[0].words[1];
        let at = |t: f32| word_state(Animation::LyricFocus, w, t);
        let (before, now, after) = (at(0.2), at(0.75), at(1.4));
        assert_eq!((before.soften, before.opacity), (1.0, FOCUS_DIM));
        assert_eq!((now.soften, now.opacity), (0.0, 1.0));
        assert!(now.scale > 1.0);
        assert_eq!(after.soften, 0.0, "a word that was said stays in focus");
        assert!(after.opacity > FOCUS_DIM && after.opacity < 1.0);
    }

    #[test]
    fn the_box_slides_from_word_to_word_and_rests_on_the_one_being_said() {
        let scene = Scene::new(&book(), input("highlight_slide", WORDS, 3));
        let line = &scene.lines[0];
        assert!(
            scene.guide(line, 0.0 - 0.1).is_none(),
            "no box before the first word"
        );
        let on = |i: usize| line.words[i].slot.x();
        assert_eq!(scene.guide(line, 0.25).unwrap().rect[0], on(0));
        assert!((scene.guide(line, 0.9).unwrap().rect[0] - on(1)).abs() < 0.01);
        let mid = scene
            .guide(line, 0.5 - LEAD_S + SLIDE_S / 4.0)
            .unwrap()
            .rect[0];
        assert!(
            mid > on(0) && mid < on(1),
            "between the two while it travels"
        );
    }

    #[test]
    fn the_line_bar_fills_as_the_line_is_spoken() {
        let scene = Scene::new(&book(), input("line_bar", WORDS, 3));
        let line = &scene.lines[0];
        let width = |t: f32| scene.guide(line, t).unwrap().rect[2];
        assert_eq!(width(0.0), 0.0);
        assert!(
            (width(0.75) - line.anchor.width() * 0.5).abs() < 1.0,
            "half way"
        );
        assert!(
            (width(1.5) - line.anchor.width()).abs() < 0.01,
            "and full at the end"
        );
        assert!(scene.guide(&scene.lines[0], 0.5).unwrap().rect[1] > line.anchor.bottom());
    }

    #[test]
    fn a_filled_word_has_no_pale_fringe_of_the_plain_colour_under_it() {
        let patch = serde_json::json!({ "highlight_colors": ["#FF0000"], "font_size": 200 });
        let words = &[("hello", 0.0, 0.5)];
        let mut r = Renderer::new(Scene::new(&book(), styled("word_sweep", words, patch)));
        r.render(0.6);
        let inked: Vec<&[u8]> = r.rgba().chunks(4).filter(|px| px[3] > 0).collect();
        assert!(inked.len() > 1000, "the word is drawn");
        // The plain colour is white: any of it left at the edge shows as green and blue.
        assert!(
            inked.iter().all(|px| px[1] < 10 && px[2] < 10),
            "an edge pixel is not pure highlight"
        );
    }

    #[test]
    fn highlight_colours_are_taken_in_turn_and_the_first_is_the_primary() {
        let mut style = input("word_pop", WORDS, 3).style;
        let (red, green, blue) = (
            Rgba([255, 0, 0, 255]),
            Rgba([0, 255, 0, 255]),
            Rgba([0, 0, 255, 255]),
        );
        style.highlight_colors = vec![red, green, blue];
        assert_eq!(style.primary(), red);
        assert_eq!(
            [0, 1, 2, 3, 4].map(|i| style.highlight(i)),
            [red, green, blue, red, green]
        );
        style.highlight_colors = vec![];
        assert_eq!(
            style.primary(),
            Rgba([255, 255, 255, 255]),
            "none: white, and no panic"
        );
        assert_eq!(style.highlight(7), style.primary());
    }

    /// How many pixels of the frame at `t` are close to `rgb` (a lit word's colour).
    fn pixels_near(renderer: &mut Renderer, t: f32, rgb: [u8; 3]) -> usize {
        renderer.render(t);
        let near = |a: u8, b: u8| a.abs_diff(b) < 40;
        renderer
            .rgba()
            .chunks(4)
            .filter(|px| px[3] == 255 && (0..3).all(|c| near(px[c], rgb[c])))
            .count()
    }

    #[test]
    fn each_word_is_lit_in_the_next_colour_and_a_single_shape_keeps_the_primary() {
        let words = &[("aaa", 0.0, 0.5), ("bbb", 0.5, 1.0)];
        let patch = serde_json::json!({
            "highlight_colors": ["#FF0000", "#00FF00"], "font_size": 200, "text_color": "#0000FF"
        });
        let mut pop = Renderer::new(Scene::new(
            &book(),
            styled("word_pop", words, patch.clone()),
        ));
        assert!(
            pixels_near(&mut pop, 0.25, [255, 0, 0]) > 500,
            "the first word is lit red"
        );
        assert!(
            pixels_near(&mut pop, 0.75, [0, 255, 0]) > 500,
            "the second is lit green"
        );
        assert_eq!(
            pixels_near(&mut pop, 0.25, [0, 255, 0]),
            0,
            "and not green too"
        );
        // One box slides between the words: it is the primary on both.
        let mut slide = Renderer::new(Scene::new(&book(), styled("highlight_slide", words, patch)));
        assert!(pixels_near(&mut slide, 0.25, [255, 0, 0]) > 500);
        assert!(
            pixels_near(&mut slide, 0.9, [255, 0, 0]) > 500,
            "still red on the second word"
        );
        assert_eq!(pixels_near(&mut slide, 0.9, [0, 255, 0]), 0);
    }

    #[test]
    fn a_gradient_sweep_runs_from_one_colour_to_the_other_across_the_line() {
        let words = &[("aaaa", 0.0, 0.5), ("bbbb", 0.5, 1.0)];
        let patch = serde_json::json!({
            "highlight_colors": ["#FF0000", "#0000FF"], "font_size": 200
        });
        let mut r = Renderer::new(Scene::new(&book(), styled("word_sweep", words, patch)));
        r.render(1.0);
        // The leftmost and rightmost fully inked pixels: the two ends of the line.
        let solid = |px: &&[u8]| px[3] == 255;
        let at = |i: usize| i % 1080;
        let pixels: Vec<&[u8]> = r.rgba().chunks(4).collect();
        let first = pixels
            .iter()
            .enumerate()
            .filter(|(_, px)| solid(px))
            .min_by_key(|(i, _)| at(*i));
        let last = pixels
            .iter()
            .enumerate()
            .filter(|(_, px)| solid(px))
            .max_by_key(|(i, _)| at(*i));
        let (left, right) = (first.unwrap().1, last.unwrap().1);
        let (left, right) = ((left[0], left[2]), (right[0], right[2]));
        assert!(left.0 > left.1, "the start of the line is red");
        assert!(right.1 > right.0, "and its end is blue");
    }

    #[test]
    fn every_animation_draws() {
        for anim in [
            "word_highlight",
            "highlight_box",
            "word_pop",
            "word_fade",
            "word_sweep",
            "word_underline",
            "typewriter",
            "none",
            "word_bounce",
            "lyric_focus",
            "highlight_slide",
            "line_bar",
            "stickers",
        ] {
            let mut r = Renderer::new(Scene::new(&book(), input(anim, WORDS, 3)));
            r.render(0.6);
            assert!(r.rgba().iter().any(|&b| b != 0), "{anim} drew nothing");
        }
    }
}
