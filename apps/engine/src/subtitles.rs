//! Subtitle files (SubRip and WebVTT) for a transcript.
//!
//! A cue is a caption line as the video and the timeline show it (`edit::lines`, the same cut the
//! scene draws), and every time carries the caption offset (`model::shifted`), so a file lines up
//! with the captions on the picture. Word timing is kept for WebVTT, which has tags for it.

use crate::edit::lines;
use crate::model::{Transcript, shifted};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Srt,
    Vtt,
}

impl Format {
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "srt" => Some(Self::Srt),
            "vtt" => Some(Self::Vtt),
            _ => None,
        }
    }
}

/// `HH:MM:SS` and milliseconds, which SubRip separates with a comma and WebVTT with a dot.
fn timestamp(seconds: f32, separator: char) -> String {
    let total = ((f64::from(seconds) * 1000.0).round() as i64).max(0);
    let (secs, ms) = (total / 1000, total % 1000);
    format!(
        "{:02}:{:02}:{:02}{separator}{ms:03}",
        secs / 3600,
        secs / 60 % 60,
        secs % 60
    )
}

/// The transcript as a subtitle file, cut into `words_per_line` words a cue (fewer where the
/// speech pauses) and shifted by `offset_ms`.
pub fn subtitles(t: &Transcript, words_per_line: u32, offset_ms: i32, format: Format) -> String {
    let cues = lines(t, words_per_line, offset_ms);
    let words: Vec<_> = t.words().collect();
    let mut out = String::new();
    if format == Format::Vtt {
        out.push_str("WEBVTT\n\n");
    }
    for (n, cue) in cues.iter().enumerate() {
        let sep = if format == Format::Srt { ',' } else { '.' };
        if format == Format::Srt {
            out.push_str(&format!("{}\n", n + 1));
        }
        out.push_str(&format!(
            "{} --> {}\n",
            timestamp(cue.start, sep),
            timestamp(cue.end, sep)
        ));
        match format {
            Format::Srt => out.push_str(&cue.text),
            Format::Vtt => {
                let tagged: Vec<String> = words[cue.from..cue.from + cue.count]
                    .iter()
                    .map(|w| {
                        format!(
                            "<{}>{}",
                            timestamp(shifted(w.start, offset_ms), sep),
                            w.text
                        )
                    })
                    .collect();
                out.push_str(&tagged.join(" "));
            }
        }
        out.push_str("\n\n");
    }
    // A file ends with one newline, and an empty one is just that.
    format!("{}\n", out.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit::lines;
    use serde_json::json;

    /// Two segments, the second after a long silence: [one two three] [four five] at three a line.
    fn transcript() -> Transcript {
        serde_json::from_value(json!({
            "schema_version": 1, "language": "en", "duration": 400.0,
            "segments": [
                { "id": "a", "start": 0.0, "end": 1.5, "text": "one two three", "words": [
                    { "text": "one", "start": 0.0, "end": 0.5 },
                    { "text": "two", "start": 0.5, "end": 1.0 },
                    { "text": "three", "start": 1.0, "end": 1.5 }] },
                { "id": "b", "start": 301.0, "end": 302.25, "text": "four five", "words": [
                    { "text": "four", "start": 301.0, "end": 301.5 },
                    { "text": "five", "start": 301.5, "end": 302.25 }] }
            ]
        }))
        .unwrap()
    }

    #[test]
    fn a_cue_is_a_caption_line_as_the_scene_cuts_it() {
        let t = transcript();
        for per_line in [1, 2, 3, 5] {
            let srt = subtitles(&t, per_line, 0, Format::Srt);
            let cues: Vec<_> = srt.trim_end().split("\n\n").collect();
            let want = lines(&t, per_line, 0);
            assert_eq!(cues.len(), want.len(), "{per_line} a line");
            for (cue, line) in cues.iter().zip(&want) {
                assert!(cue.ends_with(&line.text), "{cue:?} holds {:?}", line.text);
                assert!(cue.contains(&timestamp(line.start, ',')));
            }
        }
    }

    #[test]
    fn srt_numbers_cues_and_uses_commas() {
        let srt = subtitles(&transcript(), 3, 0, Format::Srt);
        assert_eq!(
            srt,
            "1\n00:00:00,000 --> 00:00:01,500\none two three\n\n\
             2\n00:05:01,000 --> 00:05:02,250\nfour five\n"
        );
    }

    #[test]
    fn vtt_tags_each_word_with_its_start() {
        let vtt = subtitles(&transcript(), 2, 0, Format::Vtt);
        assert!(vtt.starts_with("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n"));
        assert!(vtt.contains("<00:00:00.000>one <00:00:00.500>two\n"));
        assert!(vtt.contains("<00:05:01.500>five\n"));
        assert!(vtt.ends_with("five\n"));
    }

    #[test]
    fn the_offset_shifts_every_time_and_stops_at_zero() {
        let vtt = subtitles(&transcript(), 3, 250, Format::Vtt);
        assert!(vtt.contains("00:00:00.250 --> 00:00:01.750"));
        assert!(vtt.contains("<00:00:00.750>two"));
        let early = subtitles(&transcript(), 3, -750, Format::Srt);
        assert!(early.contains("00:00:00,000 --> 00:00:00,750"), "{early}");
        assert!(early.contains("00:05:00,250 --> 00:05:01,500"));
    }

    #[test]
    fn a_transcript_with_no_words_is_an_empty_file() {
        let t: Transcript = serde_json::from_value(
            json!({ "schema_version": 1, "language": "en", "duration": 1.0, "segments": [] }),
        )
        .unwrap();
        assert_eq!(subtitles(&t, 3, 0, Format::Srt), "\n");
        assert_eq!(subtitles(&t, 3, 0, Format::Vtt), "WEBVTT\n");
    }

    #[test]
    fn a_rounded_up_millisecond_carries_all_the_way() {
        assert_eq!(timestamp(59.9999, ','), "00:01:00,000");
        assert_eq!(timestamp(3599.9999, ','), "01:00:00,000");
    }

    #[test]
    fn a_time_is_rounded_to_the_millisecond() {
        assert_eq!(timestamp(3661.2349, ','), "01:01:01,235");
        assert_eq!(timestamp(-1.0, '.'), "00:00:00.000");
    }
}
