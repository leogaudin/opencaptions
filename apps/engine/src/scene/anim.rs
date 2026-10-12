use super::*;

/// 0 before the word, eased up to 1 while it is spoken, eased back after.
pub(super) fn pulse(t: f32, w: &Placed, secs: f32, ease: fn(f32) -> f32) -> f32 {
    let at = |edge: f32| ease(ramp(t, edge, secs));
    at(w.start - LEAD_S) - at(w.end + TRAIL_S)
}

/// Which way the word at `index` leans: left, then right, in turn.
pub(super) fn lean(w: &Placed) -> f32 {
    if w.index.is_multiple_of(2) { -1.0 } else { 1.0 }
}

/// How much of the way to a word's start the clock is: 0 before it, 1 from it on, kept after.
pub(super) fn reached(t: f32, w: &Placed, secs: f32) -> f32 {
    ramp(t, w.start - LEAD_S, secs)
}

pub(super) fn word_state(anim: Animation, w: &Placed, t: f32) -> WordState {
    let on = pulse(t, w, COLOUR_S, linear);
    let steady = WordState::STEADY;
    match anim {
        Animation::None | Animation::HighlightSlide => steady,
        Animation::WordHighlight => WordState { on, ..steady },
        Animation::HighlightBox => {
            // Grows in with the spring as the word starts, and fades out in place.
            let grow = overshoot(ramp(t, w.start - LEAD_S, BOX_S));
            WordState {
                on,
                box_scale: lerp(BOX_FROM, 1.0, grow),
                ..steady
            }
        }
        Animation::WordPop => WordState {
            on,
            scale: 1.0 + POP * pulse(t, w, MOTION_S, overshoot),
            ..steady
        },
        Animation::WordFade => {
            let at = |edge: f32| ramp(t, edge, MOTION_S);
            let opacity = 0.4 + 0.6 * at(w.start - LEAD_S) - 0.3 * at(w.end + TRAIL_S);
            WordState { opacity, ..steady }
        }
        Animation::WordSweep | Animation::WordUnderline => WordState {
            fill: ramp(t, w.start, (w.end - w.start).max(MIN_SAID_S)),
            ..steady
        },
        Animation::Typewriter => {
            // Letter by letter: the steps are whole letters, so a frame only changes when one appears.
            let typing = (w.end - w.start).clamp(MIN_SAID_S, MAX_TYPING_S) * TYPE_SHARE;
            let typed = ramp(t, w.start, typing);
            let letters = w.chars.max(1) as f32;
            WordState {
                on,
                fill: (typed * letters).ceil() / letters,
                ..steady
            }
        }
        Animation::WordBounce => {
            let lift = pulse(t, w, MOTION_S, overshoot);
            WordState {
                on,
                scale: 1.0 + BOUNCE * lift,
                tilt: lean(w) * BOUNCE_TILT * lift,
                ..steady
            }
        }
        Animation::LyricFocus => {
            // Soft and dim until said; the word being said is sharp and bright; a word already said
            // stays sharp and readable. It does not change size: the line stays still.
            let lit = pulse(t, w, MOTION_S, linear);
            let said = reached(t, w, MOTION_S);
            WordState {
                on: lit,
                opacity: lerp(FOCUS_DIM, 1.0, 0.6 * said + 0.4 * lit),
                soften: 1.0 - said,
                ..steady
            }
        }
        Animation::LineBar => WordState {
            opacity: 0.35 + 0.65 * reached(t, w, MOTION_S),
            ..steady
        },
        Animation::Stickers => WordState {
            scale: 1.0 + STICKER_LIFT * pulse(t, w, MOTION_S, overshoot),
            tilt: lean(w) * STICKER_TILT,
            ..steady
        },
        Animation::WordSlam => {
            // Dropped in from twice its size and landed in 0.12 s, no overshoot, visible from
            // the first 40% of the drop; nothing before it is said.
            let p = reached(t, w, SLAM_S);
            WordState {
                on,
                scale: lerp(SLAM_FROM, 1.0, ease_out_quad(p)),
                opacity: (p / SLAM_FADE).min(1.0),
                ..steady
            }
        }
        Animation::LetterRise => WordState {
            on,
            enter: ramp(t, w.start - LEAD_S, rise_timing(w).1),
            ..steady
        },
        Animation::WordPress => WordState {
            on,
            press: pulse(t, w, MOTION_S, overshoot),
            ..steady
        },
    }
}

/// The gap between one letter's start and the next's, and the whole entrance, for a word.
pub(super) fn rise_timing(w: &Placed) -> (f32, f32) {
    let n = w.clusters.len().max(1) as f32;
    let said = (w.end - w.start).max(MIN_SAID_S);
    let stagger = RISE_STAGGER_S.min(said * 0.5 / n).min(RISE_SPREAD_S / n);
    (stagger, (n - 1.0) * stagger + RISE_S)
}

/// The parts of a word that are drawn on their own: each an outline, how far down it sits (in
/// pixels) and how visible it is. The whole word as one part, except while its letters rise.
pub(super) fn parts<'a>(
    w: &'a Placed,
    st: &WordState,
    fs: f32,
    rising: bool,
) -> Vec<(&'a Path, f32, f32)> {
    if rising && st.enter < 1.0 {
        let (stagger, total) = rise_timing(w);
        let letters: Vec<&Path> = if w.clusters.is_empty() {
            w.glyphs.iter().collect()
        } else {
            w.clusters.iter().collect()
        };
        return letters
            .into_iter()
            .enumerate()
            .filter_map(|(i, path)| {
                let p = ramp(st.enter * total, i as f32 * stagger, RISE_S);
                (p > 0.0).then(|| (path, RISE_FROM * fs * (1.0 - overshoot(p)), p))
            })
            .collect();
    }
    w.glyphs.iter().map(|g| (g, 0.0, 1.0)).collect()
}

/// How far a word grows past its slot at most, as a share of the line: room the line's bounds keep.
pub(super) fn lift(anim: Animation) -> f32 {
    match anim {
        Animation::WordBounce => BOUNCE,
        Animation::WordSlam => SLAM_FROM - 1.0,
        Animation::Stickers => STICKER_LIFT,
        _ => POP,
    }
}

impl Scene {
    pub(super) fn active_line(&self, t: f32) -> Option<usize> {
        let ls = &self.lines;
        ls.iter()
            .position(|l| t >= l.start && t <= l.end + LINE_HOLD_S)
            .or_else(|| ls.iter().rposition(|l| t > l.end && t < l.end + LINE_GAP_S))
    }

    pub(super) fn key(&self, t: f32) -> FrameKey {
        let line = self.active_line(t);
        let states = line.map_or(vec![], |i| {
            self.lines[i]
                .words
                .iter()
                .map(|w| word_state(self.style.animation, w, t))
                .collect()
        });
        let guide = line.and_then(|i| self.guide(&self.lines[i], t));
        let jolt = line.map_or([0.0; 2], |i| self.jolt(&self.lines[i], t));
        FrameKey(line, states, guide, jolt)
    }

    /// How far the line is knocked at `t`, in pixels: each word landing jolts it, along a fixed
    /// direction by its place in the transcript, the knock dying away to nothing (a polynomial
    /// envelope, not a sine, so every build agrees).
    pub(super) fn jolt(&self, line: &Line, t: f32) -> [f32; 2] {
        if self.style.animation != Animation::WordSlam {
            return [0.0; 2];
        }
        let landed = |w: &Placed| w.start - LEAD_S + SLAM_S;
        let Some(w) = line
            .words
            .iter()
            .filter(|w| landed(w) <= t)
            .max_by(|a, b| landed(a).total_cmp(&landed(b)))
        else {
            return [0.0; 2];
        };
        let left = 1.0 - (t - landed(w)) / JOLT_S;
        if left <= 0.0 {
            return [0.0; 2];
        }
        let [dx, dy] = JOLT_DIRECTIONS[w.index % JOLT_DIRECTIONS.len()];
        let push = JOLT * self.style.font_size * left * left;
        [dx * push, dy * push]
    }

    /// The sliding box or the line bar at `t`, for the animations that have one.
    pub(super) fn guide(&self, line: &Line, t: f32) -> Option<Guide> {
        match self.style.animation {
            Animation::HighlightSlide => {
                let words = &line.words;
                let at = words.iter().rposition(|w| t >= w.start - LEAD_S)?;
                let (from, to) = (&words[at.saturating_sub(1)], &words[at]);
                let travel = overshoot(ramp(t, to.start - LEAD_S, SLIDE_S));
                let (a, b) = (from.slot, to.slot);
                Some(Guide {
                    rect: [
                        lerp(a.x(), b.x(), travel),
                        lerp(a.y(), b.y(), travel),
                        lerp(a.width(), b.width(), travel),
                        lerp(a.height(), b.height(), travel),
                    ],
                    // It fades in under the first word and is simply there after.
                    alpha: reached(t, &words[0], COLOUR_S),
                    radius: self.word_radius * lerp(from.size, to.size, travel),
                })
            }
            Animation::LineBar => {
                let done = ramp(t, line.start, (line.end - line.start).max(MIN_SAID_S));
                let a = line.anchor;
                let fs = self.style.font_size;
                Some(Guide {
                    rect: [
                        a.x(),
                        a.bottom() + fs * BAR_GAP,
                        a.width() * done,
                        (fs * BAR_THICK).max(2.0),
                    ],
                    alpha: 1.0,
                    radius: 0.0,
                })
            }
            _ => None,
        }
    }
}
