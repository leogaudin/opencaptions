use super::*;

/// The finished shadow and glow layers of the line last drawn, with what they were made from.
#[derive(Default)]
pub(super) struct LayerCache {
    pub(super) shadow: Option<(LayerKey, Option<Trimmed>)>,
    pub(super) halo: Option<(LayerKey, Option<Trimmed>)>,
}

/// A line; each of its words' opacity, size, tilt, press, entrance and (for Drift) brightness; and
/// how the line is jolted and drifts: all the layers depend on.
pub(super) type LayerKey = (usize, Vec<[u32; 6]>, [u32; 5]);

/// Renders a scene frame by frame into straight-alpha RGBA, touching only the
/// pixels a caption occupies and skipping frames identical to the last.
pub struct Renderer {
    pub(super) layers: LayerCache,
    pub(super) scene: Scene,
    pub(super) canvas: Pixmap,
    pub(super) rgba: Vec<u8>,
    /// What the last frame was made from.
    pub(super) last: Option<FrameKey>,
    pub(super) dirty: Option<IntRect>,
    /// The rows the last `render` changed, `top..bottom`: all of them the first time.
    pub(super) changed: (u32, u32),
}

impl Renderer {
    pub fn new(scene: Scene) -> Self {
        let (w, h) = (scene.width, scene.height);
        let mut renderer = Self {
            layers: LayerCache::default(),
            canvas: Pixmap::new(w, h).expect("frame dimensions are validated and non-zero"),
            rgba: vec![0; (w * h * 4) as usize],
            scene,
            last: None,
            dirty: None,
            changed: (0, 0),
        };
        renderer.draw_mark();
        renderer
    }

    /// The watermark onto the frame (which must be clear where it goes), and into the RGBA.
    fn draw_mark(&mut self) {
        let Some(mark) = &self.scene.mark else { return };
        let (x, y) = (mark.rect.x(), mark.rect.y());
        self.canvas.draw_pixmap(
            x,
            y,
            mark.pixmap.as_ref(),
            &PixmapPaint::default(),
            Transform::identity(),
            None,
        );
        unpremultiply(
            self.canvas.data(),
            &mut self.rgba,
            mark.rect,
            self.scene.width,
        );
    }

    /// Clears the watermark's place, to draw it again once what overlapped it is drawn.
    fn clear_mark(&mut self) {
        let Some(mark) = &self.scene.mark else { return };
        for span in rows(mark.rect, self.scene.width) {
            self.canvas.data_mut()[span.clone()].fill(0);
            self.rgba[span].fill(0);
        }
    }

    /// Bring the frame to time `t`; returns whether any pixel changed.
    pub fn render(&mut self, t: f32) -> bool {
        let key = self.scene.key(t);
        if self.last.as_ref() == Some(&key) {
            return false;
        }
        let width = self.scene.width;
        // A new scene's first frame is all new to whoever shows it; after that, only the rows
        // cleared and drawn. Showing just those is what keeps a playing preview cheap.
        let mut changed = if self.last.is_none() {
            Some((0, self.scene.height))
        } else {
            None
        };
        let mut grow = |r: IntRect| {
            let (top, bottom) = (r.y() as u32, r.bottom() as u32);
            changed = Some(changed.map_or((top, bottom), |(t, b)| (t.min(top), b.max(bottom))));
        };
        // Where the frame draws: its line's box.
        let area = key.0.map(|i| self.scene.lines[i].bounds);
        // The watermark is drawn again, over whatever it overlaps, when a caption clears or draws
        // where it is; otherwise it is left as it is.
        let mark = self.scene.mark.as_ref().map(|m| m.rect);
        let mut redraw_mark = false;
        if let Some(r) = self.dirty {
            grow(r);
            redraw_mark |= mark.is_some_and(|m| overlaps(r, m));
        }
        if let Some(bounds) = area {
            grow(bounds);
            redraw_mark |= mark.is_some_and(|m| overlaps(bounds, m));
        }
        if let (true, Some(m)) = (redraw_mark, mark) {
            grow(m);
        }
        self.changed = changed.unwrap_or((0, 0));
        if let Some(r) = self.dirty.take() {
            for span in rows(r, width) {
                self.canvas.data_mut()[span.clone()].fill(0);
                self.rgba[span].fill(0);
            }
        }
        if redraw_mark {
            self.clear_mark();
        }
        if let Some(bounds) = area {
            if let Some(i) = key.0 {
                let line = &self.scene.lines[i];
                self.scene.draw(
                    &mut self.canvas,
                    (i, line),
                    &key.1,
                    key.2,
                    key.3,
                    &mut self.layers,
                );
            }
            unpremultiply(self.canvas.data(), &mut self.rgba, bounds, width);
            self.dirty = Some(bounds);
        }
        if redraw_mark {
            self.draw_mark();
        }
        self.last = Some(key);
        true
    }

    /// The active caption block as (x, y, w, h) in frame pixels, for the editor to
    /// hit-test and drag. `None` when no caption shows at the last rendered time.
    pub fn active_bounds(&self) -> Option<(f32, f32, f32, f32)> {
        let line = &self.scene.lines[self.active_index()?];
        let r = line.anchor;
        Some((r.x(), r.y(), r.width(), r.height()))
    }

    /// Where the watermark sits as (x, y, w, h) in frame pixels, for an editor that moves the
    /// captions about and must keep the mark in place. `None` without one.
    pub fn watermark_rect(&self) -> Option<(f32, f32, f32, f32)> {
        let r = self.scene.mark.as_ref()?.rect;
        Some((
            r.x() as f32,
            r.y() as f32,
            r.width() as f32,
            r.height() as f32,
        ))
    }

    /// Index of the active line among all lines.
    pub fn active_index(&self) -> Option<usize> {
        self.last.as_ref()?.0
    }

    /// Flat index of the active line's first word, so the editor can map a word back to the
    /// transcript: word N of the line is transcript word `first + N`.
    pub fn active_first_word(&self) -> Option<usize> {
        Some(self.scene.lines[self.active_index()?].first)
    }

    /// Each active word's slot as (x, y, w, h) in frame pixels, in line order, for
    /// the editor to pick the word under a double-click.
    pub fn active_word_rects(&self) -> Vec<(f32, f32, f32, f32)> {
        self.active_index().map_or_else(Vec::new, |i| {
            self.scene.lines[i]
                .words
                .iter()
                .map(|w| (w.slot.x(), w.slot.y(), w.slot.width(), w.slot.height()))
                .collect()
        })
    }

    /// The current frame: width × height × 4 bytes of straight-alpha RGBA.
    /// The rows the last `render` that returned true changed, as `top..bottom`.
    pub fn changed_rows(&self) -> (u32, u32) {
        self.changed
    }

    pub fn rgba(&self) -> &[u8] {
        &self.rgba
    }

    pub fn scene(&self) -> &Scene {
        &self.scene
    }
}
