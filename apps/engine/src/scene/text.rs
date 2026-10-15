use super::*;

/// How letters are set apart and drawn wider or narrower than the face has them: the two dials that
/// reshape a face. `NONE` leaves it exactly as designed, to the last bit.
#[derive(Clone, Copy)]
pub(super) struct Tracking {
    /// Extra space after each letter but the last, as a share of the size.
    pub spacing: f32,
    /// How much wider the letters are drawn (and their advances with them).
    pub stretch: f32,
}

impl Tracking {
    pub(super) const NONE: Self = Self {
        spacing: 0.0,
        stretch: 1.0,
    };
}

pub(super) struct Sink {
    pb: PathBuilder,
    scale: f32,
    stretch: f32,
    dx: f32,
    dy: f32,
}

impl Sink {
    pub(super) fn at(&self, x: f32, y: f32) -> (f32, f32) {
        (
            self.dx + x * self.scale * self.stretch,
            self.dy - y * self.scale,
        )
    }
}

impl OutlineBuilder for Sink {
    fn move_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.at(x, y);
        self.pb.move_to(x, y);
    }
    fn line_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.at(x, y);
        self.pb.line_to(x, y);
    }
    fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
        let ((x1, y1), (x, y)) = (self.at(x1, y1), self.at(x, y));
        self.pb.quad_to(x1, y1, x, y);
    }
    fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
        let ((x1, y1), (x2, y2), (x, y)) = (self.at(x1, y1), self.at(x2, y2), self.at(x, y));
        self.pb.cubic_to(x1, y1, x2, y2, x, y);
    }
    fn close(&mut self) {
        self.pb.close();
    }
}

/// Glyph outlines for `text` with the pen at the origin on the baseline, and the advance.
pub(super) fn shape(face: &Face, text: &str, size: f32) -> (Option<Path>, f32) {
    shape_tracked(face, text, size, Tracking::NONE)
}

/// `shape`, with the letters set apart and stretched as `tracking` says.
pub(super) fn shape_tracked(
    face: &Face,
    text: &str,
    size: f32,
    tracking: Tracking,
) -> (Option<Path>, f32) {
    let mut buf = UnicodeBuffer::new();
    buf.push_str(text);
    // Direction, script and language from the text itself: Arabic and Hebrew run right to left,
    // and Arabic and the Indic scripts join and reorder their letters.
    buf.guess_segment_properties();
    let glyphs = rustybuzz::shape(face, &[], buf);
    let scale = size / face.units_per_em() as f32;
    let mut sink = Sink {
        pb: PathBuilder::new(),
        scale,
        stretch: tracking.stretch,
        dx: 0.0,
        dy: 0.0,
    };
    let gap = tracking.spacing * size;
    let mut pen = 0i32;
    for (n, (info, pos)) in glyphs
        .glyph_infos()
        .iter()
        .zip(glyphs.glyph_positions())
        .enumerate()
    {
        sink.dx = (pen + pos.x_offset) as f32 * scale * tracking.stretch + gap * n as f32;
        sink.dy = -(pos.y_offset as f32) * scale;
        face.outline_glyph(GlyphId(info.glyph_id as u16), &mut sink);
        pen += pos.x_advance;
    }
    let between = glyphs.len().saturating_sub(1) as f32;
    (
        sink.pb.finish(),
        pen as f32 * scale * tracking.stretch + gap * between,
    )
}

/// Whether `c` is in a script whose letters join or reorder, so that a word of it cannot be taken
/// apart without breaking it: Arabic and Syriac, Hebrew, the Indic scripts, Thai, Lao, Myanmar, Khmer.
pub(super) fn is_connected(c: char) -> bool {
    matches!(c as u32,
        0x0590..=0x08FF | 0x0900..=0x0DFF | 0x0E00..=0x0EFF | 0x1000..=0x109F | 0x1780..=0x17FF
        | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF)
}

/// One outline for each grapheme cluster of `text`, in reading order, with the pen at the origin
/// on the baseline like `shape`. A word of a connected script is a single cluster: it moves as a
/// piece and is never broken apart.
pub(super) fn cluster_paths(face: &Face, text: &str, size: f32, tracking: Tracking) -> Vec<Path> {
    if text.chars().any(is_connected) {
        return shape_tracked(face, text, size, tracking)
            .0
            .into_iter()
            .collect();
    }
    let mut buf = UnicodeBuffer::new();
    buf.push_str(text);
    buf.guess_segment_properties();
    let glyphs = rustybuzz::shape(face, &[], buf);
    let scale = size / face.units_per_em() as f32;
    let mut groups: Vec<(u32, PathBuilder)> = vec![];
    let gap = tracking.spacing * size;
    let mut pen = 0i32;
    for (n, (info, pos)) in glyphs
        .glyph_infos()
        .iter()
        .zip(glyphs.glyph_positions())
        .enumerate()
    {
        let at = match groups.iter().position(|(c, _)| *c == info.cluster) {
            Some(at) => at,
            None => {
                groups.push((info.cluster, PathBuilder::new()));
                groups.len() - 1
            }
        };
        let mut sink = Sink {
            pb: std::mem::replace(&mut groups[at].1, PathBuilder::new()),
            scale,
            stretch: tracking.stretch,
            dx: (pen + pos.x_offset) as f32 * scale * tracking.stretch + gap * n as f32,
            dy: -(pos.y_offset as f32) * scale,
        };
        face.outline_glyph(GlyphId(info.glyph_id as u16), &mut sink);
        groups[at].1 = sink.pb;
        pen += pos.x_advance;
    }
    groups.sort_by_key(|(cluster, _)| *cluster);
    groups
        .into_iter()
        .filter_map(|(_, pb)| pb.finish())
        .collect()
}

/// Whether the words read right to left: most of their letters are Hebrew or Arabic.
pub(super) fn is_right_to_left<'a>(words: impl Iterator<Item = &'a str>) -> bool {
    let (mut rtl, mut letters) = (0u32, 0u32);
    for c in words.flat_map(str::chars).filter(|c| c.is_alphabetic()) {
        letters += 1;
        if matches!(c as u32,
            0x0590..=0x05FF | 0x0600..=0x06FF | 0x0750..=0x077F | 0x08A0..=0x08FF | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF)
        {
            rtl += 1;
        }
    }
    rtl * 2 > letters
}
