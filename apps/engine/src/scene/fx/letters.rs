//! The looks that work letter by letter, or on the type itself: a weight that swells, a marker
//! swipe, letters that decrypt, a departures board, numbers that roll.

use super::light::reflow;
use super::*;
use tiny_skia::PathSegment;

/// Decode: when a word's first letter locks, and how long after it each next one does.
pub(in crate::scene) const DECODE_FIRST: f32 = 0.08;
pub(in crate::scene) const DECODE_STEP: f32 = 0.065;
/// Flap: when a word's first tile settles, and how long after it each next one does.
pub(in crate::scene) const FLAP_FIRST: f32 = 0.06;
pub(in crate::scene) const FLAP_STEP: f32 = 0.07;
/// How many flaps a tile turns over in a second.
const FLAPS_PER_S: f32 = 18.0;
/// The characters a decoding letter runs through.
const SCRAMBLE: &str = "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789#$%&@*+=<>/";

/// A path between `a` (at 0) and `b` (at 1): the same glyph at two weights of a variable face has
/// the same points, moved, so its weights between are their blend. None when they differ.
fn blend(a: &Path, b: &Path, k: f32) -> Option<Path> {
    if a.points().len() != b.points().len() {
        return None;
    }
    let mix = |p: Point, q: Point| (lerp(p.x, q.x, k), lerp(p.y, q.y, k));
    let mut pb = PathBuilder::new();
    for pair in a.segments().zip(b.segments()) {
        match pair {
            (PathSegment::MoveTo(p), PathSegment::MoveTo(q)) => {
                let (x, y) = mix(p, q);
                pb.move_to(x, y);
            }
            (PathSegment::LineTo(p), PathSegment::LineTo(q)) => {
                let (x, y) = mix(p, q);
                pb.line_to(x, y);
            }
            (PathSegment::QuadTo(p1, p), PathSegment::QuadTo(q1, q)) => {
                let ((x1, y1), (x, y)) = (mix(p1, q1), mix(p, q));
                pb.quad_to(x1, y1, x, y);
            }
            (PathSegment::CubicTo(p1, p2, p), PathSegment::CubicTo(q1, q2, q)) => {
                let ((x1, y1), (x2, y2), (x, y)) = (mix(p1, q1), mix(p2, q2), mix(p, q));
                pb.cubic_to(x1, y1, x2, y2, x, y);
            }
            (PathSegment::Close, PathSegment::Close) => pb.close(),
            _ => return None,
        }
    }
    pb.finish()
}

/// A word's outline at `weight` (200 to 900) at the pen's origin, and its advance, from the three
/// it was shaped at; None for a face with no weight axis.
fn at_weight(w: &Placed, weight: f32) -> Option<(Option<Path>, f32)> {
    let shapes = w.weights.as_deref()?;
    let (i, k) = if weight <= WEIGHTS[1] {
        (0, (weight - WEIGHTS[0]) / (WEIGHTS[1] - WEIGHTS[0]))
    } else {
        (1, (weight - WEIGHTS[1]) / (WEIGHTS[2] - WEIGHTS[1]))
    };
    let ((a, wa), (b, wb)) = (&shapes[i], &shapes[i + 1]);
    let path = match (a, b) {
        (Some(a), Some(b)) => {
            blend(a, b, k).or_else(|| Some(if k < 0.5 { a.clone() } else { b.clone() }))
        }
        _ => None,
    };
    Some((path, lerp(*wa, *wb, k)))
}

/// Weight: the type itself moves. The line waits in a hairline weight; the word being said swells
/// to black and stretches as it lands, then settles to medium, and the line reflows round it.
pub(in crate::scene) fn weight(fx: &Fx, canvas: &mut Pixmap) {
    let states: Vec<(f32, f32, f32)> = fx
        .words
        .iter()
        .map(|w| {
            if w.a < 0.0 {
                return (WEIGHTS[0], 0.4, 1.0);
            }
            let up = cubic_out(w.a / 0.32);
            let down = fx
                .words
                .get(w.i + 1)
                .map_or(0.0, |n| cubic_in_out(n.a / 0.4));
            let wide = 1.0 + 0.12 * sine(w.into(0.5) / 2.0) * (1.0 - down);
            (
                lerp(lerp(WEIGHTS[0], WEIGHTS[2], up), WEIGHTS[1], down),
                lerp(lerp(0.4, 1.0, up), 0.86, down),
                wide,
            )
        })
        .collect();
    let shapes: Vec<Option<(Option<Path>, f32)>> = fx
        .words
        .iter()
        .zip(&states)
        .map(|(w, st)| at_weight(w.w, st.0))
        .collect();
    let widths: Vec<f32> = fx
        .words
        .iter()
        .zip(&states)
        .zip(&shapes)
        .map(|((w, st), shape)| shape.as_ref().map_or(w.w.ink_w, |s| s.1 * w.w.size) * st.2)
        .collect();
    let starts = reflow(fx, &widths);
    let Some(mut ink) = fx.layer() else { return };
    for ((w, st), shape) in fx.words.iter().zip(&states).zip(&shapes) {
        let c = if fx.is_act(w) {
            fx.ink_of(w)
        } else {
            mix(fx.ink_of(w), BLACK, 0.055)
        };
        let fill = paint(colour(c, st.1 * fx.shown()));
        match shape {
            Some((Some(path), _)) => {
                let at = Transform::from_translate(starts[w.i], w.w.baseline)
                    .pre_scale(st.2 * w.w.size, w.w.size);
                fx.fill(&mut ink, path, &fill, at);
            }
            Some((None, _)) => {}
            None => {
                // A face with no weight axis keeps its weight and only stretches.
                if let Some(path) = &w.w.glyphs {
                    let at = Transform::from_translate(-w.w.ink_x, 0.0)
                        .post_scale(st.2, 1.0)
                        .post_translate(starts[w.i], 0.0);
                    fx.fill(&mut ink, path, &fill, at);
                }
            }
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}

/// Marker: a highlighter swipe draws itself behind the word being said, streaky and uneven like
/// real felt, and the word turns dark on it. The words already said stay clean.
pub(in crate::scene) fn marker(fx: &Fx, canvas: &mut Pixmap) {
    let (Some(mut ink), Some(mut dark)) = (fx.layer(), fx.layer()) else {
        return;
    };
    let mut swipe: Option<(&Said, f32)> = None;
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let lit = fx.is_act(w);
        let pop = if lit {
            1.0 + 0.06 * sine(w.into(0.25) / 2.0)
        } else {
            1.0
        };
        let shown = (w.a / 0.08).min(1.0);
        let at = about(w.centre(), (pop, pop), 0.0, (0.0, 0.0));
        if lit {
            swipe = Some((w, cubic_out(w.a / 0.22)));
            let c = mix(fx.s.highlight(w.w.index), BLACK, 0.9);
            fx.fill(&mut dark, path, &paint(colour(c, shown)), at);
        } else {
            fx.fill(&mut ink, path, &paint(colour(fx.ink_of(w), shown)), at);
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    if let Some((w, p)) = swipe {
        let (top, tall) = (w.w.baseline - 0.8 * w.fs, 1.02 * w.fs);
        let x0 = w.w.ink_x - 0.27 * w.fs;
        let x1 = w.w.ink_x + w.w.ink_w + 0.27 * w.fs;
        let reach = lerp(x0 - 0.5 * w.fs, x1 + 0.5 * w.fs, p);
        let lean = about((w.cx(), top + tall / 2.0), (1.0, 1.0), -0.025, (0.0, 0.0));
        let base = fx.s.highlight(w.w.index);
        let rows = 6u32;
        for r in 0..rows {
            let h = |q: u32| hash(w.w.index as u32 * 71 + r * 13 + q);
            let y = top
                + tall * (0.1 + 0.8 * r as f32 / (rows - 1) as f32)
                + (h(1) - 0.5) * 0.067 * w.fs;
            let xs = x0 + (h(2) - 0.5) * 0.3 * w.fs;
            let xe = reach.min(x1 + (h(3) - 0.5) * 0.37 * w.fs);
            if xe <= xs {
                continue;
            }
            let mut pb = PathBuilder::new();
            pb.move_to(xs, y);
            pb.quad_to(
                (xs + xe) / 2.0,
                y - 0.05 * w.fs + h(5) * 0.1 * w.fs,
                xe,
                y + (h(6) - 0.5) * 0.067 * w.fs,
            );
            if let Some(stroke_path) = pb.finish() {
                let s = Stroke {
                    width: tall / rows as f32 * 1.7,
                    line_cap: LineCap::Round,
                    ..Stroke::default()
                };
                let c = colour(base, (0.74 + 0.22 * h(4)) * opacity(base));
                canvas.stroke_path(&stroke_path, &paint(c), &s, lean, None);
            }
        }
    }
    fx.over(canvas, &ink);
    fx.over(canvas, &dark);
}

/// A glyph of the scene's face, drawn with its pen at (`x`, `baseline`) at a word's size.
fn glyph<'s>(fx: &'s Fx, c: char) -> Option<(&'s Path, f32)> {
    fx.scene
        .glyphs
        .iter()
        .find(|g| g.0 == c)
        .and_then(|g| Some((g.1.as_ref()?, g.2)))
}

/// Decode: the word decrypts itself. Its letters spin through random characters and lock in one
/// by one, left to right, glowing until they land.
pub(in crate::scene) fn decode(fx: &Fx, canvas: &mut Pixmap) {
    let frame = (fx.t * 24.0).floor() as u32;
    let chars: Vec<char> = SCRAMBLE.chars().collect();
    let (Some(mut ink), Some(mut glow)) = (fx.layer(), fx.layer()) else {
        return;
    };
    let g = fx.s.glow_color;
    for w in fx.started() {
        let n = w.w.index as u32;
        let settled = if fx.is_act(w) { 1.0 } else { 0.82 };
        for (j, letter) in w.w.letters.iter().enumerate() {
            let lock = DECODE_FIRST + j as f32 * DECODE_STEP;
            if w.a < lock {
                let pick = chars[(hash(frame * 31 + j as u32 * 7 + n * 101) * chars.len() as f32)
                    as usize
                    % chars.len()];
                if letter.path.is_some()
                    && let Some((path, _)) = glyph(fx, pick)
                {
                    let at = Transform::from_translate(letter.x, w.w.baseline)
                        .pre_scale(w.w.size, w.w.size);
                    let alpha = 0.55 + 0.45 * hash(frame + j as u32 * 3);
                    fx.fill(&mut glow, path, &paint(colour(g, alpha)), at);
                }
            } else if let Some(path) = &letter.path {
                fx.fill(
                    &mut ink,
                    path,
                    &paint(colour(fx.ink_of(w), settled)),
                    Transform::identity(),
                );
                let since = w.a - lock;
                if since < 0.12 {
                    fx.fill(
                        &mut glow,
                        path,
                        &paint(colour(WHITE, 1.0 - since / 0.12)),
                        Transform::identity(),
                    );
                }
            }
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.shadow(canvas, &glow, 0.67);
    fx.bloom(
        canvas,
        &glow,
        &[
            (0.069, Some(g), 1.0),
            (0.276, Some(mix(g, BLACK, 0.22)), 0.6),
        ],
    );
    fx.over(canvas, &glow);
    fx.over(canvas, &ink);
}

/// The character `steps` before `c` in its run (A to Z, a to z, 0 to 9), or None for any other.
fn before(c: char, steps: u32) -> Option<char> {
    let (first, len) = match c {
        'A'..='Z' => (b'A', 26),
        'a'..='z' => (b'a', 26),
        '0'..='9' => (b'0', 10),
        _ => return None,
    };
    let at = (c as u8 - first) as u32;
    Some((first + ((at + len - steps % len) % len) as u8) as char)
}

/// Flap: a departures board. The line is a row of dark split-flap tiles in the highlight colour;
/// each letter flips through the alphabet and settles, one after another, as its word is said.
pub(in crate::scene) fn flap(fx: &Fx, canvas: &mut Pixmap) {
    let (Some(mut tiles), Some(mut ink)) = (fx.layer(), fx.layer()) else {
        return;
    };
    let base = fx.s.primary();
    let shown = fx.shown();
    for w in &fx.words {
        let (tall, top) = (1.2 * w.fs, w.w.baseline - 0.95 * w.fs);
        for (j, letter) in w.w.letters.iter().enumerate() {
            let wide = letter.advance + 0.1 * w.fs;
            let cx = letter.x + letter.advance / 2.0;
            let Some(tile) = capsule(cx, top + tall / 2.0, wide, tall, 0.1 * w.fs) else {
                continue;
            };
            fx.fill(
                &mut tiles,
                &tile,
                &paint(colour(base, shown)),
                Transform::identity(),
            );
            if let Some(upper) =
                Rect::from_xywh(cx - wide / 2.0, top, wide, tall / 2.0).and_then(|r| fx.clip(r))
            {
                fx.fill_in(
                    &mut tiles,
                    &tile,
                    &paint(colour(mix(base, WHITE, 0.07), shown)),
                    Transform::identity(),
                    &upper,
                );
            }
            fx.edge(
                &mut tiles,
                &tile,
                colour(mix(base, WHITE, 0.14), shown),
                (0.03 * w.fs).max(1.0),
                Transform::identity(),
            );
            if w.a < 0.0 {
                continue;
            }
            let settle =
                FLAP_FIRST + j as f32 * FLAP_STEP + hash(w.w.index as u32 * 37 + j as u32) * 0.05;
            let left = ((settle - w.a) * FLAPS_PER_S).ceil().max(0.0) as u32;
            let ch = letter.text.chars().next().unwrap_or(' ');
            let turning = left > 0 && before(ch, left).is_some();
            let c = if fx.is_act(w) || turning {
                fx.ink_of(w)
            } else {
                mix(fx.ink_of(w), BLACK, 0.1)
            };
            let fill = paint(colour(c, 1.0));
            if !turning {
                if let Some(path) = &letter.path {
                    fx.fill(&mut ink, path, &fill, Transform::identity());
                }
                continue;
            }
            let flip = (w.a * FLAPS_PER_S).rem_euclid(1.0);
            let squash = cosine(flip / 2.0).abs().max(0.08);
            if let Some(pick) = before(ch, left)
                && let Some((path, adv)) = glyph(fx, pick)
            {
                let x = cx - adv * w.w.size / 2.0;
                let at = Transform::from_translate(x, w.w.baseline)
                    .pre_scale(w.w.size, w.w.size)
                    .post_concat(about(
                        (cx, top + tall / 2.0),
                        (1.0, squash),
                        0.0,
                        (0.0, 0.0),
                    ));
                fx.fill(&mut ink, path, &fill, at);
            }
        }
    }
    fx.shadow(canvas, &tiles, 1.0);
    fx.over(canvas, &tiles);
    fx.over(canvas, &ink);
    // The seam across the middle of every tile.
    if let (Some(matte), Some(mut seam)) = (fx.matte(&tiles), fx.layer()) {
        for w in &fx.words {
            let y = w.w.baseline - 0.95 * w.fs + 0.6 * w.fs;
            let b = fx.line.bounds;
            if let Some(r) = Rect::from_xywh(
                b.x() as f32,
                y - 0.02 * w.fs,
                b.width() as f32,
                (0.04 * w.fs).max(1.0),
            ) {
                seam.fill_rect(
                    r,
                    &paint(colour(BLACK, 0.85)),
                    fx.local(Transform::identity()),
                    Some(&matte),
                );
            }
        }
        fx.over(canvas, &seam);
    }
}

/// Count: numbers roll like an odometer. A number counts up to its value as it is said: each digit
/// turns over as the ones to its right pass nine, and a new leading digit turns in when the count
/// reaches it. The other words pop in, in the same outlined style.
pub(in crate::scene) fn count(fx: &Fx, canvas: &mut Pixmap) {
    let Some(mut ink) = fx.layer() else { return };
    let line = fx.s.stroke_width;
    // A digit, or a separator, with its outline, both `shown` as much as its place has turned in.
    let draw = |px: &mut Pixmap,
                path: &Path,
                gold: &Paint,
                at: Transform,
                (size, shown): (f32, f32),
                m: Option<&Mask>| {
        if shown <= 0.0 {
            return;
        }
        if line > 0.0 {
            let s = Stroke {
                width: line * size,
                line_join: LineJoin::Round,
                ..Stroke::default()
            };
            px.stroke_path(
                path,
                &paint(colour(fx.s.stroke_color, shown)),
                &s,
                fx.local(at),
                m,
            );
        }
        let mut fill = gold.clone();
        fill.shader.apply_opacity(shown);
        px.fill_path(path, &fill, FillRule::Winding, fx.local(at), m);
    };
    for w in fx.started() {
        let text: String = w.w.letters.iter().map(|l| l.text.as_str()).collect();
        let digits: Vec<u32> = text.chars().filter_map(|c| c.to_digit(10)).collect();
        if digits.is_empty() || digits.len() > 15 {
            let s = lerp(0.6, 1.0, back_out(w.a / 0.3));
            fx.outlined(
                &mut ink,
                w,
                &paint(colour(fx.ink_of(w), 1.0)),
                about(w.centre(), (s, s), 0.0, (0.0, 0.0)),
            );
            continue;
        }
        let Some(mut num) = fx.layer() else { continue };
        // Counted in f64: a number of up to fifteen digits is exact.
        let target = digits.iter().fold(0f64, |v, d| v * 10.0 + f64::from(*d));
        let p = f64::from(cubic_out(w.a / 1.2));
        let v = target * p;
        let gold = fx.gradient(w, fx.s.primary());
        let size = w.w.size;
        let cell = glyph(fx, '0').map_or(0.6 * w.fs, |g| g.1 * size);
        let widths: Vec<f32> =
            w.w.letters
                .iter()
                .map(|l| {
                    if l.text.chars().all(|c| c.is_ascii_digit()) {
                        cell
                    } else {
                        l.advance
                    }
                })
                .collect();
        let mut x = w.cx() - widths.iter().sum::<f32>() / 2.0;
        let top = w.w.baseline - 0.78 * w.fs;
        let (wtop, wbot) = (top - 0.29 * w.fs, w.w.baseline + 0.29 * w.fs);
        let tall = wbot - wtop;
        let mut place = digits.len() as i32;
        let mut lit = 1.0f32;
        for (letter, wide) in w.w.letters.iter().zip(&widths) {
            if !letter.text.chars().all(|c| c.is_ascii_digit()) {
                if let Some(path) = &letter.path {
                    let at = Transform::from_translate(x - letter.x, 0.0);
                    draw(&mut ink, path, &gold, at, (size, lit), None);
                }
                x += wide;
                continue;
            }
            place -= 1;
            let unit = 10f64.powi(place);
            let whole = (v / unit).floor();
            let below = v - whole * unit;
            let turn = if place == 0 {
                v - v.floor()
            } else {
                (below - (unit - 1.0)).clamp(0.0, 1.0)
            };
            let fr = ((turn as f32 - 0.6) / 0.4).clamp(0.0, 1.0);
            // A leading zero stays hidden until the count reaches its place, and turns in as it does.
            lit = if place == 0 || v >= unit {
                1.0
            } else if v >= unit - 1.0 {
                fr
            } else {
                0.0
            };
            if lit > 0.0
                && let Some(window) =
                    Rect::from_ltrb(x - 0.13 * w.fs, wtop, x + cell + 0.13 * w.fs, wbot)
                        .and_then(|r| fx.clip(r))
            {
                for (d, y) in [
                    ((whole as u64 % 10) as u32, w.w.baseline - fr * tall),
                    (
                        ((whole as u64 + 1) % 10) as u32,
                        w.w.baseline + (1.0 - fr) * tall,
                    ),
                ] {
                    let Some(c) = char::from_digit(d, 10) else {
                        continue;
                    };
                    if let Some((path, adv)) = glyph(fx, c) {
                        let at = Transform::from_translate(x + (cell - adv * size) / 2.0, y)
                            .pre_scale(size, size);
                        draw(&mut num, path, &gold, at, (size, lit), Some(&window));
                    }
                }
            }
            x += wide;
        }
        let soft = 0.19 * w.fs;
        fade(&mut num, fx.origin(), false, &|y| {
            ((y - wtop) / soft).min((wbot - y) / soft)
        });
        onto(&mut ink, &num, 1.0);
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}
