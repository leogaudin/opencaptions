use super::*;

/// Outline, shadow and glow values are tuned on letters up to this size (every built-in look is). Past
/// it they grow with the letters, so a caption at 200 keeps the weight of one at 100 instead of
/// going thin; below it they stay as set, which keeps every saved look exactly as it was.
pub(super) const EFFECTS_REF_SIZE: f32 = 100.0;

pub(super) fn scaled(style: &Style, k: f32) -> Style {
    let e = k * (style.font_size / EFFECTS_REF_SIZE).max(1.0);
    Style {
        font_size: style.font_size * k,
        stroke_width: style.stroke_width * e,
        shadow_blur: style.shadow_blur * e,
        shadow_offset_x: style.shadow_offset_x * e,
        shadow_offset_y: style.shadow_offset_y * e,
        glow_blur: style.glow_blur * e,
        ..style.clone()
    }
}

/// The watermark as a small picture in white with a soft shadow, placed in the top right corner.
pub(super) fn watermark(book: &FontBook, text: &str, width: u32, height: u32) -> Option<Mark> {
    if text.trim().is_empty() {
        return None;
    }
    let size = (height as f32 * 0.018).max(8.0);
    let face = book.face(book.primary(MARK_FAMILY));
    let (glyphs, advance) = shape(face, text, size);
    let glyphs = glyphs?;
    let margin = (size * 0.6).ceil();
    let (w, h) = (
        (advance + 2.0 * margin).ceil() as u32,
        (size * 1.5 + 2.0 * margin).ceil() as u32,
    );
    // Not in a frame too small to hold it.
    if w + 2 > width || h + 2 > height {
        return None;
    }
    let edge = height as f32 * 0.035;
    let x = (width as f32 - edge - advance - margin).max(0.0) as i32;
    let y = (edge - margin * 0.5).max(0.0) as i32;
    let rect = IntRect::from_xywh(x, y, w.min(width - x as u32), h.min(height - y as u32))?;
    let mut pixmap = Pixmap::new(rect.width(), rect.height())?;
    let at = Transform::from_translate(margin, margin + size);
    if let Some(mut shadow) = Pixmap::new(rect.width(), rect.height()) {
        shadow.fill_path(&glyphs, &paint(Color::BLACK), FillRule::Winding, at, None);
        blur(&mut shadow, size * 0.12);
        let p = PixmapPaint {
            opacity: 0.7,
            ..PixmapPaint::default()
        };
        pixmap.draw_pixmap(0, 0, shadow.as_ref(), &p, Transform::identity(), None);
    }
    let white = colour(Rgba([255, 255, 255, 255]), MARK_OPACITY);
    pixmap.fill_path(&glyphs, &paint(white), FillRule::Winding, at, None);
    Some(Mark { rect, pixmap })
}

pub(super) fn pixel_bounds(r: Rect, margin: f32, width: u32, height: u32) -> IntRect {
    let x0 = (r.left() - margin).floor().max(0.0) as i32;
    let y0 = (r.top() - margin).floor().max(0.0) as i32;
    let x1 = ((r.right() + margin).ceil() as i32)
        .min(width as i32)
        .max(x0 + 1);
    let y1 = ((r.bottom() + margin).ceil() as i32)
        .min(height as i32)
        .max(y0 + 1);
    IntRect::from_ltrb(x0, y0, x1, y1).unwrap_or(IntRect::from_xywh(0, 0, 1, 1).unwrap())
}

impl Scene {
    pub fn new(book: &FontBook, input: SceneInput) -> Self {
        // Encoders need even dimensions; the overlay must match the frame exactly.
        let (width, height) = ((input.width & !1).max(2), (input.height & !1).max(2));
        let k = height as f32 / REF_HEIGHT;
        let style = scaled(&input.style, k);
        let fs = style.font_size;
        let boxed = matches!(
            style.animation,
            Animation::HighlightBox | Animation::HighlightSlide | Animation::Stickers
        );
        let (pad_wx, pad_wy) = if boxed {
            (fs * 0.12, fs * 0.06)
        } else {
            (0.0, 0.0)
        };
        let (pad_bx, pad_by) = if style.background == Background::None {
            (0.0, 0.0)
        } else {
            (fs * 0.6, fs * 0.3)
        };
        let primary = book.primary(&style.font);
        let fallbacks: Vec<usize> = input
            .fallback_fonts
            .iter()
            .filter_map(|family| book.find(family))
            .collect();
        let face = book.face(primary);
        let em = fs / face.units_per_em() as f32;
        let (ascent, descent) = (
            f32::from(face.ascender()) * em,
            -f32::from(face.descender()) * em,
        );
        // A boxed word's padding already separates it from the next, so the boxes
        // sit almost touching instead of adding a whole space on top.
        let base_gap = if boxed {
            fs * 0.04
        } else {
            shape(face, " ", fs).1
        };
        let sep = base_gap + fs * style.word_spacing;
        let max_row = MAX_WIDTH * width as f32 - 2.0 * pad_bx;
        let reach = |dx: f32, dy: f32| dx.abs().max(dy.abs());
        // What a caption's drawing reaches past its block: the soft edges of a shadow and a glow, the
        // shadow's offset, an outline, and an italic's lean over the top corner.
        // `k` is the size of the largest word: a key word's, or a stack row's, effects grow with it.
        let margin = |k: f32| {
            (style.shadow_blur * 3.0
                + reach(style.shadow_offset_x, style.shadow_offset_y)
                + style.glow_blur * 3.0
                + style.stroke_width)
                * k
                + if style.italic {
                    fs * ITALIC_SKEW * k
                } else {
                    0.0
                }
                + match style.animation {
                    // The soft words' blur, a turned word's corners, the bar under the line.
                    Animation::LyricFocus => fs * FOCUS_BLUR * 3.0 * k,
                    Animation::WordBounce | Animation::Stickers => fs * 0.15 * k,
                    Animation::LineBar => fs * (BAR_GAP + BAR_THICK + 0.05),
                    Animation::LetterRise => fs * RISE_FROM * k,
                    Animation::WordSlam => fs * JOLT * 1.5 * k,
                    Animation::Drift => fs * (DRIFT_BOB + DRIFT_SOFT * 3.0) * k,
                    _ => 0.0,
                }
                + 2.0
        };

        let offset = input.caption_offset_ms;
        let words: Vec<_> = input.transcript.words().collect();
        let ranges = cut(&words, style.words_per_line.max(1) as usize);
        let lines = ranges
            .into_iter()
            .map(|range| {
                let first = range.start;
                let chunk = &words[range];
                let texts: Vec<String> = chunk
                    .iter()
                    .map(|w| match style.text_case {
                        TextCase::Upper => w.text.to_uppercase(),
                        TextCase::None => w.text.clone(),
                    })
                    .collect();
                let lean = Transform::from_row(1.0, 0.0, -ITALIC_SKEW, 1.0, 0.0, 0.0);
                let shaped: Vec<_> = texts
                    .iter()
                    .map(|text| {
                        let (glyphs, advance) = shape(
                            book.face(book.for_text(primary, &fallbacks, text)),
                            text,
                            fs,
                        );
                        let glyphs = if style.italic {
                            glyphs.and_then(|p| p.transform(lean))
                        } else {
                            glyphs
                        };
                        (glyphs, advance)
                    })
                    .collect();
                // One outline per letter, only for the look that moves them apart.
                let clusters: Vec<Vec<Path>> = texts
                    .iter()
                    .map(|text| {
                        if style.animation != Animation::LetterRise {
                            return vec![];
                        }
                        let face = book.face(book.for_text(primary, &fallbacks, text));
                        let letters = cluster_paths(face, text, fs);
                        if style.italic {
                            letters
                                .into_iter()
                                .filter_map(|p| p.transform(lean))
                                .collect()
                        } else {
                            letters
                        }
                    })
                    .collect();
                // Rows: words fill a row until the next does not fit (a stack's rows are short).
                let stack = style.layout == Layout::Stack;
                let limit = if stack {
                    STACK_ROW_SHARE * max_row
                } else {
                    max_row
                };
                let mut rows: Vec<(Vec<usize>, f32)> = vec![];
                for (i, (_, adv)) in shaped.iter().enumerate() {
                    let slot = adv + 2.0 * pad_wx;
                    match rows.last_mut() {
                        Some((row, w)) if *w + sep + slot <= limit => {
                            row.push(i);
                            *w += sep + slot;
                        }
                        _ => rows.push((vec![i], slot)),
                    }
                }
                // A stack scales each row up to the widest one's width, at most three times over.
                let widest = rows.iter().map(|r| r.1).fold(0.0, f32::max);
                let scales: Vec<f32> = rows
                    .iter()
                    .map(|r| {
                        if stack {
                            (widest / r.1.max(1.0)).clamp(1.0, STACK_MAX_SCALE)
                        } else {
                            1.0
                        }
                    })
                    .collect();
                let lead = if stack { STACK_LEADING } else { LINE_HEIGHT };
                let height_of = |scale: f32| (lead * fs + 2.0 * pad_wy) * scale;
                let inner_w = rows
                    .iter()
                    .zip(&scales)
                    .map(|(r, s)| r.1 * s)
                    .fold(0.0, f32::max);
                let (block_w, block_h) = (
                    inner_w + 2.0 * pad_bx,
                    scales.iter().map(|s| height_of(*s)).sum::<f32>() + 2.0 * pad_by,
                );
                // The block is centred on (position_x, position_y) and clamped so it
                // never leaves the frame, whatever a drag asks for. One wider than the
                // frame (a word at a huge size) is centred, spilling over both sides.
                let place = |norm: f32, extent: f32, limit: f32| {
                    if extent >= limit {
                        (limit - extent) / 2.0
                    } else {
                        (norm * limit - extent / 2.0).clamp(0.0, limit - extent)
                    }
                };
                let x0 = place(style.position_x, block_w, width as f32);
                let y0 = place(style.position_y, block_h, height as f32);
                let mut placed: Vec<Option<Placed>> = (0..chunk.len()).map(|_| None).collect();
                let right_to_left = is_right_to_left(chunk.iter().map(|w| w.text.as_str()));
                let mut top = y0 + pad_by;
                let mut biggest = 1.0f32;
                for ((row, row_w), scale) in rows.iter().zip(&scales) {
                    let k = *scale;
                    biggest = biggest.max(k);
                    let row_h = height_of(k);
                    // Half-leading, as CSS does, for this row's size.
                    let baseline_in_row = pad_wy * scale
                        + (lead * fs * k - (ascent + descent) * k) / 2.0
                        + ascent * k;
                    let mut x = x0 + pad_bx + (inner_w - row_w * scale) / 2.0;
                    // In a right-to-left line the first word is the rightmost.
                    let order: Vec<usize> = if right_to_left {
                        row.iter().rev().copied().collect()
                    } else {
                        row.clone()
                    };
                    for i in order {
                        let (glyphs, adv) = &shaped[i];
                        let slot_w = (adv + 2.0 * pad_wx) * scale;
                        let at =
                            Transform::from_translate(x + pad_wx * scale, top + baseline_in_row)
                                .pre_scale(*scale, *scale);
                        placed[i] = Some(Placed {
                            start: shifted(chunk[i].start, offset),
                            end: shifted(chunk[i].end, offset),
                            glyphs: glyphs.clone().and_then(|p| p.transform(at)),
                            slot: Rect::from_xywh(x, top, slot_w.max(1.0), row_h).unwrap(),
                            ink_x: x + pad_wx * scale,
                            ink_w: adv * scale,
                            baseline: top + baseline_in_row,
                            em_top: top + baseline_in_row - ascent * k,
                            clusters: clusters[i]
                                .iter()
                                .filter_map(|c| c.clone().transform(at))
                                .collect(),
                            chars: texts[i].chars().count(),
                            index: first + i,
                            size: *scale,
                        });
                        x += slot_w + sep * scale;
                    }
                    top += row_h;
                }
                let block = Rect::from_xywh(x0, y0, block_w.max(1.0), block_h.max(1.0)).unwrap();
                // Room for the pop to grow a word past its slot.
                let tallest = scales.iter().map(|s| height_of(*s)).fold(0.0, f32::max);
                let grow = inner_w.max(tallest) * lift(style.animation);
                Line {
                    first,
                    start: shifted(chunk.first().map_or(0.0, |w| w.start), offset),
                    end: shifted(chunk.last().map_or(0.0, |w| w.end), offset),
                    words: placed.into_iter().flatten().collect(),
                    block: (style.background != Background::None).then_some(block),
                    anchor: block,
                    bounds: pixel_bounds(block, margin(biggest) + grow, width, height),
                }
            })
            .collect();
        let block_radius = match style.background {
            Background::Pill => f32::MAX,
            _ => 12.0 * k,
        };
        Self {
            mark: input
                .watermark
                .as_deref()
                .and_then(|text| watermark(book, text, width, height)),
            word_radius: fs * 0.14,
            block_radius,
            style,
            width,
            height,
            lines,
        }
    }

    /// The box, as (x, y, width, height), outside which no frame of this scene ever has a pixel:
    /// every line's layer and the watermark. On even coordinates and of even size, the grain
    /// 4:2:2 and 4:2:0 video can be laid over at, and the whole frame when its own size is odd.
    /// A render sends this box for each frame rather than the picture of the whole.
    pub fn overlay_bounds(&self) -> (u32, u32, u32, u32) {
        let whole = (0, 0, self.width, self.height);
        if !self.width.is_multiple_of(2) || !self.height.is_multiple_of(2) {
            return whole;
        }
        let boxes = self
            .lines
            .iter()
            .map(|l| l.bounds)
            .chain(self.mark.as_ref().map(|m| m.rect));
        let Some((x0, y0, x1, y1)) = boxes.fold(None, |acc: Option<(i32, i32, i32, i32)>, r| {
            let r = (r.x(), r.y(), r.right(), r.bottom());
            Some(acc.map_or(r, |a| {
                (a.0.min(r.0), a.1.min(r.1), a.2.max(r.2), a.3.max(r.3))
            }))
        }) else {
            // Nothing is ever drawn: any box will do, and a small one is cheapest.
            return (0, 0, 2, 2);
        };
        let (x0, y0) = ((x0.max(0) & !1) as u32, (y0.max(0) & !1) as u32);
        let (x1, y1) = (
            (((x1 + 1) & !1) as u32).min(self.width),
            (((y1 + 1) & !1) as u32).min(self.height),
        );
        (x0, y0, (x1 - x0).max(2), (y1 - y0).max(2))
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }
}
