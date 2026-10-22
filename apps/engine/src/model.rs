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
    /// A rounded rectangle.
    Solid,
    Pill,
    /// A rectangle with sharp corners.
    Square,
}

/// How a caption's rows sit in its block, and where the block is anchored.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Align {
    /// Rows are centred on each other, and the block on `position_x`.
    #[default]
    Center,
    /// Rows start at the block's left edge, and `position_x` is where that edge sits.
    Left,
    /// Rows end at the block's right edge, and `position_x` is where that edge sits.
    Right,
    /// A poster: short rows, each scaled up to the widest one's width and stacked tight, the block
    /// centred on `position_x`.
    Justify,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
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
    /// The word being said is raised out of the page: its face lifts off an extrusion that grows.
    WordPress,
    /// Each word's letters rise into place one after another as it is said.
    LetterRise,
    /// Each word slams in, dropping from 1.7 times its size, and the line jolts as it lands.
    WordSlam,
    /// Each word fades in from a blur; the line pushes slowly toward the viewer and floats, and the
    /// word being said glows brighter.
    Drift,
    /// Each word comes out of a short blur as it is said; nothing moves.
    BlurIn,
}

impl Animation {
    /// Every animation, in the order the API and the editors list them.
    pub const ALL: [Animation; 18] = [
        Animation::WordHighlight,
        Animation::HighlightBox,
        Animation::WordPop,
        Animation::WordFade,
        Animation::WordSweep,
        Animation::WordUnderline,
        Animation::Typewriter,
        Animation::None,
        Animation::WordBounce,
        Animation::LyricFocus,
        Animation::HighlightSlide,
        Animation::LineBar,
        Animation::Stickers,
        Animation::WordPress,
        Animation::LetterRise,
        Animation::WordSlam,
        Animation::Drift,
        Animation::BlurIn,
    ];
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum TextCase {
    #[default]
    None,
    Upper,
}

fn clear() -> Rgba {
    Rgba([0, 0, 0, 0])
}

fn one() -> f32 {
    1.0
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
    /// A vertical gradient over each word's letters, top to baseline; empty is `text_color`.
    #[serde(default)]
    pub fill_colors: Vec<Rgba>,
    /// How much a solid shadow (an extrusion) darkens from the front to the back, 0 to 1.
    #[serde(default)]
    pub extrude_shade: f32,
    /// The colour the back of an extrusion fades to from `shadow_color` at the front; fully
    /// transparent for none (the shading alone).
    #[serde(default = "clear")]
    pub extrude_back: Rgba,
    #[serde(default)]
    pub align: Align,
    /// Extra space after each letter, a share of the font size (negative to tighten).
    #[serde(default)]
    pub letter_spacing: f32,
    /// How much wider (or narrower, below 1) the letters are drawn than the face draws them.
    #[serde(default = "one")]
    pub stretch: f32,
    /// Looks a word can be given instead of the style's own (see `Word::variant`); a preset
    /// defines them.
    #[serde(default)]
    pub variants: Vec<Variant>,
}

/// The most looks a style defines.
pub const MAX_VARIANTS: usize = 6;

/// How one word differs from the style's look. Every field is optional: what is absent is the
/// style's own.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Variant {
    pub font: Option<String>,
    /// How much larger than the style's font size the word is set.
    pub scale: Option<f32>,
    pub italic: Option<bool>,
    pub text_case: Option<TextCase>,
    pub text_color: Option<Rgba>,
    pub letter_spacing: Option<f32>,
    pub stretch: Option<f32>,
    /// A square box of this colour behind the word, the label of a name.
    pub box_color: Option<Rgba>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Word {
    pub text: String,
    pub start: f32,
    pub end: f32,
    /// The word's look: an index into `Style::variants`. None is the style's own look; an index past
    /// the end draws as that and is kept, so a style with more looks gives it back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variant: Option<u32>,
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
    /// The families the words' scripts need that are not bundled, by the transcript's language
    /// (see `scripts::fallback_families`): the host fetches and registers them.
    pub fn fallback_families(&self) -> Vec<String> {
        let language = self
            .rest
            .get("language")
            .and_then(|l| l.as_str())
            .unwrap_or("");
        crate::scripts::fallback_families(self.words().map(|w| w.text.as_str()), language)
    }

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
        within("extrude_shade", s.extrude_shade, 0.0, 1.0)?;
        within("letter_spacing", s.letter_spacing, -0.5, 2.0)?;
        within("stretch", s.stretch, 0.25, 4.0)?;
        if s.variants.len() > MAX_VARIANTS {
            return Err(format!("variants holds at most {MAX_VARIANTS} looks"));
        }
        for v in &s.variants {
            within("variant scale", v.scale.unwrap_or(1.0), 0.3, 3.0)?;
            within(
                "variant letter_spacing",
                v.letter_spacing.unwrap_or(0.0),
                -0.5,
                2.0,
            )?;
            within("variant stretch", v.stretch.unwrap_or(1.0), 0.25, 4.0)?;
        }
        if s.fill_colors.len() > 4 {
            return Err("fill_colors holds at most 4 colours".into());
        }
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

    #[test]
    fn every_animation_is_in_the_list_once_and_in_order() {
        // An exhaustive match: a new animation does not compile until it is placed here, and
        // then `ALL` must hold it at the same place.
        let place = |a: Animation| match a {
            Animation::WordHighlight => 0,
            Animation::HighlightBox => 1,
            Animation::WordPop => 2,
            Animation::WordFade => 3,
            Animation::WordSweep => 4,
            Animation::WordUnderline => 5,
            Animation::Typewriter => 6,
            Animation::None => 7,
            Animation::WordBounce => 8,
            Animation::LyricFocus => 9,
            Animation::HighlightSlide => 10,
            Animation::LineBar => 11,
            Animation::Stickers => 12,
            Animation::WordPress => 13,
            Animation::LetterRise => 14,
            Animation::WordSlam => 15,
            Animation::Drift => 16,
            Animation::BlurIn => 17,
        };
        for (i, a) in Animation::ALL.into_iter().enumerate() {
            assert_eq!(place(a), i, "{a:?} is out of place");
            // Each is named by its snake_case name, which is what the API and the editors send.
            let name = serde_json::to_value(a).unwrap();
            assert_eq!(serde_json::from_value::<Animation>(name).unwrap(), a);
        }
    }

    fn word(start: f32, end: f32) -> Word {
        Word {
            text: "w".into(),
            start,
            end,
            variant: None,
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
    fn a_looks_numbers_are_bounded_and_a_word_without_one_is_unchanged() {
        let mut scene = input(serde_json::json!({}));
        scene.style.variants = vec![Variant {
            scale: Some(5.0),
            ..Variant::default()
        }];
        assert!(scene.check().unwrap_err().contains("scale"));
        scene.style.variants = vec![Variant::default(); MAX_VARIANTS + 1];
        assert!(scene.check().unwrap_err().contains("variants"));
        // Without a look, a word serialises as it always did.
        let word: Word =
            serde_json::from_str(r#"{"text":"a","start":0.0,"end":1.0,"extra":1}"#).unwrap();
        assert_eq!(word.variant, None);
        let json = serde_json::to_string(&word).unwrap();
        assert!(!json.contains("variant"), "{json}");
        let styled: Word =
            serde_json::from_str(r#"{"text":"a","start":0.0,"end":1.0,"variant":2}"#).unwrap();
        assert_eq!(styled.variant, Some(2));
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
