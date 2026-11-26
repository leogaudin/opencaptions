//! What the composed looks are built from: the maths of their motion, written with no platform
//! maths library (no sin, exp or pow, so every build rounds alike), and the pixel work on their
//! layers, in integer arithmetic on premultiplied bytes like the blur.

use super::*;

/// 2 to the power `x`: the nearest whole power goes in the exponent's bits and the rest through a
/// series (good to about 1e-7), so it is plain f32 arithmetic.
pub(in crate::scene) fn exp2(x: f32) -> f32 {
    let x = x.clamp(-126.0, 126.0);
    let whole = (x + 0.5).floor();
    let f = (x - whole) * std::f32::consts::LN_2;
    // e^f for |f| up to ln 2 / 2, as its series.
    let p = 1.0
        + f * (1.0
            + f / 2.0
                * (1.0
                    + f / 3.0
                        * (1.0 + f / 4.0 * (1.0 + f / 5.0 * (1.0 + f / 6.0 * (1.0 + f / 7.0))))));
    p * f32::from_bits(((whole as i32 + 127) as u32) << 23)
}

/// A start that leaps and a long, soft landing: the exponential ease motion designers reach for.
pub(in crate::scene) fn expo_out(p: f32) -> f32 {
    if p >= 1.0 {
        1.0
    } else {
        1.0 - exp2(-10.0 * p.max(0.0))
    }
}

pub(in crate::scene) fn cubic_out(p: f32) -> f32 {
    let q = 1.0 - p.clamp(0.0, 1.0);
    1.0 - q * q * q
}

pub(in crate::scene) fn cubic_in_out(p: f32) -> f32 {
    let p = p.clamp(0.0, 1.0);
    if p < 0.5 {
        4.0 * p * p * p
    } else {
        let q = -2.0 * p + 2.0;
        1.0 - q * q * q / 2.0
    }
}

/// Past the end and back: a landing with a little overshoot.
pub(in crate::scene) fn back_out(p: f32) -> f32 {
    let (c1, q) = (1.9, p.clamp(0.0, 1.0) - 1.0);
    1.0 + (c1 + 1.0) * q * q * q + c1 * q * q
}

/// The sine of `turns` whole turns (one turn is 2π): folded onto a quarter turn and summed as a
/// series (good to about 4e-6).
pub(in crate::scene) fn sine(turns: f32) -> f32 {
    let mut r = turns - (turns + 0.5).floor();
    if r > 0.25 {
        r = 0.5 - r;
    } else if r < -0.25 {
        r = -0.5 - r;
    }
    let x = r * std::f32::consts::TAU;
    let x2 = x * x;
    x * (1.0 - x2 / 6.0 * (1.0 - x2 / 20.0 * (1.0 - x2 / 42.0 * (1.0 - x2 / 72.0))))
}

pub(in crate::scene) fn cosine(turns: f32) -> f32 {
    sine(turns + 0.25)
}

/// A number from 0 to 1 that looks random and is the same everywhere for the same `n`.
pub(in crate::scene) fn hash(n: u32) -> f32 {
    let mut n = (n ^ 61 ^ (n >> 16)).wrapping_mul(9);
    n ^= n >> 4;
    n = n.wrapping_mul(0x27d4_eb2d);
    n ^= n >> 15;
    (n >> 8) as f32 / 16_777_216.0
}

/// Scales by (`sx`, `sy`) and turns by `radians` about (`cx`, `cy`), then moves by (`dx`, `dy`).
pub(in crate::scene) fn about(
    (cx, cy): (f32, f32),
    (sx, sy): (f32, f32),
    radians: f32,
    (dx, dy): (f32, f32),
) -> Transform {
    let turns = radians / std::f32::consts::TAU;
    let (s, c) = (sine(turns), cosine(turns));
    Transform::from_translate(-cx, -cy)
        .post_scale(sx, sy)
        .post_concat(Transform::from_row(c, s, -s, c, 0.0, 0.0))
        .post_translate(cx + dx, cy + dy)
}

/// `src` in one colour: each pixel keeps its coverage and takes `c`.
pub(in crate::scene) fn tint(src: &Pixmap, c: Rgba) -> Pixmap {
    let mut out = src.clone();
    let [r, g, b, a] = c.0.map(u32::from);
    for px in out.data_mut().as_chunks_mut::<4>().0 {
        let cover = u32::from(px[3]) * a / 255;
        *px = [
            ((r * cover + 127) / 255) as u8,
            ((g * cover + 127) / 255) as u8,
            ((b * cover + 127) / 255) as u8,
            cover as u8,
        ];
    }
    out
}

/// A blur of `sigma` that stays cheap when it is wide: past a few pixels the layer is shrunk (each
/// block of pixels averaged), blurred small and drawn back up, which a wide blur cannot tell from
/// the real one.
pub(in crate::scene) fn soften(px: &mut Pixmap, sigma: f32) {
    let f: u32 = if sigma >= 24.0 {
        4
    } else if sigma >= 10.0 {
        2
    } else {
        1
    };
    if f == 1 {
        if sigma >= 0.3 {
            blur(px, sigma);
        }
        return;
    }
    let Some(mut small) = shrink(px, f) else {
        return;
    };
    // The small blur's boxes are chosen so the whole spreads as far as the real one would: three
    // boxes of radius r spread a variance of r(r + 1), and the shrinking and the drawing back up
    // add a little of their own.
    let r = blur_radius(sigma) as f32;
    let ff = (f * f) as f32;
    let target = (r * (r + 1.0) - (ff - 1.0) / 12.0 - ff / 6.0) / ff;
    let small_r = ((-1.0 + (1.0 + 4.0 * target.max(0.0)).sqrt()) / 2.0)
        .round()
        .max(1.0);
    blur(&mut small, small_r);
    px.fill(Color::TRANSPARENT);
    let p = PixmapPaint {
        quality: FilterQuality::Bilinear,
        ..PixmapPaint::default()
    };
    // The middle of a small pixel is the middle of the block it was made from.
    let half = (f as f32 - 1.0) / 2.0;
    let at = Transform::from_scale(f as f32, f as f32).post_translate(half, half);
    px.draw_pixmap(0, 0, small.as_ref(), &p, at, None);
}

/// `px` a `f`th of its size, each block of `f` by `f` pixels averaged.
pub(in crate::scene) fn shrink(px: &Pixmap, f: u32) -> Option<Pixmap> {
    let (w, h) = (px.width(), px.height());
    let (sw, sh) = (w.div_ceil(f), h.div_ceil(f));
    let mut small = Pixmap::new(sw, sh)?;
    let src = px.data();
    let dst = small.data_mut();
    let n = f * f;
    for y in 0..sh {
        for x in 0..sw {
            let mut acc = [0u32; 4];
            for yy in y * f..((y + 1) * f).min(h) {
                for xx in x * f..((x + 1) * f).min(w) {
                    let i = ((yy * w + xx) * 4) as usize;
                    for c in 0..4 {
                        acc[c] += u32::from(src[i + c]);
                    }
                }
            }
            let o = ((y * sw + x) * 4) as usize;
            for c in 0..4 {
                dst[o + c] = ((acc[c] + n / 2) / n) as u8;
            }
        }
    }
    Some(small)
}

/// The box holding a layer's ink, as (left, top, right, bottom), the last two exclusive.
pub(in crate::scene) fn extent_of(px: &Pixmap) -> Option<(usize, usize, usize, usize)> {
    ink_extent(px.data(), px.width() as usize, px.height() as usize)
}

/// A copy of the part of `px` within `extent` and `margin` pixels round it (as far as the layer
/// goes), and where that part starts in the layer: a blur of the copy is the blur of the whole
/// there, for far less work when the ink is a small part of the layer.
pub(in crate::scene) fn cut_out(
    px: &Pixmap,
    (left, top, right, bottom): (usize, usize, usize, usize),
    margin: usize,
) -> Option<(Pixmap, i32, i32)> {
    let (w, h) = (px.width() as usize, px.height() as usize);
    let (x0, y0) = (left.saturating_sub(margin), top.saturating_sub(margin));
    let (x1, y1) = ((right + margin).min(w), (bottom + margin).min(h));
    let r = IntRect::from_xywh(x0 as i32, y0 as i32, (x1 - x0) as u32, (y1 - y0) as u32)?;
    Some((px.clone_rect(r)?, x0 as i32, y0 as i32))
}

/// A blur along the rows only, the smear of something moving fast sideways.
pub(in crate::scene) fn smear(px: &mut Pixmap, sigma: f32) {
    let radius = blur_radius(sigma);
    let span = (2 * radius + 1) as u32;
    let w = px.width() as usize;
    let mut src = vec![0u8; w * 4];
    for row in px.data_mut().chunks_exact_mut(w * 4) {
        if row.iter().all(|&b| b == 0) {
            continue;
        }
        for _ in 0..3 {
            src.copy_from_slice(row);
            slide(&src, row, radius, span);
        }
    }
}

/// Every pixel's coverage multiplied by `f` of its column (`along` rows) or of its row, in frame
/// pixels: an edge fade, a window.
pub(in crate::scene) fn fade(
    px: &mut Pixmap,
    origin: (i32, i32),
    along: bool,
    f: &dyn Fn(f32) -> f32,
) {
    let (w, h) = (px.width() as usize, px.height() as usize);
    let n = if along { w } else { h };
    let start = if along { origin.0 } else { origin.1 };
    let k: Vec<u32> = (0..n)
        .map(|i| (f(start as f32 + i as f32 + 0.5).clamp(0.0, 1.0) * 255.0).round() as u32)
        .collect();
    for (y, row) in px.data_mut().chunks_exact_mut(w * 4).enumerate() {
        for (x, p) in row.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let m = if along { k[x] } else { k[y] };
            if m < 255 {
                *p = p.map(|v| ((u32::from(v) * m + 127) / 255) as u8);
            }
        }
    }
}

/// Coverage remapped: nothing below `lo`, solid above `hi`, a ramp between, in white. Blur, then
/// this, and shapes that come near each other run together like liquid.
pub(in crate::scene) fn threshold(px: &Pixmap, lo: u8, hi: u8) -> Pixmap {
    let mut out = px.clone();
    let (lo, span) = (u32::from(lo), u32::from(hi - lo).max(1));
    for p in out.data_mut().as_chunks_mut::<4>().0 {
        let a = u32::from(p[3]);
        let v = if a <= lo {
            0
        } else {
            ((a - lo) * 255 / span).min(255) as u8
        };
        *p = [v; 4];
    }
    out
}

/// `px` with `cut` (moved by `dy` rows) taken out of it: what of a shape does not overlap itself
/// moved, its top or bottom edge.
pub(in crate::scene) fn minus(px: &Pixmap, cut: &Pixmap, dy: i32) -> Pixmap {
    let mut out = px.clone();
    let p = PixmapPaint {
        blend_mode: BlendMode::DestinationOut,
        ..PixmapPaint::default()
    };
    out.draw_pixmap(0, dy, cut.as_ref(), &p, Transform::identity(), None);
    out
}

/// `src` laid over `dst`, two layers of the same line, at `opacity`.
pub(in crate::scene) fn onto(dst: &mut Pixmap, src: &Pixmap, opacity: f32) {
    let p = PixmapPaint {
        opacity,
        ..PixmapPaint::default()
    };
    dst.draw_pixmap(0, 0, src.as_ref(), &p, Transform::identity(), None);
}

/// Film grain in the ink: a few pixels in a hundred darkened and a few lightened, in a pattern
/// that changes with `frame`.
pub(in crate::scene) fn grain(px: &mut Pixmap, origin: (i32, i32), frame: u32) {
    let w = px.width() as usize;
    for (y, row) in px.data_mut().chunks_exact_mut(w * 4).enumerate() {
        let fy = (origin.1 + y as i32) as u32;
        for (x, p) in row.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            if p[3] == 0 {
                continue;
            }
            let fx = (origin.0 + x as i32) as u32;
            let h = hash(
                fx.wrapping_mul(73_856_093)
                    ^ fy.wrapping_mul(19_349_663)
                    ^ frame.wrapping_mul(83_492_791),
            );
            let a = u32::from(p[3]);
            if h < 0.035 {
                for v in &mut p[..3] {
                    *v = (u32::from(*v) * 78 / 100) as u8;
                }
            } else if h < 0.07 {
                for c in &mut p[..3] {
                    let v = u32::from(*c);
                    *c = (v + (a - v.min(a)) * 18 / 100) as u8;
                }
            }
        }
    }
}

/// A shutter that stays open: frames drawn at instants a little apart are summed and averaged, so
/// something fast leaves the streak a camera would see. Exact integer sums, then one division.
pub(in crate::scene) struct Shutter {
    sums: Vec<u32>,
    n: u32,
    width: u32,
    height: u32,
}

impl Shutter {
    pub(in crate::scene) fn new(width: u32, height: u32) -> Self {
        Self {
            sums: vec![0; (width * height * 4) as usize],
            n: 0,
            width,
            height,
        }
    }

    pub(in crate::scene) fn add(&mut self, frame: &Pixmap) {
        for (s, v) in self.sums.iter_mut().zip(frame.data()) {
            *s += u32::from(*v);
        }
        self.n += 1;
    }

    pub(in crate::scene) fn finish(self) -> Option<Pixmap> {
        let mut out = Pixmap::new(self.width, self.height)?;
        let n = self.n.max(1);
        for (o, s) in out.data_mut().iter_mut().zip(&self.sums) {
            *o = ((s + n / 2) / n) as u8;
        }
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_maths_is_close_to_the_platforms() {
        for i in -40..=40 {
            let x = i as f32 / 10.0;
            assert!((exp2(x) - x.exp2()).abs() <= x.exp2() * 1e-6, "exp2({x})");
            let turns = i as f32 / 17.0;
            let real = (turns * std::f32::consts::TAU).sin();
            assert!((sine(turns) - real).abs() < 1e-5, "sine({turns})");
        }
        assert_eq!((expo_out(0.0), expo_out(1.0)), (0.0, 1.0));
        assert_eq!((cubic_out(0.0), cubic_out(1.0)), (0.0, 1.0));
        assert_eq!((cubic_in_out(0.0), cubic_in_out(1.0)), (0.0, 1.0));
        assert!((back_out(0.0)).abs() < 1e-6 && (back_out(1.0) - 1.0).abs() < 1e-6);
        assert!(
            (0..100)
                .map(|i| back_out(i as f32 / 100.0))
                .fold(0.0, f32::max)
                > 1.05
        );
    }

    #[test]
    fn the_hash_spreads_and_repeats() {
        let values: Vec<f32> = (0..1000).map(hash).collect();
        assert!(values.iter().all(|v| (0.0..1.0).contains(v)));
        let mean = values.iter().sum::<f32>() / 1000.0;
        assert!((mean - 0.5).abs() < 0.05, "{mean}");
        assert_eq!(hash(42), hash(42));
    }

    #[test]
    fn a_shutter_of_one_frame_is_that_frame() {
        let mut px = Pixmap::new(8, 8).unwrap();
        px.fill(Color::from_rgba8(10, 20, 30, 40));
        let mut s = Shutter::new(8, 8);
        s.add(&px);
        assert_eq!(s.finish().unwrap().data(), px.data());
    }

    #[test]
    fn a_wide_soften_spreads_like_a_blur() {
        let mut a = Pixmap::new(200, 200).unwrap();
        a.fill_rect(
            Rect::from_xywh(80.0, 80.0, 40.0, 40.0).unwrap(),
            &paint(Color::WHITE),
            Transform::identity(),
            None,
        );
        let mut b = a.clone();
        soften(&mut a, 30.0);
        blur(&mut b, 30.0);
        let alpha = |p: &Pixmap, x: usize, y: usize| i32::from(p.data()[(y * 200 + x) * 4 + 3]);
        for (x, y) in [(100, 100), (60, 100), (100, 40), (30, 30)] {
            let (got, want) = (alpha(&a, x, y), alpha(&b, x, y));
            assert!((got - want).abs() <= 6, "at {x},{y}: {got} for {want}");
        }
    }
}
