//! The render request vocabulary, shared with the API's Pydantic schemas.
//! Unknown style fields are ignored so the API can grow without breaking the
//! engine. A transcript keeps its unknown fields, so an edit hands back everything
//! it was given; its times are f32, the precision the engine draws at.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

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
}

#[derive(Clone, Debug, Deserialize)]
pub struct Style {
    pub font: String,
    pub font_size: f32,
    pub text_color: Rgba,
    pub highlight_color: Rgba,
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
