use super::*;

pub(super) fn rounded_rect(r: Rect, radius: f32) -> Option<Path> {
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

pub(super) fn colour(c: Rgba, opacity: f32) -> Color {
    let [r, g, b, a] = c.0;
    let mut out = Color::from_rgba8(r, g, b, a);
    out.apply_opacity(opacity);
    out
}

pub(super) fn mix(a: Rgba, b: Rgba, k: f32) -> Rgba {
    Rgba([0, 1, 2, 3].map(|i| lerp(f32::from(a.0[i]), f32::from(b.0[i]), k).round() as u8))
}

/// The stops of a vertical gradient through `colours`, evenly spaced, each run through `tint`;
/// None when there are fewer than two (then the one colour, or the text's, is used flat).
pub(super) fn gradient_stops(
    colours: &[Rgba],
    tint: &dyn Fn(Rgba) -> Rgba,
) -> Option<Vec<GradientStop>> {
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

pub(super) fn paint(c: Color) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(c);
    p.anti_alias = true;
    p
}

/// The colour with its alpha made opaque: a layer is painted opaque and given its alpha as a whole.
pub(super) fn solid(c: Rgba) -> Rgba {
    Rgba([c.0[0], c.0[1], c.0[2], 255])
}

pub(super) fn opacity(c: Rgba) -> f32 {
    f32::from(c.0[3]) / 255.0
}

/// What of a word's letters shows, as a layer cut off at `x`: from the left edge of the
/// letters to there (typing), or the whole of it with the colour over only that much (filling).
fn cut(x: f32, within: IntRect) -> Option<Mask> {
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
}

/// A line; each of its words' opacity, size, tilt, press, entrance and (for Drift, whose glow
/// brightens with it) brightness; and how the line is jolted and drifts: all the layers depend on.
fn layer_key(
    index: usize,
    states: &[WordState],
    animation: Animation,
    motion: LineMotion,
) -> LayerKey {
    // The shadow and the glow are the letters as they stand: they change when a word's
    // opacity, size or tilt does, and for most animations they do not change at all while
    // the line is up, so the finished layer (blur and all) is kept for the next frame.
    let look = states
        .iter()
        .map(|st| {
            [
                st.opacity.to_bits(),
                st.scale.to_bits(),
                st.tilt.to_bits(),
                st.press.to_bits(),
                st.enter.to_bits(),
                if animation == Animation::Drift {
                    st.on.to_bits()
                } else {
                    0
                },
            ]
        })
        .collect();
    let motion = [
        motion.jolt[0].to_bits(),
        motion.jolt[1].to_bits(),
        motion.drift[0].to_bits(),
        motion.drift[1].to_bits(),
        motion.drift[2].to_bits(),
    ];
    (index, look, motion)
}

impl Scene {
    /// Draws `line` at the animation state `states` onto `canvas`: the backdrops, the shadow and
    /// the glow, the words, then the bar.
    pub(super) fn draw(
        &self,
        canvas: &mut Pixmap,
        (index, line): (usize, &Line),
        states: &[WordState],
        guide: Option<Guide>,
        motion: LineMotion,
        cache: &mut LayerCache,
    ) {
        let painter = LinePainter::new(self, line, states, motion);
        let key = layer_key(index, states, self.style.animation, motion);
        // The glow is laid out once and carried with the line, so the line's drift does not
        // build it again each frame.
        let still = LineMotion {
            drift: NO_DRIFT,
            ..motion
        };
        let halo_key = layer_key(index, states, self.style.animation, still);
        painter.backdrops(canvas, guide);
        painter.shadow(canvas, &mut cache.shadow, &key);
        painter.glow(canvas, &mut cache.halo, &halo_key);
        painter.words(canvas);
        painter.bar(canvas, guide);
    }
}

/// One line being drawn: the style and the state of its words, and what the passes share.
#[derive(Clone, Copy)]
struct LinePainter<'a> {
    style: &'a Style,
    line: &'a Line,
    states: &'a [WordState],
    /// How far the line is knocked, in pixels.
    jolt: [f32; 2],
    /// How the line floats (across, down, scale), for Drift.
    drift: [f32; 3],
    /// A solid shadow is an extrusion.
    extruded: bool,
    /// `word_press` raises the word being said out of the page: its face lifts away from where it
    /// was (the back of the extrusion stays put) and the extrusion fills the gap, while the other
    /// words stay flat.
    pressing: bool,
    rising: bool,
    width: u32,
    height: u32,
    word_radius: f32,
    block_radius: f32,
}

impl<'a> LinePainter<'a> {
    fn new(scene: &'a Scene, line: &'a Line, states: &'a [WordState], motion: LineMotion) -> Self {
        let s = &scene.style;
        let extruded =
            s.shadow_blur <= 0.0 && (s.shadow_offset_x != 0.0 || s.shadow_offset_y != 0.0);
        Self {
            style: s,
            line,
            states,
            jolt: motion.jolt,
            drift: motion.drift,
            extruded,
            pressing: extruded && s.animation == Animation::WordPress,
            rising: s.animation == Animation::LetterRise,
            width: scene.width,
            height: scene.height,
            word_radius: scene.word_radius,
            block_radius: scene.block_radius,
        }
    }

    /// The transform that scales, tilts and knocks a word about the middle of its slot.
    fn pivot(&self, w: &Placed, st: &WordState) -> Transform {
        let (cx, cy) = (
            w.slot.x() + w.slot.width() / 2.0,
            w.slot.y() + w.slot.height() / 2.0,
        );
        let word = Transform::from_translate(-cx, -cy)
            .post_scale(st.scale, st.scale)
            .post_rotate(st.tilt)
            .post_translate(cx + self.jolt[0], cy + self.jolt[1]);
        if self.style.animation != Animation::Drift {
            return word;
        }
        word.post_concat(self.line_motion())
    }

    /// The whole line pushes in about its middle and floats: its drift as a transform of the frame.
    fn line_motion(&self) -> Transform {
        let [dx, dy, scale] = self.drift;
        let (ax, ay) = (
            self.line.anchor.x() + self.line.anchor.width() / 2.0,
            self.line.anchor.y() + self.line.anchor.height() / 2.0,
        );
        Transform::from_translate(-ax, -ay)
            .post_scale(scale, scale)
            .post_translate(ax + dx, ay + dy)
    }

    /// How much of its extrusion a word has: all of it, but for a word being pressed up.
    fn reach(&self, st: &WordState) -> f32 {
        if self.pressing {
            st.press.clamp(0.0, 1.0)
        } else {
            1.0
        }
    }

    /// How far the face has moved from the back, as a share of the offset (opposite to it).
    fn lifted(&self, st: &WordState) -> f32 {
        if self.pressing { self.reach(st) } else { 0.0 }
    }

    /// Where a word's face is.
    fn face(&self, w: &Placed, st: &WordState) -> Transform {
        let (s, k) = (self.style, self.lifted(st));
        self.pivot(w, st).post_translate(
            -s.shadow_offset_x * w.size * k,
            -s.shadow_offset_y * w.size * k,
        )
    }

    /// The outline, `k` being the word's size against the style's: it grows with the word.
    fn stroke(&self, k: f32) -> Option<Stroke> {
        let s = self.style;
        (s.stroke_width > 0.0).then(|| Stroke {
            width: s.stroke_width * k,
            line_join: LineJoin::Round,
            line_cap: LineCap::Round,
            ..Stroke::default()
        })
    }

    /// Stroke under fill, so a thick outline grows outward instead of eating the letter.
    fn ink_with(
        &self,
        px: &mut Pixmap,
        path: &Path,
        fill: &Paint,
        edge: Color,
        at: Transform,
        k: f32,
    ) {
        if let Some(stroke) = &self.stroke(k) {
            px.stroke_path(path, &paint(edge), stroke, at, None);
        }
        px.fill_path(path, fill, FillRule::Winding, at, None);
    }

    fn ink(&self, px: &mut Pixmap, path: &Path, fill: Color, edge: Color, at: Transform, k: f32) {
        self.ink_with(px, path, &paint(fill), edge, at, k);
    }

    /// A transform in frame pixels, made one in the line's own layer.
    fn local(&self, at: Transform) -> Transform {
        at.post_translate(-self.line.bounds.x() as f32, -self.line.bounds.y() as f32)
    }

    /// An empty layer the size of the line's box.
    fn layer(&self) -> Option<Pixmap> {
        Pixmap::new(self.line.bounds.width(), self.line.bounds.height())
    }

    /// The part of the frame one word's letters can touch, as a pixel box inside the line's:
    /// their moved and scaled outline, room for the stroke and `reach` more for a blur. A word
    /// is composited on its own, and a layer the size of the whole line for each of them,
    /// cleared, drawn and blended, was most of the cost of a fade.
    fn word_box(&self, path: &Path, w: &Placed, st: &WordState, reach: usize) -> Option<IntRect> {
        let b = path.bounds();
        let mut corners = [
            Point::from_xy(b.left(), b.top()),
            Point::from_xy(b.right(), b.top()),
            Point::from_xy(b.left(), b.bottom()),
            Point::from_xy(b.right(), b.bottom()),
        ];
        self.face(w, st).map_points(&mut corners);
        let moved = Rect::from_points(&corners)?;
        let r = pixel_bounds(
            moved,
            self.style.stroke_width + reach as f32 + 2.0,
            self.width,
            self.height,
        );
        r.intersect(&self.line.bounds)
    }

    /// What is behind the words: the block, the sliding box, the labels and the highlight boxes.
    fn backdrops(&self, canvas: &mut Pixmap, guide: Option<Guide>) {
        let (s, line) = (self.style, self.line);
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
            for (w, st) in line.words.iter().zip(self.states) {
                if let Some(path) = rounded_rect(w.slot, self.word_radius * w.size * 1.6) {
                    let p = paint(colour(s.highlight(w.index), 1.0));
                    canvas.fill_path(&path, &p, FillRule::Winding, self.pivot(w, st), None);
                }
            }
        }
        if s.animation == Animation::HighlightBox {
            for (w, st) in line
                .words
                .iter()
                .zip(self.states)
                .filter(|(_, st)| st.on > 0.0)
            {
                if let Some(path) = rounded_rect(w.slot, self.word_radius * w.size) {
                    let p = paint(colour(s.highlight(w.index), st.on * st.opacity));
                    let grow = WordState {
                        scale: st.box_scale,
                        ..*st
                    };
                    canvas.fill_path(&path, &p, FillRule::Winding, self.pivot(w, &grow), None);
                }
            }
        }
    }

    /// The shadow under the words: a soft one is the letters once, moved and blurred. A hard one is
    /// the letters carried from where they are to the offset, a pixel at a time, so it reads as
    /// their outline extended (an extrusion) and not as a second copy behind them. The finished
    /// layer is kept in `slot` while what it is made from stays the same.
    fn shadow(
        &self,
        canvas: &mut Pixmap,
        slot: &mut Option<(LayerKey, Option<Trimmed>)>,
        key: &LayerKey,
    ) {
        let s = self.style;
        let has_offset = s.shadow_offset_x != 0.0 || s.shadow_offset_y != 0.0;
        if !(s.shadow_blur > 0.0 || has_offset) {
            return;
        }
        if slot.as_ref().is_none_or(|(k, _)| k != key) {
            *slot = self.layer().map(|mut shadow| {
                self.extrusion(&mut shadow);
                if s.shadow_blur > 0.0 {
                    blur(&mut shadow, s.shadow_blur / 2.0);
                }
                (key.clone(), Trimmed::of(&shadow, self.origin()))
            });
        }
        if let Some((_, Some(shadow))) = slot {
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

    /// Where the line's layer sits in the frame.
    fn origin(&self) -> (i32, i32) {
        (self.line.bounds.x(), self.line.bounds.y())
    }

    /// Lays every word's shadow (stamps from the face towards the back) onto `shadow`.
    fn extrusion(&self, shadow: &mut Pixmap) {
        let s = self.style;
        let base = solid(s.shadow_color);
        let back = s.extrude_back.0;
        let graded = back[3] > 0 && self.extruded;
        let shaded = (s.extrude_shade > 0.0 || graded) && self.extruded;
        for (w, st) in self.line.words.iter().zip(self.states) {
            let letters = parts(w, st, s.font_size * w.size, self.rising);
            let reach = self.reach(st);
            if reach <= 0.0 {
                continue;
            }
            let steps = if s.shadow_blur > 0.0 {
                1
            } else {
                ((s.shadow_offset_x.abs().max(s.shadow_offset_y.abs()) * w.size * reach).ceil()
                    as usize)
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
                let along = reach * depth - self.lifted(st);
                let mut hue = base;
                if shaded {
                    if graded {
                        let end = Rgba([back[0], back[1], back[2], base.0[3]]);
                        hue = mix(base, end, depth);
                    }
                    hue = mix(hue, Rgba([0, 0, 0, 255]), s.extrude_shade * depth);
                    if step == 1 {
                        // The edge just behind the face catches the light.
                        hue = mix(hue, Rgba([255, 255, 255, 255]), RIM_LIGHT * s.extrude_shade);
                    }
                }
                for (path, down, shown) in &letters {
                    let c = colour(hue, st.opacity * shown);
                    let at = Transform::from_translate(0.0, *down)
                        .post_concat(self.pivot(w, st))
                        .post_translate(
                            s.shadow_offset_x * w.size * along,
                            s.shadow_offset_y * w.size * along,
                        );
                    self.ink(shadow, path, c, c, self.local(at), w.size);
                }
            }
        }
    }

    /// The halo round the letters, laid down `GLOW_PASSES` times to read as light.
    fn glow(
        &self,
        canvas: &mut Pixmap,
        slot: &mut Option<(LayerKey, Option<Trimmed>)>,
        key: &LayerKey,
    ) {
        let s = self.style;
        if s.glow_blur <= 0.0 {
            return;
        }
        let drifting = s.animation == Animation::Drift;
        // Laid out where the line would be without its drift, which is applied when it is laid down.
        let flat = Self {
            drift: NO_DRIFT,
            ..*self
        };
        if slot.as_ref().is_none_or(|(k, _)| k != key) {
            *slot = self.layer().and_then(|mut halo| {
                for (w, st) in self.line.words.iter().zip(self.states) {
                    for (path, down, shown) in parts(w, st, s.font_size * w.size, self.rising) {
                        // The word being said glows brighter than the others.
                        let gain = if drifting {
                            lerp(DRIFT_GLOW_REST, 1.0, st.on)
                        } else {
                            1.0
                        };
                        let c = colour(solid(s.glow_color), st.opacity * shown * gain);
                        let at = Transform::from_translate(0.0, down).post_concat(flat.face(w, st));
                        self.ink(&mut halo, path, c, c, self.local(at), w.size);
                    }
                }
                blur(&mut halo, s.glow_blur / 2.0);
                if drifting {
                    // Laid down once here, not three times each frame: it is carried by the
                    // line's motion every frame, and carrying it is what costs.
                    let mut laid = self.layer()?;
                    let p = PixmapPaint {
                        opacity: opacity(s.glow_color),
                        ..PixmapPaint::default()
                    };
                    for _ in 0..GLOW_PASSES {
                        laid.draw_pixmap(0, 0, halo.as_ref(), &p, Transform::identity(), None);
                    }
                    halo = laid;
                }
                Some((key.clone(), Trimmed::of(&halo, self.origin())))
            });
        }
        if let Some((_, Some(halo))) = slot {
            if drifting {
                let p = PixmapPaint {
                    quality: FilterQuality::Bilinear,
                    ..PixmapPaint::default()
                };
                let motion = self.line_motion();
                canvas.draw_pixmap(halo.x, halo.y, halo.pixmap.as_ref(), &p, motion, None);
                return;
            }
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

    /// The words, a word that has grown after the smaller ones, so it covers its neighbours rather
    /// than slipping behind them (the sort is stable: words of one size keep their order).
    fn words(&self, canvas: &mut Pixmap) {
        let mut order: Vec<usize> = (0..self.states.len()).collect();
        order.sort_by(|&a, &b| self.states[a].scale.total_cmp(&self.states[b].scale));
        for i in order {
            self.word(canvas, &self.line.words[i], &self.states[i]);
        }
    }

    /// One word: its underline, then its letters in the way its animation draws them, then its cursor.
    fn word(&self, canvas: &mut Pixmap, w: &Placed, st: &WordState) {
        let s = self.style;
        let Some(path) = &w.glyphs else { return };
        self.underline(canvas, w, st);
        let fill = self.word_fill(w, st);
        let edge = colour(s.stroke_color, 1.0);
        if s.animation == Animation::WordSweep && st.fill > 0.0 {
            self.swept(canvas, path, w, st, &fill, edge);
            return;
        }
        if self.rising && st.enter < 1.0 {
            self.rising_letters(canvas, w, st, &fill, edge);
            return;
        }
        let typed = s.animation == Animation::Typewriter;
        if typed && st.fill <= 0.0 {
            return;
        }
        if st.opacity >= 1.0 && st.soften <= 0.0 && !(typed && st.fill < 1.0) {
            self.ink_with(canvas, path, &fill, edge, self.face(w, st), w.size);
        } else {
            self.grouped(canvas, path, w, st, &fill, edge);
        }
        if typed && st.on > 0.0 {
            self.cursor(canvas, w, st);
        }
    }

    /// The underline is a marker stroke laid under the letters, left to right as the word is said.
    fn underline(&self, canvas: &mut Pixmap, w: &Placed, st: &WordState) {
        let s = self.style;
        if s.animation != Animation::WordUnderline || st.fill <= 0.0 {
            return;
        }
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

    /// The word's own paint: its colour, or the gradient over its letters, either turned toward
    /// the highlight by `on` for the looks that light the word being said.
    fn word_fill(&self, w: &Placed, st: &WordState) -> Paint<'static> {
        let s = self.style;
        let lit = match s.animation {
            Animation::WordHighlight
            | Animation::WordPop
            | Animation::WordBounce
            | Animation::LyricFocus
            | Animation::LetterRise
            | Animation::WordSlam
            | Animation::Drift
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
        let tint = |c: Rgba| mix(c, s.highlight(w.index), lit);
        match gradient_stops(&s.fill_colors, &tint) {
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
        }
    }

    /// What a sweep paints with: the one highlight colour, or a run through all of them across the
    /// whole line, so each word is a different part of it.
    fn sweep(&self) -> Paint<'static> {
        let (s, line) = (self.style, self.line);
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
    }

    /// A word the sweep has reached. Each letter is painted once: the highlight on the side the sweep
    /// has passed, the plain colour on the rest. Painting the highlight over a finished plain word
    /// would leave the plain word's soft edge showing round it, a pale fringe.
    fn swept(
        &self,
        canvas: &mut Pixmap,
        path: &Path,
        w: &Placed,
        st: &WordState,
        fill: &Paint,
        edge: Color,
    ) {
        let (on, at) = (self.sweep(), self.face(w, st));
        if st.fill >= 1.0 {
            self.ink_with(canvas, path, &on, edge, at, w.size);
        } else if let Some(within) = self.word_box(path, w, st, 0)
            && let (Some(mut passed), Some(mut ahead), Some(mask)) = (
                Pixmap::new(within.width(), within.height()),
                Pixmap::new(within.width(), within.height()),
                cut(w.ink_x + w.ink_w * st.fill, within),
            )
        {
            let at = at.post_translate(-within.x() as f32, -within.y() as f32);
            self.ink_with(&mut passed, path, &on, edge, at, w.size);
            passed.apply_mask(&mask);
            self.ink_with(&mut ahead, path, fill, edge, at, w.size);
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
    }

    /// The letters that have started, each climbing and fading in on its own.
    fn rising_letters(
        &self,
        canvas: &mut Pixmap,
        w: &Placed,
        st: &WordState,
        fill: &Paint,
        edge: Color,
    ) {
        let s = self.style;
        for (part, down, shown) in parts(w, st, s.font_size * w.size, true) {
            let reach = (s.font_size * w.size * RISE_FROM).ceil() as usize + 2;
            if let Some(within) = self.word_box(part, w, st, reach)
                && let Some(mut group) = Pixmap::new(within.width(), within.height())
            {
                let at = Transform::from_translate(0.0, down)
                    .post_concat(self.face(w, st))
                    .post_translate(-within.x() as f32, -within.y() as f32);
                self.ink_with(&mut group, part, fill, edge, at, w.size);
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
    }

    /// A word that is translucent, soft or partly typed, composited as one group, like CSS
    /// opacity, so the stroke under the fill does not show through a translucent letter.
    fn grouped(
        &self,
        canvas: &mut Pixmap,
        path: &Path,
        w: &Placed,
        st: &WordState,
        fill: &Paint,
        edge: Color,
    ) {
        // A word not yet in view draws nothing, whatever its blur.
        if st.opacity <= 0.0 {
            return;
        }
        let s = self.style;
        let typed = s.animation == Animation::Typewriter;
        let sigma = st.soften * s.font_size * w.size * FOCUS_BLUR;
        let reach = if st.soften > 0.0 {
            blur_reach(sigma)
        } else {
            0
        };
        if let Some(within) = self.word_box(path, w, st, reach)
            && let Some(mut group) = Pixmap::new(within.width(), within.height())
        {
            let at = self
                .face(w, st)
                .post_translate(-within.x() as f32, -within.y() as f32);
            self.ink_with(&mut group, path, fill, edge, at, w.size);
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

    /// The typewriter's cursor sits where the next letter goes, for as long as the word is being said.
    fn cursor(&self, canvas: &mut Pixmap, w: &Placed, st: &WordState) {
        let s = self.style;
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

    /// The line bar, under the line.
    fn bar(&self, canvas: &mut Pixmap, guide: Option<Guide>) {
        let s = self.style;
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
