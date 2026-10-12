use super::*;

/// The radius of each of the three box blurs that approximate a Gaussian of `sigma`.
pub(super) fn blur_radius(sigma: f32) -> usize {
    ((sigma * sigma * 4.0 + 1.0).sqrt() / 2.0).round().max(1.0) as usize
}

/// How far a blur of `sigma` carries ink from where it was: the three boxes' radii.
pub(super) fn blur_reach(sigma: f32) -> usize {
    3 * blur_radius(sigma)
}

/// Three box blurs approximate a Gaussian of `sigma`, in integer arithmetic on
/// premultiplied bytes so every target computes the same result.
///
/// Only the part of the pixmap that can change is worked on: the ink's bounding box and the
/// reach of the blur around it. Beyond that the pixels are 0 before and 0 after (a box of
/// zeros sums to zero), and the pixmap's own edge already counts as 0, so the result is
/// exactly what blurring every pixel gives.
pub(super) fn blur(px: &mut Pixmap, sigma: f32) {
    let radius = blur_radius(sigma);
    let (w, h) = (px.width() as usize, px.height() as usize);
    let data = px.data_mut();
    let Some((left, top, right, bottom)) = ink_extent(data, w, h) else {
        return;
    };
    let reach = blur_reach(sigma);
    let x0 = left.saturating_sub(reach);
    let x1 = (right + reach).min(w);
    let y0 = top.saturating_sub(reach);
    let y1 = (bottom + reach).min(h);
    let (cw, ch) = (x1 - x0, y1 - y0);
    let span = (2 * radius + 1) as u32;
    let mut src = vec![0u8; cw.max(ch) * 4];
    let mut sums = vec![0u32; cw * 4];
    let mut rows = vec![0u8; cw * ch * 4];
    for _ in 0..3 {
        for y in y0..y1 {
            let row = &mut data[(y * w + x0) * 4..(y * w + x1) * 4];
            src[..cw * 4].copy_from_slice(row);
            slide(&src[..cw * 4], row, radius, span);
        }
        // Down the columns, a row at a time: the running sums are kept for every column
        // at once, so memory is read in order.
        for (r, y) in (y0..y1).enumerate() {
            rows[r * cw * 4..(r + 1) * cw * 4]
                .copy_from_slice(&data[(y * w + x0) * 4..(y * w + x1) * 4]);
        }
        sums.fill(0);
        for r in 0..=radius.min(ch - 1) {
            add_row(&mut sums, &rows[r * cw * 4..(r + 1) * cw * 4]);
        }
        for r in 0..ch {
            let out = &mut data[((y0 + r) * w + x0) * 4..((y0 + r) * w + x1) * 4];
            for (o, acc) in out.iter_mut().zip(&sums) {
                *o = ((acc + span / 2) / span) as u8;
            }
            if r + radius + 1 < ch {
                add_row(
                    &mut sums,
                    &rows[(r + radius + 1) * cw * 4..(r + radius + 2) * cw * 4],
                );
            }
            if r >= radius {
                for (acc, v) in sums
                    .iter_mut()
                    .zip(&rows[(r - radius) * cw * 4..(r - radius + 1) * cw * 4])
                {
                    *acc -= u32::from(*v);
                }
            }
        }
    }
}

pub(super) fn add_row(sums: &mut [u32], row: &[u8]) {
    for (acc, v) in sums.iter_mut().zip(row) {
        *acc += u32::from(*v);
    }
}

/// One box blur along a row of RGBA pixels: each output byte is the rounded mean of the
/// `2 * radius + 1` bytes around it in the same channel, with 0 beyond the ends.
pub(super) fn slide(src: &[u8], out: &mut [u8], radius: usize, span: u32) {
    let len = src.len() / 4;
    let mut acc = [0u32; 4];
    for px in src.as_chunks::<4>().0.iter().take(radius.min(len - 1) + 1) {
        for c in 0..4 {
            acc[c] += u32::from(px[c]);
        }
    }
    for i in 0..len {
        for c in 0..4 {
            out[i * 4 + c] = ((acc[c] + span / 2) / span) as u8;
        }
        if i + radius + 1 < len {
            for c in 0..4 {
                acc[c] += u32::from(src[(i + radius + 1) * 4 + c]);
            }
        }
        if i >= radius {
            for c in 0..4 {
                acc[c] -= u32::from(src[(i - radius) * 4 + c]);
            }
        }
    }
}

/// The columns and rows holding any non-zero byte: (left, top, right, bottom), the last two
/// exclusive. None for an empty pixmap.
pub(super) fn ink_extent(data: &[u8], w: usize, h: usize) -> Option<(usize, usize, usize, usize)> {
    let (mut left, mut top, mut right, mut bottom) = (w, h, 0, 0);
    for (y, row) in data.chunks_exact(w * 4).enumerate().take(h) {
        let Some(first) = row.as_chunks::<4>().0.iter().position(|p| *p != [0; 4]) else {
            continue;
        };
        let last = row.as_chunks::<4>().0.iter().rposition(|p| *p != [0; 4])?;
        left = left.min(first);
        right = right.max(last + 1);
        top = top.min(y);
        bottom = y + 1;
    }
    (right > left && bottom > top).then_some((left, top, right, bottom))
}

pub(super) fn overlaps(a: IntRect, b: IntRect) -> bool {
    a.intersect(&b).is_some()
}

/// Copies `r` of a premultiplied frame into straight-alpha RGBA.
pub(super) fn unpremultiply(src: &[u8], out: &mut [u8], r: IntRect, width: u32) {
    for span in rows(r, width) {
        for (o, p) in out[span.clone()]
            .as_chunks_mut::<4>()
            .0
            .iter_mut()
            .zip(src[span].as_chunks::<4>().0.iter())
        {
            let a = u32::from(p[3]);
            if a == 0 {
                o.fill(0);
                continue;
            }
            if a == 255 {
                // (p * 255 + 127) / 255 is p.
                *o = *p;
                continue;
            }
            for c in 0..3 {
                o[c] = ((u32::from(p[c]) * 255 + a / 2) / a) as u8;
            }
            o[3] = p[3];
        }
    }
}

pub(super) fn rows(r: IntRect, width: u32) -> impl Iterator<Item = std::ops::Range<usize>> {
    let (x0, x1, w) = (r.x() as usize, r.right() as usize, width as usize);
    (r.y() as usize..r.bottom() as usize).map(move |y| (y * w + x0) * 4..(y * w + x1) * 4)
}

/// A finished layer cut down to the box that holds its ink, and where that box goes in the
/// frame: blending the rest, which is transparent, changes nothing and cost most of the time.
pub(super) struct Trimmed {
    pub(super) pixmap: Pixmap,
    pub(super) x: i32,
    pub(super) y: i32,
}

impl Trimmed {
    /// `layer`, which sits at `origin` in the frame; None when it holds no ink.
    pub(super) fn of(layer: &Pixmap, origin: (i32, i32)) -> Option<Self> {
        let (w, h) = (layer.width() as usize, layer.height() as usize);
        let (left, top, right, bottom) = ink_extent(layer.data(), w, h)?;
        let rect = IntRect::from_xywh(
            left as i32,
            top as i32,
            (right - left) as u32,
            (bottom - top) as u32,
        )?;
        Some(Self {
            pixmap: layer.clone_rect(rect)?,
            x: origin.0 + left as i32,
            y: origin.1 + top as i32,
        })
    }
}
