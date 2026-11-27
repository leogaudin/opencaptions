//! The composed looks. Each frame of one is built from layers, the way a motion designer stacks
//! them in After Effects: the letters, the light they give off, the shadow they cast, a matte that
//! cuts them, a frame drawn several times while the shutter is open. They are drawn from the time
//! itself rather than from a word's state (`WordState`), so a frame is redrawn while anything in the
//! look moves (`moving`) and kept once it is still.
//!
//! Colours come from the style: the letters are `text_color` (or a word's own), `highlight_colors`
//! are what the look paints in (a box, a swipe, echoes), `fill_colors` a gradient over the letters
//! (gold, metal), `glow_color` its light, the outline `stroke_*` and the shadow `shadow_*`, so a
//! preset is a starting point and every colour can be changed.

use super::*;
use tiny_skia::{BlendMode, MaskType, StrokeDash};

mod kit;
mod letters;
mod light;
mod motion;
mod voice;

pub(super) use kit::*;
pub(super) use voice::Loudness;

/// A word of the line as a composed look sees it at the frame's time.
#[derive(Clone, Copy)]
pub(super) struct Said<'a> {
    pub(super) w: &'a Placed,
    /// Its place in the line.
    pub(super) i: usize,
    /// Seconds since it started, negative before.
    pub(super) a: f32,
    /// Its font size in pixels.
    pub(super) fs: f32,
}

impl Said<'_> {
    /// The middle of its letters across, and the middle of a capital's height: where a word is
    /// scaled and turned about.
    pub(super) fn cx(&self) -> f32 {
        self.w.ink_x + self.w.ink_w / 2.0
    }

    pub(super) fn mid(&self) -> f32 {
        self.w.baseline - 0.36 * self.fs
    }

    pub(super) fn centre(&self) -> (f32, f32) {
        (self.cx(), self.mid())
    }

    /// How far through an entrance of `secs` it is, 0 to 1.
    pub(super) fn into(&self, secs: f32) -> f32 {
        (self.a / secs).clamp(0.0, 1.0)
    }
}

/// One frame of a composed look: the scene, the line, the time and the words as they stand.
pub(super) struct Fx<'a> {
    pub(super) scene: &'a Scene,
    pub(super) s: &'a Style,
    pub(super) line: &'a Line,
    pub(super) t: f32,
    pub(super) words: Vec<Said<'a>>,
    /// The word being said: the last of the line to have started.
    pub(super) act: Option<usize>,
}

/// A light: how wide it spreads (a share of the font size), its colour and how strongly it is
/// laid on (past 1, laid again).
pub(super) type Level = (f32, Option<Rgba>, f32);

pub(super) const WHITE: Rgba = Rgba([255, 255, 255, 255]);
pub(super) const BLACK: Rgba = Rgba([0, 0, 0, 255]);

impl<'a> Fx<'a> {
    pub(super) fn new(scene: &'a Scene, line: &'a Line, t: f32) -> Self {
        let s = &scene.style;
        let words: Vec<Said> = line
            .words
            .iter()
            .enumerate()
            .map(|(i, w)| Said {
                w,
                i,
                a: t - (w.start - LEAD_S),
                fs: s.font_size * w.size,
            })
            .collect();
        let act = words.iter().rposition(|w| w.a >= 0.0);
        Self {
            scene,
            s,
            line,
            t,
            words,
            act,
        }
    }

    /// The words that have started.
    pub(super) fn started(&self) -> impl Iterator<Item = &Said<'a>> {
        self.words.iter().filter(|w| w.a >= 0.0)
    }

    pub(super) fn is_act(&self, w: &Said) -> bool {
        self.act == Some(w.i)
    }

    /// The style's font size, which a look's distances are shares of.
    pub(super) fn fs(&self) -> f32 {
        self.s.font_size
    }

    /// How far the line is through appearing: a look that shows its words before they are said
    /// fades them in as the line comes up.
    pub(super) fn shown(&self) -> f32 {
        ramp(self.t, self.line.start - LEAD_S, 0.15)
    }

    pub(super) fn origin(&self) -> (i32, i32) {
        (self.line.bounds.x(), self.line.bounds.y())
    }

    /// An empty layer the size of the line's box.
    pub(super) fn layer(&self) -> Option<Pixmap> {
        Pixmap::new(self.line.bounds.width(), self.line.bounds.height())
    }

    /// A transform in frame pixels, made one in the line's layer.
    pub(super) fn local(&self, at: Transform) -> Transform {
        let (x, y) = self.origin();
        at.post_translate(-x as f32, -y as f32)
    }

    pub(super) fn fill(&self, px: &mut Pixmap, path: &Path, p: &Paint, at: Transform) {
        px.fill_path(path, p, FillRule::Winding, self.local(at), None);
    }

    pub(super) fn fill_in(&self, px: &mut Pixmap, path: &Path, p: &Paint, at: Transform, m: &Mask) {
        px.fill_path(path, p, FillRule::Winding, self.local(at), Some(m));
    }

    pub(super) fn edge(&self, px: &mut Pixmap, path: &Path, c: Color, width: f32, at: Transform) {
        let stroke = Stroke {
            width,
            line_join: LineJoin::Round,
            line_cap: LineCap::Round,
            ..Stroke::default()
        };
        px.stroke_path(path, &paint(c), &stroke, self.local(at), None);
    }

    /// The letters with the style's outline under them, so a thick one grows outward.
    pub(super) fn outlined(&self, px: &mut Pixmap, w: &Said, fill: &Paint, at: Transform) {
        let Some(path) = &w.w.glyphs else { return };
        if self.s.stroke_width > 0.0 {
            let c = colour(self.s.stroke_color, 1.0);
            self.edge(px, path, c, self.s.stroke_width * w.w.size, at);
        }
        self.fill(px, path, fill, at);
    }

    /// A word's own colour, or the style's text colour.
    pub(super) fn ink_of(&self, w: &Said) -> Rgba {
        w.w.color.unwrap_or(self.s.text_color)
    }

    /// The style's gradient over a word's letters (top of the em box to the baseline, as `word_fill`
    /// paints it), or `flat` without one.
    pub(super) fn gradient(&self, w: &Said, flat: Rgba) -> Paint<'static> {
        match gradient_stops(&self.s.fill_colors, &|c| c).and_then(|stops| {
            LinearGradient::new(
                Point::from_xy(w.w.ink_x, w.w.em_top),
                Point::from_xy(w.w.ink_x, w.w.baseline),
                stops,
                SpreadMode::Pad,
                Transform::identity(),
            )
        }) {
            Some(shader) => Paint {
                shader,
                anti_alias: true,
                ..Paint::default()
            },
            None => paint(colour(
                self.s.fill_colors.first().copied().unwrap_or(flat),
                1.0,
            )),
        }
    }

    /// `layer` onto the frame where the line's box is, moved by (`dx`, `dy`) whole pixels.
    pub(super) fn put(
        &self,
        canvas: &mut Pixmap,
        layer: &Pixmap,
        opacity: f32,
        blend: BlendMode,
        (dx, dy): (f32, f32),
    ) {
        if opacity <= 0.0 {
            return;
        }
        let (x, y) = self.origin();
        let mut left = opacity;
        // A light laid on more than once over reads brighter: each whole pass and the rest.
        while left > 0.001 {
            let p = PixmapPaint {
                opacity: left.min(1.0),
                blend_mode: blend,
                ..PixmapPaint::default()
            };
            canvas.draw_pixmap(
                x + dx.round() as i32,
                y + dy.round() as i32,
                layer.as_ref(),
                &p,
                Transform::identity(),
                None,
            );
            left -= 1.0;
        }
    }

    pub(super) fn over(&self, canvas: &mut Pixmap, layer: &Pixmap) {
        self.put(canvas, layer, 1.0, BlendMode::SourceOver, (0.0, 0.0));
    }

    /// The style's soft shadow, cast by whatever is in `ink`, `gain` times as dark.
    pub(super) fn shadow(&self, canvas: &mut Pixmap, ink: &Pixmap, gain: f32) {
        self.shadow_at(canvas, ink, gain, (0, 0));
    }

    /// `shadow`, for a part of a layer that starts at `at` in it.
    pub(super) fn shadow_at(&self, canvas: &mut Pixmap, ink: &Pixmap, gain: f32, at: (i32, i32)) {
        let s = self.s;
        if opacity(s.shadow_color) <= 0.0 {
            return;
        }
        let sigma = s.shadow_blur / 2.0;
        let Some(extent) = extent_of(ink) else { return };
        let Some((piece, x, y)) = cut_out(ink, extent, blur_reach(sigma)) else {
            return;
        };
        let mut shade = tint(&piece, solid(s.shadow_color));
        soften(&mut shade, sigma);
        let to = (
            s.shadow_offset_x + (x + at.0) as f32,
            s.shadow_offset_y + (y + at.1) as f32,
        );
        self.put(
            canvas,
            &shade,
            opacity(s.shadow_color) * gain,
            BlendMode::SourceOver,
            to,
        );
    }

    /// Light from what is in `emission`: at each level it is coloured, spread and added, the way a
    /// bloom is built from blurs of several sizes.
    pub(super) fn bloom(&self, canvas: &mut Pixmap, emission: &Pixmap, levels: &[Level]) {
        self.bloom_at(canvas, emission, levels, (0, 0));
    }

    /// `bloom`, for a part of a layer that starts at `at` in it.
    pub(super) fn bloom_at(
        &self,
        canvas: &mut Pixmap,
        emission: &Pixmap,
        levels: &[Level],
        at: (i32, i32),
    ) {
        // Each light is worked on only round the ink, as far as it spreads.
        let Some(extent) = extent_of(emission) else {
            return;
        };
        for &(spread, c, gain) in levels {
            let sigma = spread * self.fs();
            let Some((piece, x, y)) = cut_out(emission, extent, blur_reach(sigma)) else {
                continue;
            };
            // A light of no colour of its own is the emission's own colours.
            let mut light = c.map_or_else(|| piece.clone(), |c| tint(&piece, c));
            soften(&mut light, sigma);
            self.put(
                canvas,
                &light,
                gain,
                BlendMode::Plus,
                ((x + at.0) as f32, (y + at.1) as f32),
            );
        }
    }

    /// A matte from the ink in `px`: drawing through it lands only on that ink.
    pub(super) fn matte(&self, px: &Pixmap) -> Option<Mask> {
        Some(Mask::from_pixmap(px.as_ref(), MaskType::Alpha))
    }

    /// A matte of a rectangle of the frame: drawing through it lands only inside it.
    pub(super) fn clip(&self, r: Rect) -> Option<Mask> {
        let b = self.line.bounds;
        let mut m = Mask::new(b.width(), b.height())?;
        m.fill_path(
            &PathBuilder::from_rect(r),
            FillRule::Winding,
            true,
            self.local(Transform::identity()),
        );
        Some(m)
    }

    /// A matte of the part of the line's box on one side of `y`: above it, or from it down.
    pub(super) fn side(&self, y: f32, above: bool) -> Option<Mask> {
        let b = self.line.bounds;
        let y = y.clamp(b.y() as f32, b.bottom() as f32);
        let (x0, x1) = (b.x() as f32, b.right() as f32);
        let r = if above {
            Rect::from_ltrb(x0, b.y() as f32, x1, y)
        } else {
            Rect::from_ltrb(x0, y, x1, b.bottom() as f32)
        };
        // An empty side is a matte that lets nothing through.
        r.map_or_else(|| Mask::new(b.width(), b.height()), |r| self.clip(r))
    }

    /// The caption block, for a style with a background.
    pub(super) fn block(&self, canvas: &mut Pixmap) {
        let s = self.s;
        if let Some(path) = self
            .line
            .block
            .and_then(|b| rounded_rect(b, self.scene.block_radius))
        {
            let p = paint(colour(s.background_color, s.background_opacity));
            canvas.fill_path(&path, &p, FillRule::Winding, Transform::identity(), None);
        }
    }

    /// A frame with its shutter open from `secs` before now: the look drawn `n` times through
    /// that time and averaged. While nothing moves one drawing is enough.
    pub(super) fn shutter(
        &self,
        n: usize,
        secs: f32,
        draw: &dyn Fn(&mut Pixmap, f32),
    ) -> Option<Pixmap> {
        let mut px = self.layer()?;
        if n <= 1 {
            draw(&mut px, 0.0);
            return Some(px);
        }
        let mut open = Shutter::new(px.width(), px.height());
        for j in 0..n {
            px.fill(Color::TRANSPARENT);
            draw(&mut px, j as f32 * secs / n as f32);
            open.add(&px);
        }
        open.finish()
    }
}

/// A rounded rectangle from its middle and size.
pub(super) fn capsule(cx: f32, cy: f32, w: f32, h: f32, radius: f32) -> Option<Path> {
    Rect::from_xywh(cx - w / 2.0, cy - h / 2.0, w.max(0.5), h.max(0.5))
        .and_then(|r| rounded_rect(r, radius))
}

/// A band of light across a layer: a strip `half` wide either side of `x`, leaning by `lean`
/// (across per down), brightest in its middle.
pub(super) fn sweep(
    x: f32,
    y: f32,
    half: f32,
    lean: f32,
    c: Rgba,
    peak: f32,
) -> Option<Paint<'static>> {
    let clear = Rgba([c.0[0], c.0[1], c.0[2], 0]);
    let stops = vec![
        GradientStop::new(0.0, colour(clear, 1.0)),
        GradientStop::new(0.5, colour(c, peak)),
        GradientStop::new(1.0, colour(clear, 1.0)),
    ];
    // Perpendicular to a band that leans `lean` across for each pixel down.
    let n = (1.0 + lean * lean).sqrt();
    let (ux, uy) = (1.0 / n, -lean / n);
    let shader = LinearGradient::new(
        Point::from_xy(x - ux * half, y - uy * half),
        Point::from_xy(x + ux * half, y + uy * half),
        stops,
        SpreadMode::Pad,
        Transform::identity(),
    )?;
    Some(Paint {
        shader,
        anti_alias: true,
        ..Paint::default()
    })
}

/// How long after a word starts a look still moves it (seconds), or None for a look that never
/// stops moving while its line is up.
fn span(anim: Animation, w: &Placed) -> Option<f32> {
    let letters = w.letters.len().max(1) as f32;
    Some(match anim {
        Animation::Trailer
        | Animation::Rays
        | Animation::Depth
        | Animation::Liquid
        | Animation::Saber
        | Animation::Pulse => return None,
        Animation::Glint => 0.85,
        Animation::Weight => 0.55,
        Animation::Signal => 0.36,
        Animation::Marker => 0.3,
        Animation::Decode => letters::DECODE_FIRST + letters * letters::DECODE_STEP + 0.15,
        Animation::Flap => letters::FLAP_FIRST + letters * letters::FLAP_STEP + 0.12,
        Animation::Count => 1.25,
        Animation::Echo => 0.92,
        Animation::Reveal => 0.62,
        Animation::Elastic => 0.42,
        Animation::Split => 0.72,
        Animation::Block => 0.32,
        Animation::Beat => 0.34,
        Animation::Scroll => 0.38,
        Animation::Reel => 0.34,
        Animation::Fill => 0.52,
        Animation::Snap => 0.36,
        Animation::Knockout => 0.32,
        Animation::Mirror => 1.17,
        Animation::Fold => 0.44,
        _ => 0.0,
    })
}

/// Whether a composed look is moving at `t` on `line`: while it is, every frame is drawn; once
/// it is not, a frame is the same as the one before, until the next word starts.
pub(super) fn moving(anim: Animation, line: &Line, t: f32) -> bool {
    // The line comes up over a moment (and Reveal draws its rule through it).
    if t < line.start - LEAD_S + 0.75 {
        return true;
    }
    line.words.iter().any(|w| {
        let a = t - (w.start - LEAD_S);
        a >= 0.0 && span(anim, w).is_none_or(|s| a <= s)
    })
}

impl Scene {
    /// Draws one frame of a composed look's `line` at `t` onto `canvas`.
    pub(super) fn compose(&self, canvas: &mut Pixmap, line: &Line, t: f32) {
        let fx = Fx::new(self, line, t);
        fx.block(canvas);
        match self.style.animation {
            Animation::Glint => light::glint(&fx, canvas),
            Animation::Weight => letters::weight(&fx, canvas),
            Animation::Saber => light::saber(&fx, canvas),
            Animation::Signal => light::signal(&fx, canvas),
            Animation::Trailer => light::trailer(&fx, canvas),
            Animation::Marker => letters::marker(&fx, canvas),
            Animation::Decode => letters::decode(&fx, canvas),
            Animation::Rays => light::rays(&fx, canvas),
            Animation::Echo => motion::echo(&fx, canvas),
            Animation::Reveal => motion::reveal(&fx, canvas),
            Animation::Depth => light::depth(&fx, canvas),
            Animation::Liquid => light::liquid(&fx, canvas),
            Animation::Elastic => motion::elastic(&fx, canvas),
            Animation::Split => motion::split(&fx, canvas),
            Animation::Block => motion::block(&fx, canvas),
            Animation::Beat => motion::beat(&fx, canvas),
            Animation::Flap => letters::flap(&fx, canvas),
            Animation::Count => letters::count(&fx, canvas),
            Animation::Scroll => motion::scroll(&fx, canvas),
            Animation::Reel => motion::reel(&fx, canvas),
            Animation::Fill => light::fill(&fx, canvas),
            Animation::Snap => motion::snap(&fx, canvas),
            Animation::Pulse => voice::pulse(&fx, canvas),
            Animation::Knockout => motion::knockout(&fx, canvas),
            Animation::Mirror => light::mirror(&fx, canvas),
            Animation::Fold => motion::fold(&fx, canvas),
            _ => {}
        }
    }
}
