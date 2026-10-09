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

/// A silence is a pause when it is this many times the usual time from one word's start to the
/// next's. It is judged against how fast the speaker talks, not against a clock: a second of quiet
/// is a pause in a rap and not in a slow documentary.
const PAUSE_PERIODS: f32 = 3.0;

/// Where the speech pauses: the index of every word that comes after one. The usual time between
/// words is the median start-to-start gap, which pauses (being few) do not move. The API holds the
/// same rule, and both are held to `testdata/pauses.json`.
pub fn pauses(words: &[&Word]) -> Vec<usize> {
    let mut periods: Vec<f32> = words
        .windows(2)
        .map(|pair| pair[1].start - pair[0].start)
        .filter(|d| d.is_finite() && *d > 0.0)
        .collect();
    if periods.is_empty() {
        return vec![];
    }
    periods.sort_by(f32::total_cmp);
    let limit = PAUSE_PERIODS * periods[periods.len() / 2];
    (1..words.len())
        .filter(|&i| words[i].start - words[i - 1].end > limit)
        .collect()
}

/// How the words are cut into captions, as ranges of the flat word list: `per_line` words each,
/// fewer where the speech pauses, so words said minutes apart never share a caption. The one rule
/// for the scene and for the editors' timeline, so what is drawn and what is listed cannot
/// disagree.
pub fn cut(words: &[&Word], per_line: usize) -> Vec<Range<usize>> {
    let per_line = per_line.max(1);
    let mut pauses = pauses(words).into_iter().peekable();
    let mut lines = vec![];
    let mut from = 0;
    for i in 1..=words.len() {
        let paused = pauses.next_if_eq(&i).is_some();
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

/// The most pixels a frame may have (8K UHD): a frame is held several times over while it
/// is drawn, so an unbounded size is an unbounded allocation.
pub const MAX_FRAME_PIXELS: u64 = 7680 * 4320;
/// The longest transcript a scene accepts, in seconds.
pub const MAX_DURATION_S: f32 = 24.0 * 3600.0;

impl SceneInput {
    /// Whether this input can be drawn. The one place the bounds are written, for the render
    /// server, the browser build and the phone alike: a number that is not finite, or a size
    /// of zero, would otherwise reach the drawing code as a panic, not as a refusal.
    pub fn check(&self) -> Result<(), String> {
        let (w, h) = (self.width, self.height);
        if !(2..=7680).contains(&w) || !(2..=7680).contains(&h) {
            return Err("width and height must be between 2 and 7680".into());
        }
        if u64::from(w) * u64::from(h) > MAX_FRAME_PIXELS {
            return Err(format!(
                "a frame may have at most {MAX_FRAME_PIXELS} pixels"
            ));
        }
        let d = self.transcript.duration;
        if !d.is_finite() || !(0.0..=MAX_DURATION_S).contains(&d) {
            return Err(format!(
                "duration must be between 0 and {MAX_DURATION_S} seconds"
            ));
        }
        if self
            .transcript
            .words()
            .any(|word| !word.start.is_finite() || !word.end.is_finite())
        {
            return Err("every word needs a finite start and end".into());
        }
        let s = &self.style;
        let within = |name: &str, v: f32, lo: f32, hi: f32| {
            if v.is_finite() && (lo..=hi).contains(&v) {
                Ok(())
            } else {
                Err(format!("{name} must be between {lo} and {hi}"))
            }
        };
        within("font_size", s.font_size, 1.0, 2000.0)?;
        within("word_spacing", s.word_spacing, -1000.0, 1000.0)?;
        within("stroke_width", s.stroke_width, 0.0, 500.0)?;
        within("shadow_blur", s.shadow_blur, 0.0, 500.0)?;
        within("shadow_offset_x", s.shadow_offset_x, -1000.0, 1000.0)?;
        within("shadow_offset_y", s.shadow_offset_y, -1000.0, 1000.0)?;
        within("glow_blur", s.glow_blur, 0.0, 500.0)?;
        within("background_opacity", s.background_opacity, 0.0, 1.0)?;
        within("position_x", s.position_x, -1.0, 2.0)?;
        within("position_y", s.position_y, -1.0, 2.0)?;
        if !(1..=100).contains(&s.words_per_line) {
            return Err("words_per_line must be between 1 and 100".into());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(start: f32, end: f32) -> Word {
        Word {
            text: "w".into(),
            start,
            end,
            rest: Map::new(),
        }
    }

    fn input(patch: serde_json::Value) -> SceneInput {
        let mut value = serde_json::json!({
            "width": 1080, "height": 1920,
            "transcript": { "duration": 5.0, "segments": [
                { "words": [{ "text": "hi", "start": 0.0, "end": 1.0 }] }
            ] },
            "style": {
                "font": "Inter", "font_size": 64, "text_color": "#FFFFFF",
                "highlight_colors": ["#7C3AED"], "background": "none",
                "background_color": "#000000", "background_opacity": 0.0,
                "position_x": 0.5, "position_y": 0.84, "animation": "none",
                "words_per_line": 3, "stroke_width": 0, "stroke_color": "#000000",
                "shadow_blur": 0, "shadow_color": "#000000"
            }
        });
        for (k, v) in patch.as_object().unwrap() {
            if value["style"].get(k).is_some() {
                value["style"][k] = v.clone();
            } else {
                value[k] = v.clone();
            }
        }
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn a_normal_scene_is_accepted() {
        assert_eq!(input(serde_json::json!({})).check(), Ok(()));
    }

    #[test]
    fn numbers_that_would_panic_the_drawing_are_refused_by_name() {
        for (patch, name) in [
            (serde_json::json!({ "font_size": -3 }), "font_size"),
            (serde_json::json!({ "font_size": 0 }), "font_size"),
            (serde_json::json!({ "stroke_width": 1e30 }), "stroke_width"),
            (serde_json::json!({ "shadow_blur": -1 }), "shadow_blur"),
            (serde_json::json!({ "words_per_line": 0 }), "words_per_line"),
            (
                serde_json::json!({ "background_opacity": 2 }),
                "background_opacity",
            ),
            (serde_json::json!({ "width": 0 }), "width"),
            (serde_json::json!({ "height": 9000 }), "width"),
            (
                serde_json::json!({ "width": 7680, "height": 7680 }),
                "pixels",
            ),
        ] {
            let err = input(patch.clone()).check().unwrap_err();
            assert!(err.contains(name), "{patch}: {err}");
        }
    }

    /// The cases the API's copy of the rule is held to as well.
    #[test]
    fn the_shared_pause_cases_hold() {
        let cases: Vec<Value> =
            serde_json::from_str(include_str!("../testdata/pauses.json")).unwrap();
        assert!(cases.len() >= 8);
        for case in cases {
            let words: Vec<Word> = case["words"]
                .as_array()
                .unwrap()
                .iter()
                .map(|w| word(w[0].as_f64().unwrap() as f32, w[1].as_f64().unwrap() as f32))
                .collect();
            let refs: Vec<&Word> = words.iter().collect();
            let expected: Vec<usize> = case["breaks"]
                .as_array()
                .unwrap()
                .iter()
                .map(|i| i.as_u64().unwrap() as usize)
                .collect();
            assert_eq!(pauses(&refs), expected, "{}", case["name"]);
        }
    }

    #[test]
    fn a_time_that_is_not_a_number_is_refused() {
        let mut scene = input(serde_json::json!({}));
        scene.transcript.segments[0].words[0].end = f32::NAN;
        assert!(scene.check().unwrap_err().contains("finite"));
        let mut long = input(serde_json::json!({}));
        long.transcript.duration = f32::INFINITY;
        assert!(long.check().unwrap_err().contains("duration"));
    }

    #[test]
    fn captions_are_cut_by_count_and_at_pauses() {
        // A word every half second, then a silence of a minute: 3 per line, then a new line.
        let words: Vec<Word> = [0.0, 0.5, 1.0, 1.5, 61.0, 61.5]
            .iter()
            .map(|s| word(*s, s + 0.4))
            .collect();
        let refs: Vec<&Word> = words.iter().collect();
        assert_eq!(cut(&refs, 3), vec![0..3, 3..4, 4..6]);
        assert_eq!(cut(&refs, 10), vec![0..4, 4..6]);
        assert_eq!(cut(&refs, 0), cut(&refs, 1), "a count of nothing is one");
        assert!(cut(&[], 3).is_empty());
    }
}
