//! The looks made of motion: words that slide, split, snap, roll and fold into place, most of them
//! through an open shutter, so what moves fast is drawn as a camera sees it.

use super::*;

/// Stretch: one pill travels from word to word. Its front edge leaps ahead and its back edge
/// catches up, so it stretches, thins and snaps into place like something elastic.
pub(in crate::scene) fn elastic(fx: &Fx, canvas: &mut Pixmap) {
    let Some(mut ink) = fx.layer() else { return };
    let shown = fx.shown();
    for w in &fx.words {
        if let Some(path) = &w.w.glyphs {
            fx.fill(
                &mut ink,
                path,
                &paint(colour(fx.ink_of(w), shown)),
                Transform::identity(),
            );
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    if let Some(cur) = fx.act.map(|i| &fx.words[i]) {
        let pad = 0.28 * cur.fs;
        let edges = |w: &Said| (w.w.ink_x - pad, w.w.ink_x + w.w.ink_w + pad);
        let (cl, cr) = edges(cur);
        let (mut l, mut r, mut squash, mut grow) = (cl, cr, 0.0, 1.0);
        // From the word before, on the same row; the first word of a row grows where it is.
        match cur
            .i
            .checked_sub(1)
            .map(|j| &fx.words[j])
            .filter(|p| p.w.row == cur.w.row)
        {
            None => grow = back_out(cur.into(0.3)),
            Some(prev) => {
                let (pl, pr) = edges(prev);
                let lead = expo_out(cur.into(0.24));
                let trail = cubic_in_out((cur.a - 0.03) / 0.34);
                // The edge in the direction of travel leads.
                if cl >= pl {
                    (l, r) = (lerp(pl, cl, trail), lerp(pr, cr, lead));
                } else {
                    (l, r) = (lerp(pl, cl, lead), lerp(pr, cr, trail));
                }
                let rest = lerp(pr - pl, cr - cl, trail);
                squash = ((r - l - rest) / (3.45 * cur.fs)).clamp(0.0, 1.0);
            }
        }
        let h = 1.14 * cur.fs * (1.0 - 0.2 * squash) * grow;
        let (wd, x, y) = ((r - l) * grow, (l + r) / 2.0, cur.mid());
        if let Some(pill) = capsule(x, y, wd, h, h / 2.0)
            && let Some(mut shade) = fx.layer()
        {
            fx.fill(
                &mut shade,
                &pill,
                &paint(Color::BLACK),
                Transform::identity(),
            );
            soften(&mut shade, 0.17 * cur.fs);
            fx.put(
                canvas,
                &shade,
                0.45,
                BlendMode::SourceOver,
                (0.0, 0.12 * cur.fs),
            );
            let c = colour(fx.s.highlight(cur.w.index), shown);
            canvas.fill_path(
                &pill,
                &paint(c),
                FillRule::Winding,
                Transform::identity(),
                None,
            );
        }
    }
    fx.over(canvas, &ink);
}

/// Whether any started word is younger than `secs`: its entrance is still being drawn.
fn entering(fx: &Fx, secs: f32) -> bool {
    fx.started().any(|w| w.a < secs)
}

/// Split: each word arrives in two halves, the top from the left and the bottom from the right,
/// motion-blurred, and they lock together with a flash of light along the cut.
pub(in crate::scene) fn split(fx: &Fx, canvas: &mut Pixmap) {
    let words: Vec<(&Said, Mask, Mask)> = fx
        .started()
        .filter_map(|w| Some((w, fx.side(w.mid(), true)?, fx.side(w.mid(), false)?)))
        .collect();
    let n = if entering(fx, 0.45) { 6 } else { 1 };
    let Some(ink) = fx.shutter(n, 0.035, &|px, back| {
        for (w, top, bottom) in &words {
            let Some(path) = &w.w.glyphs else { continue };
            let aj = (w.a - back).max(0.0);
            let off = (1.0 - expo_out(aj / 0.45)) * 3.94 * w.fs;
            let p = paint(colour(fx.ink_of(w), (aj / 0.08).min(1.0)));
            fx.fill_in(px, path, &p, Transform::from_translate(-off, 0.0), top);
            fx.fill_in(px, path, &p, Transform::from_translate(off, 0.0), bottom);
        }
    }) else {
        return;
    };
    let Some(mut cut) = fx.layer() else { return };
    for (w, _, _) in &words {
        let f = w.a - 0.3;
        if f > 0.0 && f < 0.4 {
            let q = f / 0.4;
            let ext = w.w.ink_w * (0.7 + 0.7 * cubic_out(q));
            if let Some(r) = Rect::from_xywh(
                w.cx() - ext / 2.0,
                w.mid() - 1.0,
                ext,
                (0.03 * w.fs).max(2.0),
            ) {
                let p = paint(colour(Rgba([255, 255, 255, 255]), 1.0 - q));
                cut.fill_rect(r, &p, fx.local(Transform::identity()), None);
            }
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
    let g = fx.s.glow_color;
    fx.bloom(
        canvas,
        &cut,
        &[(0.045, Some(mix(g, WHITE, 0.7)), 1.2), (0.18, Some(g), 0.8)],
    );
    fx.put(canvas, &cut, 1.0, BlendMode::Plus, (0.0, 0.0));
}

/// Block: a solid block sweeps across where the word will be, and as it pulls away the word is
/// left behind, already in place.
pub(in crate::scene) fn block(fx: &Fx, canvas: &mut Pixmap) {
    let (Some(mut ink), Some(mut blocks)) = (fx.layer(), fx.layer()) else {
        return;
    };
    let b = fx.line.bounds;
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let (top, h) = (w.w.baseline - 0.84 * w.fs, 1.08 * w.fs);
        let x0 = w.w.ink_x - 0.17 * w.fs;
        let x1 = w.w.ink_x + w.w.ink_w + 0.17 * w.fs;
        let right = lerp(x0, x1, expo_out(w.into(0.22)));
        let left = lerp(x0, x1, cubic_in_out((w.a - 0.2) / 0.3));
        if right > left + 0.5
            && let Some(r) = Rect::from_ltrb(left, top, right, top + h)
        {
            let p = paint(colour(fx.s.highlight(w.w.index), 1.0));
            blocks.fill_rect(r, &p, fx.local(Transform::identity()), None);
        }
        // The word is there behind the block's trailing edge.
        if w.a >= 0.2
            && let Some(m) = Rect::from_ltrb(b.x() as f32, b.y() as f32, left, b.bottom() as f32)
                .and_then(|r| fx.clip(r))
        {
            fx.fill_in(
                &mut ink,
                path,
                &paint(colour(fx.ink_of(w), 1.0)),
                Transform::identity(),
                &m,
            );
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
    fx.over(canvas, &blocks);
}

/// Where a word sits when it is shown on its own in the middle of the caption block: moved so its
/// slot's middle is the block's, with the point it is scaled about.
fn centred(fx: &Fx, w: &Said) -> (Transform, (f32, f32)) {
    let a = fx.line.anchor;
    let (ax, ay) = (a.x() + a.width() / 2.0, a.y() + a.height() / 2.0);
    let slot_y = w.w.slot.y() + w.w.slot.height() / 2.0;
    let (dx, dy) = (ax - w.cx(), ay - slot_y);
    (Transform::from_translate(dx, dy), (ax, w.mid() + dy))
}

/// Beat: one word at a time, filling the caption on its own, punching in with motion blur and a
/// small kick of the camera as it lands, in the highlight colours in turn.
pub(in crate::scene) fn beat(fx: &Fx, canvas: &mut Pixmap) {
    let Some(w) = fx.act.map(|i| &fx.words[i]) else {
        return;
    };
    let (moved, centre) = centred(fx, w);
    let lean = if w.w.index.is_multiple_of(2) {
        -1.0
    } else {
        1.0
    };
    let (mut dx, mut dy) = (0.0, 0.0);
    if w.a > 0.1 && w.a < 0.32 {
        let q = (w.a - 0.1) / 0.22;
        let frame = (fx.t * 60.0).floor() as u32;
        dx = (hash(frame) - 0.5) * 0.121 * w.fs * (1.0 - q);
        dy = (hash(frame + 7) - 0.5) * 0.091 * w.fs * (1.0 - q);
    }
    let fill = paint(colour(fx.s.highlight(w.w.index), 1.0));
    let n = if w.a < 0.2 { 7 } else { 1 };
    let Some(ink) = fx.shutter(n, 0.03, &|px, back| {
        let aj = (w.a - back).max(0.0);
        let s = lerp(1.5, 1.0, expo_out(aj / 0.18));
        let turn = lean * 0.03 * (1.0 - (aj / 0.18).min(1.0));
        fx.outlined(
            px,
            w,
            &fill,
            moved.post_concat(about(centre, (s, s), turn, (dx, dy))),
        );
    }) else {
        return;
    };
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}

/// Scroll: the line runs as one row that glides so the word being said always sits in the middle,
/// underlined, while the words around it fade toward the edges of the frame.
pub(in crate::scene) fn scroll(fx: &Fx, canvas: &mut Pixmap) {
    let words = &fx.words;
    let Some(first) = words.first() else { return };
    let frame_w = fx.scene.width as f32;
    let target = (fx.s.position_x * frame_w).clamp(0.0, frame_w);
    let shift = |back: f32| {
        let mut x = target - first.cx();
        for pair in words.windows(2) {
            let p = ((pair[1].a - back) / 0.35).clamp(0.0, 1.0);
            x += (pair[0].cx() - pair[1].cx()) * expo_out(p);
        }
        x
    };
    let act = fx.act.unwrap_or(0);
    let moving = act > 0 && words[act].a < 0.35;
    let shown = fx.shown();
    let Some(mut ink) = fx.shutter(if moving { 6 } else { 1 }, 0.04, &|px, back| {
        let dx = shift(back);
        for w in words {
            let Some(path) = &w.w.glyphs else { continue };
            let x = w.cx() + dx;
            let far = (((x - target).abs() - 0.083 * frame_w) / (0.39 * frame_w)).clamp(0.0, 1.0);
            let lit = w.i == act;
            let ink = if lit {
                fx.ink_of(w)
            } else {
                mix(fx.ink_of(w), BLACK, 0.11)
            };
            let at = Transform::from_translate(dx, 0.0);
            fx.fill(
                px,
                path,
                &paint(colour(ink, shown * (1.0 - 0.82 * far))),
                at,
            );
            if lit
                && let Some(r) = Rect::from_xywh(
                    w.w.ink_x + dx,
                    w.w.baseline + 0.21 * w.fs,
                    w.w.ink_w,
                    0.086 * w.fs,
                )
            {
                let p = paint(colour(fx.s.highlight(w.w.index), shown));
                px.fill_rect(r, &p, fx.local(Transform::identity()), None);
            }
        }
    }) else {
        return;
    };
    let edge = 0.24 * frame_w;
    fade(&mut ink, fx.origin(), true, &|x| {
        (x / edge).min((frame_w - x) / edge)
    });
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}

/// Reel: one slot in the middle of the caption, the words rolling through it as if printed on a
/// drum: each turns up into place and the one before rolls away over the top.
pub(in crate::scene) fn reel(fx: &Fx, canvas: &mut Pixmap) {
    let Some(i) = fx.act else { return };
    let cur = &fx.words[i];
    let (_, (_, cy)) = centred(fx, cur);
    let band = 0.95 * cur.fs;
    let (top, bottom) = (cy - 0.62 * band, cy + 0.62 * band);
    let b = fx.line.bounds;
    let Some(slot) =
        Rect::from_ltrb(b.x() as f32, top, b.right() as f32, bottom).and_then(|r| fx.clip(r))
    else {
        return;
    };
    let put = |px: &mut Pixmap, w: &Said, off: f32, sy: f32| {
        let Some(path) = &w.w.glyphs else { return };
        let (moved, centre) = centred(fx, w);
        let at = moved.post_concat(about(centre, (1.0, sy), 0.0, (0.0, off)));
        let c = colour(fx.s.highlight(w.w.index), 1.0);
        if fx.s.stroke_width > 0.0 {
            let stroke = Stroke {
                width: fx.s.stroke_width * w.w.size,
                line_join: LineJoin::Round,
                ..Stroke::default()
            };
            let edge = paint(colour(fx.s.stroke_color, 1.0));
            px.stroke_path(path, &edge, &stroke, fx.local(at), Some(&slot));
        }
        px.fill_path(
            path,
            &paint(c),
            FillRule::Winding,
            fx.local(at),
            Some(&slot),
        );
    };
    let n = if cur.a < 0.32 { 6 } else { 1 };
    let Some(mut ink) = fx.shutter(n, 0.02, &|px, back| {
        let p = expo_out(((cur.a - back) / 0.32).clamp(0.0, 1.0));
        if let Some(prev) = i.checked_sub(1).map(|j| &fx.words[j]) {
            put(px, prev, -p * band, lerp(1.0, 0.35, p));
        }
        put(px, cur, (1.0 - p) * band, lerp(0.35, 1.0, p));
    }) else {
        return;
    };
    let soft = 0.32 * band;
    fade(&mut ink, fx.origin(), false, &|y| {
        ((y - top) / soft).min((bottom - y) / soft)
    });
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}

/// Snap: each word arrives stretched three times its width and smeared sideways, then pulls tight
/// in a fifth of a second, overshooting a little before it settles.
pub(in crate::scene) fn snap(fx: &Fx, canvas: &mut Pixmap) {
    let Some(mut ink) = fx.layer() else { return };
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let p = w.into(0.2);
        let sx = if w.a < 0.2 {
            lerp(3.0, 0.94, expo_out(p))
        } else {
            lerp(0.94, 1.0, cubic_out((w.a - 0.2) / 0.14))
        };
        let at = about(w.centre(), (sx, 1.0), 0.0, (0.0, 0.0));
        let fill = paint(colour(fx.ink_of(w), (w.a / 0.06).min(1.0)));
        let streak = (1.0 - p) * 0.57 * w.fs;
        if streak > 0.8
            && let Some(mut one) = fx.layer()
        {
            fx.fill(&mut one, path, &fill, at);
            smear(&mut one, streak);
            onto(&mut ink, &one, 1.0);
        } else {
            fx.fill(&mut ink, path, &fill, at);
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}

/// Knockout: the word being said is cut out of a solid block that grows in behind it, so the
/// picture shows through its letters; the others are plain.
pub(in crate::scene) fn knockout(fx: &Fx, canvas: &mut Pixmap) {
    let (Some(mut ink), Some(mut cutout)) = (fx.layer(), fx.layer()) else {
        return;
    };
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        if !fx.is_act(w) {
            fx.fill(
                &mut ink,
                path,
                &paint(colour(fx.ink_of(w), 1.0)),
                Transform::identity(),
            );
            continue;
        }
        let wd = (w.w.ink_w + 0.48 * w.fs) * lerp(0.2, 1.0, expo_out(w.into(0.26)));
        let h = 1.12 * w.fs * lerp(0.6, 1.0, back_out(w.into(0.3)));
        if let Some(slab) = capsule(w.cx(), w.mid(), wd, h, 0.13 * w.fs) {
            let c = colour(fx.s.highlight(w.w.index), 1.0);
            fx.fill(&mut cutout, &slab, &paint(c), Transform::identity());
            let mut hole = paint(Color::BLACK);
            hole.blend_mode = BlendMode::DestinationOut;
            fx.fill(&mut cutout, path, &hole, Transform::identity());
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.shadow(canvas, &cutout, 0.6);
    fx.over(canvas, &ink);
    fx.over(canvas, &cutout);
}

/// Fold: each word unfolds like paper, the bottom half dropping open and the top following over
/// the crease, each shaded while it is turned away.
pub(in crate::scene) fn fold(fx: &Fx, canvas: &mut Pixmap) {
    let Some(mut ink) = fx.layer() else { return };
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let half = |ink: &mut Pixmap, sy: f32, upper: bool| {
            if sy <= 0.01 {
                return;
            }
            let Some(m) = fx.side(w.mid(), upper) else {
                return;
            };
            let at = about(w.centre(), (1.0, sy), 0.0, (0.0, 0.0));
            fx.fill_in(ink, path, &paint(colour(fx.ink_of(w), 1.0)), at, &m);
            let shade = 0.65 * (1.0 - sy.min(1.0));
            if shade > 0.0 {
                fx.fill_in(ink, path, &paint(colour(BLACK, shade)), at, &m);
            }
        };
        half(&mut ink, cubic_out(w.into(0.18)), false);
        half(&mut ink, back_out((w.a - 0.12) / 0.3).max(0.0), true);
        let c = w.a - 0.12;
        if c > 0.0
            && c < 0.3
            && let Some(r) = Rect::from_xywh(
                w.w.ink_x - 0.057 * w.fs,
                w.mid() - 1.0,
                w.w.ink_w + 0.114 * w.fs,
                2.0,
            )
        {
            let p = paint(colour(BLACK, 0.5 * (1.0 - c / 0.3)));
            ink.fill_rect(r, &p, fx.local(Transform::identity()), None);
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}

/// Echo: each word slides in fast, trailed by outlined afterimages in the highlight colours that
/// catch up and fold into it, then its outline ripples out twice as it lands.
pub(in crate::scene) fn echo(fx: &Fx, canvas: &mut Pixmap) {
    let (Some(mut ink), Some(mut echoes), Some(mut rings)) = (fx.layer(), fx.layer(), fx.layer())
    else {
        return;
    };
    let pose = |w: &Said, a: f32| {
        let p = cubic_out(a / 0.3);
        about(
            w.centre(),
            (lerp(1.12, 1.0, p), lerp(1.12, 1.0, p)),
            0.0,
            ((1.0 - p) * 1.79 * w.fs, 0.0),
        )
    };
    for w in fx.started() {
        let Some(path) = &w.w.glyphs else { continue };
        let line = 0.036 * w.fs;
        let trail = ((0.48 - w.a) / 0.18).clamp(0.0, 1.0);
        for j in (1..=4).rev() {
            let aj = w.a - j as f32 * 0.05;
            if trail > 0.0 && aj >= 0.0 {
                let c = colour(fx.s.highlight(j - 1), (1.0 - j as f32 / 5.0) * trail);
                fx.edge(&mut echoes, path, c, line, pose(w, aj));
            }
        }
        let fill = paint(colour(fx.ink_of(w), (w.a / 0.05).min(1.0)));
        fx.outlined(&mut ink, w, &fill, pose(w, w.a));
        if fx.is_act(w) {
            for m in 0..2 {
                let r = (w.a - 0.28 - m as f32 * 0.12) / 0.5;
                if r > 0.0 && r < 1.0 {
                    let grow = 1.0 + 0.32 * cubic_out(r);
                    let c = colour(fx.s.highlight(if m == 1 { 3 } else { 0 }), 1.0 - r);
                    fx.edge(
                        &mut rings,
                        path,
                        c,
                        line,
                        about(w.centre(), (grow, grow), 0.0, (0.0, 0.0)),
                    );
                }
            }
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.bloom(canvas, &echoes, &[(0.048, None, 0.7)]);
    fx.over(canvas, &echoes);
    fx.bloom(canvas, &rings, &[(0.048, None, 0.8)]);
    fx.over(canvas, &rings);
    fx.over(canvas, &ink);
}

/// Reveal: a thin rule draws itself under the line, then each word rises out of an invisible slot
/// on it, with a soft motion blur and a long, unhurried ease.
pub(in crate::scene) fn reveal(fx: &Fx, canvas: &mut Pixmap) {
    let words: Vec<(&Said, Mask)> = fx
        .started()
        .filter_map(|w| Some((w, fx.side(w.w.baseline + 0.22 * w.fs, true)?)))
        .collect();
    let n = if entering(fx, 0.5) { 6 } else { 1 };
    let Some(mut ink) = fx.shutter(n, 0.04, &|px, back| {
        for (w, slot) in &words {
            let Some(path) = &w.w.glyphs else { continue };
            let aj = (w.a - back).max(0.0);
            let dy = (1.0 - expo_out(aj / 0.6)) * 1.1 * w.fs;
            let c = if fx.is_act(w) {
                fx.ink_of(w)
            } else {
                mix(fx.ink_of(w), BLACK, 0.075)
            };
            fx.fill_in(
                px,
                path,
                &paint(colour(c, 1.0)),
                Transform::from_translate(0.0, dy),
                slot,
            );
        }
    }) else {
        return;
    };
    // A rule under each row, drawn out from its middle as the line comes up.
    let drawn = expo_out(ramp(fx.t, fx.line.start - LEAD_S, 0.7));
    let mut rows: Vec<(usize, f32, f32, f32, f32)> = vec![];
    for w in &fx.words {
        let (l, r) = (w.w.ink_x, w.w.ink_x + w.w.ink_w);
        match rows.iter_mut().find(|row| row.0 == w.w.row) {
            Some(row) => (row.1, row.2) = (row.1.min(l), row.2.max(r)),
            None => rows.push((w.w.row, l, r, w.w.baseline, w.fs)),
        }
    }
    for (_, l, r, baseline, fs) in rows {
        let half = (r - l) / 2.0 + 0.2 * fs;
        let c = (l + r) / 2.0;
        let y = baseline + 0.22 * fs + 0.133 * fs;
        if let Some(rule) = Rect::from_xywh(
            c - half * drawn,
            y,
            (2.0 * half * drawn).max(0.5),
            (0.033 * fs).max(1.0),
        ) {
            let p = paint(colour(fx.s.text_color, 0.9));
            ink.fill_rect(rule, &p, fx.local(Transform::identity()), None);
        }
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}
