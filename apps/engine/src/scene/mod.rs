//! Layout once, draw per frame.
//!
//! A scene shapes and places every caption line up front; a frame is then only
//! the per-word animation state at time `t` applied to fixed geometry. Every
//! operation is integer or IEEE f32 arithmetic with no platform maths library,
//! which is what makes native and WASM output byte-identical.

use rustybuzz::ttf_parser::{GlyphId, OutlineBuilder};
use rustybuzz::{Face, UnicodeBuffer};
use tiny_skia::{
    Color, FillRule, FilterQuality, GradientStop, IntRect, LineCap, LineJoin, LinearGradient, Mask,
    Paint, Path, PathBuilder, Pixmap, PixmapPaint, Point, Rect, SpreadMode, Stroke, Transform,
};

mod anim;
mod draw;
mod ease;
mod layout;
mod pixels;
mod renderer;
#[cfg(test)]
mod tests;
mod text;

use crate::fonts::FontBook;
use crate::model::{
    Animation, Background, Layout, Rgba, SceneInput, Style, TextCase, cut, shifted,
};
use anim::*;
use draw::*;
use ease::{ease_out_quad, lerp, linear, overshoot, ramp, wave};
use layout::*;
use pixels::*;
pub use renderer::Renderer;
use renderer::*;
use text::*;

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
/// Drift: how long a word takes to come into focus, how blurred it starts (a share of the font
/// size), how far the line pushes in over its life and bobs (shares of the font size and of the
/// line), the bob's period, and how much of its glow a word keeps until it is said.
const DRIFT_IN_S: f32 = 0.35;
const DRIFT_SOFT: f32 = 0.12;
const DRIFT_PUSH: f32 = 0.06;
const DRIFT_BOB: f32 = 0.02;
const DRIFT_PERIOD_S: f32 = 3.0;
const DRIFT_GLOW_REST: f32 = 0.55;
/// A line that does not drift.
const NO_DRIFT: [f32; 3] = [0.0, 0.0, 1.0];
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
/// The watermark is drawn in the application's default face.
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
    /// How much larger than the style's size it is set: its row's scale in a stack, else 1.
    size: f32,
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

/// How a whole line moves: knocked about by a landing word (across, down, in pixels), and floating
/// (across, down, scale).
#[derive(Clone, Copy, PartialEq)]
struct LineMotion {
    jolt: [f32; 2],
    drift: [f32; 3],
}

impl LineMotion {
    /// A line that stays where it is laid out.
    const STILL: Self = Self {
        jolt: [0.0; 2],
        drift: NO_DRIFT,
    };
}

/// The frame's line, its words' states, its guide shape, and how the line moves.
#[derive(PartialEq)]
struct FrameKey(Option<usize>, Vec<WordState>, Option<Guide>, LineMotion);
