//! The looks made of light: blooms, sweeps, rays, glitches, focus and liquid metal. A light is
//! added (`BlendMode::Plus`) inside the caption layer, which is then laid over the video.

use super::*;

/// The middle of the caption block.
fn middle(fx: &Fx) -> (f32, f32) {
    let a = fx.line.anchor;
    (a.x() + a.width() / 2.0, a.y() + a.height() / 2.0)
}

/// Glint: bold letters on a heavy outline and a hard drop. The word being said snaps in with real
/// motion blur, takes the gradient (gold), and a light sweep crosses it.
pub(in crate::scene) fn glint(fx: &Fx, canvas: &mut Pixmap) {
    let pose = |w: &Said, a: f32| {
        let p = (a / 0.36).clamp(0.0, 1.0);
        let s = lerp(0.45, 1.0, back_out(p));
        about(w.centre(), (s, s), (1.0 - cubic_out(p)) * -0.14, (0.0, 0.0))
    };
    let draw = |px: &mut Pixmap, w: &Said, a: f32| {
        let Some(path) = &w.w.glyphs else { return };
        let at = pose(w, a);
        let shown = (a / 0.06).min(1.0);
        let fill = if fx.is_act(w) {
            fx.gradient(w, fx.s.primary())
        } else {
            paint(colour(fx.ink_of(w), 1.0))
        };
        let dark = colour(fx.s.stroke_color, shown);
        let drop = at.pre_translate(0.0, 0.125 * w.fs);
        let line = fx.s.stroke_width * w.w.size;
        if line > 0.0 {
            fx.edge(px, path, dark, line, drop);
        }
        fx.fill(px, path, &paint(dark), drop);
        if line > 0.0 {
            fx.edge(px, path, dark, line, at);
        }
        let mut fill = fill;
        fill.shader.apply_opacity(shown);
        fx.fill(px, path, &fill, at);
    };
    let moving = fx.started().any(|w| w.a < 0.42);
    let Some(ink) = fx.shutter(if moving { 8 } else { 1 }, 0.05, &|px, back| {
        for w in fx.started() {
            if w.a - back >= 0.0 {
                draw(px, w, w.a - back);
            }
        }
    }) else {
        return;
    };
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
    let Some(w) = fx.act.map(|i| &fx.words[i]) else {
        return;
    };
    let (Some(path), Some(mut lit)) = (&w.w.glyphs, fx.layer()) else {
        return;
    };
    fx.fill(&mut lit, path, &paint(Color::WHITE), pose(w, w.a));
    let g = fx.s.glow_color;
    fx.bloom(
        canvas,
        &lit,
        &[
            (0.107, Some(mix(g, WHITE, 0.5)), 0.45),
            (0.39, Some(g), 0.3),
        ],
    );
    let gp = (w.a - 0.3) / 0.5;
    if gp <= 0.0 || gp >= 1.0 {
        return;
    }
    let x = lerp(
        w.w.ink_x - 0.9 * w.fs,
        w.w.ink_x + w.w.ink_w + 0.9 * w.fs,
        cubic_in_out(gp),
    );
    if let (Some(band), Some(matte), Some(mut shine)) = (
        sweep(x, w.mid(), 0.61 * w.fs, 0.4, WHITE, 0.95),
        fx.matte(&lit),
        fx.layer(),
    ) {
        let b = fx.line.bounds;
        if let Some(r) = Rect::from_xywh(
            b.x() as f32,
            b.y() as f32,
            b.width() as f32,
            b.height() as f32,
        ) {
            shine.fill_rect(r, &band, fx.local(Transform::identity()), Some(&matte));
        }
        fx.put(canvas, &shine, 1.0, BlendMode::Plus, (0.0, 0.0));
    }
}

/// Saber: a glowing stroke writes each letter's outline, then the face fills in over its own glow.
/// While the word is said, bright comets run around its edges.
pub(in crate::scene) fn saber(fx: &Fx, canvas: &mut Pixmap) {
    let (Some(mut light), Some(mut core), Some(mut face)) = (fx.layer(), fx.layer(), fx.layer())
    else {
        return;
    };
    let g = fx.s.glow_color;
    let stroke = |px: &mut Pixmap, path: &Path, c: Color, width: f32, dash: Option<StrokeDash>| {
        let s = Stroke {
            width: width.max(1.0),
            line_join: LineJoin::Round,
            line_cap: LineCap::Round,
            dash,
            ..Stroke::default()
        };
        px.stroke_path(path, &paint(c), &s, fx.local(Transform::identity()), None);
    };
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let (lit, writing) = (fx.is_act(w), w.a < 0.6);
        // Full while the outline is written, then the glow settles back within half a second,
        // whether or not the word is still being said.
        let glow = 1.0 - ((w.a - 0.6) / 0.5).clamp(0.0, 1.0);
        // The write-on: each outline drawn from its start as far as the stroke has reached.
        let reach = 12.2 * w.fs * cubic_in_out(w.a / 0.6);
        let dash = || {
            writing
                .then(|| StrokeDash::new(vec![reach.max(0.01), 81.0 * w.fs], 0.0))
                .flatten()
        };
        if !writing || reach > 0.5 {
            stroke(
                &mut light,
                path,
                colour(WHITE, lerp(0.25, 1.0, glow)),
                0.095 * w.fs,
                dash(),
            );
            let c = colour(mix(WHITE, g, 0.1), lerp(0.5, 1.0, glow));
            stroke(&mut core, path, c, 0.024 * w.fs, dash());
        }
        if lit && w.a > 0.45 {
            let (on, off) = (0.68 * w.fs, 3.24 * w.fs);
            let phase = (w.a * 7.57 * w.fs).rem_euclid(on + off);
            let comets = || StrokeDash::new(vec![on, off], on + off - phase);
            stroke(&mut light, path, colour(WHITE, 1.0), 0.135 * w.fs, comets());
            stroke(&mut core, path, colour(WHITE, 1.0), 0.041 * w.fs, comets());
        }
        let shown = cubic_out((w.a - 0.3) / 0.3);
        if shown > 0.0 {
            let mut fill = fx.gradient(w, fx.ink_of(w));
            fill.shader.apply_opacity(shown);
            fx.fill(&mut face, path, &fill, Transform::identity());
        }
    }
    let deep = fx.s.primary();
    fx.shadow(canvas, &face, 1.0);
    fx.bloom(
        canvas,
        &light,
        &[
            (0.04, Some(mix(g, WHITE, 0.65)), 0.9),
            (0.12, Some(g), 1.3),
            (0.32, Some(mix(g, deep, 0.5)), 0.8),
            (0.81, Some(deep), 0.4),
        ],
    );
    fx.over(canvas, &face);
    fx.put(canvas, &core, 1.0, BlendMode::Plus, (0.0, 0.0));
}

/// Signal: each word tears in like a broken transmission, its colour channels split and its bands
/// sliding apart, with scanlines and stray blocks, then locks clean with a faint chromatic edge.
pub(in crate::scene) fn signal(fx: &Fx, canvas: &mut Pixmap) {
    let frame = (fx.t * 30.0).floor() as u32;
    let Some(mut plain) = fx.layer() else { return };
    for w in fx.started() {
        if let Some(path) = &w.w.glyphs {
            fx.fill(
                &mut plain,
                path,
                &paint(Color::WHITE),
                Transform::identity(),
            );
        }
    }
    fx.shadow(canvas, &plain, 1.0);
    for w in fx.started() {
        let (Some(path), Some(mut split), Some(mut out)) = (&w.w.glyphs, fx.layer(), fx.layer())
        else {
            continue;
        };
        let g = 1.0 - w.into(0.34);
        let n = w.w.index as u32;
        let d = 0.024 * w.fs + 0.18 * w.fs * g * (0.5 + hash(frame * 13 + n));
        let [r, gr, b, _] = fx.ink_of(w).0;
        for (c, dx) in [
            (Rgba([r, 0, 0, 255]), -d),
            (Rgba([0, gr, 0, 255]), 0.0),
            (Rgba([0, 0, b, 255]), d),
        ] {
            let mut p = paint(colour(c, 1.0));
            p.blend_mode = BlendMode::Plus;
            fx.fill(&mut split, path, &p, Transform::from_translate(dx, 0.0));
        }
        let top = w.w.baseline - 0.8 * w.fs;
        if g <= 0.0 {
            out = split;
        } else {
            // Bands of the word slide apart, each its own way.
            let band = 0.95 * w.fs / 5.0;
            let (_, oy) = fx.origin();
            for k in 0..5u32 {
                let y0 = (top + k as f32 * band - oy as f32).max(0.0);
                let off = (hash(frame * 31 + k * 7 + n * 101) - 0.5) * 0.76 * w.fs * g;
                let strip = IntRect::from_xywh(0, y0 as i32, split.width(), band.ceil() as u32 + 1)
                    .and_then(|r| {
                        r.intersect(&IntRect::from_xywh(0, 0, split.width(), split.height())?)
                    })
                    .and_then(|r| Some((r, split.clone_rect(r)?)));
                if let Some((r, piece)) = strip {
                    out.draw_pixmap(
                        off.round() as i32,
                        r.y(),
                        piece.as_ref(),
                        &PixmapPaint::default(),
                        Transform::identity(),
                        None,
                    );
                }
            }
            let (period, thick) = ((0.06 * w.fs).max(3.0), (0.023 * w.fs).max(1.0));
            let bottom = w.w.baseline + 0.15 * w.fs;
            fade(&mut out, fx.origin(), false, &|y| {
                if y >= top && y <= bottom && (y - top) % period < thick {
                    0.65
                } else {
                    1.0
                }
            });
            for m in 0..2u32 {
                let h = |q: u32| hash(frame * 17 + m * 5 + n * 71 + q);
                let x = w.w.ink_x + h(2) * w.w.ink_w;
                let y = top + h(3) * w.fs;
                if let Some(rect) = Rect::from_xywh(
                    x,
                    y,
                    (0.12 + 0.76 * h(4)) * w.fs,
                    (0.045 + 0.09 * h(5)) * w.fs,
                ) {
                    let p = paint(colour(fx.s.highlight(if h(1) > 0.5 { 0 } else { 1 }), 1.0));
                    out.fill_rect(rect, &p, fx.local(Transform::identity()), None);
                }
            }
        }
        let opacity = if fx.is_act(w) { 1.0 } else { 0.72 };
        fx.put(canvas, &out, opacity, BlendMode::SourceOver, (0.0, 0.0));
    }
}

/// Lays a line's rows out again with each word `widths[i]` wide, every row held where the layout
/// put it (its middle, or its left or right edge), and returns where each word now starts. The
/// space after word `i` is its own width plus `after[i]`.
pub(in crate::scene) fn reflow(fx: &Fx, widths: &[f32], after: &[f32]) -> Vec<f32> {
    let mut starts: Vec<f32> = fx.words.iter().map(|w| w.w.ink_x).collect();
    let rows = fx.words.iter().map(|w| w.w.row).max().map_or(0, |r| r + 1);
    for row in 0..rows {
        let mut order: Vec<&Said> = fx.words.iter().filter(|w| w.w.row == row).collect();
        order.sort_by(|a, b| a.w.ink_x.total_cmp(&b.w.ink_x));
        let (Some(first), Some(last)) = (order.first(), order.last()) else {
            continue;
        };
        let (left, right) = (first.w.ink_x, last.w.ink_x + last.w.ink_w);
        let gaps: f32 = order
            .windows(2)
            .map(|p| p[1].w.ink_x - (p[0].w.ink_x + p[0].w.ink_w) + after[p[0].i])
            .sum();
        let total = order.iter().map(|w| widths[w.i]).sum::<f32>() + gaps;
        let mut x = match fx.s.align {
            Align::Left => left,
            Align::Right => right - total,
            Align::Center | Align::Justify => (left + right) / 2.0 - total / 2.0,
        };
        for (k, w) in order.iter().enumerate() {
            starts[w.i] = x;
            x += widths[w.i];
            if let Some(next) = order.get(k + 1) {
                x += next.w.ink_x - (w.w.ink_x + w.w.ink_w) + after[w.i];
            }
        }
    }
    starts
}

/// Trailer: a film title card. A serif whose wide tracking slowly pulls in as each word fades out
/// of a blur, a warm halo, grain inside the letters, and a soft scrim behind to keep it legible.
pub(in crate::scene) fn trailer(fx: &Fx, canvas: &mut Pixmap) {
    let tracks: Vec<f32> = fx
        .words
        .iter()
        .map(|w| lerp(0.32, 0.03, cubic_out(w.a.max(0.0) / 1.5)) * w.fs)
        .collect();
    let widths: Vec<f32> = fx
        .words
        .iter()
        .map(|w| w.w.ink_w + w.w.letters.len().saturating_sub(1) as f32 * tracks[w.i])
        .collect();
    // The letters are tracked wide, so the space between words opens up with them.
    let spaces: Vec<f32> = tracks.iter().map(|t| 2.5 * t).collect();
    let starts = reflow(fx, &widths, &spaces);
    // The scrim: a dark ellipse behind the line that fades to nothing before the box's edge.
    let (cx, cy) = middle(fx);
    let b = fx.line.bounds;
    let rx = (0.48 * fx.scene.width as f32).min(
        (b.width() as f32 / 2.0)
            .min(cx - b.x() as f32)
            .min(b.right() as f32 - cx),
    );
    let ry = (rx * 0.32).min((cy - b.y() as f32).min(b.bottom() as f32 - cy));
    let shade = fx.s.shadow_color;
    if rx > 1.0 && ry > 1.0 && opacity(shade) > 0.0 {
        let clear = Rgba([shade.0[0], shade.0[1], shade.0[2], 0]);
        let stops = vec![
            GradientStop::new(0.0, colour(shade, 1.0)),
            GradientStop::new(1.0, colour(clear, 1.0)),
        ];
        let squash = Transform::from_translate(-cx, -cy)
            .post_scale(1.0, ry / rx)
            .post_translate(cx, cy);
        if let Some(shader) = RadialGradient::new(
            Point::from_xy(cx, cy),
            0.0,
            Point::from_xy(cx, cy),
            rx,
            stops,
            SpreadMode::Pad,
            squash,
        ) && let Some(r) = Rect::from_xywh(
            b.x() as f32,
            b.y() as f32,
            b.width() as f32,
            b.height() as f32,
        ) {
            let p = Paint {
                shader,
                anti_alias: true,
                ..Paint::default()
            };
            canvas.fill_rect(r, &p, Transform::identity(), None);
        }
    }
    let Some(mut ink) = fx.layer() else { return };
    for w in fx.started() {
        let shift = starts[w.i] - w.w.ink_x;
        let fill = paint(colour(fx.ink_of(w), 1.0));
        let soft = 0.083 * w.fs * (1.0 - cubic_out(w.a / 0.8));
        let alpha = cubic_out(w.a / 0.7);
        let Some(mut one) = fx.layer() else { continue };
        let target = if soft > 0.6 || alpha < 1.0 {
            &mut one
        } else {
            &mut ink
        };
        if w.w.letters.is_empty()
            && let Some(path) = &w.w.glyphs
        {
            fx.fill(target, path, &fill, Transform::from_translate(shift, 0.0));
        }
        for (j, letter) in w.w.letters.iter().enumerate() {
            if let Some(path) = &letter.path {
                fx.fill(
                    target,
                    path,
                    &fill,
                    Transform::from_translate(shift + j as f32 * tracks[w.i], 0.0),
                );
            }
        }
        if soft > 0.6 || alpha < 1.0 {
            soften(&mut one, soft);
            onto(&mut ink, &one, alpha);
        }
    }
    let g = fx.s.glow_color;
    fx.bloom(
        canvas,
        &ink,
        &[
            (0.167, Some(mix(g, WHITE, 0.55)), 0.35),
            (0.5, Some(g), 0.18),
        ],
    );
    grain(&mut ink, fx.origin(), (fx.t * 24.0).floor() as u32);
    fx.over(canvas, &ink);
}

/// Rays: light pours out of the letters toward the camera from a source that sweeps slowly along
/// the line, and swells as each word is said. The letters stay solid in front of their own light.
pub(in crate::scene) fn rays(fx: &Fx, canvas: &mut Pixmap) {
    let (Some(mut ink), Some(mut light)) = (fx.layer(), fx.layer()) else {
        return;
    };
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let p = cubic_out(w.a / 0.35);
        let at = about(
            w.centre(),
            (lerp(1.08, 1.0, p), lerp(1.08, 1.0, p)),
            0.0,
            (0.0, 0.0),
        );
        fx.fill(&mut ink, path, &paint(colour(fx.ink_of(w), p)), at);
        let glow = p * if fx.is_act(w) { 1.0 } else { 0.3 };
        fx.fill(&mut light, path, &paint(colour(WHITE, glow)), at);
    }
    let (cx, _) = middle(fx);
    let fs = fx.fs();
    let sx = cx + sine(fx.t * 0.8 / std::f32::consts::TAU) * 0.25 * fx.scene.width as f32;
    let sy = fx.line.anchor.bottom() + 0.75 * fs;
    // A zoom blur away from the source: the light and copies of itself, each a little larger,
    // doubled five times over (32 copies).
    let (ox, oy) = fx.origin();
    let k = 4.0;
    fx.shadow(canvas, &ink, 1.0);
    // All of the beams' work is done at a quarter size and only laid on at full size.
    if let Some(mut beams) = shrink(&tint(&light, Rgba([255, 255, 255, 27])), k as u32) {
        let centre = ((sx - ox as f32) / k, (sy - oy as f32) / k);
        let mut step = 1.025f32;
        for _ in 0..5 {
            let mut next = beams.clone();
            let p = PixmapPaint {
                opacity: 0.85,
                blend_mode: BlendMode::Plus,
                quality: FilterQuality::Bilinear,
            };
            next.draw_pixmap(
                0,
                0,
                beams.as_ref(),
                &p,
                about(centre, (step, step), 0.0, (0.0, 0.0)),
                None,
            );
            beams = next;
            step *= step;
        }
        let mut beams = tint(&beams, mix(fx.s.glow_color, WHITE, 0.3));
        // Faded out before the edges of the box, so the light ends softly.
        let (b, edge) = (fx.line.bounds, 0.6 * fs);
        let (w, h) = (b.width() as f32 / k, b.height() as f32 / k);
        let soft = edge / k;
        fade(&mut beams, (0, 0), true, &|x| {
            (x / soft).min((w - x) / soft)
        });
        fade(&mut beams, (0, 0), false, &|y| {
            (y / soft).min((h - y) / soft)
        });
        let up = Transform::from_scale(k, k).post_translate(ox as f32 + 1.5, oy as f32 + 1.5);
        for opacity in [1.0, 0.6] {
            let p = PixmapPaint {
                opacity,
                blend_mode: BlendMode::Plus,
                quality: FilterQuality::Bilinear,
            };
            canvas.draw_pixmap(0, 0, beams.as_ref(), &p, up, None);
        }
    }
    // The letters' own light, and a dark rim that keeps them solid in front of it.
    fx.bloom(canvas, &light, &[(0.31, Some(fx.s.glow_color), 0.4)]);
    let d = (0.031 * fs).max(1.0);
    if let Some((piece, x, y)) = extent_of(&ink).and_then(|e| cut_out(&ink, e, 0)) {
        let rim = tint(&piece, mix(fx.s.glow_color, BLACK, 0.9));
        for (dx, dy) in [(-d, 0.0), (d, 0.0), (0.0, -d), (0.0, 1.5 * d)] {
            fx.put(
                canvas,
                &rim,
                0.6,
                BlendMode::SourceOver,
                (dx + x as f32, dy + y as f32),
            );
        }
        fx.put(
            canvas,
            &piece,
            1.0,
            BlendMode::SourceOver,
            (x as f32, y as f32),
        );
    }
}

/// Depth: a focus pull. The whole line is in the shot, softly out of focus; focus racks onto each
/// word as it is said while the camera creeps in and drifts, so nearer and farther words slide a
/// little past each other.
pub(in crate::scene) fn depth(fx: &Fx, canvas: &mut Pixmap) {
    let words = &fx.words;
    let line = fx.line;
    let since = fx.t - (line.start - LEAD_S);
    let focus: f32 = words.iter().skip(1).map(|w| cubic_in_out(w.a / 0.35)).sum();
    let last = words.last().map_or(0.0, |w| w.w.start - line.start);
    let push = 1.0 + 0.04 * cubic_in_out(since / (last + 1.0));
    let shown = ramp(since, 0.0, 0.3);
    let pan = -since * 0.113 * fx.fs();
    let centre = middle(fx);
    let camera = about(centre, (push, push), 0.0, (0.0, 0.0));
    let mut order: Vec<(&Said, f32)> = words.iter().map(|w| (w, w.i as f32 - focus)).collect();
    order.sort_by(|a, b| b.1.abs().total_cmp(&a.1.abs()));
    let s = fx.s;
    for (w, d) in order {
        let (Some(path), Some(mut one)) = (&w.w.glyphs, fx.layer()) else {
            continue;
        };
        let far = d.abs().min(1.4);
        let near = far.min(1.0);
        let soft = far * if d > 0.0 { 0.055 } else { 0.042 } * w.fs;
        let scale = 1.05 - 0.08 * near;
        let alpha = shown
            * if d > 0.0 {
                lerp(1.0, 0.5, near)
            } else {
                lerp(1.0, 0.65, near)
            };
        let dx = pan * (1.0 + 0.15 * d.clamp(-1.0, 1.0));
        let dy = sine((fx.t * 1.3 + w.i as f32 * 1.7) / std::f32::consts::TAU) * 0.04 * w.fs;
        let at = about(w.centre(), (scale, scale), 0.0, (dx, dy)).post_concat(camera);
        fx.fill(&mut one, path, &paint(colour(fx.ink_of(w), 1.0)), at);
        let sharp = 1.0 - near;
        let shade_sigma = s.shadow_blur / 2.0 + soft;
        let Some(extent) = extent_of(&one) else {
            continue;
        };
        let Some((mut piece, x, y)) = cut_out(&one, extent, blur_reach(shade_sigma.max(soft)))
        else {
            continue;
        };
        let (x, y) = (x as f32, y as f32);
        if opacity(s.shadow_color) > 0.0 {
            let mut shade = tint(&piece, solid(s.shadow_color));
            soften(&mut shade, shade_sigma);
            let gain = opacity(s.shadow_color) * lerp(0.5, 1.0, sharp) * alpha;
            let drop = s.shadow_offset_y * lerp(0.57, 1.0, sharp);
            fx.put(
                canvas,
                &shade,
                gain,
                BlendMode::SourceOver,
                (s.shadow_offset_x + x, drop + y),
            );
        }
        if soft > 0.6 {
            soften(&mut piece, soft);
        }
        fx.put(canvas, &piece, alpha, BlendMode::SourceOver, (x, y));
    }
}

/// The stops of a polished metal from a light and a dark colour: a bright top, the light, a dark
/// horizon line, and the light again below it.
fn metal(light: Rgba, dark: Rgba) -> Vec<GradientStop> {
    [
        (0.0, mix(light, WHITE, 0.7)),
        (0.3, light),
        (0.5, mix(light, dark, 0.5)),
        (0.56, dark),
        (0.76, mix(light, WHITE, 0.4)),
        (1.0, mix(light, dark, 0.4)),
    ]
    .into_iter()
    .map(|(at, c)| GradientStop::new(at, colour(c, 1.0)))
    .collect()
}

/// The rows of the line: each row's baseline and size, top to bottom.
fn rows(fx: &Fx) -> Vec<(f32, f32)> {
    let mut rows: Vec<(f32, f32)> = vec![];
    for w in &fx.words {
        if !rows.iter().any(|r| (r.0 - w.w.baseline).abs() < 0.5) {
            rows.push((w.w.baseline, w.fs));
        }
    }
    rows.sort_by(|a, b| a.0.total_cmp(&b.0));
    rows
}

/// Liquid: molten metal poured into the letters. Drops fall and run together as each word fills
/// from the bottom up, then it settles to polished metal inside a dark rim, with a highlight that
/// slowly rolls across it.
pub(in crate::scene) fn liquid(fx: &Fx, canvas: &mut Pixmap) {
    let Some(mut goo) = fx.layer() else { return };
    for w in fx.started() {
        let (Some(path), Some(mut m)) = (&w.w.glyphs, fx.layer()) else {
            continue;
        };
        let p = cubic_in_out(w.a / 0.8);
        let top = w.w.baseline - 0.74 * w.fs;
        let level = lerp(w.w.baseline + 0.095 * w.fs, top - 0.19 * w.fs, p);
        if let Some(below) = fx.side(level, false) {
            let fat = lerp(0.143, 0.0, p) * w.fs;
            if fat > 0.5 {
                let s = Stroke {
                    width: fat,
                    line_join: LineJoin::Round,
                    ..Stroke::default()
                };
                m.stroke_path(
                    path,
                    &paint(Color::WHITE),
                    &s,
                    fx.local(Transform::identity()),
                    Some(&below),
                );
            }
            fx.fill_in(
                &mut m,
                path,
                &paint(Color::WHITE),
                Transform::identity(),
                &below,
            );
        }
        for n in 0..9u32 {
            let h = |q: u32| hash(w.w.index as u32 * 53 + n * 11 + q);
            let ta = w.a - h(1) * 0.45;
            if ta < 0.0 {
                continue;
            }
            let y = top - (1.43 + 1.07 * h(2)) * w.fs + 15.5 * w.fs * ta * ta;
            if y > level + 0.07 * w.fs {
                continue;
            }
            let x = w.w.ink_x + w.w.ink_w * (0.05 + 0.9 * h(3));
            let r = (0.048 + 0.071 * h(4)) * w.fs;
            if let Some(drop) = Rect::from_xywh(x - 0.8 * r, y - 1.25 * r, 1.6 * r, 2.5 * r)
                .and_then(PathBuilder::from_oval)
            {
                fx.fill(&mut m, &drop, &paint(Color::WHITE), Transform::identity());
            }
        }
        let sigma = lerp(0.06, 0.013, p) * w.fs;
        if let Some((mut piece, x, y)) =
            extent_of(&m).and_then(|e| cut_out(&m, e, blur_reach(sigma)))
        {
            soften(&mut piece, sigma);
            goo.draw_pixmap(
                x,
                y,
                piece.as_ref(),
                &PixmapPaint::default(),
                Transform::identity(),
                None,
            );
        }
    }
    // From here on only the part of the box round the metal is worked on.
    let fs = fx.fs();
    let lip = (0.048 * fs).round().max(1.0) as i32;
    let rise = (0.06 * fs).round().max(1.0) as i32;
    let margin = blur_reach(fx.s.shadow_blur / 2.0).max(blur_reach(0.19 * fs)) + rise as usize + 2;
    let Some((goo, ox, oy)) = extent_of(&goo).and_then(|e| cut_out(&goo, e, margin)) else {
        return;
    };
    let at = (ox, oy);
    let place = |x: f32, y: f32| (x + ox as f32, y + oy as f32);
    let here = fx
        .local(Transform::identity())
        .post_translate(-ox as f32, -oy as f32);
    // The same blur cut at a lower level is a little fatter: a dark rim that keeps the metal apart
    // from the picture.
    let rim = threshold(&goo, 36, 68);
    let metal_mask = threshold(&goo, 112, 144);
    let fills = &fx.s.fill_colors;
    let light = fills.first().copied().unwrap_or(fx.s.primary());
    let dark = fills
        .last()
        .copied()
        .filter(|_| fills.len() > 1)
        .unwrap_or(mix(light, BLACK, 0.3));
    fx.shadow_at(canvas, &rim, 1.0, at);
    fx.put(
        canvas,
        &tint(&rim, mix(dark, BLACK, 0.8)),
        1.0,
        BlendMode::SourceOver,
        place(0.0, 0.0),
    );
    let (Some(matte), Some(mut face)) = (
        fx.matte(&metal_mask),
        Pixmap::new(goo.width(), goo.height()),
    ) else {
        return;
    };
    let rows = rows(fx);
    let b = fx.line.bounds;
    for (k, &(baseline, fs)) in rows.iter().enumerate() {
        let above = if k == 0 {
            b.y() as f32
        } else {
            (rows[k - 1].0 + baseline) / 2.0
        };
        let below = rows
            .get(k + 1)
            .map_or(b.bottom() as f32, |r| (r.0 + baseline) / 2.0);
        let top = baseline - 0.74 * fs;
        if let (Some(shader), Some(r)) = (
            LinearGradient::new(
                Point::from_xy(0.0, top),
                Point::from_xy(0.0, baseline + 0.05 * fs),
                metal(light, dark),
                SpreadMode::Pad,
                Transform::identity(),
            ),
            Rect::from_ltrb(b.x() as f32, above, b.right() as f32, below),
        ) {
            let p = Paint {
                shader,
                anti_alias: true,
                ..Paint::default()
            };
            face.fill_rect(r, &p, here, Some(&matte));
        }
    }
    fx.put(canvas, &face, 1.0, BlendMode::SourceOver, place(0.0, 0.0));
    let mut low = tint(
        &minus(&metal_mask, &metal_mask, -lip),
        mix(dark, BLACK, 0.55),
    );
    soften(&mut low, 0.018 * fs);
    fx.put(canvas, &low, 0.6, BlendMode::SourceOver, place(0.0, 0.0));
    let mut high = tint(&minus(&metal_mask, &metal_mask, rise), WHITE);
    soften(&mut high, 0.014 * fs);
    fx.put(canvas, &high, 0.9, BlendMode::Plus, place(0.0, 0.0));
    let width = fx.scene.width as f32;
    let x = (fx.t * 0.24 * width).rem_euclid(1.55 * width) - 0.28 * width;
    if let (Some(band), Some(mut shine)) = (
        sweep(x, b.y() as f32, 0.71 * fs, 0.55, WHITE, 0.55),
        Pixmap::new(goo.width(), goo.height()),
    ) && let Some(r) = Rect::from_xywh(
        b.x() as f32,
        b.y() as f32,
        b.width() as f32,
        b.height() as f32,
    ) {
        shine.fill_rect(r, &band, here, Some(&matte));
        fx.put(canvas, &shine, 1.0, BlendMode::Plus, place(0.0, 0.0));
    }
    fx.bloom_at(
        canvas,
        &metal_mask,
        &[(0.19, Some(fx.s.glow_color), 0.22)],
        at,
    );
}

/// Fill: the line waits as clean outlines; the word being said fills from the bottom with a moving
/// wave and a bright edge on the water line, then rests solid.
pub(in crate::scene) fn fill(fx: &Fx, canvas: &mut Pixmap) {
    let (Some(mut ink), Some(mut edge)) = (fx.layer(), fx.layer()) else {
        return;
    };
    let shown = fx.shown();
    for w in &fx.words {
        if let Some(path) = &w.w.glyphs {
            fx.edge(
                &mut ink,
                path,
                colour(fx.ink_of(w), shown),
                (0.034 * w.fs).max(1.0),
                Transform::identity(),
            );
        }
    }
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let p = cubic_in_out(w.a / 0.5);
        let level = lerp(w.w.baseline + 0.25 * w.fs, w.w.baseline - 0.935 * w.fs, p);
        let amp = 0.081 * w.fs * (1.0 - p * p);
        let (x0, x1) = (
            w.w.ink_x - 0.135 * w.fs,
            w.w.ink_x + w.w.ink_w + 0.135 * w.fs,
        );
        let surface = |x: f32| {
            let u = (x - w.w.ink_x) / w.fs;
            let tau = std::f32::consts::TAU;
            level
                + sine((u * 3.7 + fx.t * 9.0) / tau) * amp
                + sine((u * 8.14 - fx.t * 6.0) / tau) * amp * 0.5
        };
        let step = (0.08 * w.fs).max(2.0);
        let mut water = PathBuilder::new();
        let mut line = PathBuilder::new();
        let bottom = fx.line.bounds.bottom() as f32;
        water.move_to(x0, bottom);
        let mut x = x0;
        while x < x1 + step {
            let xx = x.min(x1);
            water.line_to(xx, surface(xx));
            if xx == x0 {
                line.move_to(xx, surface(xx))
            } else {
                line.line_to(xx, surface(xx))
            }
            x += step;
        }
        water.line_to(x1, bottom);
        water.close();
        let b = fx.line.bounds;
        if let Some(water) = water.finish()
            && let Some(mut m) = Mask::new(b.width(), b.height())
        {
            m.fill_path(
                &water,
                FillRule::Winding,
                true,
                fx.local(Transform::identity()),
            );
            fx.fill_in(
                &mut ink,
                path,
                &paint(colour(fx.s.highlight(w.w.index), 1.0)),
                Transform::identity(),
                &m,
            );
        }
        if p < 1.0
            && let Some(line) = line.finish()
            && let Some(mut letters) = Mask::new(b.width(), b.height())
        {
            letters.fill_path(
                path,
                FillRule::Winding,
                true,
                fx.local(Transform::identity()),
            );
            let s = Stroke {
                width: (0.04 * w.fs).max(1.0),
                line_cap: LineCap::Round,
                ..Stroke::default()
            };
            edge.stroke_path(
                &line,
                &paint(colour(fx.s.glow_color, 1.0)),
                &s,
                fx.local(Transform::identity()),
                Some(&letters),
            );
        }
    }
    let g = fx.s.glow_color;
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
    fx.bloom(
        canvas,
        &edge,
        &[(0.04, Some(g), 1.0), (0.135, Some(mix(g, BLACK, 0.2)), 0.6)],
    );
    fx.put(canvas, &edge, 1.0, BlendMode::Plus, (0.0, 0.0));
}

/// Mirror: an elegant serif on a glossy floor. Each word fades up out of a blur, a soft light
/// crosses the word being said, and the line's reflection fades into the floor under it.
pub(in crate::scene) fn mirror(fx: &Fx, canvas: &mut Pixmap) {
    let Some(mut ink) = fx.layer() else { return };
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let p = cubic_out(w.a / 0.6);
        let at = about(
            w.centre(),
            (lerp(0.96, 1.0, p), lerp(0.96, 1.0, p)),
            0.0,
            (0.0, 0.0),
        );
        let c = if fx.is_act(w) {
            fx.ink_of(w)
        } else {
            mix(fx.ink_of(w), BLACK, 0.07)
        };
        let soft = 0.065 * w.fs * (1.0 - p);
        if soft > 0.6 || p < 1.0 {
            let Some(mut one) = fx.layer() else { continue };
            fx.fill(&mut one, path, &paint(colour(c, 1.0)), at);
            soften(&mut one, soft);
            onto(&mut ink, &one, p);
        } else {
            fx.fill(&mut ink, path, &paint(colour(c, 1.0)), at);
        }
        if fx.is_act(w) && w.a > 0.25 {
            let gx = lerp(
                w.w.ink_x - 0.65 * w.fs,
                w.w.ink_x + w.w.ink_w + 0.65 * w.fs,
                cubic_in_out((w.a - 0.25) / 0.9),
            );
            let b = fx.line.bounds;
            if let Some(mut band) = sweep(gx, w.mid(), 0.54 * w.fs, 0.0, fx.s.glow_color, 0.7)
                && let Some(mut letters) = Mask::new(b.width(), b.height())
                && let Some(r) = Rect::from_xywh(
                    b.x() as f32,
                    b.y() as f32,
                    b.width() as f32,
                    b.height() as f32,
                )
            {
                letters.fill_path(path, FillRule::Winding, true, fx.local(at));
                band.blend_mode = BlendMode::Plus;
                ink.fill_rect(r, &band, fx.local(Transform::identity()), Some(&letters));
            }
        }
    }
    // The reflection of the bottom row, flipped about a line just under its baseline.
    let floor = fx
        .words
        .iter()
        .map(|w| (w.w.baseline, w.fs))
        .fold((f32::MIN, fx.fs()), |a, b| if b.0 > a.0 { b } else { a });
    let (y0, fs) = (floor.0 + 0.033 * floor.1, floor.1);
    if let Some(mut flipped) = fx.layer() {
        let (_, oy) = fx.origin();
        let at = Transform::from_row(1.0, 0.0, 0.0, -1.0, 0.0, 2.0 * (y0 - oy as f32));
        flipped.draw_pixmap(0, 0, ink.as_ref(), &PixmapPaint::default(), at, None);
        let deep = 0.75 * fs;
        fade(&mut flipped, fx.origin(), false, &|y| {
            if y < y0 {
                0.0
            } else {
                0.45 * (1.0 - (y - y0) / deep)
            }
        });
        soften(&mut flipped, 0.016 * fs);
        fx.shadow(canvas, &ink, 1.0);
        fx.over(canvas, &flipped);
    }
    fx.over(canvas, &ink);
}
