//! Caption edits, shared by every editor: the web through WebAssembly, the phone
//! natively. Captions are the transcript's words in reading order, cut every
//! `words_per_line` words exactly as the scene cuts them; edits address words by
//! that flat index and rebuild the segments around them.

use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::model::{Transcript, Word};

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

pub fn lines(t: &Transcript, words_per_line: u32) -> Vec<Line> {
    let words: Vec<_> = t.words().collect();
    let size = words_per_line.max(1) as usize;
    words
        .chunks(size)
        .enumerate()
        .map(|(n, chunk)| Line {
            from: n * size,
            count: chunk.len(),
            start: chunk[0].start,
            end: chunk[chunk.len() - 1].end,
            text: join(chunk.iter().copied()),
        })
        .collect()
}

/// Moves one edge of word `index` to `time`, kept between its neighbours and,
/// where there is room, no shorter than MIN_WORD_S. The neighbour wins over the
/// minimum, so words stay ordered and never overlap.
pub fn retime(t: &Transcript, index: usize, edge: Edge, time: f32) -> Transcript {
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

/// Replaces `count` words from `from` with the words of `text`. The same number
/// of words keeps every timing; a different number shares the run's time span by
/// word length. Empty text removes the run. New words join the run's first segment.
pub fn replace(t: &Transcript, from: usize, count: usize, text: &str) -> Transcript {
    let entries = flatten(t);
    let Some(run) = from
        .checked_add(count)
        .and_then(|end| entries.get(from..end))
        .filter(|r| !r.is_empty())
    else {
        return t.clone();
    };
    let tokens: Vec<_> = text.split_whitespace().collect();
    let replaced: Vec<_> = if tokens.len() == run.len() {
        run.iter()
            .zip(&tokens)
            .map(|((seg, w), &text)| {
                (
                    *seg,
                    Word {
                        text: text.into(),
                        ..w.clone()
                    },
                )
            })
            .collect()
    } else {
        let seg = run[0].0;
        spread(&tokens, run[0].1.start, run[run.len() - 1].1.end)
            .map(|w| (seg, w))
            .collect()
    };
    let mut out = entries[..from].to_vec();
    out.extend(replaced);
    out.extend_from_slice(&entries[from + count..]);
    rebuild(t, out)
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
            Some(crate::model::Segment { words, rest })
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

/// New words over `start..end`, each taking a share proportional to its length.
fn spread<'a>(tokens: &'a [&str], start: f32, end: f32) -> impl Iterator<Item = Word> + 'a {
    let len = |s: &str| s.chars().count() as f32;
    let total: f32 = tokens.iter().map(|s| len(s)).sum();
    let mut done = 0.0;
    tokens.iter().enumerate().map(move |(i, &text)| {
        let begin = start + (end - start) * done / total;
        done += len(text);
        Word {
            text: text.into(),
            start: begin,
            // The last word ends exactly where the run did, free of rounding.
            end: if i + 1 == tokens.len() {
                end
            } else {
                start + (end - start) * done / total
            },
            rest: Map::from_iter([("confidence".into(), Value::from(1))]),
        }
    })
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
    fn lines_cut_across_segments_like_the_scene() {
        let ls = lines(&transcript(), 3);
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
        let t = retime(&transcript(), 1, Edge::End, 1.2);
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
            words(&retime(&t, 0, Edge::Start, 0.2))[0],
            ("one".into(), 0.2, 0.9)
        );
        assert_eq!(
            words(&retime(&t, 2, Edge::End, 3.5))[2].2,
            2.6,
            "stops at four"
        );
        assert_eq!(
            words(&retime(&t, 1, Edge::Start, 0.1))[1].1,
            0.9,
            "stops at one"
        );
        assert_eq!(
            words(&retime(&t, 3, Edge::End, 9.0))[3].2,
            4.0,
            "stops at the end"
        );
        let short = retime(&t, 1, Edge::End, 0.0);
        assert!(
            (words(&short)[1].2 - (0.9 + MIN_WORD_S)).abs() < 1e-6,
            "keeps a minimum"
        );
    }

    #[test]
    fn retime_never_crosses_a_neighbour_even_below_the_minimum() {
        let t = replace(
            &transcript(),
            3,
            1,
            "a b c d e f g h i j k l m n o p q r s t u v w x y z",
        );
        let ws = words(&t);
        // Each new word is shorter than MIN_WORD_S; its start cannot pass the previous end.
        let moved = words(&retime(&t, 4, Edge::Start, 0.0));
        assert_eq!(moved[4].1, ws[3].2);
        assert!(moved.windows(2).all(|p| p[0].2 <= p[1].1 + 1e-6));
    }

    #[test]
    fn replace_keeps_timings_for_the_same_count_and_spreads_otherwise() {
        let t = transcript();
        let same = replace(&t, 0, 3, "uno dos tres");
        assert_eq!(
            words(&same)[2],
            ("tres".into(), 1.3, 1.7),
            "word in the second segment"
        );
        assert_eq!(same.segments[0].rest["text"], "uno dos");

        let more = replace(&t, 3, 1, "ab abcdef");
        let ws = words(&more);
        assert_eq!((ws[3].0.as_str(), ws[3].1), ("ab", 2.6));
        assert!(
            (ws[3].2 - 2.7).abs() < 1e-5 && ws[4].1 == ws[3].2,
            "shared by length"
        );
        assert_eq!(
            (ws[4].0.as_str(), ws[4].2),
            ("abcdef", 3.0),
            "ends where the run did"
        );
        assert_eq!(more.segments[1].words[1].rest["confidence"], 1);

        let merged = replace(&t, 1, 2, "x");
        assert_eq!(merged.segments[0].rest["text"], "one x");
        assert_eq!(merged.segments[1].rest["text"], "four");
    }

    #[test]
    fn replace_with_nothing_removes_words_and_empty_segments() {
        let t = replace(&transcript(), 3, 1, "  ");
        assert_eq!(t.segments.len(), 2);
        let gone = replace(&replace(&transcript(), 2, 2, ""), 0, 2, "");
        assert!(gone.segments.is_empty());
    }
}
