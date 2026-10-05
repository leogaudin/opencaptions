//! Caption edits, shared by every editor: the web through WebAssembly, the phone
//! natively. Captions are the transcript's words in reading order, cut every
//! `words_per_line` words exactly as the scene cuts them; edits address words by
//! that flat index and rebuild the segments around them. Text edits are one word
//! at a time, so no edit ever has to invent a timing.

use serde::Serialize;
use serde_json::json;

use crate::model::{Segment, Transcript, Word, shifted};

/// The shortest a word may be made by retiming, in seconds.
pub const MIN_WORD_S: f32 = 0.05;

/// One caption as the viewer sees it.
#[derive(Debug, PartialEq, Serialize)]
pub struct Line {
    /// Flat index of the line's first word; the line holds `count` words.
    pub from: usize,
    pub count: usize,
    pub start: f32,
    pub end: f32,
    pub text: String,
}

#[derive(Clone, Copy, Debug)]
pub enum Edge {
    Start,
    End,
}

/// A caption position after magnetism toward the video's centre lines.
#[derive(Debug, PartialEq)]
pub struct Snapped {
    pub x: f32,
    pub y: f32,
    /// Whether `x` was pulled to the vertical centre line (0.5), and `y` to the horizontal.
    pub on_x: bool,
    pub on_y: bool,
}

/// Magnetism for dragging the caption block: each axis snaps to the video's centre
/// (0.5) when the block's centre is within `threshold` of it, measured in the same
/// unit as `width` and `height` (the pixels the editor shows the video at), so the
/// pull feels the same at any zoom. The two axes snap independently.
pub fn snap_to_centre(x: f32, y: f32, width: f32, height: f32, threshold: f32) -> Snapped {
    let near = |v: f32, extent: f32| (v - 0.5).abs() * extent <= threshold;
    let (on_x, on_y) = (near(x, width), near(y, height));
    Snapped {
        x: if on_x { 0.5 } else { x },
        y: if on_y { 0.5 } else { y },
        on_x,
        on_y,
    }
}

/// The captions as shown: times carry the caption offset, as the scene's do.
pub fn lines(t: &Transcript, words_per_line: u32, offset_ms: i32) -> Vec<Line> {
    let words: Vec<_> = t.words().collect();
    let size = words_per_line.max(1) as usize;
    words
        .chunks(size)
        .enumerate()
        .map(|(n, chunk)| Line {
            from: n * size,
            count: chunk.len(),
            start: shifted(chunk[0].start, offset_ms),
            end: shifted(chunk[chunk.len() - 1].end, offset_ms),
            text: join(chunk.iter().copied()),
        })
        .collect()
}

/// Moves one edge of word `index` to `time` as shown (with the caption offset),
/// kept between its neighbours and, where there is room, no shorter than
/// MIN_WORD_S. The neighbour wins over the minimum, so words stay ordered and
/// never overlap. The transcript keeps unshifted times, so the edit converts back.
pub fn retime(t: &Transcript, index: usize, edge: Edge, time: f32, offset_ms: i32) -> Transcript {
    let time = time - offset_ms as f32 / 1000.0;
    let mut entries = flatten(t);
    let prev_end = index
        .checked_sub(1)
        .and_then(|i| entries.get(i))
        .map_or(0.0, |e| e.1.end);
    let next_start = index
        .checked_add(1)
        .and_then(|i| entries.get(i))
        .map_or(t.duration, |e| e.1.start);
    let Some((_, w)) = entries.get_mut(index) else {
        return t.clone();
    };
    match edge {
        Edge::Start => w.start = time.clamp(prev_end, prev_end.max(w.end - MIN_WORD_S)),
        Edge::End => w.end = time.clamp(next_start.min(w.start + MIN_WORD_S), next_start),
    }
    rebuild(t, entries)
}

/// Sets the text of word `index`, keeping its timing and every other field.
/// Empty text removes the word (and a segment left with none). Text with more
/// than one word is refused: splitting a word would invent timings.
pub fn set_word(t: &Transcript, index: usize, text: &str) -> Result<Transcript, String> {
    let mut entries = flatten(t);
    if index >= entries.len() {
        return Err(format!("no word at index {index}"));
    }
    let text = text.trim();
    if text.is_empty() {
        entries.remove(index);
    } else if text.split_whitespace().count() > 1 {
        return Err("one word at a time".into());
    } else {
        entries[index].1.text = text.into();
    }
    Ok(rebuild(t, entries))
}

/// Each word paired with the index of the segment it belongs to.
fn flatten(t: &Transcript) -> Vec<(usize, Word)> {
    t.segments
        .iter()
        .enumerate()
        .flat_map(|(i, s)| s.words.iter().map(move |w| (i, w.clone())))
        .collect()
}

/// Regroups words into their segments, refreshing each segment's span and text;
/// a segment left with no words is dropped.
fn rebuild(t: &Transcript, entries: Vec<(usize, Word)>) -> Transcript {
    let segments = t
        .segments
        .iter()
        .enumerate()
        .filter_map(|(i, seg)| {
            let words: Vec<_> = entries
                .iter()
                .filter(|e| e.0 == i)
                .map(|e| e.1.clone())
                .collect();
            let (first, last) = (words.first()?, words.last()?);
            let mut rest = seg.rest.clone();
            rest.insert("start".into(), json!(first.start));
            rest.insert("end".into(), json!(last.end));
            rest.insert("text".into(), json!(join(words.iter())));
            Some(Segment { words, rest })
        })
        .collect();
    Transcript {
        segments,
        ..t.clone()
    }
}

fn join<'a>(words: impl Iterator<Item = &'a Word>) -> String {
    words.map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [one two] [three four]: at three words per line the first line spans both.
    fn transcript() -> Transcript {
        serde_json::from_value(json!({
            "schema_version": 1,
            "language": "en",
            "duration": 4.0,
            "segments": [
                { "id": "a", "start": 0.5, "end": 1.3, "text": "one two", "words": [
                    { "text": "one", "start": 0.5, "end": 0.9, "confidence": 0.9 },
                    { "text": "two", "start": 0.9, "end": 1.3, "confidence": 0.8 }] },
                { "id": "b", "start": 1.3, "end": 3.0, "text": "three four", "words": [
                    { "text": "three", "start": 1.3, "end": 1.7, "confidence": 1 },
                    { "text": "four", "start": 2.6, "end": 3.0, "confidence": 1 }] }
            ]
        }))
        .unwrap()
    }

    fn words(t: &Transcript) -> Vec<(String, f32, f32)> {
        t.words()
            .map(|w| (w.text.clone(), w.start, w.end))
            .collect()
    }

    #[test]
    fn the_caption_snaps_to_each_centre_line_within_the_threshold() {
        // A 400 x 800 px preview, 8 px of pull: 0.02 across, 0.01 down.
        let s = snap_to_centre(0.51, 0.84, 400.0, 800.0, 8.0);
        assert_eq!(
            s,
            Snapped {
                x: 0.5,
                y: 0.84,
                on_x: true,
                on_y: false
            }
        );
        let both = snap_to_centre(0.49, 0.505, 400.0, 800.0, 8.0);
        assert_eq!(
            (both.x, both.y, both.on_x, both.on_y),
            (0.5, 0.5, true, true)
        );
        let outside = snap_to_centre(0.53, 0.52, 400.0, 800.0, 8.0);
        assert_eq!((outside.x, outside.y), (0.53, 0.52));
        assert!(!outside.on_x && !outside.on_y);
        // The threshold is in pixels, so a bigger preview pulls over less of the range.
        assert!(snap_to_centre(0.51, 0.1, 400.0, 800.0, 8.0).on_x);
        assert!(!snap_to_centre(0.51, 0.1, 2000.0, 800.0, 8.0).on_x);
        // Exactly at the edge of the threshold still snaps; a zero threshold only snaps on the line.
        assert!(snap_to_centre(0.52, 0.1, 400.0, 800.0, 8.0).on_x);
        assert!(snap_to_centre(0.5, 0.5, 400.0, 800.0, 0.0).on_x);
        assert!(!snap_to_centre(0.5001, 0.5, 400.0, 800.0, 0.0).on_x);
    }

    #[test]
    fn lines_cut_across_segments_like_the_scene() {
        let ls = lines(&transcript(), 3, 0);
        assert_eq!(
            ls,
            [
                Line {
                    from: 0,
                    count: 3,
                    start: 0.5,
                    end: 1.7,
                    text: "one two three".into()
                },
                Line {
                    from: 3,
                    count: 1,
                    start: 2.6,
                    end: 3.0,
                    text: "four".into()
                },
            ]
        );
    }

    #[test]
    fn edits_keep_every_field_they_do_not_change() {
        let t = retime(&transcript(), 1, Edge::End, 1.2, 0);
        let v = serde_json::to_value(&t).unwrap();
        assert_eq!(v["schema_version"], 1);
        assert_eq!(v["segments"][0]["id"], "a");
        assert_eq!(v["segments"][0]["words"][0]["confidence"], 0.9f32);
        assert_eq!(v["segments"][0]["end"], 1.2f32);
    }

    #[test]
    fn retime_moves_one_edge_and_stops_at_the_neighbours() {
        let t = transcript();
        assert_eq!(
            words(&retime(&t, 0, Edge::Start, 0.2, 0))[0],
            ("one".into(), 0.2, 0.9)
        );
        assert_eq!(
            words(&retime(&t, 2, Edge::End, 3.5, 0))[2].2,
            2.6,
            "stops at four"
        );
        assert_eq!(
            words(&retime(&t, 1, Edge::Start, 0.1, 0))[1].1,
            0.9,
            "stops at one"
        );
        assert_eq!(
            words(&retime(&t, 3, Edge::End, 9.0, 0))[3].2,
            4.0,
            "stops at the end"
        );
        let short = retime(&t, 1, Edge::End, 0.0, 0);
        assert!(
            (words(&short)[1].2 - (0.9 + MIN_WORD_S)).abs() < 1e-6,
            "keeps a minimum"
        );
    }

    #[test]
    fn the_caption_offset_is_shown_in_lines_and_removed_from_edits() {
        let ls = lines(&transcript(), 3, 500);
        assert_eq!((ls[0].start, ls[0].end), (1.0, 2.2));
        assert_eq!(lines(&transcript(), 3, -2000)[0].start, 0.0, "clamped");
        // Dragging word three's end to 2.1 as shown at +500 ms writes 1.6.
        let t = retime(&transcript(), 2, Edge::End, 2.1, 500);
        assert!((words(&t)[2].2 - 1.6).abs() < 1e-5, "unshifted on write");
    }

    #[test]
    fn retime_never_crosses_a_neighbour_even_below_the_minimum() {
        // Words shorter than MIN_WORD_S, back to back.
        let t: Transcript = serde_json::from_value(json!({
            "duration": 1.0,
            "segments": [{ "id": "a", "start": 0.0, "end": 0.06, "text": "a b c", "words": [
                { "text": "a", "start": 0.0, "end": 0.02 },
                { "text": "b", "start": 0.02, "end": 0.04 },
                { "text": "c", "start": 0.04, "end": 0.06 }] }]
        }))
        .unwrap();
        let moved = words(&retime(&t, 1, Edge::Start, 0.0, 0));
        assert_eq!(moved[1].1, 0.02, "start cannot pass the previous end");
        let moved = words(&retime(&t, 1, Edge::End, 0.5, 0));
        assert_eq!(moved[1].2, 0.04, "end cannot pass the next start");
        assert!(moved.windows(2).all(|p| p[0].2 <= p[1].1 + 1e-6));
    }

    #[test]
    fn set_word_renames_one_word_and_keeps_everything_else() {
        let t = set_word(&transcript(), 2, "  tres ").unwrap();
        assert_eq!(words(&t)[2], ("tres".into(), 1.3, 1.7), "timing kept");
        assert_eq!(t.segments[1].rest["text"], "tres four");
        assert_eq!(
            t.segments[0].rest["text"], "one two",
            "other segments untouched"
        );
        let v = serde_json::to_value(&t).unwrap();
        assert_eq!(v["segments"][0]["words"][0]["confidence"], 0.9f32);
        assert_eq!(v["segments"][1]["id"], "b");
    }

    #[test]
    fn set_word_refuses_several_words_and_missing_indexes() {
        assert_eq!(
            set_word(&transcript(), 0, "uno dos").unwrap_err(),
            "one word at a time"
        );
        assert!(set_word(&transcript(), 4, "x").is_err());
    }

    #[test]
    fn set_word_with_nothing_removes_the_word_and_empty_segments() {
        let t = set_word(&transcript(), 1, "  ").unwrap();
        assert_eq!(words(&t).len(), 3);
        assert_eq!(t.segments[0].rest["text"], "one");
        assert_eq!(t.segments[0].rest["end"], 0.9f32, "span follows the words");
        let gone = (0..4).fold(transcript(), |t, _| set_word(&t, 0, "").unwrap());
        assert!(gone.segments.is_empty());
    }
}
