//! Caption edits, shared by every editor: the web through WebAssembly, the phone
//! natively. Captions are the transcript's words in reading order, cut every
//! `words_per_line` words (fewer around a long pause) exactly as the scene cuts them; edits address words by
//! that flat index and rebuild the segments around them. Text edits are one word
//! at a time, so no edit ever has to invent a timing.

use serde::Serialize;
use serde_json::json;

use crate::model::{Segment, Transcript, Word, cut, shifted};

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

/// Where a dragged caption block lands on one axis, and the guide line it is on (a share of the axis).
#[derive(Debug, PartialEq)]
pub struct Snap {
    pub position: f32,
    /// The line the block snapped to, or `None` if it is free.
    pub line: Option<f32>,
}

/// Magnetism for dragging the caption block along one axis. The block has three lines of its own, its
/// start, its middle and its end, and the frame has three: a margin in from each side and the centre. Each
/// of the block's lines is pulled to its own line of the frame (start to the near margin, middle to the
/// centre, end to the far margin) when it is within `threshold` of it, so a caption can sit centred, or
/// flush against either margin whatever its width.
///
/// `position` is where the block is held, as a share of the axis, and `anchor` which part of the block that
/// is (0 its start, 0.5 its middle, 1 its end: a block aligned left is held by its start). `extent` is the
/// block's length as a share of the axis, `size` the axis as the editor shows it and `threshold` the pull,
/// both in pixels, so the pull feels the same at any zoom. `margin` is a share of the axis.
pub fn snap_axis(
    position: f32,
    extent: f32,
    anchor: f32,
    size: f32,
    threshold: f32,
    margin: f32,
) -> Snap {
    // Which part of the block (0 start, 0.5 middle, 1 end) goes with which line of the frame.
    let pairs = [(0.0, margin), (0.5, 0.5), (1.0, 1.0 - margin)];
    let mut best: Option<(f32, Snap)> = None;
    for (part, line) in pairs {
        // Where the block must be held for that part to be on the line.
        let held = line - (part - anchor) * extent;
        let pull = (position - held).abs() * size;
        if pull <= threshold && best.as_ref().is_none_or(|(nearest, _)| pull < *nearest) {
            best = Some((
                pull,
                Snap {
                    position: held,
                    line: Some(line),
                },
            ));
        }
    }
    best.map_or(
        Snap {
            position,
            line: None,
        },
        |(_, snap)| snap,
    )
}

/// The captions as shown: times carry the caption offset, as the scene's do.
pub fn lines(t: &Transcript, words_per_line: u32, offset_ms: i32) -> Vec<Line> {
    let words: Vec<_> = t.words().collect();
    let ranges = cut(&words, words_per_line as usize);
    ranges
        .into_iter()
        .map(|range| {
            let chunk = &words[range.clone()];
            Line {
                from: range.start,
                count: chunk.len(),
                start: shifted(chunk[0].start, offset_ms),
                end: shifted(chunk[chunk.len() - 1].end, offset_ms),
                text: join(chunk.iter().copied()),
            }
        })
        .collect()
}

/// Moves one edge of word `index` to `time` as shown (with the caption offset). Past a
/// neighbour that touches it, the neighbour gives way (a rolling edit): its facing edge is
/// pushed along, down to MIN_WORD_S, and never lengthened, so two captions that meet can
/// have the boundary between them dragged either way. Words stay ordered and never
/// overlap, and where there is room the word keeps at least MIN_WORD_S; the neighbour wins
/// over the minimum. The transcript keeps unshifted times, so the edit converts back.
pub fn retime(t: &Transcript, index: usize, edge: Edge, time: f32, offset_ms: i32) -> Transcript {
    let time = time - offset_ms as f32 / 1000.0;
    let mut entries = flatten(t);
    if index >= entries.len() {
        return t.clone();
    }
    match edge {
        Edge::Start => {
            let before = index.checked_sub(1);
            let (prev_start, prev_end) =
                before.map_or((0.0, 0.0), |i| (entries[i].1.start, entries[i].1.end));
            // The previous word may be shortened to the minimum, not below what it already is.
            let floor = (prev_start + MIN_WORD_S).min(prev_end);
            let w = &mut entries[index].1;
            let start = time.clamp(floor, prev_end.max(w.end - MIN_WORD_S));
            w.start = start;
            if let Some(i) = before.filter(|_| start < prev_end) {
                entries[i].1.end = start;
            }
        }
        Edge::End => {
            let after = (index + 1 < entries.len()).then_some(index + 1);
            let (next_start, next_end) = after.map_or((t.duration, t.duration), |i| {
                (entries[i].1.start, entries[i].1.end)
            });
            // The next word may be shortened to the minimum, not below what it already is.
            let ceiling = next_start.max(next_end - MIN_WORD_S);
            let w = &mut entries[index].1;
            let end = time.clamp(next_start.min(w.start + MIN_WORD_S), ceiling);
            w.end = end;
            if let Some(i) = after.filter(|_| end > next_start) {
                entries[i].1.start = end;
            }
        }
    }
    rebuild(t, entries)
}

/// Sets the text of word `index`, keeping its timing and every other field.
/// Empty text removes the word (and a segment left with none). Spaces inside the
/// text stay, collapsed to one: it is still a single word, timed and drawn as one.
pub fn set_word(t: &Transcript, index: usize, text: &str) -> Result<Transcript, String> {
    let mut entries = flatten(t);
    if index >= entries.len() {
        return Err(format!("no word at index {index}"));
    }
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.is_empty() {
        entries.remove(index);
    } else {
        entries[index].1.text = text;
    }
    Ok(rebuild(t, entries))
}

/// Gives word `index` the look `variant` of the style (None for the style's own), keeping its
/// text, timing and every other field. An index the style has no look for is kept: a preset with
/// more looks gives it back.
pub fn set_variant(
    t: &Transcript,
    index: usize,
    variant: Option<u32>,
) -> Result<Transcript, String> {
    let mut entries = flatten(t);
    let Some(entry) = entries.get_mut(index) else {
        return Err(format!("no word at index {index}"));
    };
    entry.1.variant = variant;
    Ok(rebuild(t, entries))
}

/// Hands every word one of the style's `count` looks, or its own, at random: half the words keep the
/// style's own look and the rest take the looks evenly, never the same one twice in a row. The same
/// `seed` gives the same words the same looks, so what the preview shows is what is exported, and
/// another seed deals again. Text, timing and every other field stay.
pub fn shuffle_variants(t: &Transcript, count: u32, seed: u32) -> Transcript {
    let mut entries = flatten(t);
    let mut state = u64::from(seed);
    let mut last = None;
    for (_, word) in &mut entries {
        let roll = splitmix(&mut state);
        let mut pick = None;
        if count > 0 && roll & 1 == 1 {
            let mut look = ((roll >> 1) % u64::from(count)) as u32;
            if count > 1 && Some(look) == last {
                look = (look + 1) % count;
            }
            pick = Some(look);
        }
        word.variant = pick;
        last = pick.or(last);
    }
    rebuild(t, entries)
}

/// The next number of a SplitMix64 sequence: small, and the same on every platform.
fn splitmix(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
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
    fn captions_break_at_a_long_pause_and_otherwise_every_n_words() {
        let t: Transcript = serde_json::from_value(json!({
            "schema_version": 1, "language": "en", "duration": 200.0,
            "segments": [
                { "id": "a", "start": 0.0, "end": 1.0, "text": "one two", "words": [
                    { "text": "one", "start": 0.0, "end": 0.5 },
                    { "text": "two", "start": 0.5, "end": 1.0 }] },
                { "id": "b", "start": 120.0, "end": 121.5, "text": "three four five", "words": [
                    { "text": "three", "start": 120.0, "end": 120.5 },
                    { "text": "four", "start": 120.5, "end": 121.0 },
                    { "text": "five", "start": 121.0, "end": 121.5 }] }
            ]
        }))
        .unwrap();
        let cut: Vec<_> = lines(&t, 3, 0)
            .iter()
            .map(|l| (l.from, l.count, l.text.clone()))
            .collect();
        assert_eq!(
            cut,
            [(0, 2, "one two".into()), (2, 3, "three four five".into())]
        );
        // Without the pause the same words are cut by count alone.
        let counts: Vec<_> = lines(&t, 2, 0).iter().map(|l| (l.from, l.count)).collect();
        assert_eq!(counts, [(0, 2), (2, 2), (4, 1)]);
    }

    #[test]
    fn a_word_edit_keeps_everything_else() {
        let t: Transcript = serde_json::from_value(json!({
            "schema_version": 1, "language": "en", "duration": 4.0, "mystery": 7,
            "segments": [{ "id": "a", "start": 0.0, "end": 1.5, "text": "we grew 40", "words": [
                { "text": "we", "start": 0.0, "end": 0.5, "confidence": 0.9 },
                { "text": "grew", "start": 0.5, "end": 1.0 },
                { "text": "40", "start": 1.0, "end": 1.5, "extra": [1] }] }]
        }))
        .unwrap();
        let edited = set_word(&t, 1, "grow").unwrap();
        let kept = serde_json::to_value(&edited).unwrap();
        assert_eq!(kept["mystery"], 7);
        assert_eq!(kept["segments"][0]["words"][0]["confidence"], json!(0.9));
        assert_eq!(kept["segments"][0]["words"][1]["text"], "grow");
        assert_eq!(kept["segments"][0]["words"][2]["extra"], json!([1]));
        assert!(set_word(&t, 9, "x").is_err());
    }

    #[test]
    fn the_caption_snaps_its_middle_to_the_centre_within_the_threshold() {
        // A 400 px axis, 8 px of pull: 0.02 of it. A block held by its middle, 100 px (0.25) long.
        let near = snap_axis(0.51, 0.25, 0.5, 400.0, 8.0, 0.06);
        assert_eq!(
            near,
            Snap {
                position: 0.5,
                line: Some(0.5)
            }
        );
        let free = snap_axis(0.53, 0.25, 0.5, 400.0, 8.0, 0.06);
        assert_eq!(
            free,
            Snap {
                position: 0.53,
                line: None
            }
        );
        // The threshold is in pixels, so a bigger preview pulls over less of the range.
        assert!(snap_axis(0.51, 0.25, 0.5, 400.0, 8.0, 0.06).line.is_some());
        assert!(snap_axis(0.51, 0.25, 0.5, 2000.0, 8.0, 0.06).line.is_none());
        // Exactly at the threshold still snaps; a zero threshold only snaps on the line.
        assert!(snap_axis(0.52, 0.25, 0.5, 400.0, 8.0, 0.06).line.is_some());
        assert!(snap_axis(0.5, 0.25, 0.5, 400.0, 0.0, 0.06).line.is_some());
        assert!(
            snap_axis(0.5001, 0.25, 0.5, 400.0, 0.0, 0.06)
                .line
                .is_none()
        );
    }

    #[test]
    fn each_end_of_the_block_snaps_to_its_own_margin() {
        // Held by its middle and 0.25 long, its start is on the near margin (0.06) at 0.06 + 0.125 and its
        // end on the far one at 0.94 - 0.125.
        let start = snap_axis(0.19, 0.25, 0.5, 400.0, 8.0, 0.06);
        assert_eq!(start.line, Some(0.06));
        assert!((start.position - 0.185).abs() < 1e-6);
        let end = snap_axis(0.82, 0.25, 0.5, 400.0, 8.0, 0.06);
        assert_eq!(end.line, Some(0.94));
        assert!((end.position - 0.815).abs() < 1e-6);
        // Held by its start (a block aligned left) it is the position itself that goes to the margin, and
        // its middle that goes to the centre: 0.5 - 0.125.
        assert_eq!(snap_axis(0.07, 0.25, 0.0, 400.0, 8.0, 0.06).position, 0.06);
        let middle = snap_axis(0.38, 0.25, 0.0, 400.0, 8.0, 0.06);
        assert_eq!(middle.line, Some(0.5));
        assert!((middle.position - 0.375).abs() < 1e-6);
        // Held by its end: the position is the end, which goes to the far margin.
        assert_eq!(snap_axis(0.93, 0.25, 1.0, 400.0, 8.0, 0.06).position, 0.94);
    }

    #[test]
    fn the_nearest_line_wins_when_two_are_in_reach() {
        // A block 0.8 long, held by its middle: it is centred at 0.5 and has its end on the far margin at
        // 0.54. At 0.525 both are in reach of a 10 px pull on a 400 px axis, and the end (6 px) is nearer
        // than the centre (10 px).
        let near = snap_axis(0.525, 0.8, 0.5, 400.0, 10.0, 0.06);
        assert_eq!(near.line, Some(0.94));
        assert!((near.position - 0.54).abs() < 1e-6);
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
                    text: "one two three".into(),
                },
                Line {
                    from: 3,
                    count: 1,
                    start: 2.6,
                    end: 3.0,
                    text: "four".into(),
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
    fn retime_moves_one_edge_and_a_touching_neighbour_gives_way() {
        let t = transcript();
        assert_eq!(
            words(&retime(&t, 0, Edge::Start, 0.2, 0))[0],
            ("one".into(), 0.2, 0.9)
        );
        // Four is in the way, so it is pushed along, down to its minimum.
        let pushed = words(&retime(&t, 2, Edge::End, 3.5, 0));
        assert_eq!(pushed[2].2, 3.0 - MIN_WORD_S);
        assert_eq!(pushed[3], ("four".into(), 3.0 - MIN_WORD_S, 3.0));
        // Two starts where one ends: dragging it back shortens one, to its minimum.
        let rolled = words(&retime(&t, 1, Edge::Start, 0.1, 0));
        assert_eq!(rolled[0], ("one".into(), 0.5, 0.5 + MIN_WORD_S));
        assert_eq!(rolled[1].1, 0.5 + MIN_WORD_S);
        // And dragging it on shortens two, leaving the boundary where it was put.
        let on = words(&retime(&t, 1, Edge::Start, 1.0, 0));
        assert_eq!((on[0].2, on[1].1), (0.9, 1.0));
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
    fn retime_leaves_a_neighbour_alone_while_there_is_a_gap_to_move_through() {
        let t = transcript();
        let before = words(&t);
        // Three ends at 1.7 and four starts at 2.6: both can move through the gap.
        let extended = words(&retime(&t, 2, Edge::End, 2.0, 0));
        assert_eq!(extended[2].2, 2.0);
        assert_eq!(extended[3], before[3]);
        let earlier = words(&retime(&t, 3, Edge::Start, 2.0, 0));
        assert_eq!(earlier[3].1, 2.0);
        assert_eq!(earlier[2], before[2]);
    }

    #[test]
    fn a_line_starting_on_a_tiny_word_that_touches_the_last_can_still_be_moved() {
        // A word of no length, right against the one before it: nothing to shrink and nowhere
        // to go, which is how a start edge came to be stuck.
        let t: Transcript = serde_json::from_value(json!({
            "duration": 20.0,
            "segments": [{ "id": "a", "start": 9.0, "end": 10.4, "text": "x oh I", "words": [
                { "text": "x", "start": 9.0, "end": 10.0 },
                { "text": "oh", "start": 10.0, "end": 10.0 },
                { "text": "I", "start": 10.0, "end": 10.4 }] }]
        }))
        .unwrap();
        let moved = words(&retime(&t, 1, Edge::Start, 9.6, 0));
        assert_eq!(moved[1], ("oh".into(), 9.6, 10.0));
        assert_eq!(moved[0].2, 9.6, "the word before gives way");
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
    fn set_word_keeps_spaces_inside_as_one_word_with_its_timing() {
        let t = set_word(&transcript(), 0, "  hello   big world ").unwrap();
        assert_eq!(words(&t).len(), 4, "still four words");
        assert_eq!(words(&t)[0], ("hello big world".into(), 0.5, 0.9));
        assert_eq!(t.segments[0].rest["text"], "hello big world two");
    }

    #[test]
    fn set_word_refuses_missing_indexes() {
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

    #[test]
    fn set_variant_sets_and_clears_one_words_look_and_nothing_else() {
        let t = set_variant(&transcript(), 1, Some(2)).unwrap();
        let v = serde_json::to_value(&t).unwrap();
        assert_eq!(v["segments"][0]["words"][1]["variant"], 2);
        assert!(v["segments"][0]["words"][0].get("variant").is_none());
        assert_eq!(v["segments"][0]["words"][1]["confidence"], 0.8f32);
        assert_eq!(words(&t), words(&transcript()), "text and timing kept");
        let cleared = set_variant(&t, 1, None).unwrap();
        assert_eq!(
            serde_json::to_value(&cleared.segments[0].words).unwrap(),
            serde_json::to_value(&transcript().segments[0].words).unwrap(),
            "a cleared look leaves the words as they were"
        );
        assert!(set_variant(&transcript(), 4, Some(0)).is_err());
    }

    #[test]
    fn shuffle_deals_the_same_looks_for_a_seed_and_others_for_another() {
        let looks = |t: &Transcript| t.words().map(|w| w.variant).collect::<Vec<_>>();
        let a = shuffle_variants(&transcript(), 5, 7);
        assert_eq!(looks(&a), looks(&shuffle_variants(&transcript(), 5, 7)));
        assert!((0..40).any(|s| looks(&shuffle_variants(&transcript(), 5, s)) != looks(&a)));
        assert_eq!(words(&a), words(&transcript()), "text and timing kept");
    }

    #[test]
    fn shuffle_keeps_half_the_words_plain_and_never_repeats_a_look_in_a_row() {
        let many = Transcript {
            segments: vec![Segment {
                words: (0..400)
                    .map(|i| Word {
                        text: "w".into(),
                        start: i as f32,
                        end: i as f32 + 1.0,
                        variant: None,
                        rest: Default::default(),
                    })
                    .collect(),
                rest: Default::default(),
            }],
            ..transcript()
        };
        let t = shuffle_variants(&many, 4, 99);
        let looks: Vec<_> = t.words().map(|w| w.variant).collect();
        let plain = looks.iter().filter(|v| v.is_none()).count();
        assert!((140..260).contains(&plain), "{plain} of 400 plain");
        assert!(looks.iter().flatten().all(|&v| v < 4));
        let dealt: Vec<_> = looks.iter().flatten().collect();
        assert!(dealt.windows(2).all(|w| w[0] != w[1]));
        let seen: std::collections::BTreeSet<_> = dealt.into_iter().collect();
        assert_eq!(seen.len(), 4, "every look is used");
    }

    #[test]
    fn shuffle_with_no_looks_clears_them() {
        let with = set_variant(&transcript(), 1, Some(2)).unwrap();
        assert!(
            shuffle_variants(&with, 0, 3)
                .words()
                .all(|w| w.variant.is_none())
        );
    }

    #[test]
    fn a_look_survives_renaming_and_retiming_its_word() {
        let t = set_variant(&transcript(), 1, Some(3)).unwrap();
        let renamed = set_word(&t, 1, "deux").unwrap();
        assert_eq!(renamed.words().nth(1).unwrap().variant, Some(3));
        let moved = retime(&t, 1, Edge::End, 1.1, 0);
        assert_eq!(moved.words().nth(1).unwrap().variant, Some(3));
        let other = set_word(&t, 0, "uno").unwrap();
        assert_eq!(
            other.words().nth(1).unwrap().variant,
            Some(3),
            "a neighbour's edit"
        );
    }
}
