//! How loud the voice is through a video, for the look that follows it (Pulse). It is measured once
//! from the audio, beside the transcript and on the same clock, and kept in the transcript
//! (`Transcript::loudness`), so the preview and the export read the same values.
//!
//! The audio is band-passed to the voice (250 to 3,500 Hz, a second-order high-pass and low-pass as
//! FFmpeg's `highpass` and `lowpass` make them) and its level taken 60 times a second, in decibels.
//! Then (`envelope`) it is counted only while a word is being said, with 0.03 s either side, so
//! music and noise between words move nothing; it is placed against the video's loudest words (the
//! 95th percentile of the frames inside words) over an 18 dB range; and a rise is followed at once
//! and a fall eased, 0.22 of the way each frame. The API, which filters with FFmpeg itself, holds
//! its copy of `envelope` to the same cases (`testdata/loudness.json`).

use crate::model::{Loudness, Transcript};

/// Levels a second.
pub const RATE: u32 = 60;
const LOW_HZ: f64 = 250.0;
const HIGH_HZ: f64 = 3500.0;
const RANGE_DB: f64 = 18.0;
const PERCENTILE: f64 = 0.95;
const MARGIN_S: f64 = 0.03;
const RELEASE: f64 = 0.22;

/// A second-order filter (the cookbook's, with a Q of 1/√2).
struct Biquad {
    b: [f64; 3],
    a: [f64; 2],
    x: [f64; 2],
    y: [f64; 2],
}

impl Biquad {
    fn new(hz: f64, sample_rate: f64, high: bool) -> Self {
        let w0 = std::f64::consts::TAU * hz / sample_rate;
        let (sin, cos) = w0.sin_cos();
        let alpha = sin / (2.0 * std::f64::consts::FRAC_1_SQRT_2);
        let a0 = 1.0 + alpha;
        let b = if high {
            [(1.0 + cos) / 2.0, -(1.0 + cos), (1.0 + cos) / 2.0]
        } else {
            [(1.0 - cos) / 2.0, 1.0 - cos, (1.0 - cos) / 2.0]
        };
        Self {
            b: b.map(|v| v / a0),
            a: [-2.0 * cos / a0, (1.0 - alpha) / a0],
            x: [0.0; 2],
            y: [0.0; 2],
        }
    }

    fn run(&mut self, v: f64) -> f64 {
        let out = self.b[0] * v + self.b[1] * self.x[0] + self.b[2] * self.x[1]
            - self.a[0] * self.y[0]
            - self.a[1] * self.y[1];
        self.x = [v, self.x[0]];
        self.y = [out, self.y[0]];
        out
    }
}

/// Takes the audio a buffer at a time (mono samples, -1 to 1) and keeps one level, in decibels,
/// for each sixtieth of a second.
pub struct Meter {
    high: Biquad,
    low: Biquad,
    sample_rate: u64,
    /// Samples taken so far, and where the frame being filled ends.
    seen: u64,
    frame_end: u64,
    sum: f64,
    count: u64,
    levels: Vec<f64>,
}

impl Meter {
    pub fn new(sample_rate: u32) -> Self {
        let sr = f64::from(sample_rate.max(1));
        Self {
            high: Biquad::new(LOW_HZ, sr, true),
            low: Biquad::new(HIGH_HZ.min(sr * 0.45), sr, false),
            sample_rate: u64::from(sample_rate.max(1)),
            seen: 0,
            frame_end: frame_end(0, sample_rate.max(1)),
            sum: 0.0,
            count: 0,
            levels: vec![],
        }
    }

    pub fn push(&mut self, samples: &[f32]) {
        for &s in samples {
            let v = self.low.run(self.high.run(f64::from(s)));
            self.sum += v * v;
            self.count += 1;
            self.seen += 1;
            if self.seen >= self.frame_end {
                self.close();
            }
        }
    }

    fn close(&mut self) {
        let mean = self.sum / self.count.max(1) as f64;
        self.levels.push(10.0 * (mean + 1e-10).log10());
        (self.sum, self.count) = (0.0, 0);
        self.frame_end = frame_end(self.levels.len() as u64, self.sample_rate as u32);
    }

    /// The level of every frame, in decibels, the last part frame with them.
    pub fn finish(mut self) -> Vec<f64> {
        if self.count > 0 {
            self.close();
        }
        self.levels
    }
}

/// Where frame `k` ends, in samples: frames are a sixtieth of a second however the rate divides.
fn frame_end(k: u64, sample_rate: u32) -> u64 {
    (k + 1) * u64::from(sample_rate) / u64::from(RATE)
}

/// The levels (decibels, a frame each) made a voice's loudness for the words `(start, end)`: 0 to
/// 255 a frame, counted only inside words, against the loudest of them, with a quick rise and an
/// eased fall.
pub fn envelope(levels: &[f64], words: &[(f64, f64)]) -> Vec<u8> {
    let mut spans: Vec<(f64, f64)> = words
        .iter()
        .map(|&(s, e)| (s - MARGIN_S, e + MARGIN_S))
        .collect();
    spans.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut next = 0;
    let inside: Vec<bool> = (0..levels.len())
        .map(|k| {
            let t = (k as f64 + 0.5) / f64::from(RATE);
            while next < spans.len() && spans[next].1 < t {
                next += 1;
            }
            spans[next..]
                .iter()
                .take_while(|s| s.0 <= t)
                .any(|s| s.1 >= t)
        })
        .collect();
    let mut said: Vec<f64> = levels
        .iter()
        .zip(&inside)
        .filter(|(_, i)| **i)
        .map(|(l, _)| *l)
        .collect();
    if said.is_empty() {
        return vec![0; levels.len()];
    }
    said.sort_by(f64::total_cmp);
    let loud = said[(PERCENTILE * (said.len() - 1) as f64).floor() as usize];
    let floor = loud - RANGE_DB;
    let mut held = 0.0f64;
    levels
        .iter()
        .zip(&inside)
        .map(|(l, i)| {
            let level = if *i {
                ((l - floor) / RANGE_DB).clamp(0.0, 1.0)
            } else {
                0.0
            };
            held = if level > held {
                level
            } else {
                held + (level - held) * RELEASE
            };
            (held * 255.0 + 0.5).floor() as u8
        })
        .collect()
}

/// The words of `transcript` as (start, end).
fn spans(transcript: &Transcript) -> Vec<(f64, f64)> {
    transcript
        .words()
        .map(|w| (f64::from(w.start), f64::from(w.end)))
        .collect()
}

/// The finished measure of `levels` for `transcript`, as the transcript keeps it.
pub fn measure(levels: &[f64], transcript: &Transcript) -> Loudness {
    Loudness {
        rate: RATE,
        values: encode(&envelope(levels, &spans(transcript))),
    }
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64, with padding.
pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i)) as usize & 63] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Standard base64 back to bytes; None for text that is not.
pub fn decode(text: &str) -> Option<Vec<u8>> {
    let digit = |c: u8| ALPHABET.iter().position(|&a| a == c).map(|p| p as u32);
    let text = text.trim_end_matches('=').as_bytes();
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    for chunk in text.chunks(4) {
        if chunk.len() == 1 {
            return None;
        }
        let mut n = 0u32;
        for (i, &c) in chunk.iter().enumerate() {
            n |= digit(c)? << (18 - 6 * i);
        }
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&bytes[..chunk.len() - 1]);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tone of `hz` for `secs` at `amp`, at 16 kHz.
    fn tone(hz: f32, secs: f32, amp: f32) -> Vec<f32> {
        (0..(secs * 16_000.0) as usize)
            .map(|i| amp * (std::f32::consts::TAU * hz * i as f32 / 16_000.0).sin())
            .collect()
    }

    #[test]
    fn a_frame_is_a_sixtieth_of_a_second() {
        let mut m = Meter::new(16_000);
        m.push(&tone(1000.0, 1.0, 0.5));
        assert_eq!(m.finish().len(), 60);
        let mut m = Meter::new(44_100);
        m.push(&vec![0.0; 44_100 * 2]);
        assert_eq!(m.finish().len(), 120);
    }

    #[test]
    fn the_voice_passes_and_the_bass_and_hiss_do_not() {
        let level = |hz: f32| {
            let mut m = Meter::new(16_000);
            m.push(&tone(hz, 0.5, 0.5));
            m.finish()[20]
        };
        assert!(level(1000.0) > level(60.0) + 20.0, "a bass note is cut");
        assert!(level(1000.0) > level(7000.0) + 10.0, "a hiss is cut");
    }

    #[test]
    fn only_words_move_it_and_the_loudest_word_is_full() {
        // Loud between 0.5 s and 1 s, quieter from 1 s to 1.5 s, loud music after, said nothing.
        let levels: Vec<f64> = (0..180)
            .map(|k| match k {
                30..60 => -10.0,
                60..90 => -22.0,
                _ => -5.0,
            })
            .collect();
        let v = envelope(&levels, &[(0.5, 1.0), (1.0, 1.5)]);
        assert_eq!(v[10], 0, "before the words");
        assert_eq!(v[45], 255, "the loud word");
        assert!(v[80] > 0 && v[80] < 128, "the quiet word, {}", v[80]);
        assert!(v[150] < 3, "the music after the words, {}", v[150]);
        assert!(v[61] > v[70], "a fall is eased");
    }

    #[test]
    fn base64_goes_there_and_back() {
        for n in 0..10 {
            let bytes: Vec<u8> = (0..n).map(|i| (i * 37 + 11) as u8).collect();
            assert_eq!(decode(&encode(&bytes)), Some(bytes));
        }
        assert_eq!(encode(b"Man"), "TWFu");
        assert_eq!(encode(b"Ma"), "TWE=");
        assert_eq!(decode("TQ=="), Some(b"M".to_vec()));
    }

    /// `testdata/loudness.json` holds levels, words and the envelope this draws from them, so the
    /// API's copy is held to the same answers (`OC_PRINT_GOLDEN=1` writes the file anew).
    #[test]
    fn the_envelope_is_the_shared_cases() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/loudness.json");
        let cases: Vec<serde_json::Value> = (0..4u32)
            .map(|c| {
                let levels: Vec<f64> = (0..240u32)
                    .map(|k| {
                        let h = (k.wrapping_mul(2_654_435_761) ^ c.wrapping_mul(40_503)) % 1000;
                        -40.0 + f64::from(h) * 0.035 + if k % 50 < 20 { 6.0 } else { 0.0 }
                    })
                    .map(|l: f64| (l * 1000.0).round() / 1000.0)
                    .collect();
                let words: Vec<(f64, f64)> = (0..(c + 2))
                    .map(|i| (0.3 + f64::from(i) * 0.9, 0.3 + f64::from(i) * 0.9 + 0.5))
                    .collect();
                let values = envelope(&levels, &words);
                serde_json::json!({ "levels": levels, "words": words, "values": values })
            })
            .collect();
        if std::env::var_os("OC_PRINT_GOLDEN").is_some() {
            std::fs::write(path, serde_json::to_string(&cases).unwrap() + "\n").unwrap();
        }
        let kept: Vec<serde_json::Value> =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(
            cases, kept,
            "rewrite testdata/loudness.json if this change is meant"
        );
    }
}
