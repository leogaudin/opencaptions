//! The render request vocabulary, shared with the API's Pydantic schemas.
//! Unknown style fields are ignored so the API can grow without breaking the
//! engine. A transcript keeps its unknown fields, so an edit hands back everything
//! it was given; its times are f32, the precision the engine draws at.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use std::ops::Range;

/// A straight-alpha colour parsed from `#RRGGBB` or `#RRGGBBAA`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rgba(pub [u8; 4]);

impl Rgba {
    pub fn parse(hex: &str) -> Option<Self> {
        let h = hex.strip_prefix('#')?;
        let byte = |i: usize| u8::from_str_radix(h.get(i..i + 2)?, 16).ok();
        match h.len() {
            6 => Some(Self([byte(0)?, byte(2)?, byte(4)?, 255])),
            8 => Some(Self([byte(0)?, byte(2)?, byte(4)?, byte(6)?])),
            _ => None,
        }
    }
}

impl<'de> Deserialize<'de> for Rgba {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Self::parse(&s).ok_or_else(|| D::Error::custom(format!("invalid colour {s:?}")))
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Background {
    None,
    Solid,
    Pill,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Animation {
    WordHighlight,
    HighlightBox,
    WordPop,
    WordFade,
    /// The highlight colour fills each word from left to right as it is said, and stays.
    WordSweep,
    /// An underline in the highlight colour is drawn under each word as it is said, and stays.
    WordUnderline,
    /// Each word is typed out letter by letter as it is said, with a cursor at the end.
    Typewriter,
    /// Nothing moves: the line is shown as it is, for subtitles.
    None,
    /// Each word jumps up past its size as it is said and leans a little, left and right in turn.
    WordBounce,
    /// The line is dim and soft; the word being said comes into focus, bright and a little larger.
    LyricFocus,
    /// One box that slides from word to word as they are said.
    HighlightSlide,
    /// Words light up as they are said, and a thin bar under the line fills as the line is spoken.
    LineBar,
    /// Every word sits on its own label, tilted left and right in turn; the word being said lifts.
    Stickers,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum TextCase {
    #[default]
    None,
    Upper,
}

fn white() -> Rgba {
    Rgba([255, 255, 255, 255])
}

impl Style {
    /// The first highlight colour, what a single shape is painted in.
    pub fn primary(&self) -> Rgba {
        self.highlight_colors.first().copied().unwrap_or_else(white)
    }

    /// The colour the `index`th word of the transcript is marked in: the highlight colours in turn.
    pub fn highlight(&self, index: usize) -> Rgba {
        self.highlight_colors
            .get(index % self.highlight_colors.len().max(1))
            .copied()
            .unwrap_or_else(white)
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct Style {
    pub font: String,
    pub font_size: f32,
    pub text_color: Rgba,
    /// What the animation paints in: the first is the primary. A look that marks each word (the lit
    /// word, a box, a label, an underline) takes them in turn, word by word; a single shape (the
    /// sliding box, the bar) is the primary; a sweep runs through all of them across the line.
    pub highlight_colors: Vec<Rgba>,
    pub background: Background,
    pub background_color: Rgba,
    pub background_opacity: f32,
    /// Normalised centre of the caption block, 0..1 across the frame.
    pub position_x: f32,
    pub position_y: f32,
    pub animation: Animation,
    pub words_per_line: u32,
    #[serde(default)]
    pub word_spacing: f32,
    pub stroke_width: f32,
    pub stroke_color: Rgba,
    pub shadow_blur: f32,
    pub shadow_color: Rgba,
    /// Where the shadow falls, away from the letters, tuned like the blur. A shadow with no blur is
    /// solid and is drawn as an extrusion: the outline carried on out to the offset.
    #[serde(default)]
    pub shadow_offset_x: f32,
    #[serde(default)]
    pub shadow_offset_y: f32,
    /// A halo of `glow_color` around the letters (0 for none), the neon look.
    #[serde(default)]
    pub glow_blur: f32,
    #[serde(default = "white")]
    pub glow_color: Rgba,
    #[serde(default)]
    pub text_case: TextCase,
    /// Letters leaned to the right, drawn from the upright face by shearing it.
    #[serde(default)]
    pub italic: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Word {
    pub text: String,
    pub start: f32,
    pub end: f32,
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Segment {
    pub words: Vec<Word>,
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Transcript {
    pub duration: f32,
    pub segments: Vec<Segment>,
    #[serde(flatten)]
    pub rest: Map<String, Value>,
}

impl Transcript {
    /// Every word in reading order, across segments: the sequence captions are cut from.
    pub fn words(&self) -> impl Iterator<Item = &Word> {
        self.segments.iter().flat_map(|s| &s.words)
    }
}

/// A silence this long ends a caption: words said further apart than this never share one, or the
/// line would hang on screen through the whole pause with its first words long gone.
pub const LINE_BREAK_S: f32 = 1.0;

/// How the words are cut into captions, as ranges of the flat word list: `per_line` words each,
/// fewer where a pause of `LINE_BREAK_S` falls inside. The one rule for the scene and for the
/// editors' timeline, so what is drawn and what is listed cannot disagree.
pub fn cut(words: &[&Word], per_line: usize) -> Vec<Range<usize>> {
    let per_line = per_line.max(1);
    let mut lines = vec![];
    let mut from = 0;
    for i in 1..=words.len() {
        let paused = words
            .get(i)
            .is_some_and(|next| next.start - words[i - 1].end >= LINE_BREAK_S);
        if i == words.len() || i - from == per_line || paused {
            lines.push(from..i);
            from = i;
        }
    }
    lines
}

/// A transcript time as it is shown: moved by the caption offset (positive means
/// later) and never before the start. The one rule for the offset, so the scene,
/// the timeline and an export agree; `duration` is the video's length, not a
/// caption time, and is never shifted.
pub fn shifted(t: f32, offset_ms: i32) -> f32 {
    (t + offset_ms as f32 / 1000.0).max(0.0)
}

/// Everything that decides what a frame looks like.
#[derive(Clone, Debug, Deserialize)]
pub struct SceneInput {
    pub transcript: Transcript,
    pub style: Style,
    pub width: u32,
    pub height: u32,
    /// Global caption timing offset in milliseconds; positive shows captions later.
    #[serde(default)]
    pub caption_offset_ms: i32,
    /// A small mark of this text in the top right corner of every frame (a free tier's), drawn by
    /// the engine so the preview and the export carry the same one. None or empty draws nothing.
    #[serde(default)]
    pub watermark: Option<String>,
    /// Families, already registered with the font book, to draw with where the style's font lacks a
    /// letter (see `scripts::fallback_families`), tried in this order before the bundled faces.
    #[serde(default)]
    pub fallback_fonts: Vec<String>,
}
