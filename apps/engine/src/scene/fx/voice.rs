//! Pulse: captions that hear the voice. The word being said swells with how loudly it is spoken,
//! a shouted word shakes and takes the highlight colour, and a thin waveform under the line draws
//! the voice. The loudness is the video's own (`crate::loudness`), measured once beside the
//! transcript and on the same clock, so what is drawn is what is heard.

use super::*;

/// How loud the voice is through the video, decoded from the transcript: `rate` values a second
/// from the video's start, each 0 for silence to 255 for its loudest words.
pub(in crate::scene) struct Loudness {
    pub(in crate::scene) rate: f32,
    pub(in crate::scene) values: Vec<u8>,
}

impl Loudness {
    /// How loud the voice is at `t` (video time, which the caption offset does not move), 0 to 1.
    pub(in crate::scene) fn at(&self, t: f32) -> f32 {
        if t < 0.0 || self.values.is_empty() {
            return 0.0;
        }
        let i = ((t * self.rate).round() as usize).min(self.values.len() - 1);
        f32::from(self.values[i]) / 255.0
    }
}

/// How many bars the waveform has, and how far back in time (one a frame at 60 a second) it reaches.
const BARS: usize = 56;
/// Past this loudness the word is shouted: it shakes and takes the highlight colour.
const SHOUT: f32 = 0.85;

pub(in crate::scene) fn pulse(fx: &Fx, canvas: &mut Pixmap) {
    let voice = fx.scene.loudness.as_ref();
    // Without a measure of the voice, the word being said swells as it is spoken, and nothing else.
    let level = |t: f32| voice.map_or(0.0, |v| v.at(t));
    let now = match voice {
        Some(_) => level(fx.t),
        None => fx.act.map_or(0.0, |i| {
            let w = &fx.words[i];
            0.6 * pulse_of(fx.t, w.w)
        }),
    };
    let Some(mut ink) = fx.layer() else { return };
    let frame = (fx.t * 60.0).floor() as u32;
    for w in fx.started() {
        if w.w.glyphs.is_none() {
            continue;
        }
        let lit = fx.is_act(w);
        let swell = if lit { 1.0 + 0.14 * now } else { 1.0 };
        let shout = lit && voice.is_some() && now > SHOUT;
        let (mut dx, mut dy) = (0.0, 0.0);
        if shout {
            dx = (hash(frame + w.w.index as u32) - 0.5) * 0.143 * w.fs * now;
            dy = (hash(frame + 31) - 0.5) * 0.107 * w.fs * now;
        }
        let c = if shout {
            fx.s.highlight(w.w.index)
        } else if lit {
            fx.ink_of(w)
        } else {
            mix(fx.ink_of(w), BLACK, 0.09)
        };
        let at = about(w.centre(), (swell, swell), 0.0, (dx, dy));
        fx.outlined(&mut ink, w, &paint(colour(c, (w.a / 0.06).min(1.0))), at);
    }
    if let Some(voice) = voice
        && let Some(mut bars) = fx.layer()
    {
        let fs = fx.fs();
        let (bw, gap) = (0.089 * fs, 0.071 * fs);
        let a = fx.line.anchor;
        let x0 = a.x() + a.width() / 2.0 - BARS as f32 * (bw + gap) / 2.0;
        let floor = fx
            .words
            .iter()
            .map(|w| w.w.baseline)
            .fold(f32::MIN, f32::max);
        let y = floor + 0.89 * fs;
        for i in 0..BARS {
            let back = (BARS - 1 - i) as f32 / 60.0;
            let h = 0.054 * fs + voice.at(fx.t - back) * 0.71 * fs;
            let c = if i == BARS - 1 {
                fx.s.primary()
            } else {
                fx.s.text_color
            };
            let alpha = (0.35 + 0.65 * i as f32 / BARS as f32) * fx.shown();
            if let Some(bar) = capsule(x0 + i as f32 * (bw + gap) + bw / 2.0, y, bw, h, bw / 2.0) {
                fx.fill(
                    &mut bars,
                    &bar,
                    &paint(colour(c, alpha)),
                    Transform::identity(),
                );
            }
        }
        fx.shadow(canvas, &bars, 0.77);
        fx.over(canvas, &bars);
    }
    fx.shadow(canvas, &ink, 1.0);
    fx.over(canvas, &ink);
}

/// 0 before the word, up to 1 while it is said, back down after: the swell without a voice to follow.
fn pulse_of(t: f32, w: &Placed) -> f32 {
    super::super::anim::pulse(t, w, MOTION_S, linear)
}
