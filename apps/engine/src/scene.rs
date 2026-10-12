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
use crate::model::{
    Animation, Background, Layout, Rgba, SceneInput, Style, TextCase, cut, emphasis, shifted,
};

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
/// A stack's rows are cut at this share of the widest row a line may have, each is then scaled up to
/// the widest one's width by at most `STACK_MAX_SCALE`, and the rows sit this tight (a share of
/// their own size).
const STACK_ROW_SHARE: f32 = 0.55;
const STACK_MAX_SCALE: f32 = 3.0;
const STACK_LEADING: f32 = 1.0;
/// Word slam: the size a word drops in from, how long the drop takes, the share of it in which the
/// word fades in, and how far the line is jolted when it lands (a share of the font size) and for
/// how long. The jolt goes along one of these directions, by the word's place in the transcript.
const SLAM_FROM: f32 = 1.7;
const SLAM_S: f32 = 0.12;
const SLAM_FADE: f32 = 0.4;
const JOLT: f32 = 0.035;
const JOLT_S: f32 = 0.15;
const JOLT_DIRECTIONS: [[f32; 2]; 4] = [[1.0, 0.6], [-0.8, 0.8], [0.6, -1.0], [-1.0, -0.4]];
/// Letter rise: each letter climbs this far (a share of the font size) from below, takes `RISE_S`,
/// and starts a `RISE_STAGGER_S` after the one before it (less, in a word said quickly, and so that
/// the letters of a long word start within `RISE_SPREAD_S` of the first: the word is whole soon
/// after it is said).
const RISE_FROM: f32 = 0.45;
const RISE_S: f32 = 0.12;
const RISE_STAGGER_S: f32 = 0.03;
const RISE_SPREAD_S: f32 = 0.1;
/// How much the first step of a shaded extrusion is lightened, times the shading.
const RIM_LIGHT: f32 = 0.25;
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
const BOUNCE: f32 = 0.18;
const BOUNCE_TILT: f32 = 5.0;
/// A label's lean (degrees) and how far the word being said lifts it.
const STICKER_TILT: f32 = 3.0;
const STICKER_LIFT: f32 = 0.12;
/// Lyric focus: how dim and how soft (a share of the font size) a word is before it is said.
const FOCUS_DIM: f32 = 0.35;
const FOCUS_BLUR: f32 = 0.05;
/// The marker stroke of the underline: its thickness and how far it rises above the baseline, as
/// shares of the font size, and how far it runs past the word at each end.
const MARKER_THICK: f32 = 0.3;
const MARKER_RISE: f32 = 0.2;
const MARKER_OVERHANG: f32 = 0.04;
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
    /// The word's letters, one outline each (a connected script's whole word is one): only for the
    /// animation that moves them separately.
    clusters: Vec<Path>,
    /// The top of the em box, where a gradient fill starts.
    em_top: f32,
    /// How many letters (for the typewriter's steps).
    chars: usize,
    /// Its place in the transcript, which decides which way it leans.
    index: usize,
    /// How much larger than the style's size it is set: a key word's emphasis and its row's scale
    /// in a stack, else 1.
    size: f32,
    /// Whether it is a key word that is set apart (emphasis on): always in its highlight colour.
    key: bool,
}

struct Line {
    /// Flat index of the line's first word in the transcript.
    first: usize,
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
    /// How far the word is pushed into its extrusion, 0 to 1 (a little past it on the spring).
    press: f32,
    /// How far through its staggered entrance the word is, 0 to 1 (letter by letter).
    enter: f32,
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
        press: 0.0,
        enter: 1.0,
    };
}

/// A shape that belongs to the line and not to a word (the sliding box, the bar), at a moment:
/// its rectangle (x, y, width, height) and how visible it is.
#[derive(Clone, Copy, PartialEq)]
struct Guide {
    rect: [f32; 4],
    alpha: f32,
    /// The corner radius of the sliding box, which follows the size of the words it moves between.
    radius: f32,
}

#[derive(PartialEq)]
/// The frame's line, its words' states, its guide shape, and how far the line is jolted.
struct FrameKey(Option<usize>, Vec<WordState>, Option<Guide>, [f32; 2]);

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

/// Whether `c` is in a script whose letters join or reorder, so that a word of it cannot be taken
/// apart without breaking it: Arabic and Syriac, Hebrew, the Indic scripts, Thai, Lao, Myanmar, Khmer.
fn is_connected(c: char) -> bool {
    matches!(c as u32,
        0x0590..=0x08FF | 0x0900..=0x0DFF | 0x0E00..=0x0EFF | 0x1000..=0x109F | 0x1780..=0x17FF
        | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF)
}

/// One outline for each grapheme cluster of `text`, in reading order, with the pen at the origin
/// on the baseline like `shape`. A word of a connected script is a single cluster: it moves as a
/// piece and is never broken apart.
fn cluster_paths(face: &Face, text: &str, size: f32) -> Vec<Path> {
    if text.chars().any(is_connected) {
        return shape(face, text, size).0.into_iter().collect();
    }
    let mut buf = UnicodeBuffer::new();
    buf.push_str(text);
    buf.guess_segment_properties();
    let glyphs = rustybuzz::shape(face, &[], buf);
    let scale = size / face.units_per_em() as f32;
    let mut groups: Vec<(u32, PathBuilder)> = vec![];
    let mut pen = 0i32;
    for (info, pos) in glyphs.glyph_infos().iter().zip(glyphs.glyph_positions()) {
        let at = match groups.iter().position(|(c, _)| *c == info.cluster) {
            Some(at) => at,
            None => {
                groups.push((info.cluster, PathBuilder::new()));
                groups.len() - 1
            }
        };
        let mut sink = Sink {
            pb: std::mem::replace(&mut groups[at].1, PathBuilder::new()),
            scale,
            dx: (pen + pos.x_offset) as f32 * scale,
            dy: -(pos.y_offset as f32) * scale,
        };
        face.outline_glyph(GlyphId(info.glyph_id as u16), &mut sink);
        groups[at].1 = sink.pb;
        pen += pos.x_advance;
    }
    groups.sort_by_key(|(cluster, _)| *cluster);
    groups
        .into_iter()
        .filter_map(|(_, pb)| pb.finish())
        .collect()
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

/// The stops of a vertical gradient through `colours`, evenly spaced, each run through `tint`;
/// None when there are fewer than two (then the one colour, or the text's, is used flat).
fn gradient_stops(colours: &[Rgba], tint: &dyn Fn(Rgba) -> Rgba) -> Option<Vec<GradientStop>> {
    if colours.len() < 2 {
        return None;
    }
    let last = (colours.len() - 1) as f32;
    Some(
        colours
            .iter()
            .enumerate()
            .map(|(i, c)| GradientStop::new(i as f32 / last, colour(tint(*c), 1.0)))
            .collect(),
    )
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
            // Soft and dim until said; the word being said is sharp and bright; a word already said
            // stays sharp and readable. It does not change size: the line stays still.
            let lit = pulse(t, w, MOTION_S, linear);
            let said = reached(t, w, MOTION_S);
            WordState {
                on: lit,
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
        Animation::WordSlam => {
            // Dropped in from twice its size and landed in 0.12 s, no overshoot, visible from
            // the first 40% of the drop; nothing before it is said.
            let p = reached(t, w, SLAM_S);
            let eased = 1.0 - (1.0 - p) * (1.0 - p);
            WordState {
                on,
                scale: SLAM_FROM + (1.0 - SLAM_FROM) * eased,
                opacity: (p / SLAM_FADE).min(1.0),
                ..steady
            }
        }
        Animation::LetterRise => WordState {
            on,
            enter: ((t - (w.start - LEAD_S)) / rise_timing(w).1).clamp(0.0, 1.0),
            ..steady
        },
        Animation::WordPress => WordState {
            on,
            press: pulse(t, w, MOTION_S, overshoot),
            ..steady
        },
    }
}

/// The gap between one letter's start and the next's, and the whole entrance, for a word.
fn rise_timing(w: &Placed) -> (f32, f32) {
    let n = w.clusters.len().max(1) as f32;
    let said = (w.end - w.start).max(MIN_SAID_S);
    let stagger = RISE_STAGGER_S.min(said * 0.5 / n).min(RISE_SPREAD_S / n);
    (stagger, (n - 1.0) * stagger + RISE_S)
}

/// The parts of a word that are drawn on their own: each an outline, how far down it sits (in
/// pixels) and how visible it is. The whole word as one part, except while its letters rise.
fn parts<'a>(w: &'a Placed, st: &WordState, fs: f32, rising: bool) -> Vec<(&'a Path, f32, f32)> {
    if rising && st.enter < 1.0 {
        let (stagger, total) = rise_timing(w);
        let letters: Vec<&Path> = if w.clusters.is_empty() {
            w.glyphs.iter().collect()
        } else {
            w.clusters.iter().collect()
        };
        return letters
            .into_iter()
            .enumerate()
            .filter_map(|(i, path)| {
                let p = ((st.enter * total - i as f32 * stagger) / RISE_S).clamp(0.0, 1.0);
                (p > 0.0).then(|| (path, RISE_FROM * fs * (1.0 - overshoot(p)), p))
            })
            .collect();
    }
    w.glyphs.iter().map(|g| (g, 0.0, 1.0)).collect()
}

/// How far a word grows past its slot at most, as a share of the line: room the line's bounds keep.
fn lift(anim: Animation) -> f32 {
    match anim {
        Animation::WordBounce => BOUNCE,
        Animation::WordSlam => SLAM_FROM - 1.0,
        Animation::Stickers => STICKER_LIFT,
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

/// The radius of each of the three box blurs that approximate a Gaussian of `sigma`.
fn blur_radius(sigma: f32) -> usize {
    ((sigma * sigma * 4.0 + 1.0).sqrt() / 2.0).round().max(1.0) as usize
}

/// How far a blur of `sigma` carries ink from where it was: the three boxes' radii.
fn blur_reach(sigma: f32) -> usize {
    3 * blur_radius(sigma)
}

/// Three box blurs approximate a Gaussian of `sigma`, in integer arithmetic on
/// premultiplied bytes so every target computes the same result.
///
/// Only the part of the pixmap that can change is worked on: the ink's bounding box and the
/// reach of the blur around it. Beyond that the pixels are 0 before and 0 after (a box of
/// zeros sums to zero), and the pixmap's own edge already counts as 0, so the result is
/// exactly what blurring every pixel gives.
fn blur(px: &mut Pixmap, sigma: f32) {
    let radius = blur_radius(sigma);
    let (w, h) = (px.width() as usize, px.height() as usize);
    let data = px.data_mut();
    let Some((left, top, right, bottom)) = ink_extent(data, w, h) else {
        return;
    };
    let reach = blur_reach(sigma);
    let x0 = left.saturating_sub(reach);
    let x1 = (right + reach).min(w);
    let y0 = top.saturating_sub(reach);
    let y1 = (bottom + reach).min(h);
    let (cw, ch) = (x1 - x0, y1 - y0);
    let span = (2 * radius + 1) as u32;
    let mut src = vec![0u8; cw.max(ch) * 4];
    let mut sums = vec![0u32; cw * 4];
    let mut rows = vec![0u8; cw * ch * 4];
    for _ in 0..3 {
        for y in y0..y1 {
            let row = &mut data[(y * w + x0) * 4..(y * w + x1) * 4];
            src[..cw * 4].copy_from_slice(row);
            slide(&src[..cw * 4], row, radius, span);
        }
        // Down the columns, a row at a time: the running sums are kept for every column
        // at once, so memory is read in order.
        for (r, y) in (y0..y1).enumerate() {
            rows[r * cw * 4..(r + 1) * cw * 4]
                .copy_from_slice(&data[(y * w + x0) * 4..(y * w + x1) * 4]);
        }
        sums.fill(0);
        for r in 0..=radius.min(ch - 1) {
            add_row(&mut sums, &rows[r * cw * 4..(r + 1) * cw * 4]);
        }
        for r in 0..ch {
            let out = &mut data[((y0 + r) * w + x0) * 4..((y0 + r) * w + x1) * 4];
            for (o, acc) in out.iter_mut().zip(&sums) {
                *o = ((acc + span / 2) / span) as u8;
            }
            if r + radius + 1 < ch {
                add_row(
                    &mut sums,
                    &rows[(r + radius + 1) * cw * 4..(r + radius + 2) * cw * 4],
                );
            }
            if r >= radius {
                for (acc, v) in sums
                    .iter_mut()
                    .zip(&rows[(r - radius) * cw * 4..(r - radius + 1) * cw * 4])
                {
                    *acc -= u32::from(*v);
                }
            }
        }
    }
}

fn add_row(sums: &mut [u32], row: &[u8]) {
    for (acc, v) in sums.iter_mut().zip(row) {
        *acc += u32::from(*v);
    }
}

/// One box blur along a row of RGBA pixels: each output byte is the rounded mean of the
/// `2 * radius + 1` bytes around it in the same channel, with 0 beyond the ends.
fn slide(src: &[u8], out: &mut [u8], radius: usize, span: u32) {
    let len = src.len() / 4;
    let mut acc = [0u32; 4];
    for px in src.as_chunks::<4>().0.iter().take(radius.min(len - 1) + 1) {
        for c in 0..4 {
            acc[c] += u32::from(px[c]);
        }
    }
    for i in 0..len {
        for c in 0..4 {
            out[i * 4 + c] = ((acc[c] + span / 2) / span) as u8;
        }
        if i + radius + 1 < len {
            for c in 0..4 {
                acc[c] += u32::from(src[(i + radius + 1) * 4 + c]);
            }
        }
        if i >= radius {
            for c in 0..4 {
                acc[c] -= u32::from(src[(i - radius) * 4 + c]);
            }
        }
    }
}

/// The columns and rows holding any non-zero byte: (left, top, right, bottom), the last two
/// exclusive. None for an empty pixmap.
fn ink_extent(data: &[u8], w: usize, h: usize) -> Option<(usize, usize, usize, usize)> {
    let (mut left, mut top, mut right, mut bottom) = (w, h, 0, 0);
    for (y, row) in data.chunks_exact(w * 4).enumerate().take(h) {
        let Some(first) = row.as_chunks::<4>().0.iter().position(|p| *p != [0; 4]) else {
            continue;
        };
        let last = row.as_chunks::<4>().0.iter().rposition(|p| *p != [0; 4])?;
        left = left.min(first);
        right = right.max(last + 1);
        top = top.min(y);
        bottom = y + 1;
    }
    (right > left && bottom > top).then_some((left, top, right, bottom))
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
            if a == 255 {
                // (p * 255 + 127) / 255 is p.
                *o = *p;
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
        // `k` is the size of the largest word: a key word's, or a stack row's, effects grow with it.
        let margin = |k: f32| {
            (style.shadow_blur * 3.0
                + reach(style.shadow_offset_x, style.shadow_offset_y)
                + style.glow_blur * 3.0
                + style.stroke_width)
                * k
                + if style.italic {
                    fs * ITALIC_SKEW * k
                } else {
                    0.0
                }
                + match style.animation {
                    // The soft words' blur, a turned word's corners, the bar under the line.
                    Animation::LyricFocus => fs * FOCUS_BLUR * 3.0 * k,
                    Animation::WordBounce | Animation::Stickers => fs * 0.15 * k,
                    Animation::LineBar => fs * (BAR_GAP + BAR_THICK + 0.05),
                    Animation::LetterRise => fs * RISE_FROM * k,
                    Animation::WordSlam => fs * JOLT * 1.5 * k,
                    _ => 0.0,
                }
                + 2.0
        };

        let offset = input.caption_offset_ms;
        let words: Vec<_> = input.transcript.words().collect();
        let ranges = cut(&words, style.words_per_line.max(1) as usize);
        // The key words, sized up and alone on a row when the style asks for it.
        let key = emphasis(&words, &ranges);
        let big = style.emphasis_scale > 1.0;
        let lines = ranges
            .into_iter()
            .map(|range| {
                let first = range.start;
                let sizes: Vec<f32> = key[range.clone()]
                    .iter()
                    .map(|&k| if k && big { style.emphasis_scale } else { 1.0 })
                    .collect();
                let chunk = &words[range];
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
                    .zip(&sizes)
                    .map(|(text, size)| {
                        let (glyphs, advance) = shape(
                            book.face(book.for_text(primary, &fallbacks, text)),
                            text,
                            fs * size,
                        );
                        let glyphs = if style.italic {
                            glyphs.and_then(|p| p.transform(lean))
                        } else {
                            glyphs
                        };
                        (glyphs, advance)
                    })
                    .collect();
                // One outline per letter, only for the look that moves them apart.
                let clusters: Vec<Vec<Path>> = texts
                    .iter()
                    .zip(&sizes)
                    .map(|(text, size)| {
                        if style.animation != Animation::LetterRise {
                            return vec![];
                        }
                        let face = book.face(book.for_text(primary, &fallbacks, text));
                        // At the word's own size, or a key word would rise small and then jump.
                        let letters = cluster_paths(face, text, fs * size);
                        if style.italic {
                            letters
                                .into_iter()
                                .filter_map(|p| p.transform(lean))
                                .collect()
                        } else {
                            letters
                        }
                    })
                    .collect();
                // Rows: words fill a row until the next does not fit (a stack's rows are short); a
                // key word has a row to itself, and the row is as tall as its word.
                let stack = style.layout == Layout::Stack;
                let limit = if stack {
                    STACK_ROW_SHARE * max_row
                } else {
                    max_row
                };
                let mut rows: Vec<(Vec<usize>, f32, f32)> = vec![];
                for (i, (_, adv)) in shaped.iter().enumerate() {
                    let slot = adv + 2.0 * pad_wx;
                    let alone = sizes[i] > 1.0;
                    match rows.last_mut() {
                        Some((row, w, k)) if !alone && *k <= 1.0 && *w + sep + slot <= limit => {
                            row.push(i);
                            *w += sep + slot;
                        }
                        _ => rows.push((vec![i], slot, sizes[i])),
                    }
                }
                // A stack scales each row up to the widest one's width, at most three times over.
                let widest = rows.iter().map(|r| r.1).fold(0.0, f32::max);
                let scales: Vec<f32> = rows
                    .iter()
                    .map(|r| {
                        if stack {
                            (widest / r.1.max(1.0)).clamp(1.0, STACK_MAX_SCALE)
                        } else {
                            1.0
                        }
                    })
                    .collect();
                let lead = if stack { STACK_LEADING } else { LINE_HEIGHT };
                let height_of = |k: f32, scale: f32| lead * fs * k + 2.0 * pad_wy * scale;
                let inner_w = rows
                    .iter()
                    .zip(&scales)
                    .map(|(r, s)| r.1 * s)
                    .fold(0.0, f32::max);
                let (block_w, block_h) = (
                    inner_w + 2.0 * pad_bx,
                    rows.iter()
                        .zip(&scales)
                        .map(|(r, s)| height_of(r.2 * s, *s))
                        .sum::<f32>()
                        + 2.0 * pad_by,
                );
                // The block is centred on (position_x, position_y) and clamped so it
                // never leaves the frame, whatever a drag asks for. One wider than the
                // frame (a word at a huge size) is centred, spilling over both sides.
                let place = |norm: f32, extent: f32, limit: f32| {
                    if extent >= limit {
                        (limit - extent) / 2.0
                    } else {
                        (norm * limit - extent / 2.0).clamp(0.0, limit - extent)
                    }
                };
                let x0 = place(style.position_x, block_w, width as f32);
                let y0 = place(style.position_y, block_h, height as f32);
                let mut placed: Vec<Option<Placed>> = (0..chunk.len()).map(|_| None).collect();
                let right_to_left = is_right_to_left(chunk.iter().map(|w| w.text.as_str()));
                let mut top = y0 + pad_by;
                let mut biggest = 1.0f32;
                for ((row, row_w, e), scale) in rows.iter().zip(&scales) {
                    let k = e * scale;
                    biggest = biggest.max(k);
                    let row_h = height_of(k, *scale);
                    // Half-leading, as CSS does, for this row's size.
                    let baseline_in_row = pad_wy * scale
                        + (lead * fs * k - (ascent + descent) * k) / 2.0
                        + ascent * k;
                    let mut x = x0 + pad_bx + (inner_w - row_w * scale) / 2.0;
                    // In a right-to-left line the first word is the rightmost.
                    let order: Vec<usize> = if right_to_left {
                        row.iter().rev().copied().collect()
                    } else {
                        row.clone()
                    };
                    for i in order {
                        let (glyphs, adv) = &shaped[i];
                        let slot_w = (adv + 2.0 * pad_wx) * scale;
                        let at =
                            Transform::from_translate(x + pad_wx * scale, top + baseline_in_row)
                                .pre_scale(*scale, *scale);
                        placed[i] = Some(Placed {
                            start: shifted(chunk[i].start, offset),
                            end: shifted(chunk[i].end, offset),
                            glyphs: glyphs.clone().and_then(|p| p.transform(at)),
                            slot: Rect::from_xywh(x, top, slot_w.max(1.0), row_h).unwrap(),
                            ink_x: x + pad_wx * scale,
                            ink_w: adv * scale,
                            baseline: top + baseline_in_row,
                            em_top: top + baseline_in_row - ascent * k,
                            clusters: clusters[i]
                                .iter()
                                .filter_map(|c| c.clone().transform(at))
                                .collect(),
                            chars: texts[i].chars().count(),
                            index: first + i,
                            size: sizes[i] * scale,
                            key: sizes[i] > 1.0,
                        });
                        x += slot_w + sep * scale;
                    }
                    top += row_h;
                }
                let block = Rect::from_xywh(x0, y0, block_w.max(1.0), block_h.max(1.0)).unwrap();
                // Room for the pop to grow a word past its slot.
                let tallest = rows
                    .iter()
                    .zip(&scales)
                    .map(|(r, s)| height_of(r.2 * s, *s))
                    .fold(0.0, f32::max);
                let grow = inner_w.max(tallest) * lift(style.animation);
                Line {
                    first,
                    start: shifted(chunk.first().map_or(0.0, |w| w.start), offset),
                    end: shifted(chunk.last().map_or(0.0, |w| w.end), offset),
                    words: placed.into_iter().flatten().collect(),
                    block: (style.background != Background::None).then_some(block),
                    anchor: block,
                    bounds: pixel_bounds(block, margin(biggest) + grow, width, height),
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

    /// The box, as (x, y, width, height), outside which no frame of this scene ever has a pixel:
    /// every line's layer and the watermark. On even coordinates and of even size, the grain
    /// 4:2:2 and 4:2:0 video can be laid over at, and the whole frame when its own size is odd.
    /// A render sends this box for each frame rather than the picture of the whole.
    pub fn overlay_bounds(&self) -> (u32, u32, u32, u32) {
        let whole = (0, 0, self.width, self.height);
        if !self.width.is_multiple_of(2) || !self.height.is_multiple_of(2) {
            return whole;
        }
        let boxes = self
            .lines
            .iter()
            .map(|l| l.bounds)
            .chain(self.mark.as_ref().map(|m| m.rect));
        let Some((x0, y0, x1, y1)) = boxes.fold(None, |acc: Option<(i32, i32, i32, i32)>, r| {
            let r = (r.x(), r.y(), r.right(), r.bottom());
            Some(acc.map_or(r, |a| {
                (a.0.min(r.0), a.1.min(r.1), a.2.max(r.2), a.3.max(r.3))
            }))
        }) else {
            // Nothing is ever drawn: any box will do, and a small one is cheapest.
            return (0, 0, 2, 2);
        };
        let (x0, y0) = ((x0.max(0) & !1) as u32, (y0.max(0) & !1) as u32);
        let (x1, y1) = (
            (((x1 + 1) & !1) as u32).min(self.width),
            (((y1 + 1) & !1) as u32).min(self.height),
        );
        (x0, y0, (x1 - x0).max(2), (y1 - y0).max(2))
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
        let jolt = line.map_or([0.0; 2], |i| self.jolt(&self.lines[i], t));
        FrameKey(line, states, guide, jolt)
    }

    /// How far the line is knocked at `t`, in pixels: each word landing jolts it, along a fixed
    /// direction by its place in the transcript, the knock dying away to nothing (a polynomial
    /// envelope, not a sine, so every build agrees).
    fn jolt(&self, line: &Line, t: f32) -> [f32; 2] {
        if self.style.animation != Animation::WordSlam {
            return [0.0; 2];
        }
        let landed = |w: &Placed| w.start - LEAD_S + SLAM_S;
        let Some(w) = line
            .words
            .iter()
            .filter(|w| landed(w) <= t)
            .max_by(|a, b| landed(a).total_cmp(&landed(b)))
        else {
            return [0.0; 2];
        };
        let left = 1.0 - (t - landed(w)) / JOLT_S;
        if left <= 0.0 {
            return [0.0; 2];
        }
        let [dx, dy] = JOLT_DIRECTIONS[w.index % JOLT_DIRECTIONS.len()];
        let push = JOLT * self.style.font_size * left * left;
        [dx * push, dy * push]
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
                    radius: self.word_radius * lerp(from.size, to.size),
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
                    radius: 0.0,
                })
            }
            _ => None,
        }
    }

    fn draw(
        &self,
        canvas: &mut Pixmap,
        (index, line): (usize, &Line),
        states: &[WordState],
        guide: Option<Guide>,
        jolt: [f32; 2],
        cache: &mut LayerCache,
    ) {
        let s = &self.style;
        let pivot = |w: &Placed, st: &WordState| {
            let (cx, cy) = (
                w.slot.x() + w.slot.width() / 2.0,
                w.slot.y() + w.slot.height() / 2.0,
            );
            Transform::from_translate(-cx, -cy)
                .post_scale(st.scale, st.scale)
                .post_rotate(st.tilt)
                .post_translate(cx + jolt[0], cy + jolt[1])
        };
        // A solid shadow is an extrusion; `word_press` raises the word being said out of the page: its
        // face lifts away from where it was (the back of the extrusion stays put) and the extrusion
        // fills the gap, while the other words stay flat.
        let extruded =
            s.shadow_blur <= 0.0 && (s.shadow_offset_x != 0.0 || s.shadow_offset_y != 0.0);
        let pressing = extruded && s.animation == Animation::WordPress;
        let reach = |st: &WordState| {
            if pressing {
                st.press.clamp(0.0, 1.0)
            } else {
                1.0
            }
        };
        // How far the face has moved from the back, as a share of the offset (opposite to it).
        let lifted = |st: &WordState| if pressing { reach(st) } else { 0.0 };
        let face = |w: &Placed, st: &WordState| {
            let k = lifted(st);
            pivot(w, st).post_translate(
                -s.shadow_offset_x * w.size * k,
                -s.shadow_offset_y * w.size * k,
            )
        };
        if let Some(path) = line.block.and_then(|b| rounded_rect(b, self.block_radius)) {
            let p = paint(colour(s.background_color, s.background_opacity));
            canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
        }
        if s.animation == Animation::HighlightSlide
            && let Some(g) = guide
            && let Some(path) = Rect::from_xywh(g.rect[0], g.rect[1], g.rect[2], g.rect[3])
                .and_then(|r| rounded_rect(r, g.radius))
        {
            let p = paint(colour(s.primary(), g.alpha));
            canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
        }
        if s.animation == Animation::Stickers {
            for (w, st) in line.words.iter().zip(states) {
                if let Some(path) = rounded_rect(w.slot, self.word_radius * w.size * 1.6) {
                    let p = paint(colour(s.highlight(w.index), 1.0));
                    canvas.fill_path(&path, &p, FillRule::Winding, pivot(w, st), None);
                }
            }
        }
        if s.animation == Animation::HighlightBox {
            for (w, st) in line.words.iter().zip(states).filter(|(_, st)| st.on > 0.0) {
                if let Some(path) = rounded_rect(w.slot, self.word_radius * w.size) {
                    let p = paint(colour(s.highlight(w.index), st.on * st.opacity));
                    let grow = WordState {
                        scale: st.box_scale,
                        ..*st
                    };
                    canvas.fill_path(&path, &p, FillRule::Winding, pivot(w, &grow), None);
                }
            }
        }
        // `k` is the word's size against the style's: a key word's outline grows with it.
        let stroke = |k: f32| {
            (s.stroke_width > 0.0).then(|| Stroke {
                width: s.stroke_width * k,
                line_join: LineJoin::Round,
                line_cap: LineCap::Round,
                ..Stroke::default()
            })
        };
        // Stroke under fill, so a thick outline grows outward instead of eating the letter.
        let ink_with =
            |px: &mut Pixmap, path: &Path, fill: &Paint, edge: Color, at: Transform, k: f32| {
                if let Some(stroke) = &stroke(k) {
                    px.stroke_path(path, &paint(edge), stroke, at, None);
                }
                px.fill_path(path, fill, FillRule::Winding, at, None);
            };
        let ink =
            |px: &mut Pixmap, path: &Path, fill: Color, edge: Color, at: Transform, k: f32| {
                ink_with(px, path, &paint(fill), edge, at, k);
            };
        let (bx, by) = (line.bounds.x(), line.bounds.y());
        let local = |at: Transform| at.post_translate(-bx as f32, -by as f32);
        let layer = || Pixmap::new(line.bounds.width(), line.bounds.height());
        // The part of the frame one word's letters can touch, as a pixel box inside the line's:
        // their moved and scaled outline, room for the stroke and `reach` more for a blur. A word
        // is composited on its own, and a layer the size of the whole line for each of them,
        // cleared, drawn and blended, was most of the cost of a fade.
        let word_box = |path: &Path, w: &Placed, st: &WordState, reach: usize| -> Option<IntRect> {
            let b = path.bounds();
            let mut corners = [
                Point::from_xy(b.left(), b.top()),
                Point::from_xy(b.right(), b.top()),
                Point::from_xy(b.left(), b.bottom()),
                Point::from_xy(b.right(), b.bottom()),
            ];
            face(w, st).map_points(&mut corners);
            let (mut x0, mut y0, mut x1, mut y1) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
            for c in corners {
                (x0, y0, x1, y1) = (x0.min(c.x), y0.min(c.y), x1.max(c.x), y1.max(c.y));
            }
            let moved = Rect::from_ltrb(x0, y0, x1, y1)?;
            let r = pixel_bounds(
                moved,
                s.stroke_width + reach as f32 + 2.0,
                self.width,
                self.height,
            );
            let l = line.bounds;
            IntRect::from_ltrb(
                r.x().max(l.x()),
                r.y().max(l.y()),
                r.right().min(l.right()),
                r.bottom().min(l.bottom()),
            )
        };

        let solid = |c: Rgba| Rgba([c.0[0], c.0[1], c.0[2], 255]);
        let opacity = |c: Rgba| f32::from(c.0[3]) / 255.0;
        let rising = s.animation == Animation::LetterRise;
        let has_offset = s.shadow_offset_x != 0.0 || s.shadow_offset_y != 0.0;
        // The shadow and the glow are the letters as they stand: they change when a word's
        // opacity, size or tilt does, and for most animations they do not change at all while
        // the line is up, so the finished layer (blur and all) is kept for the next frame.
        let look: Vec<[u32; 5]> = states
            .iter()
            .map(|st| {
                [
                    st.opacity.to_bits(),
                    st.scale.to_bits(),
                    st.tilt.to_bits(),
                    st.press.to_bits(),
                    st.enter.to_bits(),
                ]
            })
            .collect();
        let key = (index, look);
        if s.shadow_blur > 0.0 || has_offset {
            if cache.shadow.as_ref().is_none_or(|(k, _)| *k != key) {
                cache.shadow = layer().map(|mut shadow| {
                    // A soft shadow is the letters once, moved and blurred. A hard one is the letters
                    // carried from where they are to the offset, a pixel at a time, so it reads as
                    // their outline extended (an extrusion) and not as a second copy behind them.
                    let base = solid(s.shadow_color);
                    let back = s.extrude_back.0;
                    let graded = back[3] > 0 && extruded;
                    let shaded = (s.extrude_shade > 0.0 || graded) && extruded;
                    for (w, st) in line.words.iter().zip(states) {
                        let letters = parts(w, st, s.font_size * w.size, rising);
                        let reach = reach(st);
                        if reach <= 0.0 {
                            continue;
                        }
                        let steps = if s.shadow_blur > 0.0 {
                            1
                        } else {
                            ((s.shadow_offset_x.abs().max(s.shadow_offset_y.abs()) * w.size * reach)
                                .ceil() as usize)
                                .clamp(1, 96)
                        };
                        // Shaded, the back goes down first and the front over it, so each pixel shows
                        // the nearest stamp that covers it and the colour deepens with the depth.
                        let order: Vec<usize> = if shaded {
                            (1..=steps).rev().collect()
                        } else {
                            (1..=steps).collect()
                        };
                        for step in order {
                            let depth = step as f32 / steps as f32;
                            let along = reach * depth - lifted(st);
                            let mut hue = base;
                            if shaded {
                                if graded {
                                    let end = Rgba([back[0], back[1], back[2], base.0[3]]);
                                    hue = mix(base, end, depth);
                                }
                                hue = mix(hue, Rgba([0, 0, 0, 255]), s.extrude_shade * depth);
                                if step == 1 {
                                    // The edge just behind the face catches the light.
                                    hue = mix(
                                        hue,
                                        Rgba([255, 255, 255, 255]),
                                        RIM_LIGHT * s.extrude_shade,
                                    );
                                }
                            }
                            for (path, down, shown) in &letters {
                                let c = colour(hue, st.opacity * shown);
                                let at = Transform::from_translate(0.0, *down)
                                    .post_concat(pivot(w, st))
                                    .post_translate(
                                        s.shadow_offset_x * w.size * along,
                                        s.shadow_offset_y * w.size * along,
                                    );
                                ink(&mut shadow, path, c, c, local(at), w.size);
                            }
                        }
                    }
                    if s.shadow_blur > 0.0 {
                        blur(&mut shadow, s.shadow_blur / 2.0);
                    }
                    (key.clone(), Trimmed::of(&shadow, (bx, by)))
                });
            }
            if let Some((_, Some(shadow))) = &cache.shadow {
                let p = PixmapPaint {
                    opacity: opacity(s.shadow_color),
                    ..PixmapPaint::default()
                };
                canvas.draw_pixmap(
                    shadow.x,
                    shadow.y,
                    shadow.pixmap.as_ref(),
                    &p,
                    Transform::identity(),
                    None,
                );
            }
        }
        if s.glow_blur > 0.0 {
            if cache.halo.as_ref().is_none_or(|(k, _)| *k != key) {
                cache.halo = layer().map(|mut halo| {
                    for (w, st) in line.words.iter().zip(states) {
                        for (path, down, shown) in parts(w, st, s.font_size * w.size, rising) {
                            let c = colour(solid(s.glow_color), st.opacity * shown);
                            let at = Transform::from_translate(0.0, down).post_concat(face(w, st));
                            ink(&mut halo, path, c, c, local(at), w.size);
                        }
                    }
                    blur(&mut halo, s.glow_blur / 2.0);
                    (key.clone(), Trimmed::of(&halo, (bx, by)))
                });
            }
            if let Some((_, Some(halo))) = &cache.halo {
                let p = PixmapPaint {
                    opacity: opacity(s.glow_color),
                    ..PixmapPaint::default()
                };
                for _ in 0..GLOW_PASSES {
                    canvas.draw_pixmap(
                        halo.x,
                        halo.y,
                        halo.pixmap.as_ref(),
                        &p,
                        Transform::identity(),
                        None,
                    );
                }
            }
        }

        // What of a word's letters shows, as a layer cut off at `x`: from the left edge of the
        // letters to there (typing), or the whole of it with the colour over only that much (filling).
        let cut = |x: f32, within: IntRect| {
            let mut mask = Mask::new(within.width(), within.height())?;
            let edge = Rect::from_ltrb(
                0.0,
                0.0,
                (x - within.x() as f32).max(0.0),
                within.height() as f32,
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
        // A word that has grown is drawn after the smaller ones, so it covers its neighbours rather
        // than slipping behind them (the sort is stable: words of one size keep their order).
        let mut order: Vec<usize> = (0..states.len()).collect();
        order.sort_by(|&a, &b| states[a].scale.total_cmp(&states[b].scale));
        for (w, st) in order.iter().map(|&i| (&line.words[i], &states[i])) {
            let Some(path) = &w.glyphs else { continue };
            // The underline is a marker stroke laid under the letters, left to right as the word is said.
            if s.animation == Animation::WordUnderline && st.fill > 0.0 {
                let thick = s.font_size * w.size * MARKER_THICK;
                let over = s.font_size * w.size * MARKER_OVERHANG;
                let stroke = Rect::from_xywh(
                    w.ink_x - over,
                    w.baseline - s.font_size * w.size * MARKER_RISE,
                    (w.ink_w * st.fill + 2.0 * over).max(1.0),
                    thick,
                );
                if let Some(band) = stroke.and_then(|r| rounded_rect(r, thick / 2.0)) {
                    let p = paint(colour(s.highlight(w.index), 1.0));
                    canvas.fill_path(&band, &p, FillRule::Winding, Transform::identity(), None);
                }
            }
            // The word's own paint: its colour, or the gradient over its letters, either turned
            // toward the highlight by `on` for the looks that light the word being said.
            let lit = match s.animation {
                Animation::WordHighlight
                | Animation::WordPop
                | Animation::WordBounce
                | Animation::LyricFocus
                | Animation::LetterRise
                | Animation::WordSlam
                | Animation::WordPress => st.on,
                Animation::None
                | Animation::HighlightBox
                | Animation::HighlightSlide
                | Animation::LineBar
                | Animation::Stickers
                | Animation::WordFade
                | Animation::WordSweep
                | Animation::WordUnderline
                | Animation::Typewriter => 0.0,
            };
            // A key word is always in its highlight colour.
            let lit = if w.key { 1.0 } else { lit };
            let tint = |c: Rgba| mix(c, s.highlight(w.index), lit);
            let fill = match gradient_stops(&s.fill_colors, &tint) {
                Some(stops) => LinearGradient::new(
                    Point::from_xy(w.ink_x, w.em_top),
                    Point::from_xy(w.ink_x, w.baseline),
                    stops,
                    SpreadMode::Pad,
                    Transform::identity(),
                )
                .map_or_else(
                    || paint(colour(tint(s.fill_colors[0]), 1.0)),
                    |shader| Paint {
                        shader,
                        anti_alias: true,
                        ..Paint::default()
                    },
                ),
                None => paint(colour(
                    tint(s.fill_colors.first().copied().unwrap_or(s.text_color)),
                    1.0,
                )),
            };
            let edge = colour(s.stroke_color, 1.0);
            if s.animation == Animation::WordSweep && st.fill > 0.0 {
                // Each letter is painted once: the highlight on the side the sweep has passed, the
                // plain colour on the rest. Painting the highlight over a finished plain word would
                // leave the plain word's soft edge showing round it, a pale fringe.
                let (on, at) = (sweep(), face(w, st));
                if st.fill >= 1.0 {
                    ink_with(canvas, path, &on, edge, at, w.size);
                } else if let Some(within) = word_box(path, w, st, 0)
                    && let (Some(mut passed), Some(mut ahead), Some(mask)) = (
                        Pixmap::new(within.width(), within.height()),
                        Pixmap::new(within.width(), within.height()),
                        cut(w.ink_x + w.ink_w * st.fill, within),
                    )
                {
                    let at = at.post_translate(-within.x() as f32, -within.y() as f32);
                    ink_with(&mut passed, path, &on, edge, at, w.size);
                    passed.apply_mask(&mask);
                    ink_with(&mut ahead, path, &fill, edge, at, w.size);
                    let mut rest = mask;
                    rest.invert();
                    ahead.apply_mask(&rest);
                    let p = PixmapPaint::default();
                    for half in [&passed, &ahead] {
                        canvas.draw_pixmap(
                            within.x(),
                            within.y(),
                            half.as_ref(),
                            &p,
                            Transform::identity(),
                            None,
                        );
                    }
                }
                continue;
            }
            if rising && st.enter < 1.0 {
                // The letters that have started, each climbing and fading in on its own.
                for (part, down, shown) in parts(w, st, s.font_size * w.size, true) {
                    let reach = (s.font_size * w.size * RISE_FROM).ceil() as usize + 2;
                    if let Some(within) = word_box(part, w, st, reach)
                        && let Some(mut group) = Pixmap::new(within.width(), within.height())
                    {
                        let at = Transform::from_translate(0.0, down)
                            .post_concat(face(w, st))
                            .post_translate(-within.x() as f32, -within.y() as f32);
                        ink_with(&mut group, part, &fill, edge, at, w.size);
                        let p = PixmapPaint {
                            opacity: st.opacity * shown,
                            ..PixmapPaint::default()
                        };
                        canvas.draw_pixmap(
                            within.x(),
                            within.y(),
                            group.as_ref(),
                            &p,
                            Transform::identity(),
                            None,
                        );
                    }
                }
                continue;
            }
            let typed = s.animation == Animation::Typewriter;
            if typed && st.fill <= 0.0 {
                continue;
            }
            if st.opacity >= 1.0 && st.soften <= 0.0 && !(typed && st.fill < 1.0) {
                ink_with(canvas, path, &fill, edge, face(w, st), w.size);
            } else {
                let sigma = st.soften * s.font_size * w.size * FOCUS_BLUR;
                let reach = if st.soften > 0.0 {
                    blur_reach(sigma)
                } else {
                    0
                };
                if let Some(within) = word_box(path, w, st, reach)
                    && let Some(mut group) = Pixmap::new(within.width(), within.height())
                {
                    // Composited as one group, like CSS opacity, so the stroke under
                    // the fill does not show through a translucent letter.
                    let at = face(w, st).post_translate(-within.x() as f32, -within.y() as f32);
                    ink_with(&mut group, path, &fill, edge, at, w.size);
                    if typed && let Some(mask) = cut(w.ink_x + w.ink_w * st.fill, within) {
                        group.apply_mask(&mask);
                    }
                    if st.soften > 0.0 {
                        blur(&mut group, sigma);
                    }
                    let p = PixmapPaint {
                        opacity: st.opacity,
                        ..PixmapPaint::default()
                    };
                    canvas.draw_pixmap(
                        within.x(),
                        within.y(),
                        group.as_ref(),
                        &p,
                        Transform::identity(),
                        None,
                    );
                }
            }
            match s.animation {
                Animation::Typewriter if st.on > 0.0 => {
                    // The cursor sits where the next letter goes, for as long as the word is being said.
                    let width = (s.font_size * w.size * 0.07).max(2.0);
                    let cursor = Rect::from_xywh(
                        w.ink_x + w.ink_w * st.fill,
                        w.baseline - s.font_size * w.size * 0.78,
                        width,
                        s.font_size * w.size * 0.92,
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
/// The finished shadow and glow layers of the line last drawn, with what they were made from.
#[derive(Default)]
struct LayerCache {
    shadow: Option<(LayerKey, Option<Trimmed>)>,
    halo: Option<(LayerKey, Option<Trimmed>)>,
}

/// A finished layer cut down to the box that holds its ink, and where that box goes in the
/// frame: blending the rest, which is transparent, changes nothing and cost most of the time.
struct Trimmed {
    pixmap: Pixmap,
    x: i32,
    y: i32,
}

impl Trimmed {
    /// `layer`, which sits at `origin` in the frame; None when it holds no ink.
    fn of(layer: &Pixmap, origin: (i32, i32)) -> Option<Self> {
        let (w, h) = (layer.width() as usize, layer.height() as usize);
        let (left, top, right, bottom) = ink_extent(layer.data(), w, h)?;
        let rect = IntRect::from_xywh(
            left as i32,
            top as i32,
            (right - left) as u32,
            (bottom - top) as u32,
        )?;
        Some(Self {
            pixmap: layer.clone_rect(rect)?,
            x: origin.0 + left as i32,
            y: origin.1 + top as i32,
        })
    }
}

/// A line, and each of its words' opacity, size, tilt and press: all the layers depend on.
type LayerKey = (usize, Vec<[u32; 5]>);

/// How many sub-frames the shutter averages when something moves within it.
const BLUR_SAMPLES: usize = 8;

pub struct Renderer {
    layers: LayerCache,
    scene: Scene,
    canvas: Pixmap,
    rgba: Vec<u8>,
    /// What the last frame was made from: the keys of its sub-frames (a single one when nothing
    /// moved within the shutter), the first being the frame's own time.
    last: Option<Vec<FrameKey>>,
    /// The frame a sub-frame is drawn on before it is added to the average.
    scratch: Option<Pixmap>,
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
            layers: LayerCache::default(),
            canvas: Pixmap::new(w, h).expect("frame dimensions are validated and non-zero"),
            rgba: vec![0; (w * h * 4) as usize],
            scene,
            last: None,
            scratch: None,
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

    /// The keys of the sub-frames the shutter opens over before `t`, `t`'s own first: just that
    /// one when none of them differs, so a still frame costs a single draw.
    fn sample_keys(&self, t: f32) -> Vec<FrameKey> {
        let mut keys = vec![self.scene.key(t)];
        let shutter = self.scene.style.motion_blur / 30.0;
        if shutter > 0.0 {
            for k in 1..BLUR_SAMPLES {
                keys.push(
                    self.scene
                        .key(t - shutter * k as f32 / (BLUR_SAMPLES - 1) as f32),
                );
            }
            if keys.iter().all(|key| *key == keys[0]) {
                keys.truncate(1);
            }
        }
        keys
    }

    /// Draws every sub-frame in `keys` over `area` and puts their average onto the canvas.
    /// Integer sums of premultiplied bytes, so every build averages alike.
    fn draw_blurred(&mut self, keys: &[FrameKey], area: IntRect) {
        let width = self.scene.width;
        let mut scratch = self.scratch.take().unwrap_or_else(|| {
            Pixmap::new(width, self.scene.height).expect("frame dimensions are validated")
        });
        let row_len = area.width() as usize * 4;
        let mut sum = vec![0u32; row_len * area.height() as usize];
        for key in keys {
            for span in rows(area, width) {
                scratch.data_mut()[span].fill(0);
            }
            if let Some(i) = key.0 {
                let line = &self.scene.lines[i];
                self.scene.draw(
                    &mut scratch,
                    (i, line),
                    &key.1,
                    key.2,
                    key.3,
                    &mut self.layers,
                );
            }
            for (row, span) in sum.chunks_mut(row_len).zip(rows(area, width)) {
                for (acc, byte) in row.iter_mut().zip(&scratch.data()[span]) {
                    *acc += u32::from(*byte);
                }
            }
        }
        let n = keys.len() as u32;
        for (row, span) in sum.chunks(row_len).zip(rows(area, width)) {
            for (byte, acc) in self.canvas.data_mut()[span].iter_mut().zip(row) {
                *byte = ((acc + n / 2) / n) as u8;
            }
        }
        self.scratch = Some(scratch);
    }

    /// Bring the frame to time `t`; returns whether any pixel changed.
    pub fn render(&mut self, t: f32) -> bool {
        let keys = self.sample_keys(t);
        if self.last.as_ref() == Some(&keys) {
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
        // Where the frame draws: its line's box, or the union of the boxes of the lines the
        // shutter saw (one arriving or leaving within it).
        let area = keys
            .iter()
            .filter_map(|k| k.0)
            .map(|i| self.scene.lines[i].bounds)
            .reduce(|a, b| {
                IntRect::from_ltrb(
                    a.x().min(b.x()),
                    a.y().min(b.y()),
                    a.right().max(b.right()),
                    a.bottom().max(b.bottom()),
                )
                .unwrap_or(a)
            });
        // The watermark is drawn again, over whatever it overlaps, when a caption clears or draws
        // where it is; otherwise it is left as it is.
        let mark = self.scene.mark.as_ref().map(|m| m.rect);
        let mut redraw_mark = false;
        if let Some(r) = self.dirty {
            grow(r);
            redraw_mark |= mark.is_some_and(|m| overlaps(r, m));
        }
        if let Some(bounds) = area {
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
        if let Some(bounds) = area {
            if keys.len() > 1 {
                self.draw_blurred(&keys, bounds);
            } else if let Some(i) = keys[0].0 {
                let line = &self.scene.lines[i];
                let key = &keys[0];
                self.scene.draw(
                    &mut self.canvas,
                    (i, line),
                    &key.1,
                    key.2,
                    key.3,
                    &mut self.layers,
                );
            }
            unpremultiply(self.canvas.data(), &mut self.rgba, bounds, width);
            self.dirty = Some(bounds);
        }
        if redraw_mark {
            self.draw_mark();
        }
        self.last = Some(keys);
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

    /// Index of the active line among all lines.
    pub fn active_index(&self) -> Option<usize> {
        self.last.as_ref()?.first()?.0
    }

    /// Flat index of the active line's first word, so the editor can map a word back to the
    /// transcript: word N of the line is transcript word `first + N`.
    pub fn active_first_word(&self) -> Option<usize> {
        Some(self.scene.lines[self.active_index()?].first)
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
            "shadow_blur": 0, "shadow_color": "#00000000",
            // Off unless a case asks, so the cases that predate it still pin what they pinned.
            "motion_blur": 0
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

    fn blurred(animation: &str, motion_blur: f32) -> Renderer {
        let patch = serde_json::json!({ "motion_blur": motion_blur });
        Renderer::new(Scene::new(&book(), styled(animation, WORDS, patch)))
    }

    /// How many pixels are neither clear nor solid: the soft edges and the smears.
    fn partial(rgba: &[u8]) -> usize {
        rgba.chunks(4).filter(|p| p[3] != 0 && p[3] != 255).count()
    }

    #[test]
    fn a_moving_word_leaves_a_trail_along_its_path() {
        // word_pop scales the word up as it starts: the shutter sees it smaller a moment ago.
        let t = 0.52;
        let (mut sharp, mut smeared) = (blurred("word_pop", 0.0), blurred("word_pop", 1.0));
        sharp.render(t);
        smeared.render(t);
        assert_ne!(
            sharp.rgba(),
            smeared.rgba(),
            "the shutter changed the frame"
        );
        assert!(
            partial(smeared.rgba()) > partial(sharp.rgba()),
            "the trail is made of partial alpha"
        );
    }

    #[test]
    fn a_still_frame_is_the_same_with_or_without_blur() {
        // Mid-word, nothing moves within the shutter: one draw, byte for byte the sharp one.
        for animation in ["none", "word_highlight", "highlight_box", "word_pop"] {
            let (mut sharp, mut smeared) = (blurred(animation, 0.0), blurred(animation, 1.0));
            sharp.render(0.3);
            smeared.render(0.3);
            assert_eq!(sharp.rgba(), smeared.rgba(), "{animation}");
        }
    }

    #[test]
    fn a_blurred_frame_reaches_the_next_and_back_without_leaving_traces() {
        let mut r = blurred("word_bounce", 1.0);
        let times = [0.52, 0.3, 0.505, 2.5];
        for t in times {
            r.render(t);
            let mut fresh = blurred("word_bounce", 1.0);
            fresh.render(t);
            assert_eq!(r.rgba(), fresh.rgba(), "t = {t}");
        }
        assert!(r.rgba().iter().all(|&b| b == 0), "cleared after the line");
    }

    #[test]
    fn a_blurred_second_of_full_frames_stays_cheap() {
        let mut r = blurred("word_bounce", 1.0);
        let start = std::time::Instant::now();
        for i in 0..30 {
            r.render(0.4 + i as f32 / 30.0);
        }
        let took = start.elapsed();
        println!("30 blurred frames: {took:?}");
        // A loose ceiling in an unoptimised build; the release build is several times faster.
        assert!(took.as_secs_f32() < 15.0, "{took:?}");
    }

    fn lone(animation: &str, patch: serde_json::Value) -> Renderer {
        let mut patch = patch;
        patch["motion_blur"] = 0.into();
        Renderer::new(Scene::new(
            &book(),
            styled(animation, &[("HELLO", 0.0, 1.0)], patch),
        ))
    }

    /// The mean colour of the solid pixels of rows `rows`.
    fn mean_colour(r: &Renderer, rows: std::ops::Range<usize>) -> [f32; 3] {
        let (mut sum, mut n) = ([0.0f32; 3], 0.0f32);
        for y in rows {
            for px in r.rgba()[y * 1080 * 4..(y + 1) * 1080 * 4].chunks(4) {
                if px[3] == 255 {
                    (0..3).for_each(|c| sum[c] += f32::from(px[c]));
                    n += 1.0;
                }
            }
        }
        sum.map(|v| v / n.max(1.0))
    }

    #[test]
    fn a_gradient_fill_runs_from_the_first_colour_at_the_top_to_the_last_at_the_baseline() {
        let patch = serde_json::json!({ "fill_colors": ["#FF0000", "#0000FF"], "font_size": 200 });
        let mut r = lone("none", patch);
        r.render(0.5);
        let (_, _, top, bottom) = extent(&r, 1080).unwrap();
        let fifth = (bottom - top) / 5;
        let up = mean_colour(&r, top..top + fifth);
        let down = mean_colour(&r, bottom - fifth..bottom);
        // The letters start below the em box's top, so the top of the ink is not quite the first colour.
        assert!(up[0] > up[2] + 50.0, "red at the top: {up:?}");
        assert!(down[2] > down[0] + 50.0, "blue at the bottom: {down:?}");
        let mut flat = lone("none", serde_json::json!({ "font_size": 200 }));
        flat.render(0.5);
        assert_ne!(flat.rgba(), r.rgba());
    }

    #[test]
    fn an_extrusion_fades_from_its_colour_to_the_back_colour() {
        let patch = serde_json::json!({
            "shadow_color": "#FF0000", "extrude_back": "#0000FF", "shadow_offset_y": 60,
            "stroke_width": 0, "text_color": "#000000"
        });
        let mut r = lone("none", patch);
        r.render(0.5);
        let mut face = lone("none", serde_json::json!({ "text_color": "#000000" }));
        face.render(0.5);
        let flat = extent(&face, 1080).unwrap().3;
        let back = extent(&r, 1080).unwrap().3;
        let span = back - flat;
        let near = mean_colour(&r, flat + 4..flat + 4 + span / 3);
        let far = mean_colour(&r, back - span / 3..back);
        assert!(
            near[0] > far[0] + 60.0,
            "red near the face: {near:?} {far:?}"
        );
        assert!(
            far[2] > near[2] + 60.0,
            "blue at the back: {near:?} {far:?}"
        );
    }

    #[test]
    fn an_extrusion_darkens_with_depth_only_when_shaded() {
        let still = |shade: f32| {
            let patch = serde_json::json!({
                "shadow_color": "#FFAA00", "shadow_offset_y": 60, "extrude_shade": shade,
                "text_color": "#000000"
            });
            let mut r = lone("none", patch);
            r.render(0.5);
            r
        };
        let flat_face = {
            let mut r = lone("none", serde_json::json!({ "text_color": "#000000" }));
            r.render(0.5);
            extent(&r, 1080).unwrap().3
        };
        for (shade, darkens) in [(0.0, false), (1.0, true)] {
            let r = still(shade);
            let back = extent(&r, 1080).unwrap().3;
            let span = back - flat_face;
            assert!(span > 20, "there is an extrusion to measure: {span}");
            let near = mean_colour(&r, flat_face + 4..flat_face + 4 + span / 3);
            let far = mean_colour(&r, back - span / 3..back);
            assert_eq!(
                near[0] > far[0] + 30.0,
                darkens,
                "shade {shade}: {near:?} then {far:?}"
            );
        }
    }

    #[test]
    fn a_pressed_word_lifts_its_face_off_a_back_that_stays_put() {
        let patch = serde_json::json!({
            "shadow_color": "#C2410C", "shadow_offset_y": 60, "stroke_width": 0
        });
        let mut pressed = lone("word_press", patch.clone());
        // The same word with no extrusion: the face where the back is.
        let mut flat = lone(
            "word_highlight",
            serde_json::json!({ "shadow_offset_y": 0, "stroke_width": 0 }),
        );
        pressed.render(0.5);
        flat.render(0.5);
        let (a, b) = (
            extent(&pressed, 1080).unwrap(),
            extent(&flat, 1080).unwrap(),
        );
        let travel = 60.0 * 1920.0 / REF_HEIGHT;
        assert!(
            a.3.abs_diff(b.3) <= 3,
            "the back stays where the flat word was: {a:?} {b:?}"
        );
        assert!(
            ((b.2 as f32 - a.2 as f32) - travel).abs() < 4.0,
            "the face lifted by the offset: {} rows, not {travel}",
            b.2 as f32 - a.2 as f32
        );
    }

    fn rising(words: &[(&str, f32, f32)]) -> Renderer {
        let patch = serde_json::json!({ "font_size": 120, "motion_blur": 0 });
        Renderer::new(Scene::new(&book(), styled("letter_rise", words, patch)))
    }

    /// The first row with ink in the columns `from..to` of the current frame.
    fn top_of(r: &Renderer, from: usize, to: usize) -> Option<usize> {
        (0..1920).find(|&y| (from..to).any(|x| r.rgba()[(y * 1080 + x) * 4 + 3] > 0))
    }

    #[test]
    fn the_letters_of_a_word_rise_one_after_another() {
        let mut r = rising(&[("HELLO", 0.0, 1.0)]);
        // Partway through the entrance, the first letters are up and the last are still low.
        r.render(0.06);
        let scene = r.scene();
        let word = &scene.lines[0].words[0];
        assert_eq!(word.clusters.len(), 5, "one outline a letter");
        let cols: Vec<(usize, usize)> = word
            .clusters
            .iter()
            .map(|c| (c.bounds().left() as usize, c.bounds().right() as usize))
            .collect();
        let tops: Vec<Option<usize>> = cols.iter().map(|&(a, b)| top_of(&r, a, b)).collect();
        let first = tops[0].expect("the first letter has started");
        assert!(
            tops[4].is_none_or(|last| last > first),
            "the last letter is lower than the first, or not there yet: {tops:?}"
        );
        assert!(
            tops.iter()
                .flatten()
                .collect::<std::collections::HashSet<_>>()
                .len()
                > 1
                || tops.iter().any(Option::is_none),
            "the letters are at different heights: {tops:?}"
        );
        // And in the end they are all in place, as the plain word.
        r.render(0.9);
        let rest = r.rgba().to_vec();
        let mut plain = rising(&[("HELLO", 0.0, 1.0)]);
        plain.render(0.9);
        assert_eq!(rest, plain.rgba());
        assert!(rest.iter().any(|&b| b != 0));
    }

    #[test]
    fn nothing_of_a_word_is_drawn_before_it_starts() {
        let mut r = rising(&[("one", 0.0, 0.5), ("two", 0.5, 1.0)]);
        r.render(0.3);
        let rects = r.active_word_rects();
        let (x, y, w, h) = rects[1];
        let any = (y as usize..(y + h) as usize).any(|row| {
            (x as usize..(x + w) as usize).any(|col| r.rgba()[(row * 1080 + col) * 4 + 3] > 0)
        });
        assert!(!any, "the second word is not there yet");
        r.render(0.9);
        let any = (y as usize..(y + h) as usize).any(|row| {
            (x as usize..(x + w) as usize).any(|col| r.rgba()[(row * 1080 + col) * 4 + 3] > 0)
        });
        assert!(any, "and then it is");
    }

    #[test]
    fn a_word_of_a_connected_script_is_one_piece() {
        let mut b = book();
        for font in [
            &include_bytes!("../fonts/NotoSansArabic.ttf")[..],
            include_bytes!("../fonts/NotoSansDevanagari.ttf"),
            include_bytes!("../fonts/NotoSansThai.ttf"),
        ] {
            b.add(font).unwrap();
        }
        let pieces =
            |family: &str, text: &str| cluster_paths(b.face(b.primary(family)), text, 64.0).len();
        assert_eq!(pieces("Inter", "HELLO"), 5);
        assert_eq!(pieces("Noto Sans Arabic", "مرحبا"), 1);
        assert_eq!(pieces("Noto Sans Devanagari", "नमस्ते"), 1);
        assert_eq!(pieces("Noto Sans Thai", "สวัสดี"), 1);
    }

    const FIGURES: &[(&str, f32, f32)] = &[
        ("we", 0.0, 0.4),
        ("grew", 0.4, 0.8),
        ("40", 0.8, 1.2),
        ("percent", 1.2, 1.6),
    ];

    fn emphasised(scale: f32) -> Scene {
        let patch = serde_json::json!({
            "emphasis_scale": scale, "words_per_line": 4, "motion_blur": 0
        });
        Scene::new(&book(), styled("none", FIGURES, patch))
    }

    #[test]
    fn a_key_word_is_larger_and_alone_on_its_row() {
        let scene = emphasised(1.5);
        let words = &scene.lines[0].words;
        let row = |i: usize| words[i].slot.y();
        // "we grew" share a row, "40" has its own, and so does "percent" under it.
        assert_eq!(row(0), row(1));
        assert!(row(2) > row(0) && row(3) > row(2), "three rows, in order");
        assert_eq!(words[2].size, 1.5);
        assert_eq!(words[0].size, 1.0);
        let height = |i: usize| words[i].glyphs.as_ref().unwrap().bounds().height();
        assert!(height(2) > 1.3 * height(0), "the key word is set larger");
        assert!(
            words[2].slot.height() > 1.3 * words[0].slot.height(),
            "and its row is taller"
        );
        // Off, the same words are one row at one size.
        let flat = emphasised(1.0);
        assert!(
            flat.lines[0]
                .words
                .iter()
                .all(|w| w.size == 1.0 && w.slot.y() == flat.lines[0].words[0].slot.y())
        );
        // The captions are the same ones: emphasis splits rows, never captions.
        assert_eq!(scene.lines.len(), flat.lines.len());
        assert_eq!(scene.lines[0].start, flat.lines[0].start);
    }

    #[test]
    fn a_word_the_user_marks_is_the_key_word_whatever_the_rule_says() {
        let mut input = styled(
            "none",
            FIGURES,
            serde_json::json!({ "emphasis_scale": 2.0, "words_per_line": 4 }),
        );
        for w in input
            .transcript
            .segments
            .iter_mut()
            .flat_map(|s| &mut s.words)
        {
            // Clear the figure the rule would pick and mark the first word instead.
            w.emphasis = match w.text.as_str() {
                "we" => Some(true),
                "40" => Some(false),
                _ => None,
            };
        }
        let scene = Scene::new(&book(), input);
        let sizes: Vec<f32> = scene.lines[0].words.iter().map(|w| w.size).collect();
        assert_eq!(sizes, [2.0, 1.0, 1.0, 1.0]);
    }

    fn slamming() -> Scene {
        let patch = serde_json::json!({ "font_size": 100, "motion_blur": 0 });
        Scene::new(&book(), styled("word_slam", WORDS, patch))
    }

    #[test]
    fn a_slammed_word_starts_large_and_invisible_and_lands_at_rest() {
        let scene = slamming();
        // The second word starts at 0.5: before that it is not there at all.
        let before = &scene.key(0.2).1[1];
        assert_eq!(before.opacity, 0.0, "hidden until said");
        let start = &scene.key(0.5 - LEAD_S + 0.01).1[1];
        assert!(
            start.scale > 1.5,
            "it drops in from well over its size: {}",
            start.scale
        );
        assert!(start.opacity > 0.0 && start.opacity < 1.0);
        let landed = &scene.key(0.5 - LEAD_S + SLAM_S + 0.01).1[1];
        assert_eq!((landed.scale, landed.opacity), (1.0, 1.0));
        // With no overshoot: it never goes under its resting size on the way.
        for step in 0..=24 {
            let t = 0.48 + step as f32 * 0.005;
            assert!(scene.key(t).1[1].scale >= 1.0, "t = {t}");
        }
    }

    #[test]
    fn the_line_jolts_when_a_word_lands_and_is_still_again_after() {
        let scene = slamming();
        let line = &scene.lines[0];
        let landing = 0.5 - LEAD_S + SLAM_S;
        let at = |dt: f32| scene.jolt(line, landing + dt);
        assert_eq!(at(-0.05), scene.jolt(line, 0.3), "nothing new has landed");
        let hit = at(0.01);
        let size = scene.style.font_size;
        let push = (hit[0] * hit[0] + hit[1] * hit[1]).sqrt();
        assert!(
            push > 0.0 && push < 0.05 * size * 1.2,
            "a small knock: {push}"
        );
        let later = at(0.07);
        assert!(
            (later[0].abs() + later[1].abs()) < (hit[0].abs() + hit[1].abs()),
            "it dies away"
        );
        assert_eq!(at(JOLT_S + 0.001), [0.0, 0.0]);
        // The jolt is in the frame's identity, so the frame is drawn again as it moves.
        assert!(scene.key(landing + 0.01) != scene.key(landing + 0.02));
    }

    const POSTER: &[(&str, f32, f32)] = &[
        ("MAKE", 0.0, 0.4),
        ("IT", 0.4, 0.8),
        ("BIG", 0.8, 1.2),
        ("AND", 1.2, 1.6),
        ("BOLD", 1.6, 2.0),
    ];

    fn stacked(animation: &str, words: &[(&str, f32, f32)], patch: serde_json::Value) -> Scene {
        let mut patch = patch;
        patch["layout"] = "stack".into();
        patch["words_per_line"] = 5.into();
        patch["motion_blur"] = 0.into();
        Scene::new(&book(), styled(animation, words, patch))
    }

    /// The rows of a line as lists of the words on them, top to bottom.
    fn rows_of(scene: &Scene) -> Vec<Vec<&Placed>> {
        let mut rows: Vec<Vec<&Placed>> = vec![];
        for w in &scene.lines[0].words {
            match rows.last_mut() {
                Some(row) if row[0].slot.y() == w.slot.y() => row.push(w),
                _ => rows.push(vec![w]),
            }
        }
        rows
    }

    #[test]
    fn in_a_stack_every_row_is_as_wide_as_the_widest() {
        let scene = stacked("none", POSTER, serde_json::json!({}));
        let rows = rows_of(&scene);
        assert!(rows.len() >= 2, "the words are cut into several rows");
        let width = |row: &Vec<&Placed>| {
            let (first, last) = (row[0], row[row.len() - 1]);
            last.ink_x + last.ink_w - first.ink_x
        };
        let widest = rows.iter().map(width).fold(0.0, f32::max);
        // The row that was widest is as it was; the others are scaled up to it.
        for row in &rows {
            assert!(
                (width(row) - widest).abs() < 2.0 || row[0].size >= 3.0,
                "{} against {widest}",
                width(row)
            );
        }
        assert!(
            rows.iter().any(|r| r[0].size > 1.1),
            "a narrower row is scaled up: {:?}",
            rows.iter()
                .map(|r| (r.len(), r[0].size))
                .collect::<Vec<_>>()
        );
        // Stacked tight: a row begins about where the one above ends.
        let ys: Vec<f32> = rows.iter().map(|r| r[0].slot.y()).collect();
        assert!(ys.windows(2).all(|p| p[1] > p[0]));
    }

    #[test]
    fn a_stack_scales_a_short_row_by_three_at_most() {
        let words = [("I", 0.0, 0.4), ("EXTRAORDINARILY", 0.4, 1.0)];
        let scene = stacked("none", &words, serde_json::json!({}));
        let rows = rows_of(&scene);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0][0].size, 3.0, "the cap holds");
        assert_eq!(rows[1][0].size, 1.0, "the widest row is as it is");
        assert!(scene.lines[0].words.iter().all(|w| w.size <= 3.0));
    }

    #[test]
    fn every_animation_draws_inside_the_lines_bounds_in_a_stack() {
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
            "word_press",
            "letter_rise",
            "word_slam",
        ] {
            let patch = serde_json::json!({
                "emphasis_scale": 1.4, "stroke_width": 4, "stroke_color": "#000000",
                "shadow_blur": 6, "shadow_color": "#000000B0"
            });
            let scene = stacked(anim, POSTER, patch);
            let bounds = scene.lines[0].bounds;
            let mut r = Renderer::new(scene);
            for t in [0.1, 0.45, 0.9, 1.3, 1.9] {
                r.render(t);
                let Some((l, rt, tp, bt)) = extent(&r, 1080) else {
                    continue;
                };
                assert!(
                    l as i32 >= bounds.x()
                        && rt as i32 <= bounds.right()
                        && tp as i32 >= bounds.y()
                        && bt as i32 <= bounds.bottom(),
                    "{anim} at {t}: ink {:?} outside {:?}",
                    (l, rt, tp, bt),
                    bounds
                );
            }
            r.render(0.9);
            assert!(extent(&r, 1080).is_some(), "{anim} drew nothing");
        }
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
    fn a_long_pause_ends_a_caption_instead_of_joining_words_minutes_apart() {
        let words = [
            ("one", 0.0, 0.5),
            ("two", 0.5, 1.0),
            ("three", 90.0, 90.5),
            ("four", 90.5, 91.0),
            ("five", 91.0, 91.5),
        ];
        let mut r = Renderer::new(Scene::new(&book(), input("word_highlight", &words, 3)));
        r.render(0.3);
        assert_eq!(r.active_first_word(), Some(0));
        assert_eq!(r.active_word_rects().len(), 2, "one two, not three");
        r.render(45.0);
        assert_eq!(
            r.active_index(),
            None,
            "nothing hangs on through the silence"
        );
        r.render(90.2);
        assert_eq!(r.active_index(), Some(1));
        assert_eq!(r.active_first_word(), Some(2), "word N of it is word 2 + N");
        assert_eq!(r.active_word_rects().len(), 3, "three four five");
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
    fn a_block_wider_than_the_frame_spills_over_both_sides_not_one() {
        for x in [0.0, 0.5, 1.0] {
            let mut i = input("word_highlight", WORDS, 1);
            i.style.font_size = 900.0;
            i.style.position_x = x;
            let mut r = Renderer::new(Scene::new(&book(), i));
            r.render(0.3);
            let (bx, _, bw, _) = r.active_bounds().unwrap();
            assert!(bw > 1080.0, "the word is wider than the frame ({bw})");
            assert!(
                (bx + bw / 2.0 - 540.0).abs() < 1.0,
                "centred on the frame whatever position_x is ({x}): starts at {bx}"
            );
        }
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
        assert!(a.scale > 1.1 && b.scale > 1.1, "both are larger while said");
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
        assert_eq!(now.scale, 1.0, "the word being said does not grow");
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
            "word_press",
            "letter_rise",
            "word_slam",
        ] {
            let mut r = Renderer::new(Scene::new(&book(), input(anim, WORDS, 3)));
            r.render(0.6);
            assert!(r.rgba().iter().any(|&b| b != 0), "{anim} drew nothing");
        }
    }

    /// FNV-1a over a frame's bytes: a fingerprint of every pixel.
    fn fingerprint(bytes: &[u8], mut h: u64) -> u64 {
        for &b in bytes {
            h = (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3);
        }
        h
    }

    /// The frame times a golden case is drawn at, in order, as a player would reach them.
    const GOLDEN_TIMES: [f32; 5] = [0.0, 0.25, 0.6, 1.2, 3.2];

    /// Draws a scene through `GOLDEN_TIMES` and returns one fingerprint of all the frames,
    /// after checking that each frame, drawn on the renderer that kept the last one, is the
    /// frame a fresh renderer draws at that time: the incremental redraw changes nothing.
    fn golden(mut input: SceneInput) -> u64 {
        // Half size: layout is proportional to the frame's height, so this is the same
        // picture, a quarter of the pixels.
        (input.width, input.height) = (540, 960);
        let book = book();
        let mut kept = Renderer::new(Scene::new(&book, input.clone()));
        let mut all = 0xcbf2_9ce4_8422_2325;
        for t in GOLDEN_TIMES {
            kept.render(t);
            let mut fresh = Renderer::new(Scene::new(&book, input.clone()));
            fresh.render(t);
            assert!(
                kept.rgba() == fresh.rgba(),
                "the frame at {t} s differs between an incremental and a fresh redraw"
            );
            all = fingerprint(kept.rgba(), all);
        }
        all
    }

    /// Every look the engine can draw, as (name, style patch, animation).
    fn golden_cases() -> Vec<(String, SceneInput)> {
        let mut cases = Vec::new();
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
            "word_press",
            "letter_rise",
            "word_slam",
        ] {
            cases.push((anim.to_string(), styled(anim, WORDS, serde_json::json!({}))));
        }
        let effects = [
            (
                "stroke",
                serde_json::json!({ "stroke_width": 6, "stroke_color": "#000000" }),
            ),
            (
                "hard_shadow",
                serde_json::json!({
                    "stroke_width": 4, "stroke_color": "#000000", "shadow_blur": 0,
                    "shadow_color": "#000000", "shadow_offset_x": 8, "shadow_offset_y": 10
                }),
            ),
            (
                "blur_shadow",
                serde_json::json!({
                    "shadow_blur": 12, "shadow_color": "#000000CC",
                    "shadow_offset_x": 4, "shadow_offset_y": 6
                }),
            ),
            (
                "glow",
                serde_json::json!({ "glow_blur": 14, "glow_color": "#00FFAA" }),
            ),
            (
                "italic_upper",
                serde_json::json!({ "italic": true, "text_case": "upper" }),
            ),
            (
                "pill",
                serde_json::json!({
                    "background": "pill", "background_color": "#101010", "background_opacity": 0.8
                }),
            ),
        ];
        for (name, patch) in effects {
            // On a still look and on two that move every word's opacity or scale.
            for anim in ["word_highlight", "word_fade", "word_pop"] {
                cases.push((format!("{anim}+{name}"), styled(anim, WORDS, patch.clone())));
            }
        }
        for anim in [
            "word_pop",
            "word_bounce",
            "highlight_slide",
            "none",
            "letter_rise",
        ] {
            cases.push((
                format!("{anim}+motion_blur"),
                styled(anim, WORDS, serde_json::json!({ "motion_blur": 1.0 })),
            ));
        }
        let chunky = serde_json::json!({
            "fill_colors": ["#FFF36B", "#FFB800"], "stroke_width": 6, "stroke_color": "#3B1A00",
            "shadow_blur": 0, "shadow_color": "#C2410C", "shadow_offset_y": 16, "extrude_shade": 0.6
        });
        for anim in ["word_press", "word_pop"] {
            cases.push((
                format!("{anim}+chunky"),
                styled(anim, WORDS, chunky.clone()),
            ));
        }
        let keyed = serde_json::json!({ "emphasis_scale": 1.5, "words_per_line": 4 });
        for anim in ["word_pop", "word_slam"] {
            cases.push((
                format!("{anim}+emphasis"),
                styled(anim, FIGURES, keyed.clone()),
            ));
        }
        let poster = serde_json::json!({
            "layout": "stack", "emphasis_scale": 1.4, "words_per_line": 4,
            "stroke_width": 4, "stroke_color": "#000000"
        });
        for anim in ["word_pop", "letter_rise", "highlight_box"] {
            cases.push((
                format!("{anim}+stack"),
                styled(anim, FIGURES, poster.clone()),
            ));
        }
        let mut marked = styled("word_highlight", WORDS, serde_json::json!({}));
        marked.watermark = Some("OpenCaptions".to_string());
        cases.push(("watermark".to_string(), marked));
        cases
    }

    /// The fingerprint of every look at every golden time. A change that is meant to alter the
    /// picture updates these (`OC_PRINT_GOLDEN=1 cargo test golden -- --nocapture` prints
    /// them); a change that only makes drawing faster must not touch one.
    #[test]
    fn frames_are_byte_for_byte_what_they_were() {
        let got: Vec<(String, u64)> = golden_cases()
            .into_iter()
            .map(|(name, input)| {
                let h = golden(input);
                (name, h)
            })
            .collect();
        if std::env::var_os("OC_PRINT_GOLDEN").is_some() {
            for (name, h) in &got {
                println!("        (\"{name}\", 0x{h:016x}),");
            }
        }
        let want: &[(&str, u64)] = GOLDEN;
        let got_names: Vec<&str> = got.iter().map(|(n, _)| n.as_str()).collect();
        let want_names: Vec<&str> = want.iter().map(|(n, _)| *n).collect();
        assert_eq!(
            got_names, want_names,
            "the looks covered changed: update GOLDEN"
        );
        for ((name, h), (_, expected)) in got.iter().zip(want) {
            assert_eq!(*h, *expected, "{name}: the drawn frames changed");
        }
    }

    /// The blur as it was first written: every pixel, every pass, a column at a time.
    fn blur_everywhere(px: &mut Pixmap, sigma: f32) {
        let radius = blur_radius(sigma);
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

    #[test]
    fn the_blur_is_exactly_the_blur_of_every_pixel() {
        let mut seed = 0x9e37_79b9_7f4a_7c15_u64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        // Sizes and sigmas that put ink at the edges, in the middle, nowhere, and so thin
        // or small that the blur's reach is wider than the pixmap.
        for (w, h, sigma) in [
            (64, 40, 0.5),
            (64, 40, 3.0),
            (7, 5, 6.0),
            (1, 1, 2.0),
            (90, 9, 1.2),
            (33, 61, 9.0),
            (120, 80, 14.0),
        ] {
            for case in 0..6 {
                let mut a = Pixmap::new(w, h).unwrap();
                let (bw, bh) = (
                    1 + next() as usize % w as usize,
                    1 + next() as usize % h as usize,
                );
                let (ox, oy) = (
                    next() as usize % (w as usize - bw + 1),
                    next() as usize % (h as usize - bh + 1),
                );
                if case != 0 {
                    for y in oy..oy + bh {
                        for x in ox..ox + bw {
                            if case == 1 || next() % 3 == 0 {
                                // Premultiplied: no channel above alpha.
                                let alpha = 1 + (next() % 255) as u8;
                                let i = (y * w as usize + x) * 4;
                                for c in 0..3 {
                                    a.data_mut()[i + c] = (next() % (u64::from(alpha) + 1)) as u8;
                                }
                                a.data_mut()[i + 3] = alpha;
                            }
                        }
                    }
                }
                let mut b = a.clone();
                blur(&mut a, sigma);
                blur_everywhere(&mut b, sigma);
                assert!(
                    a.data() == b.data(),
                    "{w}x{h} sigma {sigma} case {case}: the cropped blur differs"
                );
            }
        }
    }

    #[test]
    fn the_overlay_box_holds_every_line_and_the_mark_on_even_edges() {
        let plain = input("word_highlight", WORDS, 2);
        let mut marked = plain.clone();
        marked.watermark = Some("OpenCaptions".into());
        let scene = Scene::new(&book(), marked);
        let (x, y, w, h) = scene.overlay_bounds();
        assert!(x % 2 == 0 && y % 2 == 0 && w % 2 == 0 && h % 2 == 0);
        assert!(x + w <= scene.width && y + h <= scene.height);
        let mark = scene.mark.as_ref().unwrap().rect;
        for r in scene.lines.iter().map(|l| l.bounds).chain([mark]) {
            assert!(
                x as i32 <= r.x()
                    && y as i32 <= r.y()
                    && (x + w) as i32 >= r.right()
                    && (y + h) as i32 >= r.bottom(),
                "{r:?} is outside the box {:?}",
                (x, y, w, h)
            );
        }
        // And nothing is ever drawn outside it.
        let mut renderer = Renderer::new(Scene::new(&book(), plain));
        let (x, y, w, h) = renderer.scene().overlay_bounds();
        for t in [0.0, 0.3, 0.6, 1.2, 3.2] {
            renderer.render(t);
            let width = renderer.scene().width as usize;
            for (row, line) in renderer.rgba().chunks_exact(width * 4).enumerate() {
                for (col, px) in line.as_chunks::<4>().0.iter().enumerate() {
                    let inside = (x as usize..(x + w) as usize).contains(&col)
                        && (y as usize..(y + h) as usize).contains(&row);
                    assert!(inside || px[3] == 0, "ink at ({col}, {row}) at {t} s");
                }
            }
        }
    }

    const GOLDEN: &[(&str, u64)] = &[
        ("word_highlight", 0xf26273125dfc6bf6),
        ("highlight_box", 0xd7eb38aa81c8867f),
        ("word_pop", 0xda614d49f56c55f4),
        ("word_fade", 0x44ed1a5d9329ca4e),
        ("word_sweep", 0x76a12a545f6c55d2),
        ("word_underline", 0xfb9619a6926772c7),
        ("typewriter", 0x774d718bfa4e3047),
        ("none", 0xfe846054695b2f5c),
        ("word_bounce", 0x7ccda292d88c19ac),
        ("lyric_focus", 0xf67ff5ba29429af2),
        ("highlight_slide", 0x88314a33e4a554f9),
        ("line_bar", 0x6b1e7afb5365656d),
        ("stickers", 0x5c9bad18f058c1c7),
        ("word_press", 0xf26273125dfc6bf6),
        ("letter_rise", 0x9bf46ac595f09960),
        ("word_slam", 0x8b017b454af2f0ab),
        ("word_highlight+stroke", 0xa886db0bfe0007d8),
        ("word_fade+stroke", 0x100c37255aee5408),
        ("word_pop+stroke", 0x8bbaecd606e3c7e3),
        ("word_highlight+hard_shadow", 0x5b74783a76662701),
        ("word_fade+hard_shadow", 0x475ee9f0778267b3),
        ("word_pop+hard_shadow", 0x553d16d2b7218cc0),
        ("word_highlight+blur_shadow", 0x14f08f9b6e36576c),
        ("word_fade+blur_shadow", 0x06a272810bee5643),
        ("word_pop+blur_shadow", 0x93eadae460e3a326),
        ("word_highlight+glow", 0x3ee4161be9e7bfda),
        ("word_fade+glow", 0x9eb95ca66e0a91ce),
        ("word_pop+glow", 0xd34e7d3719c1ed61),
        ("word_highlight+italic_upper", 0xbb710f6a8ee71ff2),
        ("word_fade+italic_upper", 0xbd182700c42782ba),
        ("word_pop+italic_upper", 0xd20257c98ebb01a7),
        ("word_highlight+pill", 0x39e4fe882e5dfa3b),
        ("word_fade+pill", 0xbcf444e5865cfa9c),
        ("word_pop+pill", 0xc9c9ca585f268aa2),
        ("word_pop+motion_blur", 0x7cafa1034b42134a),
        ("word_bounce+motion_blur", 0xfe8ce16569a3e8c2),
        ("highlight_slide+motion_blur", 0x4a203c274cc98750),
        ("none+motion_blur", 0x73229f3640871f60),
        ("letter_rise+motion_blur", 0x8930aa30d029025d),
        ("word_press+chunky", 0xe55ee93138faa2d6),
        ("word_pop+chunky", 0x064022aaf29214a8),
        ("word_pop+emphasis", 0x0e7b974001700c3c),
        ("word_slam+emphasis", 0x043fd6913511f0fc),
        ("word_pop+stack", 0xfd681dd2b6862af5),
        ("letter_rise+stack", 0xcd8b7f73eae89dab),
        ("highlight_box+stack", 0x9a370ca616d3fee2),
        ("watermark", 0xe22c164ced6e9dd5),
    ];
}
