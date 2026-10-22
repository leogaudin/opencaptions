use super::*;

fn book() -> FontBook<'static> {
    let mut b = FontBook::new();
    for font in [
        // A subset of Anton that draws only "helo": a face missing most glyphs.
        &include_bytes!("../../testdata/anton-subset.ttf")[..],
        include_bytes!("../../fonts/Inter.ttf"),
    ] {
        b.add(font).unwrap();
    }
    b
}

fn input(animation: &str, words: &[(&str, f32, f32)], words_per_line: u32) -> SceneInput {
    let words: Vec<_> = words.iter().map(|(t, s, e)| json_word(t, *s, *e)).collect();
    serde_json::from_value(serde_json::json!({
        "width": 1080, "height": 1920,
        "transcript": { "duration": 10.0, "segments": [{ "words": words }] },
        "style": {
            "font": "Inter", "font_size": 64, "text_color": "#FFFFFF",
            "highlight_colors": ["#7C3AED"], "background": "none",
            "background_color": "#000000", "background_opacity": 0.0,
            "position_x": 0.5, "position_y": 0.84, "animation": animation,
            "words_per_line": words_per_line, "word_spacing": 0,
            "stroke_width": 2, "stroke_color": "#000000",
            "shadow_blur": 8, "shadow_color": "#00000080"
        }
    }))
    .unwrap()
}

/// Every animation's name, as the style names it.
fn animation_names() -> Vec<String> {
    Animation::ALL
        .into_iter()
        .map(|a| {
            serde_json::to_value(a)
                .unwrap()
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect()
}

fn json_word(t: &str, s: f32, e: f32) -> serde_json::Value {
    serde_json::json!({ "text": t, "start": s, "end": e })
}

const WORDS: &[(&str, f32, f32)] = &[
    ("one", 0.0, 0.5),
    ("two", 0.5, 1.0),
    ("three", 1.0, 1.5),
    ("four", 3.0, 3.5),
];

#[test]
fn colours_parse_with_and_without_alpha() {
    assert_eq!(Rgba::parse("#7C3AED"), Some(Rgba([0x7C, 0x3A, 0xED, 255])));
    assert_eq!(Rgba::parse("#00000080"), Some(Rgba([0, 0, 0, 0x80])));
    assert_eq!(Rgba::parse("7C3AED"), None);
    assert_eq!(Rgba::parse("#7C3AE"), None);
}

#[test]
fn fonts_register_under_their_own_family_and_fall_back() {
    let b = book();
    assert_eq!(b.families(), ["Anton", "Inter"]);
    assert_eq!(b.primary("anton"), 0);
    assert_eq!(
        b.primary("No Such Face"),
        1,
        "falls back to the default face"
    );
    // The Anton subset cannot draw Cyrillic and Inter can, so the word moves to Inter.
    assert_eq!(b.for_text(0, &[], "hello"), 0);
    assert_eq!(b.for_text(0, &[], "привет"), 1);
}

#[test]
fn a_requested_font_is_found_by_name_but_never_a_fallback() {
    let mut b = book();
    let lobster = include_bytes!("../../fonts/Inter.ttf");
    assert!(b.add_requested("Lobster", lobster));
    assert_eq!(b.primary("lobster"), 2);
    assert_eq!(b.families(), ["Anton", "Inter"]);
    assert_eq!(
        b.for_text(0, &[], "привет"),
        1,
        "falls back to bundled Inter, not the request"
    );
    let mut first = book();
    first.add_requested("Inter", lobster);
    assert_eq!(
        first.primary("Inter"),
        1,
        "a bundled family wins over a request"
    );
}

#[test]
fn the_highlight_box_springs_in_past_full_size_then_settles() {
    let scene = Scene::new(&book(), input("highlight_box", WORDS, 3));
    let w = &scene.lines[0].words[1];
    let at = |t: f32| word_state(Animation::HighlightBox, w, t).box_scale;
    assert!(at(0.49) < 0.7, "starts small");
    assert!(
        (0..30)
            .map(|i| at(0.5 + i as f32 * 0.01))
            .fold(0.0, f32::max)
            > 1.02,
        "overshoots"
    );
    assert!((at(0.9) - 1.0).abs() < 1e-3, "settles at full size");
}

/// `input` with some style fields changed.
fn styled(animation: &str, words: &[(&str, f32, f32)], patch: serde_json::Value) -> SceneInput {
    let base = input(animation, words, 3);
    let mut style = serde_json::to_value(serde_json::json!({
        "font": "Inter", "font_size": 64, "text_color": "#FFFFFF",
        "highlight_colors": ["#FF0000"], "background": "none",
        "background_color": "#000000", "background_opacity": 0.0,
        "position_x": 0.5, "position_y": 0.5, "animation": animation,
        "words_per_line": 3, "stroke_width": 0, "stroke_color": "#000000",
        "shadow_blur": 0, "shadow_color": "#00000000"
    }))
    .unwrap();
    for (k, v) in patch.as_object().unwrap() {
        style[k] = v.clone();
    }
    let mut value = serde_json::json!({
        "width": base.width, "height": base.height,
        "transcript": serde_json::to_value(&base.transcript).unwrap_or_default(),
    });
    value["style"] = style;
    serde_json::from_value(value).unwrap()
}

/// The columns and rows with any ink in a frame: (left, right, top, bottom).
fn extent(renderer: &Renderer, width: usize) -> Option<(usize, usize, usize, usize)> {
    let rgba = renderer.rgba();
    let mut found: Option<(usize, usize, usize, usize)> = None;
    for (i, px) in rgba.chunks(4).enumerate() {
        if px[3] > 0 {
            let (x, y) = (i % width, i / width);
            found = Some(match found {
                None => (x, x, y, y),
                Some((l, r, t, b)) => (l.min(x), r.max(x), t.min(y), b.max(y)),
            });
        }
    }
    found
}

fn drawn(patch: serde_json::Value, at: f32) -> Option<(usize, usize, usize, usize)> {
    let scene = Scene::new(
        &book(),
        styled("word_highlight", &[("hello", 0.0, 1.0)], patch),
    );
    let mut renderer = Renderer::new(scene);
    renderer.render(at);
    extent(&renderer, 1080)
}

#[test]
fn a_sweep_fills_the_word_as_it_is_said_and_keeps_it() {
    let scene = Scene::new(&book(), input("word_sweep", WORDS, 3));
    let w = &scene.lines[0].words[1];
    let at = |t: f32| word_state(Animation::WordSweep, w, t).fill;
    assert_eq!(at(0.4), 0.0, "not said yet");
    assert!((at(0.75) - 0.5).abs() < 0.01, "half way through the word");
    assert_eq!(at(1.4), 1.0, "and it stays filled after");
    let underline = Scene::new(&book(), input("word_underline", WORDS, 3));
    let w = &underline.lines[0].words[1];
    assert!((word_state(Animation::WordUnderline, w, 0.75).fill - 0.5).abs() < 0.01);
}

#[test]
fn typed_words_appear_a_letter_at_a_time_and_none_before_they_start() {
    let scene = Scene::new(&book(), input("typewriter", &[("three", 1.0, 1.5)], 3));
    let w = &scene.lines[0].words[0];
    let at = |t: f32| word_state(Animation::Typewriter, w, t).fill;
    assert_eq!(at(0.9), 0.0);
    let steps: Vec<f32> = (0..40).map(|i| at(1.0 + i as f32 * 0.01)).collect();
    assert!(
        steps
            .iter()
            .all(|f| (f * 5.0 - (f * 5.0).round()).abs() < 1e-4),
        "whole letters"
    );
    assert_eq!(at(1.5), 1.0, "all of it once typed");
    assert!(steps.windows(2).all(|p| p[0] <= p[1]), "never untyped");
}

#[test]
fn upper_case_is_drawn_not_stored() {
    let word = [("hello", 0.0, 1.0)];
    let lower = Scene::new(
        &book(),
        styled("word_highlight", &word, serde_json::json!({})),
    );
    let upper = Scene::new(
        &book(),
        styled(
            "word_highlight",
            &word,
            serde_json::json!({ "text_case": "upper" }),
        ),
    );
    assert!(upper.lines[0].words[0].slot.width() > lower.lines[0].words[0].slot.width());
}

#[test]
fn outlines_and_shadows_keep_their_weight_as_the_letters_grow() {
    let effects = |font_size: u32| {
        let patch = serde_json::json!({
            "font_size": font_size, "stroke_width": 10, "shadow_blur": 4,
            "shadow_offset_x": 8, "shadow_offset_y": 10, "glow_blur": 20
        });
        let s = scaled(
            &styled("word_highlight", &[("a", 0.0, 1.0)], patch).style,
            1.0,
        );
        // Each relative to the letters, so what a viewer sees as weight.
        [
            s.stroke_width,
            s.shadow_blur,
            s.shadow_offset_x,
            s.shadow_offset_y,
            s.glow_blur,
        ]
        .map(|v| v / s.font_size)
    };
    let at_100 = effects(100);
    for (big, small) in effects(200).into_iter().zip(at_100) {
        assert!((big - small).abs() < 1e-4, "{big} against {small}");
    }
    let at_300 = effects(300);
    assert!(at_300.iter().zip(at_100).all(|(a, b)| (a - b).abs() < 1e-4));
    // Smaller letters are left as they were set, so no saved look changes.
    let small = scaled(
        &styled(
            "word_highlight",
            &[("a", 0.0, 1.0)],
            serde_json::json!({ "font_size": 50, "stroke_width": 10 }),
        )
        .style,
        1.0,
    );
    assert_eq!(small.stroke_width, 10.0);
}

#[test]
fn a_hard_shadow_is_the_letters_carried_to_the_offset() {
    let plain = drawn(serde_json::json!({}), 0.5).unwrap();
    let solid = serde_json::json!({
        "shadow_offset_x": 20, "shadow_offset_y": 20, "shadow_blur": 0,
        "shadow_color": "#000000FF"
    });
    let shadowed = drawn(solid, 0.5).unwrap();
    assert!(shadowed.1 >= plain.1 + 8, "reaches right of the letters");
    assert!(shadowed.3 >= plain.3 + 8, "and below them");
}

#[test]
fn a_glow_reaches_around_the_letters() {
    let plain = drawn(serde_json::json!({}), 0.5).unwrap();
    let glow = serde_json::json!({ "glow_blur": 30, "glow_color": "#00FFFFFF" });
    let lit = drawn(glow, 0.5).unwrap();
    assert!(
        lit.0 + 8 <= plain.0 && lit.1 >= plain.1 + 8,
        "a halo past the letters"
    );
}

#[test]
fn an_italic_leans_over_the_right_edge() {
    let upright = drawn(serde_json::json!({}), 0.5).unwrap();
    let leaning = drawn(serde_json::json!({ "italic": true }), 0.5).unwrap();
    assert!(
        leaning.1 > upright.1,
        "the top of the last letter leans out"
    );
    assert_eq!(
        (leaning.2, leaning.3),
        (upright.2, upright.3),
        "the same height"
    );
}

#[test]
fn a_word_with_a_space_in_it_is_drawn_as_one_wider_word() {
    let book = book();
    let one = Scene::new(&book, input("word_highlight", &[("hello", 0.0, 0.5)], 3));
    let spaced = Scene::new(
        &book,
        input("word_highlight", &[("hello world", 0.0, 0.5)], 3),
    );
    assert_eq!(spaced.lines[0].words.len(), 1, "one word, not two");
    assert!(spaced.lines[0].words[0].slot.width() > one.lines[0].words[0].slot.width() * 1.5);
    let mut renderer = Renderer::new(spaced);
    assert!(renderer.render(0.2), "it draws");
    assert!(renderer.rgba().iter().any(|b| *b != 0));
}

#[test]
fn lines_follow_speech_hold_briefly_and_clear_in_long_gaps() {
    let scene = Scene::new(&book(), input("word_highlight", WORDS, 3));
    assert_eq!(scene.lines.len(), 2);
    assert_eq!(scene.active_line(0.2), Some(0));
    assert_eq!(scene.active_line(1.52), Some(0), "held past the last word");
    assert_eq!(scene.active_line(1.7), Some(0), "short gap keeps the line");
    assert_eq!(scene.active_line(2.5), None, "long gap clears");
    assert_eq!(scene.active_line(3.2), Some(1));
}

#[test]
fn the_caption_offset_moves_every_line_and_clamps_at_the_start() {
    let at = |offset_ms: i32| {
        let mut i = input("word_highlight", WORDS, 3);
        i.caption_offset_ms = offset_ms;
        Scene::new(&book(), i)
    };
    let later = at(500);
    assert_eq!(later.active_line(0.2), None, "first line not yet showing");
    assert_eq!(later.active_line(0.7), Some(0));
    assert_eq!(later.active_line(3.7), Some(1));
    let earlier = at(-2000);
    assert_eq!(
        earlier.lines[0].start, 0.0,
        "clamped at the start, never negative"
    );
    assert_eq!(earlier.active_line(1.2), Some(1), "line two is at 1.0");
    let none = at(0);
    assert_eq!(
        (none.lines[0].start, none.lines[1].start),
        (0.0, 3.0),
        "zero changes nothing"
    );
}

#[test]
fn long_lines_wrap_inside_the_frame() {
    let long: Vec<_> = (0..10)
        .map(|i| ("extraordinarily", i as f32, i as f32 + 1.0))
        .collect();
    let scene = Scene::new(&book(), input("word_highlight", &long, 10));
    let line = &scene.lines[0];
    let rows: std::collections::BTreeSet<_> =
        line.words.iter().map(|w| w.slot.y() as i32).collect();
    assert!(rows.len() > 1, "wrapped onto several rows");
    assert!(
        line.words
            .iter()
            .all(|w| w.slot.left() >= 0.0 && w.slot.right() <= 1080.0)
    );
}

#[test]
fn highlight_box_reserves_its_padding_so_words_never_touch() {
    let scene = Scene::new(&book(), input("highlight_box", WORDS, 3));
    let w = &scene.lines[0].words;
    assert!(w[0].slot.right() < w[1].slot.left());
}

#[test]
fn the_active_word_changes_the_frame_and_steady_frames_are_reused() {
    let mut r = Renderer::new(Scene::new(&book(), input("highlight_box", WORDS, 3)));
    assert!(r.render(0.3));
    let first = r.rgba().to_vec();
    assert!(first.iter().any(|&b| b != 0), "something was drawn");
    assert!(!r.render(0.31), "nothing animates mid-word");
    assert!(r.render(0.75));
    assert_ne!(first, r.rgba(), "the box moved to the next word");
    assert!(r.render(2.5));
    assert!(
        r.rgba().iter().all(|&b| b == 0),
        "a cleared frame is fully transparent"
    );
}

fn drifting(words: &[(&str, f32, f32)], patch: serde_json::Value) -> Renderer {
    let mut patch = patch;
    if patch.get("font_size").is_none() {
        patch["font_size"] = 200.into();
    }
    Renderer::new(Scene::new(&book(), styled("drift", words, patch)))
}

#[test]
fn a_drifting_word_is_soft_and_unseen_before_it_is_said_then_sharp_and_whole() {
    let scene = Scene::new(&book(), styled("drift", WORDS, serde_json::json!({})));
    // The second word starts at 0.5.
    let before = &scene.key(0.2).1[1];
    assert_eq!(
        (before.opacity, before.soften > 0.0),
        (0.0, true),
        "not there yet"
    );
    let coming = &scene.key(0.5 - LEAD_S + DRIFT_IN_S / 2.0).1[1];
    assert!(
        coming.opacity > 0.3 && coming.opacity < 0.7,
        "{}",
        coming.opacity
    );
    assert!(coming.soften > 0.0, "and still out of focus");
    let said = &scene.key(0.5 - LEAD_S + DRIFT_IN_S + 0.01).1[1];
    assert_eq!((said.opacity, said.soften), (1.0, 0.0), "sharp and whole");
    // How blurred it starts is the setting: a share of the font size.
    let sigma = before.soften * scene.style.font_size * FOCUS_BLUR;
    assert!((sigma - DRIFT_SOFT * scene.style.font_size).abs() < 1e-3);
}

#[test]
fn a_drifting_line_pushes_in_over_its_life() {
    let r = drifting(&[("HELLO", 0.0, 4.0)], serde_json::json!({}));
    let mut r = r;
    let width = |r: &mut Renderer, t: f32| {
        r.render(t);
        let (l, rt, _, _) = extent(r, 1080).unwrap();
        (rt - l) as f32
    };
    let (early, late) = (width(&mut r, 0.5), width(&mut r, 3.9));
    assert!(late > early * 1.03, "{early} then {late}");
}

#[test]
fn a_drifting_line_floats_and_comes_back() {
    let scene = Scene::new(
        &book(),
        styled("drift", &[("HELLO", 0.0, 4.0)], serde_json::json!({})),
    );
    let line = &scene.lines[0];
    let down = |t: f32| scene.drift(line, t)[1];
    let amplitude = DRIFT_BOB * scene.style.font_size;
    assert!(down(0.0).abs() < 1e-4, "it starts at rest");
    assert!(
        (down(0.75) - amplitude).abs() < 1e-3,
        "down at a quarter of its period"
    );
    assert!(
        (down(2.25) + amplitude).abs() < 1e-3,
        "up at three quarters"
    );
    assert!(
        (down(0.4) - down(0.4 + DRIFT_PERIOD_S)).abs() < 1e-3,
        "and back after a period"
    );
    // And it is seen: the ink is lower a quarter of the way round than three quarters.
    let mut r = drifting(&[("HELLO", 0.0, 4.0)], serde_json::json!({}));
    let top = |r: &mut Renderer, t: f32| {
        r.render(t);
        extent(r, 1080).unwrap().2
    };
    let (low, high) = (top(&mut r, 0.75), top(&mut r, 2.25));
    assert!(low > high + 3, "{low} then {high}");
    // Other animations do not drift at all.
    let still = Scene::new(&book(), styled("word_pop", WORDS, serde_json::json!({})));
    assert_eq!(still.drift(&still.lines[0], 0.7), NO_DRIFT);
}

#[test]
fn a_drifting_word_glows_more_while_it_is_said_than_after() {
    let words = [
        ("HELLO", 0.0, 1.0),
        ("WORLD", 1.0, 2.0),
        ("AGAIN", 2.0, 3.0),
    ];
    let patch = serde_json::json!({
        "glow_blur": 28, "glow_color": "#99CCFF", "stroke_width": 0, "font_size": 200
    });
    let scene = Scene::new(&book(), styled("drift", &words, patch));
    // Every word in view; the first one drawn lit, then not, on otherwise equal frames.
    let key = scene.key(2.9);
    let halo = |on: f32| -> u64 {
        let mut states = key.1.clone();
        states[0].on = on;
        let mut canvas = Pixmap::new(1080, 1920).unwrap();
        scene.draw(
            &mut canvas,
            (0, &scene.lines[0]),
            &states,
            None,
            key.3,
            &mut LayerCache::default(),
        );
        let slot = scene.lines[0].words[0].slot;
        let (x0, x1) = (
            (slot.x() - 80.0).max(0.0) as usize,
            (slot.right() + 80.0) as usize,
        );
        let (y0, y1) = (
            (slot.y() - 80.0).max(0.0) as usize,
            (slot.bottom() + 80.0) as usize,
        );
        (y0..y1)
            .flat_map(|y| (x0..x1).map(move |x| (y * 1080 + x) * 4 + 3))
            .map(|i| u64::from(canvas.data()[i]))
            .sum()
    };
    let (said, after) = (halo(1.0), halo(0.0));
    assert!(said as f64 > after as f64 * 1.05, "{said} then {after}");
}

#[test]
fn a_drifting_glow_stays_cheap() {
    let words = [
        ("HELLO", 0.0, 1.0),
        ("WORLD", 1.0, 2.0),
        ("AGAIN", 2.0, 3.0),
    ];
    let patch = serde_json::json!({ "glow_blur": 20, "glow_color": "#99CCFF", "stroke_width": 0, "font_size": 90 });
    let mut r = drifting(&words, patch);
    let start = std::time::Instant::now();
    for i in 0..6 {
        r.render(1.0 + i as f32 / 30.0);
    }
    let took = start.elapsed();
    println!("6 drifting frames with a glow: {took:?}");
    // A loose ceiling in an unoptimised build; the release build is several times faster.
    assert!(took.as_secs_f32() < 40.0, "{took:?}");
}

fn lone(animation: &str, patch: serde_json::Value) -> Renderer {
    Renderer::new(Scene::new(
        &book(),
        styled(animation, &[("HELLO", 0.0, 1.0)], patch),
    ))
}

/// The mean colour of the solid pixels of rows `rows`.
fn mean_colour(r: &Renderer, rows: std::ops::Range<usize>) -> [f32; 3] {
    let (mut sum, mut n) = ([0.0f32; 3], 0.0f32);
    for y in rows {
        for px in r.rgba()[y * 1080 * 4..(y + 1) * 1080 * 4].chunks(4) {
            if px[3] == 255 {
                (0..3).for_each(|c| sum[c] += f32::from(px[c]));
                n += 1.0;
            }
        }
    }
    sum.map(|v| v / n.max(1.0))
}

#[test]
fn a_gradient_fill_runs_from_the_first_colour_at_the_top_to_the_last_at_the_baseline() {
    let patch = serde_json::json!({ "fill_colors": ["#FF0000", "#0000FF"], "font_size": 200 });
    let mut r = lone("none", patch);
    r.render(0.5);
    let (_, _, top, bottom) = extent(&r, 1080).unwrap();
    let fifth = (bottom - top) / 5;
    let up = mean_colour(&r, top..top + fifth);
    let down = mean_colour(&r, bottom - fifth..bottom);
    // The letters start below the em box's top, so the top of the ink is not quite the first colour.
    assert!(up[0] > up[2] + 50.0, "red at the top: {up:?}");
    assert!(down[2] > down[0] + 50.0, "blue at the bottom: {down:?}");
    let mut flat = lone("none", serde_json::json!({ "font_size": 200 }));
    flat.render(0.5);
    assert_ne!(flat.rgba(), r.rgba());
}

#[test]
fn an_extrusion_fades_from_its_colour_to_the_back_colour() {
    let patch = serde_json::json!({
        "shadow_color": "#FF0000", "extrude_back": "#0000FF", "shadow_offset_y": 60,
        "stroke_width": 0, "text_color": "#000000"
    });
    let mut r = lone("none", patch);
    r.render(0.5);
    let mut face = lone("none", serde_json::json!({ "text_color": "#000000" }));
    face.render(0.5);
    let flat = extent(&face, 1080).unwrap().3;
    let back = extent(&r, 1080).unwrap().3;
    let span = back - flat;
    let near = mean_colour(&r, flat + 4..flat + 4 + span / 3);
    let far = mean_colour(&r, back - span / 3..back);
    assert!(
        near[0] > far[0] + 60.0,
        "red near the face: {near:?} {far:?}"
    );
    assert!(
        far[2] > near[2] + 60.0,
        "blue at the back: {near:?} {far:?}"
    );
}

#[test]
fn an_extrusion_darkens_with_depth_only_when_shaded() {
    let still = |shade: f32| {
        let patch = serde_json::json!({
            "shadow_color": "#FFAA00", "shadow_offset_y": 60, "extrude_shade": shade,
            "text_color": "#000000"
        });
        let mut r = lone("none", patch);
        r.render(0.5);
        r
    };
    let flat_face = {
        let mut r = lone("none", serde_json::json!({ "text_color": "#000000" }));
        r.render(0.5);
        extent(&r, 1080).unwrap().3
    };
    for (shade, darkens) in [(0.0, false), (1.0, true)] {
        let r = still(shade);
        let back = extent(&r, 1080).unwrap().3;
        let span = back - flat_face;
        assert!(span > 20, "there is an extrusion to measure: {span}");
        let near = mean_colour(&r, flat_face + 4..flat_face + 4 + span / 3);
        let far = mean_colour(&r, back - span / 3..back);
        assert_eq!(
            near[0] > far[0] + 30.0,
            darkens,
            "shade {shade}: {near:?} then {far:?}"
        );
    }
}

#[test]
fn a_pressed_word_lifts_its_face_off_a_back_that_stays_put() {
    let patch = serde_json::json!({
        "shadow_color": "#C2410C", "shadow_offset_y": 60, "stroke_width": 0
    });
    let mut pressed = lone("word_press", patch.clone());
    // The same word with no extrusion: the face where the back is.
    let mut flat = lone(
        "word_highlight",
        serde_json::json!({ "shadow_offset_y": 0, "stroke_width": 0 }),
    );
    pressed.render(0.5);
    flat.render(0.5);
    let (a, b) = (
        extent(&pressed, 1080).unwrap(),
        extent(&flat, 1080).unwrap(),
    );
    let travel = 60.0 * 1920.0 / REF_HEIGHT;
    assert!(
        a.3.abs_diff(b.3) <= 3,
        "the back stays where the flat word was: {a:?} {b:?}"
    );
    assert!(
        ((b.2 as f32 - a.2 as f32) - travel).abs() < 4.0,
        "the face lifted by the offset: {} rows, not {travel}",
        b.2 as f32 - a.2 as f32
    );
}

fn rising(words: &[(&str, f32, f32)]) -> Renderer {
    let patch = serde_json::json!({ "font_size": 120 });
    Renderer::new(Scene::new(&book(), styled("letter_rise", words, patch)))
}

/// The first row with ink in the columns `from..to` of the current frame.
fn top_of(r: &Renderer, from: usize, to: usize) -> Option<usize> {
    (0..1920).find(|&y| (from..to).any(|x| r.rgba()[(y * 1080 + x) * 4 + 3] > 0))
}

#[test]
fn the_letters_of_a_word_rise_one_after_another() {
    let mut r = rising(&[("HELLO", 0.0, 1.0)]);
    // Partway through the entrance, the first letters are up and the last are still low.
    r.render(0.06);
    let scene = r.scene();
    let word = &scene.lines[0].words[0];
    assert_eq!(word.clusters.len(), 5, "one outline a letter");
    let cols: Vec<(usize, usize)> = word
        .clusters
        .iter()
        .map(|c| (c.bounds().left() as usize, c.bounds().right() as usize))
        .collect();
    let tops: Vec<Option<usize>> = cols.iter().map(|&(a, b)| top_of(&r, a, b)).collect();
    let first = tops[0].expect("the first letter has started");
    assert!(
        tops[4].is_none_or(|last| last > first),
        "the last letter is lower than the first, or not there yet: {tops:?}"
    );
    assert!(
        tops.iter()
            .flatten()
            .collect::<std::collections::HashSet<_>>()
            .len()
            > 1
            || tops.iter().any(Option::is_none),
        "the letters are at different heights: {tops:?}"
    );
    // And in the end they are all in place, as the plain word.
    r.render(0.9);
    let rest = r.rgba().to_vec();
    let mut plain = rising(&[("HELLO", 0.0, 1.0)]);
    plain.render(0.9);
    assert_eq!(rest, plain.rgba());
    assert!(rest.iter().any(|&b| b != 0));
}

#[test]
fn nothing_of_a_word_is_drawn_before_it_starts() {
    let mut r = rising(&[("one", 0.0, 0.5), ("two", 0.5, 1.0)]);
    r.render(0.3);
    let rects = r.active_word_rects();
    let (x, y, w, h) = rects[1];
    let any = (y as usize..(y + h) as usize).any(|row| {
        (x as usize..(x + w) as usize).any(|col| r.rgba()[(row * 1080 + col) * 4 + 3] > 0)
    });
    assert!(!any, "the second word is not there yet");
    r.render(0.9);
    let any = (y as usize..(y + h) as usize).any(|row| {
        (x as usize..(x + w) as usize).any(|col| r.rgba()[(row * 1080 + col) * 4 + 3] > 0)
    });
    assert!(any, "and then it is");
}

#[test]
fn a_word_of_a_connected_script_is_one_piece() {
    let mut b = book();
    for font in [
        &include_bytes!("../../fonts/NotoSansArabic.ttf")[..],
        include_bytes!("../../fonts/NotoSansDevanagari.ttf"),
        include_bytes!("../../fonts/NotoSansThai.ttf"),
    ] {
        b.add(font).unwrap();
    }
    let pieces = |family: &str, text: &str| {
        cluster_paths(b.face(b.primary(family)), text, 64.0, Tracking::NONE).len()
    };
    assert_eq!(pieces("Inter", "HELLO"), 5);
    assert_eq!(pieces("Noto Sans Arabic", "مرحبا"), 1);
    assert_eq!(pieces("Noto Sans Devanagari", "नमस्ते"), 1);
    assert_eq!(pieces("Noto Sans Thai", "สวัสดี"), 1);
}

const FIGURES: &[(&str, f32, f32)] = &[
    ("we", 0.0, 0.4),
    ("grew", 0.4, 0.8),
    ("40", 0.8, 1.2),
    ("percent", 1.2, 1.6),
];

#[test]
fn a_slammed_lines_shadow_follows_its_jolt() {
    // The extrusion and the glow are kept between frames; the line's knock moves them, so a frame
    // drawn after others must be the one drawn fresh, all through the knock.
    let patch = serde_json::json!({
        "font_size": 100, "shadow_color": "#C2410C", "shadow_offset_y": 12,
        "glow_blur": 10
    });
    let input = styled("word_slam", WORDS, patch);
    let landing = 0.5 - LEAD_S + SLAM_S;
    let mut kept = Renderer::new(Scene::new(&book(), input.clone()));
    for i in 0..8 {
        let t = landing + i as f32 * JOLT_S / 8.0;
        kept.render(t);
        let mut fresh = Renderer::new(Scene::new(&book(), input.clone()));
        fresh.render(t);
        assert!(
            kept.rgba() == fresh.rgba(),
            "the frame at {t} s differs from a fresh one"
        );
    }
}

fn slamming() -> Scene {
    let patch = serde_json::json!({ "font_size": 100 });
    Scene::new(&book(), styled("word_slam", WORDS, patch))
}

#[test]
fn a_slammed_word_starts_large_and_invisible_and_lands_at_rest() {
    let scene = slamming();
    // The second word starts at 0.5: before that it is not there at all.
    let before = &scene.key(0.2).1[1];
    assert_eq!(before.opacity, 0.0, "hidden until said");
    let start = &scene.key(0.5 - LEAD_S + 0.01).1[1];
    assert!(
        start.scale > 1.5,
        "it drops in from well over its size: {}",
        start.scale
    );
    assert!(start.opacity > 0.0 && start.opacity < 1.0);
    let landed = &scene.key(0.5 - LEAD_S + SLAM_S + 0.01).1[1];
    assert_eq!((landed.scale, landed.opacity), (1.0, 1.0));
    // With no overshoot: it never goes under its resting size on the way.
    for step in 0..=24 {
        let t = 0.48 + step as f32 * 0.005;
        assert!(scene.key(t).1[1].scale >= 1.0, "t = {t}");
    }
}

#[test]
fn the_line_jolts_when_a_word_lands_and_is_still_again_after() {
    let scene = slamming();
    let line = &scene.lines[0];
    let landing = 0.5 - LEAD_S + SLAM_S;
    let at = |dt: f32| scene.jolt(line, landing + dt);
    assert_eq!(at(-0.05), scene.jolt(line, 0.3), "nothing new has landed");
    let hit = at(0.01);
    let size = scene.style.font_size;
    assert!(
        hit[1] > 0.0 && hit[1] < 0.05 * size,
        "a small knock, down: {hit:?}"
    );
    assert_eq!(hit[0], 0.0, "never sideways: that reads as a tremble");
    let later = at(0.07);
    assert!(
        later[1] < hit[1] && later[1] >= 0.0,
        "it dies away, without crossing rest"
    );
    assert_eq!(at(JOLT_S + 0.001), [0.0, 0.0]);
    // The jolt is in the frame's identity, so the frame is drawn again as it moves.
    assert!(scene.key(landing + 0.01) != scene.key(landing + 0.02));
}

const POSTER: &[(&str, f32, f32)] = &[
    ("MAKE", 0.0, 0.4),
    ("IT", 0.4, 0.8),
    ("BIG", 0.8, 1.2),
    ("AND", 1.2, 1.6),
    ("BOLD", 1.6, 2.0),
];

fn stacked(animation: &str, words: &[(&str, f32, f32)], patch: serde_json::Value) -> Scene {
    let mut patch = patch;
    patch["align"] = "justify".into();
    patch["words_per_line"] = 5.into();
    Scene::new(&book(), styled(animation, words, patch))
}

/// The rows of a line as lists of the words on them, top to bottom.
fn rows_of(scene: &Scene) -> Vec<Vec<&Placed>> {
    let mut rows: Vec<Vec<&Placed>> = vec![];
    for w in &scene.lines[0].words {
        match rows.last_mut() {
            Some(row) if row[0].slot.y() == w.slot.y() => row.push(w),
            _ => rows.push(vec![w]),
        }
    }
    rows
}

#[test]
fn in_a_stack_every_row_is_as_wide_as_the_widest() {
    let scene = stacked("none", POSTER, serde_json::json!({}));
    let rows = rows_of(&scene);
    assert!(rows.len() >= 2, "the words are cut into several rows");
    let width = |row: &Vec<&Placed>| {
        let (first, last) = (row[0], row[row.len() - 1]);
        last.ink_x + last.ink_w - first.ink_x
    };
    let widest = rows.iter().map(width).fold(0.0, f32::max);
    // The row that was widest is as it was; the others are scaled up to it.
    for row in &rows {
        assert!(
            (width(row) - widest).abs() < 2.0 || row[0].size >= 3.0,
            "{} against {widest}",
            width(row)
        );
    }
    assert!(
        rows.iter().any(|r| r[0].size > 1.1),
        "a narrower row is scaled up: {:?}",
        rows.iter()
            .map(|r| (r.len(), r[0].size))
            .collect::<Vec<_>>()
    );
    // Stacked tight: a row begins about where the one above ends.
    let ys: Vec<f32> = rows.iter().map(|r| r[0].slot.y()).collect();
    assert!(ys.windows(2).all(|p| p[1] > p[0]));
}

#[test]
fn a_stack_scales_a_short_row_by_three_at_most() {
    let words = [("I", 0.0, 0.4), ("EXTRAORDINARILY", 0.4, 1.0)];
    let scene = stacked("none", &words, serde_json::json!({}));
    let rows = rows_of(&scene);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0][0].size, 3.0, "the cap holds");
    assert_eq!(rows[1][0].size, 1.0, "the widest row is as it is");
    assert!(scene.lines[0].words.iter().all(|w| w.size <= 3.0));
}

#[test]
fn every_animation_draws_inside_the_lines_bounds_in_a_stack() {
    for anim in animation_names() {
        let patch = serde_json::json!({
            "stroke_width": 4, "stroke_color": "#000000",
            "shadow_blur": 6, "shadow_color": "#000000B0"
        });
        let scene = stacked(&anim, POSTER, patch);
        let bounds = scene.lines[0].bounds;
        let mut r = Renderer::new(scene);
        for t in [0.1, 0.45, 0.9, 1.3, 1.9] {
            r.render(t);
            let Some((l, rt, tp, bt)) = extent(&r, 1080) else {
                continue;
            };
            assert!(
                l as i32 >= bounds.x()
                    && rt as i32 <= bounds.right()
                    && tp as i32 >= bounds.y()
                    && bt as i32 <= bounds.bottom(),
                "{anim} at {t}: ink {:?} outside {:?}",
                (l, rt, tp, bt),
                bounds
            );
        }
        r.render(0.9);
        assert!(extent(&r, 1080).is_some(), "{anim} drew nothing");
    }
}

#[test]
fn the_active_caption_bounds_track_the_rendered_line() {
    let mut r = Renderer::new(Scene::new(&book(), input("word_highlight", WORDS, 3)));
    assert_eq!(r.active_bounds(), None, "nothing rendered yet");
    r.render(0.3);
    let (x, y, w, h) = r.active_bounds().expect("a line shows at 0.3s");
    assert!(w > 0.0 && h > 0.0);
    assert!(
        x >= 0.0 && y >= 0.0 && x + w <= 1080.0 && y + h <= 1920.0,
        "stays in frame"
    );
    r.render(2.5); // a long gap: no caption
    assert_eq!(r.active_bounds(), None);
}

#[test]
fn active_words_are_reported_in_line_order_and_in_frame() {
    let mut r = Renderer::new(Scene::new(&book(), input("word_highlight", WORDS, 3)));
    r.render(0.3);
    assert_eq!(r.active_index(), Some(0));
    let rects = r.active_word_rects();
    assert_eq!(rects.len(), 3, "one, two, three");
    // Left to right, non-overlapping, inside the frame.
    for pair in rects.windows(2) {
        assert!(pair[0].0 < pair[1].0);
    }
    assert!(
        rects
            .iter()
            .all(|(x, _, w, _)| *x >= 0.0 && x + w <= 1080.0)
    );
}

#[test]
fn a_long_pause_ends_a_caption_instead_of_joining_words_minutes_apart() {
    let words = [
        ("one", 0.0, 0.5),
        ("two", 0.5, 1.0),
        ("three", 90.0, 90.5),
        ("four", 90.5, 91.0),
        ("five", 91.0, 91.5),
    ];
    let mut r = Renderer::new(Scene::new(&book(), input("word_highlight", &words, 3)));
    r.render(0.3);
    assert_eq!(r.active_first_word(), Some(0));
    assert_eq!(r.active_word_rects().len(), 2, "one two, not three");
    r.render(45.0);
    assert_eq!(
        r.active_index(),
        None,
        "nothing hangs on through the silence"
    );
    r.render(90.2);
    assert_eq!(r.active_index(), Some(1));
    assert_eq!(r.active_first_word(), Some(2), "word N of it is word 2 + N");
    assert_eq!(r.active_word_rects().len(), 3, "three four five");
}

#[test]
fn position_places_and_clamps_the_block() {
    let bounds = |x: f32, y: f32| {
        let mut i = input("word_highlight", WORDS, 3);
        i.style.position_x = x;
        i.style.position_y = y;
        let mut r = Renderer::new(Scene::new(&book(), i));
        r.render(0.3);
        r.active_bounds().unwrap()
    };
    let (lx, _, _, _) = bounds(0.0, 0.5);
    assert_eq!(lx, 0.0, "pinned to the left edge, not off-screen");
    let (cx, cy, cw, ch) = bounds(0.5, 0.5);
    assert!(
        (cx + cw / 2.0 - 540.0).abs() < 1.0 && (cy + ch / 2.0 - 960.0).abs() < 1.0,
        "centred"
    );
}

/// The first word's letters, as (width, font size) in the scene's pixels.
fn first_word_ink(patch: serde_json::Value) -> (f32, f32) {
    let scene = Scene::new(&book(), styled("none", WORDS, patch));
    (scene.lines[0].words[0].ink_w, scene.style.font_size)
}

#[test]
fn stretch_draws_the_letters_wider_and_spacing_opens_them() {
    let (plain, _) = first_word_ink(serde_json::json!({}));
    let (narrow, _) = first_word_ink(serde_json::json!({ "stretch": 0.5 }));
    assert!(
        (narrow / plain - 0.5).abs() < 1e-3,
        "half the width at half the stretch: {narrow} of {plain}"
    );
    let (open, size) = first_word_ink(serde_json::json!({ "letter_spacing": 0.1 }));
    let letters = WORDS[0].0.chars().count() as f32;
    assert!(
        (open - plain - 0.1 * size * (letters - 1.0)).abs() < 0.01,
        "a tenth of the size after every letter but the last: {open} from {plain}"
    );
    let (tight, _) = first_word_ink(serde_json::json!({ "letter_spacing": -0.05 }));
    assert!(tight < plain, "negative spacing tightens");
}

#[test]
fn left_and_right_hold_the_block_by_their_edge_whatever_the_words() {
    // Lines of different widths: the edge the rows are aligned to is where `position_x` says.
    for (align, x) in [("left", 0.1_f32), ("right", 0.9)] {
        let scene = Scene::new(
            &book(),
            styled(
                "none",
                WORDS,
                serde_json::json!({ "align": align, "position_x": x, "words_per_line": 2 }),
            ),
        );
        assert!(scene.lines.len() > 1);
        for line in &scene.lines {
            let edge = if align == "left" {
                line.anchor.left()
            } else {
                line.anchor.right()
            };
            assert!(
                (edge - x * 1080.0).abs() < 1.0,
                "{align}: a line's edge is at {edge}"
            );
        }
    }
}

#[test]
fn rows_start_at_the_left_edge_and_end_at_the_right_one() {
    let rows = |align: &str| {
        let scene = Scene::new(
            &book(),
            styled(
                "none",
                FIGURES,
                serde_json::json!({
                    "align": align, "words_per_line": 4, "font_size": 190, "position_x": 0.5
                }),
            ),
        );
        let line = &scene.lines[0];
        let mut firsts: Vec<(f32, f32)> = vec![];
        let mut top = f32::MIN;
        for w in &line.words {
            if w.slot.top() > top + 1.0 {
                top = w.slot.top();
                firsts.push((w.slot.left(), w.slot.right()));
            } else if let Some(last) = firsts.last_mut() {
                last.1 = w.slot.right();
            }
        }
        (line.anchor, firsts)
    };
    let (block, left) = rows("left");
    assert!(left.len() > 1, "the words need more than one row");
    assert!(
        left.iter().all(|r| (r.0 - block.left()).abs() < 1.0),
        "flush left"
    );
    let (block, right) = rows("right");
    assert!(
        right.iter().all(|r| (r.1 - block.right()).abs() < 1.0),
        "flush right"
    );
}

#[test]
fn a_block_wider_than_the_frame_spills_over_both_sides_not_one() {
    for x in [0.0, 0.5, 1.0] {
        let mut i = input("word_highlight", WORDS, 1);
        i.style.font_size = 900.0;
        i.style.position_x = x;
        let mut r = Renderer::new(Scene::new(&book(), i));
        r.render(0.3);
        let (bx, _, bw, _) = r.active_bounds().unwrap();
        assert!(bw > 1080.0, "the word is wider than the frame ({bw})");
        assert!(
            (bx + bw / 2.0 - 540.0).abs() < 1.0,
            "centred on the frame whatever position_x is ({x}): starts at {bx}"
        );
    }
}

#[test]
fn a_frame_reports_the_rows_it_changed_and_no_others_differ() {
    let mut r = Renderer::new(Scene::new(&book(), input("word_pop", WORDS, 3)));
    let row = (1080 * 4) as usize;
    assert!(r.render(0.3));
    assert_eq!(
        r.changed_rows(),
        (0, 1920),
        "a new scene's first frame is all new"
    );
    // A word popping in, the next one, then nothing showing: each time, the rows outside the
    // band are exactly as they were, so a viewer copying only the band shows the frame.
    for t in [0.52, 1.03, 100.0] {
        let before = r.rgba().to_vec();
        assert!(r.render(t), "{t} changes something");
        let (top, bottom) = r.changed_rows();
        assert!(top < bottom && bottom <= 1920);
        assert!(
            bottom - top < 1920 / 2,
            "a caption's band, not the frame: {top}..{bottom}"
        );
        let after = r.rgba();
        assert_eq!(before[..top as usize * row], after[..top as usize * row]);
        assert_eq!(
            before[bottom as usize * row..],
            after[bottom as usize * row..]
        );
    }
}

fn marked(animation: &str, x: f64, y: f64) -> SceneInput {
    let mut i = input(animation, WORDS, 3);
    i.style.position_x = x as f32;
    i.style.position_y = y as f32;
    i.watermark = Some("Made with OpenCaptions".into());
    i
}

fn inked(rgba: &[u8]) -> usize {
    rgba.as_chunks::<4>().0.iter().filter(|p| p[3] != 0).count()
}

#[test]
fn a_watermark_is_in_the_corner_of_every_frame_and_only_there() {
    let mut plain = Renderer::new(Scene::new(&book(), input("word_pop", WORDS, 3)));
    plain.render(100.0);
    assert_eq!(inked(plain.rgba()), 0, "nothing without one");

    let mut r = Renderer::new(Scene::new(&book(), marked("word_pop", 0.5, 0.84)));
    assert!(r.render(100.0), "the first frame is a frame");
    let rows = (1080 * 4) as usize;
    let first = r.rgba().to_vec();
    let ink = inked(&first);
    assert!(ink > 100, "a mark is drawn: {ink} pixels");
    // Top right quarter only.
    for (i, p) in first.as_chunks::<4>().0.iter().enumerate() {
        if p[3] != 0 {
            let (x, y) = (i % 1080, i / 1080);
            assert!(x > 540 && y < 480, "inked at {x},{y}");
        }
    }
    // A caption comes and goes elsewhere: the mark is left as it was.
    r.render(0.6);
    assert!(inked(r.rgba()) > ink, "caption and mark");
    r.render(100.0);
    assert_eq!(first, r.rgba(), "back to the mark alone, exactly");
    assert_eq!(rows, 1080 * 4);
}

#[test]
fn a_caption_over_the_watermark_does_not_erase_it_or_leave_it_doubled() {
    // The caption is at the top right, where the mark is.
    let mut r = Renderer::new(Scene::new(&book(), marked("word_pop", 0.8, 0.04)));
    r.render(100.0);
    let alone = r.rgba().to_vec();
    r.render(0.6);
    assert_ne!(alone, r.rgba(), "the caption is drawn");
    let mut fresh = Renderer::new(Scene::new(&book(), marked("word_pop", 0.8, 0.04)));
    fresh.render(0.6);
    assert_eq!(
        fresh.rgba(),
        r.rgba(),
        "the same frame however it was reached"
    );
    r.render(100.0);
    assert_eq!(alone, r.rgba(), "and the mark alone again, not thickened");
}

#[test]
fn the_watermarks_rectangle_is_reported_and_holds_all_its_ink() {
    let plain = Renderer::new(Scene::new(&book(), input("word_pop", WORDS, 3)));
    assert_eq!(plain.watermark_rect(), None);

    let mut r = Renderer::new(Scene::new(&book(), marked("word_pop", 0.5, 0.2)));
    r.render(100.0);
    let (x, y, w, h) = r.watermark_rect().expect("a rectangle");
    let (fw, fh) = (r.scene.width as usize, r.scene.height as usize);
    for (i, p) in r.rgba().as_chunks::<4>().0.iter().enumerate() {
        let (px, py) = ((i % fw) as f32, (i / fw) as f32);
        let inside = px >= x && px < x + w && py >= y && py < y + h;
        assert!(
            inside || p[3] == 0,
            "ink outside the rectangle at {px},{py}"
        );
    }
    assert!(x + w <= fw as f32 && y + h <= fh as f32);
}

#[test]
fn no_mark_in_a_frame_too_small_for_it() {
    let mut i = marked("word_pop", 0.5, 0.5);
    i.width = 40;
    i.height = 40;
    let mut r = Renderer::new(Scene::new(&book(), i));
    r.render(100.0);
    assert_eq!(inked(r.rgba()), 0);
}

fn book_with_scripts() -> FontBook<'static> {
    let mut b = book();
    for font in [
        &include_bytes!("../../fonts/NotoSansArabic.ttf")[..],
        include_bytes!("../../fonts/NotoSansHebrew.ttf"),
        include_bytes!("../../fonts/NotoSansDevanagari.ttf"),
        include_bytes!("../../fonts/NotoSansThai.ttf"),
    ] {
        b.add(font).unwrap();
    }
    b
}

fn word_xs(words: &[(&str, f32, f32)]) -> Vec<f32> {
    let mut r = Renderer::new(Scene::new(
        &book_with_scripts(),
        input("word_pop", words, 3),
    ));
    r.render(0.5);
    assert!(r.rgba().iter().any(|&b| b != 0), "something is drawn");
    r.active_word_rects().iter().map(|rect| rect.0).collect()
}

#[test]
fn right_to_left_lines_run_from_the_right_and_left_to_right_ones_do_not() {
    let latin = word_xs(&[("one", 0.0, 0.4), ("two", 0.4, 0.8), ("three", 0.8, 1.2)]);
    assert!(latin[0] < latin[1] && latin[1] < latin[2], "{latin:?}");
    let arabic = word_xs(&[("مرحبا", 0.0, 0.4), ("بكم", 0.4, 0.8), ("جميعا", 0.8, 1.2)]);
    assert!(arabic[0] > arabic[1] && arabic[1] > arabic[2], "{arabic:?}");
    let hebrew = word_xs(&[("שלום", 0.0, 0.4), ("לכולם", 0.4, 0.8), ("היום", 0.8, 1.2)]);
    assert!(hebrew[0] > hebrew[1] && hebrew[1] > hebrew[2], "{hebrew:?}");
}

#[test]
fn scripts_the_default_face_lacks_are_drawn_with_the_bundled_ones() {
    let book = book_with_scripts();
    let inter = book.primary("Inter");
    for text in ["مرحبا", "שלום", "नमस्ते", "สวัสดี"] {
        let face = book.for_text(inter, &[], text);
        assert_ne!(face, inter, "{text} needs another face");
        let ink = |t: &str| {
            let mut r = Renderer::new(Scene::new(
                &book,
                input("word_highlight", &[(t, 0.0, 1.0)], 3),
            ));
            r.render(0.5);
            r.rgba()
                .as_chunks::<4>()
                .0
                .iter()
                .filter(|p| p[3] != 0)
                .count()
        };
        assert!(ink(text) > 500, "{text} is drawn, not left out");
    }
}

#[test]
fn a_named_fallback_font_draws_what_the_style_font_lacks() {
    // Only what the scene names is tried before the bundled faces: here the Arabic face is
    // registered the way a fetched font is, not bundled.
    let arabic: &'static [u8] = include_bytes!("../../fonts/NotoSansArabic.ttf");
    let mut b = book();
    assert!(b.add_requested("Noto Sans Arabic", arabic));
    let named = b.find("Noto Sans Arabic").unwrap();
    let primary = b.primary("Anton");
    assert_eq!(
        b.for_text(primary, &[], "مرحبا"),
        primary,
        "nothing names it"
    );
    assert_eq!(b.for_text(primary, &[named], "مرحبا"), named);
    assert_eq!(
        b.for_text(primary, &[named], "helo"),
        primary,
        "the style's font still wins"
    );
    let frame = |fallbacks: &[&str]| {
        let mut i = input("word_highlight", &[("مرحبا", 0.0, 1.0)], 3);
        i.fallback_fonts = fallbacks.iter().map(|f| f.to_string()).collect();
        let mut r = Renderer::new(Scene::new(&b, i));
        r.render(0.5);
        r.rgba().to_vec()
    };
    assert_ne!(
        frame(&["Noto Sans Arabic"]),
        frame(&[]),
        "the named font is the one drawn with"
    );
}

#[test]
fn a_bounced_word_rises_past_its_size_and_leans_left_then_right() {
    let scene = Scene::new(&book(), input("word_bounce", WORDS, 3));
    let [one, two] = [&scene.lines[0].words[0], &scene.lines[0].words[1]];
    let (a, b) = (
        word_state(Animation::WordBounce, one, 0.25),
        word_state(Animation::WordBounce, two, 0.75),
    );
    assert!(a.scale > 1.1 && b.scale > 1.1, "both are larger while said");
    assert!(a.tilt < 0.0 && b.tilt > 0.0, "and lean opposite ways");
    assert_eq!(
        word_state(Animation::WordBounce, two, 0.0).tilt,
        0.0,
        "not before"
    );
}

#[test]
fn lyric_focus_is_soft_until_said_sharp_while_said_and_readable_after() {
    let scene = Scene::new(&book(), input("lyric_focus", WORDS, 3));
    let w = &scene.lines[0].words[1];
    let at = |t: f32| word_state(Animation::LyricFocus, w, t);
    let (before, now, after) = (at(0.2), at(0.75), at(1.4));
    assert_eq!((before.soften, before.opacity), (1.0, FOCUS_DIM));
    assert_eq!((now.soften, now.opacity), (0.0, 1.0));
    assert_eq!(now.scale, 1.0, "the word being said does not grow");
    assert_eq!(after.soften, 0.0, "a word that was said stays in focus");
    assert!(after.opacity > FOCUS_DIM && after.opacity < 1.0);
}

#[test]
fn the_box_slides_from_word_to_word_and_rests_on_the_one_being_said() {
    let scene = Scene::new(&book(), input("highlight_slide", WORDS, 3));
    let line = &scene.lines[0];
    assert!(
        scene.guide(line, 0.0 - 0.1).is_none(),
        "no box before the first word"
    );
    let on = |i: usize| line.words[i].slot.x();
    assert_eq!(scene.guide(line, 0.25).unwrap().rect[0], on(0));
    assert!((scene.guide(line, 0.9).unwrap().rect[0] - on(1)).abs() < 0.01);
    let mid = scene
        .guide(line, 0.5 - LEAD_S + SLIDE_S / 4.0)
        .unwrap()
        .rect[0];
    assert!(
        mid > on(0) && mid < on(1),
        "between the two while it travels"
    );
}

#[test]
fn the_line_bar_fills_as_the_line_is_spoken() {
    let scene = Scene::new(&book(), input("line_bar", WORDS, 3));
    let line = &scene.lines[0];
    let width = |t: f32| scene.guide(line, t).unwrap().rect[2];
    assert_eq!(width(0.0), 0.0);
    assert!(
        (width(0.75) - line.anchor.width() * 0.5).abs() < 1.0,
        "half way"
    );
    assert!(
        (width(1.5) - line.anchor.width()).abs() < 0.01,
        "and full at the end"
    );
    assert!(scene.guide(&scene.lines[0], 0.5).unwrap().rect[1] > line.anchor.bottom());
}

#[test]
fn a_filled_word_has_no_pale_fringe_of_the_plain_colour_under_it() {
    let patch = serde_json::json!({ "highlight_colors": ["#FF0000"], "font_size": 200 });
    let words = &[("hello", 0.0, 0.5)];
    let mut r = Renderer::new(Scene::new(&book(), styled("word_sweep", words, patch)));
    r.render(0.6);
    let inked: Vec<&[u8]> = r.rgba().chunks(4).filter(|px| px[3] > 0).collect();
    assert!(inked.len() > 1000, "the word is drawn");
    // The plain colour is white: any of it left at the edge shows as green and blue.
    assert!(
        inked.iter().all(|px| px[1] < 10 && px[2] < 10),
        "an edge pixel is not pure highlight"
    );
}

#[test]
fn highlight_colours_are_taken_in_turn_and_the_first_is_the_primary() {
    let mut style = input("word_pop", WORDS, 3).style;
    let (red, green, blue) = (
        Rgba([255, 0, 0, 255]),
        Rgba([0, 255, 0, 255]),
        Rgba([0, 0, 255, 255]),
    );
    style.highlight_colors = vec![red, green, blue];
    assert_eq!(style.primary(), red);
    assert_eq!(
        [0, 1, 2, 3, 4].map(|i| style.highlight(i)),
        [red, green, blue, red, green]
    );
    style.highlight_colors = vec![];
    assert_eq!(
        style.primary(),
        Rgba([255, 255, 255, 255]),
        "none: white, and no panic"
    );
    assert_eq!(style.highlight(7), style.primary());
}

/// How many pixels of the frame at `t` are close to `rgb` (a lit word's colour).
fn pixels_near(renderer: &mut Renderer, t: f32, rgb: [u8; 3]) -> usize {
    renderer.render(t);
    let near = |a: u8, b: u8| a.abs_diff(b) < 40;
    renderer
        .rgba()
        .chunks(4)
        .filter(|px| px[3] == 255 && (0..3).all(|c| near(px[c], rgb[c])))
        .count()
}

#[test]
fn each_word_is_lit_in_the_next_colour_and_a_single_shape_keeps_the_primary() {
    let words = &[("aaa", 0.0, 0.5), ("bbb", 0.5, 1.0)];
    let patch = serde_json::json!({
        "highlight_colors": ["#FF0000", "#00FF00"], "font_size": 200, "text_color": "#0000FF"
    });
    let mut pop = Renderer::new(Scene::new(
        &book(),
        styled("word_pop", words, patch.clone()),
    ));
    assert!(
        pixels_near(&mut pop, 0.25, [255, 0, 0]) > 500,
        "the first word is lit red"
    );
    assert!(
        pixels_near(&mut pop, 0.75, [0, 255, 0]) > 500,
        "the second is lit green"
    );
    assert_eq!(
        pixels_near(&mut pop, 0.25, [0, 255, 0]),
        0,
        "and not green too"
    );
    // One box slides between the words: it is the primary on both.
    let mut slide = Renderer::new(Scene::new(&book(), styled("highlight_slide", words, patch)));
    assert!(pixels_near(&mut slide, 0.25, [255, 0, 0]) > 500);
    assert!(
        pixels_near(&mut slide, 0.9, [255, 0, 0]) > 500,
        "still red on the second word"
    );
    assert_eq!(pixels_near(&mut slide, 0.9, [0, 255, 0]), 0);
}

#[test]
fn a_gradient_sweep_runs_from_one_colour_to_the_other_across_the_line() {
    let words = &[("aaaa", 0.0, 0.5), ("bbbb", 0.5, 1.0)];
    let patch = serde_json::json!({
        "highlight_colors": ["#FF0000", "#0000FF"], "font_size": 200
    });
    let mut r = Renderer::new(Scene::new(&book(), styled("word_sweep", words, patch)));
    r.render(1.0);
    // The leftmost and rightmost fully inked pixels: the two ends of the line.
    let solid = |px: &&[u8]| px[3] == 255;
    let at = |i: usize| i % 1080;
    let pixels: Vec<&[u8]> = r.rgba().chunks(4).collect();
    let first = pixels
        .iter()
        .enumerate()
        .filter(|(_, px)| solid(px))
        .min_by_key(|(i, _)| at(*i));
    let last = pixels
        .iter()
        .enumerate()
        .filter(|(_, px)| solid(px))
        .max_by_key(|(i, _)| at(*i));
    let (left, right) = (first.unwrap().1, last.unwrap().1);
    let (left, right) = ((left[0], left[2]), (right[0], right[2]));
    assert!(left.0 > left.1, "the start of the line is red");
    assert!(right.1 > right.0, "and its end is blue");
}

/// FNV-1a over a frame's bytes: a fingerprint of every pixel.
fn fingerprint(bytes: &[u8], mut h: u64) -> u64 {
    for &b in bytes {
        h = (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// The frame times a golden case is drawn at, in order, as a player would reach them.
const GOLDEN_TIMES: [f32; 5] = [0.0, 0.25, 0.6, 1.2, 3.2];

/// Draws a scene through `GOLDEN_TIMES` and returns one fingerprint of all the frames,
/// after checking that each frame, drawn on the renderer that kept the last one, is the
/// frame a fresh renderer draws at that time: the incremental redraw changes nothing.
fn golden(mut input: SceneInput) -> (u64, bool) {
    // Half size: layout is proportional to the frame's height, so this is the same
    // picture, a quarter of the pixels.
    (input.width, input.height) = (540, 960);
    let book = book();
    let mut kept = Renderer::new(Scene::new(&book, input.clone()));
    let mut all = 0xcbf2_9ce4_8422_2325;
    let mut inked = false;
    for t in GOLDEN_TIMES {
        kept.render(t);
        let mut fresh = Renderer::new(Scene::new(&book, input.clone()));
        fresh.render(t);
        assert!(
            kept.rgba() == fresh.rgba(),
            "the frame at {t} s differs between an incremental and a fresh redraw"
        );
        inked |= kept.rgba().iter().any(|&b| b != 0);
        all = fingerprint(kept.rgba(), all);
    }
    (all, inked)
}

/// Every look the engine can draw, as (name, style patch, animation).
fn golden_cases() -> Vec<(String, SceneInput)> {
    let mut cases = Vec::new();
    for anim in animation_names() {
        cases.push((anim.clone(), styled(&anim, WORDS, serde_json::json!({}))));
    }
    let effects = [
        (
            "stroke",
            serde_json::json!({ "stroke_width": 6, "stroke_color": "#000000" }),
        ),
        (
            "hard_shadow",
            serde_json::json!({
                "stroke_width": 4, "stroke_color": "#000000", "shadow_blur": 0,
                "shadow_color": "#000000", "shadow_offset_x": 8, "shadow_offset_y": 10
            }),
        ),
        (
            "blur_shadow",
            serde_json::json!({
                "shadow_blur": 12, "shadow_color": "#000000CC",
                "shadow_offset_x": 4, "shadow_offset_y": 6
            }),
        ),
        (
            "glow",
            serde_json::json!({ "glow_blur": 14, "glow_color": "#00FFAA" }),
        ),
        (
            "italic_upper",
            serde_json::json!({ "italic": true, "text_case": "upper" }),
        ),
        (
            "pill",
            serde_json::json!({
                "background": "pill", "background_color": "#101010", "background_opacity": 0.8
            }),
        ),
    ];
    for (name, patch) in effects {
        // On a still look and on two that move every word's opacity or scale.
        for anim in ["word_highlight", "word_fade", "word_pop"] {
            cases.push((format!("{anim}+{name}"), styled(anim, WORDS, patch.clone())));
        }
    }
    let chunky = serde_json::json!({
        "fill_colors": ["#FFF36B", "#FFB800"], "stroke_width": 6, "stroke_color": "#3B1A00",
        "shadow_blur": 0, "shadow_color": "#C2410C", "shadow_offset_y": 16, "extrude_shade": 0.6
    });
    for anim in ["word_press", "word_pop"] {
        cases.push((
            format!("{anim}+chunky"),
            styled(anim, WORDS, chunky.clone()),
        ));
    }
    let poster = serde_json::json!({
        "align": "justify", "words_per_line": 4,
        "stroke_width": 4, "stroke_color": "#000000"
    });
    for anim in ["word_pop", "letter_rise", "highlight_box"] {
        cases.push((
            format!("{anim}+stack"),
            styled(anim, FIGURES, poster.clone()),
        ));
    }
    let mut marked = styled("word_highlight", WORDS, serde_json::json!({}));
    marked.watermark = Some("OpenCaptions".to_string());
    cases.push(("watermark".to_string(), marked));
    cases
}

/// The fingerprint of every look at every golden time. A change that is meant to alter the
/// picture updates these (`OC_PRINT_GOLDEN=1 cargo test golden -- --nocapture` prints
/// them); a change that only makes drawing faster must not touch one.
#[test]
fn frames_are_byte_for_byte_what_they_were() {
    let got: Vec<(String, u64)> = golden_cases()
        .into_iter()
        .map(|(name, input)| {
            let (h, inked) = golden(input);
            assert!(inked, "{name} drew nothing at any time");
            (name, h)
        })
        .collect();
    if std::env::var_os("OC_PRINT_GOLDEN").is_some() {
        for (name, h) in &got {
            println!("        (\"{name}\", 0x{h:016x}),");
        }
    }
    let want: &[(&str, u64)] = GOLDEN;
    let got_names: Vec<&str> = got.iter().map(|(n, _)| n.as_str()).collect();
    let want_names: Vec<&str> = want.iter().map(|(n, _)| *n).collect();
    assert_eq!(
        got_names, want_names,
        "the looks covered changed: update GOLDEN"
    );
    for ((name, h), (_, expected)) in got.iter().zip(want) {
        assert_eq!(*h, *expected, "{name}: the drawn frames changed");
    }
}

/// The blur as it was first written: every pixel, every pass, a column at a time.
fn blur_everywhere(px: &mut Pixmap, sigma: f32) {
    let radius = blur_radius(sigma);
    let (w, h) = (px.width() as usize, px.height() as usize);
    let data = px.data_mut();
    let mut line = vec![0u32; w.max(h) * 4];
    let span = (2 * radius + 1) as u32;
    let mut pass = |len: usize, at: &dyn Fn(usize) -> usize| {
        for i in 0..len {
            for c in 0..4 {
                line[i * 4 + c] = u32::from(data[at(i) + c]);
            }
        }
        let mut acc = [0u32; 4];
        for i in 0..=radius.min(len - 1) {
            for c in 0..4 {
                acc[c] += line[i * 4 + c];
            }
        }
        for i in 0..len {
            for c in 0..4 {
                data[at(i) + c] = ((acc[c] + span / 2) / span) as u8;
            }
            if i + radius + 1 < len {
                for c in 0..4 {
                    acc[c] += line[(i + radius + 1) * 4 + c];
                }
            }
            if i >= radius {
                for c in 0..4 {
                    acc[c] -= line[(i - radius) * 4 + c];
                }
            }
        }
    };
    for _ in 0..3 {
        for y in 0..h {
            pass(w, &|x| (y * w + x) * 4);
        }
        for x in 0..w {
            pass(h, &|y| (y * w + x) * 4);
        }
    }
}

#[test]
fn the_blur_is_exactly_the_blur_of_every_pixel() {
    let mut seed = 0x9e37_79b9_7f4a_7c15_u64;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    // Sizes and sigmas that put ink at the edges, in the middle, nowhere, and so thin
    // or small that the blur's reach is wider than the pixmap.
    for (w, h, sigma) in [
        (64, 40, 0.5),
        (64, 40, 3.0),
        (7, 5, 6.0),
        (1, 1, 2.0),
        (90, 9, 1.2),
        (33, 61, 9.0),
        (120, 80, 14.0),
    ] {
        for case in 0..6 {
            let mut a = Pixmap::new(w, h).unwrap();
            let (bw, bh) = (
                1 + next() as usize % w as usize,
                1 + next() as usize % h as usize,
            );
            let (ox, oy) = (
                next() as usize % (w as usize - bw + 1),
                next() as usize % (h as usize - bh + 1),
            );
            if case != 0 {
                for y in oy..oy + bh {
                    for x in ox..ox + bw {
                        if case == 1 || next() % 3 == 0 {
                            // Premultiplied: no channel above alpha.
                            let alpha = 1 + (next() % 255) as u8;
                            let i = (y * w as usize + x) * 4;
                            for c in 0..3 {
                                a.data_mut()[i + c] = (next() % (u64::from(alpha) + 1)) as u8;
                            }
                            a.data_mut()[i + 3] = alpha;
                        }
                    }
                }
            }
            let mut b = a.clone();
            blur(&mut a, sigma);
            blur_everywhere(&mut b, sigma);
            assert!(
                a.data() == b.data(),
                "{w}x{h} sigma {sigma} case {case}: the cropped blur differs"
            );
        }
    }
}

#[test]
fn the_overlay_box_holds_every_line_and_the_mark_on_even_edges() {
    let plain = input("word_highlight", WORDS, 2);
    let mut marked = plain.clone();
    marked.watermark = Some("OpenCaptions".into());
    let scene = Scene::new(&book(), marked);
    let (x, y, w, h) = scene.overlay_bounds();
    assert!(x % 2 == 0 && y % 2 == 0 && w % 2 == 0 && h % 2 == 0);
    assert!(x + w <= scene.width && y + h <= scene.height);
    let mark = scene.mark.as_ref().unwrap().rect;
    for r in scene.lines.iter().map(|l| l.bounds).chain([mark]) {
        assert!(
            x as i32 <= r.x()
                && y as i32 <= r.y()
                && (x + w) as i32 >= r.right()
                && (y + h) as i32 >= r.bottom(),
            "{r:?} is outside the box {:?}",
            (x, y, w, h)
        );
    }
    // And nothing is ever drawn outside it.
    let mut renderer = Renderer::new(Scene::new(&book(), plain));
    let (x, y, w, h) = renderer.scene().overlay_bounds();
    for t in [0.0, 0.3, 0.6, 1.2, 3.2] {
        renderer.render(t);
        let width = renderer.scene().width as usize;
        for (row, line) in renderer.rgba().chunks_exact(width * 4).enumerate() {
            for (col, px) in line.as_chunks::<4>().0.iter().enumerate() {
                let inside = (x as usize..(x + w) as usize).contains(&col)
                    && (y as usize..(y + h) as usize).contains(&row);
                assert!(inside || px[3] == 0, "ink at ({col}, {row}) at {t} s");
            }
        }
    }
}

const GOLDEN: &[(&str, u64)] = &[
    ("word_highlight", 0xf26273125dfc6bf6),
    ("highlight_box", 0xd7eb38aa81c8867f),
    ("word_pop", 0xda614d49f56c55f4),
    ("word_fade", 0x44ed1a5d9329ca4e),
    ("word_sweep", 0x76a12a545f6c55d2),
    ("word_underline", 0xfb9619a6926772c7),
    ("typewriter", 0x774d718bfa4e3047),
    ("none", 0xfe846054695b2f5c),
    ("word_bounce", 0x7ccda292d88c19ac),
    ("lyric_focus", 0xf67ff5ba29429af2),
    ("highlight_slide", 0x88314a33e4a554f9),
    ("line_bar", 0x6b1e7afb5365656d),
    ("stickers", 0x5c9bad18f058c1c7),
    ("word_press", 0xf26273125dfc6bf6),
    ("letter_rise", 0x9bf46ac595f09960),
    ("word_slam", 0x01b67dcf00483f0b),
    ("drift", 0x4db2b22b1c3c5323),
    ("blur_in", 0x838ead26fd0a0a6b),
    ("word_highlight+stroke", 0xa886db0bfe0007d8),
    ("word_fade+stroke", 0x100c37255aee5408),
    ("word_pop+stroke", 0x8bbaecd606e3c7e3),
    ("word_highlight+hard_shadow", 0x5b74783a76662701),
    ("word_fade+hard_shadow", 0x475ee9f0778267b3),
    ("word_pop+hard_shadow", 0x553d16d2b7218cc0),
    ("word_highlight+blur_shadow", 0x14f08f9b6e36576c),
    ("word_fade+blur_shadow", 0x06a272810bee5643),
    ("word_pop+blur_shadow", 0x93eadae460e3a326),
    ("word_highlight+glow", 0x3ee4161be9e7bfda),
    ("word_fade+glow", 0x9eb95ca66e0a91ce),
    ("word_pop+glow", 0xd34e7d3719c1ed61),
    ("word_highlight+italic_upper", 0xbb710f6a8ee71ff2),
    ("word_fade+italic_upper", 0xbd182700c42782ba),
    ("word_pop+italic_upper", 0xd20257c98ebb01a7),
    ("word_highlight+pill", 0x39e4fe882e5dfa3b),
    ("word_fade+pill", 0xbcf444e5865cfa9c),
    ("word_pop+pill", 0xc9c9ca585f268aa2),
    ("word_press+chunky", 0xe55ee93138faa2d6),
    ("word_pop+chunky", 0x064022aaf29214a8),
    ("word_pop+stack", 0x7a2ceb6d7115026e),
    ("letter_rise+stack", 0xe4534b8dcb4a39e8),
    ("highlight_box+stack", 0x7215adeb165d3e2e),
    ("watermark", 0xe22c164ced6e9dd5),
];

#[test]
fn a_glow_lies_under_the_extrusion_and_surrounds_it() {
    let frame = |glow: bool| {
        let mut patch = serde_json::json!({
            "font_size": 120, "shadow_color": "#FFA305FF", "shadow_offset_y": 40, "shadow_blur": 0
        });
        if glow {
            patch["glow_blur"] = 16.into();
            patch["glow_color"] = "#000000FF".into();
        }
        let scene = Scene::new(
            &book(),
            styled("word_highlight", &[("hello", 0.0, 1.0)], patch),
        );
        let mut renderer = Renderer::new(scene);
        renderer.render(0.5);
        let reach = extent(&renderer, 1080).unwrap();
        (renderer.rgba().to_vec(), reach)
    };
    let (bare, bare_reach) = frame(false);
    let (lit, lit_reach) = frame(true);
    // Whatever the letters and the extrusion cover is theirs alone: the halo is beneath it.
    for (i, (a, b)) in bare.chunks(4).zip(lit.chunks(4)).enumerate() {
        assert!(
            a[3] < 255 || a == b,
            "pixel {i} of the letters or extrusion is dimmed by the glow"
        );
    }
    // And the halo is made from the extrusion too, so it reaches past its far end.
    assert!(
        lit_reach.3 >= bare_reach.3 + 6,
        "the halo surrounds the extrusion"
    );
}

// Word looks: a style's variants, and a word's choice of one.

fn serif_book() -> FontBook<'static> {
    let mut b = FontBook::new();
    for font in [
        &include_bytes!("../../fonts/Inter.ttf")[..],
        include_bytes!("../../fonts/InstrumentSerif-Italic.ttf"),
        include_bytes!("../../fonts/InstrumentSerif-Regular.ttf"),
    ] {
        b.add(font).unwrap();
    }
    b
}

/// Three words on one row, the middle one given look `variant`, over a style with these looks.
fn with_looks(variants: serde_json::Value, variant: Option<u32>) -> SceneInput {
    let mut scene = styled(
        "none",
        &[("xxx", 0.0, 0.5), ("xxx", 0.5, 1.0), ("xxx", 1.0, 1.5)],
        serde_json::json!({ "variants": variants }),
    );
    scene.transcript.segments[0].words[1].variant = variant;
    scene
}

#[test]
fn a_word_with_a_look_is_set_at_its_scale_on_the_rows_baseline() {
    let looks = serde_json::json!([{ "scale": 0.5 }]);
    let plain = Scene::new(&serif_book(), with_looks(looks.clone(), None));
    let small = Scene::new(&serif_book(), with_looks(looks, Some(0)));
    let (a, b) = (&small.lines[0].words[0], &small.lines[0].words[1]);
    assert_eq!((a.size, b.size), (1.0, 0.5));
    assert_eq!(a.baseline, b.baseline, "one baseline for the row");
    assert!(b.slot.width() < plain.lines[0].words[1].slot.width() * 0.6);
    let (ga, gb) = (a.glyphs.as_ref().unwrap(), b.glyphs.as_ref().unwrap());
    assert!(
        gb.bounds().height() < ga.bounds().height() * 0.6,
        "drawn smaller"
    );
    assert!(
        (ga.bounds().bottom() - gb.bounds().bottom()).abs() < 1.0,
        "and standing on the same line"
    );
    // The gap after a small word is small too.
    let (c_plain, c_small) = (&plain.lines[0].words[2], &small.lines[0].words[2]);
    assert!(c_small.slot.x() < c_plain.slot.x());
}

#[test]
fn a_look_past_the_end_draws_as_the_base_look() {
    let looks = serde_json::json!([{ "scale": 0.5, "text_color": "#00FF00" }]);
    let frame = |variant| {
        let mut r = Renderer::new(Scene::new(
            &serif_book(),
            with_looks(looks.clone(), variant),
        ));
        r.render(0.7);
        r.rgba().to_vec()
    };
    assert_eq!(frame(Some(7)), frame(None));
    assert_ne!(frame(Some(0)), frame(None));
}

#[test]
fn a_look_can_change_a_words_face_colour_and_case() {
    let looks = serde_json::json!([
        { "font": "Instrument Serif", "text_color": "#00FF00", "text_case": "upper" }
    ]);
    let mut r = Renderer::new(Scene::new(&serif_book(), with_looks(looks, Some(0))));
    r.render(0.7);
    let green = r
        .rgba()
        .chunks(4)
        .filter(|p| p[3] == 255 && p[1] > 200 && p[0] < 60 && p[2] < 60)
        .count();
    assert!(green > 100, "the word is painted in its own colour");
    let word = &r.scene().lines[0].words[1];
    assert_eq!(word.chars, 3);
    assert_eq!(word.color, Some(Rgba([0, 255, 0, 255])));
}

#[test]
fn an_italic_family_uses_its_italic_and_is_not_leaned_again() {
    let book = serif_book();
    let scene = |italic| {
        styled(
            "none",
            &[("aaa", 0.0, 0.5)],
            serde_json::json!({ "font": "Instrument Serif", "italic": italic }),
        )
    };
    let (upright, italic) = (
        Scene::new(&book, scene(false)),
        Scene::new(&book, scene(true)),
    );
    let (u, i) = (&upright.lines[0].words[0], &italic.lines[0].words[0]);
    let fs = italic.style.font_size;
    let advance = |face: usize| {
        shape_tracked(
            book.face(face),
            "aaa",
            fs,
            Tracking {
                spacing: 0.0,
                stretch: 1.0,
            },
        )
        .1
    };
    let (regular, real) = (
        book.styled("Instrument Serif", false).0,
        book.styled("Instrument Serif", true).0,
    );
    assert_ne!(regular, real);
    assert!((u.ink_w - advance(regular)).abs() < 0.01);
    assert!(
        (i.ink_w - advance(real)).abs() < 0.01,
        "set in the italic face"
    );
    // Inter has no italic: it is the upright face, leaned over its top corner.
    let plain = Scene::new(
        &book,
        styled("none", &[("aaa", 0.0, 0.5)], serde_json::json!({})),
    );
    let leaned = Scene::new(
        &book,
        styled(
            "none",
            &[("aaa", 0.0, 0.5)],
            serde_json::json!({ "italic": true }),
        ),
    );
    let (p, l) = (&plain.lines[0].words[0], &leaned.lines[0].words[0]);
    assert_eq!(p.ink_w, l.ink_w);
    assert!(
        l.glyphs.as_ref().unwrap().bounds().right() > p.glyphs.as_ref().unwrap().bounds().right()
    );
}

#[test]
fn a_boxed_word_has_a_square_box_behind_it() {
    let looks = serde_json::json!([{ "box_color": "#00FF00", "scale": 0.8 }]);
    let mut r = Renderer::new(Scene::new(&serif_book(), with_looks(looks, Some(0))));
    r.render(0.7);
    let slot = r.scene().lines[0].words[1].slot;
    let (x, y) = (slot.x() as usize + 1, slot.y() as usize + 1);
    let at = |x: usize, y: usize| {
        let i = (y * 1080 + x) * 4;
        r.rgba()[i..i + 4].to_vec()
    };
    // The corner of the box is its colour: a square, not rounded.
    assert_eq!(at(x, y), vec![0, 255, 0, 255]);
    // Another word has none.
    let other = r.scene().lines[0].words[0].slot;
    assert_ne!(
        at(other.x() as usize + 1, other.y() as usize + 1),
        vec![0, 255, 0, 255]
    );
}

#[test]
fn blur_in_comes_out_of_a_blur_in_a_few_frames_and_moves_nothing() {
    let scene = Scene::new(&book(), input("blur_in", WORDS, 3));
    let w = &scene.lines[0].words[0];
    let state = |t| word_state(Animation::BlurIn, w, t);
    let before = state(w.start - LEAD_S);
    assert_eq!(before.opacity, 0.0);
    assert!(before.soften > 0.0);
    let part = state(w.start - LEAD_S + BLUR_IN_S / 2.0);
    assert!(part.opacity > 0.0 && part.opacity < 1.0 && part.soften > 0.0);
    for t in [w.start - LEAD_S, w.start, w.end + 1.0] {
        let st = state(t);
        assert_eq!(
            (st.scale, st.tilt, st.on, st.press),
            (1.0, 0.0, 0.0, 0.0),
            "nothing moves"
        );
    }
    let after = state(w.start - LEAD_S + BLUR_IN_S + 0.001);
    assert_eq!(
        (after.opacity, after.soften),
        (1.0, 0.0),
        "sharp after {BLUR_IN_S} s"
    );
    assert_eq!(state(w.end + 5.0).opacity, 1.0, "and it stays");
}
