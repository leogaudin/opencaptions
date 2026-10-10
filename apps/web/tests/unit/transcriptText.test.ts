import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  formatTranscript,
  importSubtitles,
  type Parsed,
  parseTranscript,
  type Transcript,
} from "../../src/lib/transcriptText.ts";

const base: Transcript = {
  schema_version: 1,
  language: "fr",
  language_detection: "auto",
  duration: 10,
  segments: [],
};

const word = (text: string, start: number, end: number) => ({ text, start, end, confidence: 1 });

const sample: Transcript = {
  ...base,
  segments: [
    {
      id: "a",
      start: 0.5,
      end: 1.3,
      text: "un deux",
      words: [word("un", 0.5, 0.9), word("deux", 0.9, 1.3)],
    },
    { id: "b", start: 2, end: 2.4, text: "trois", words: [word("trois", 2, 2.4)] },
  ],
};

function ok(parsed: Parsed): Transcript {
  assert.ok(parsed.ok, `expected success, got ${JSON.stringify(parsed)}`);
  return parsed.transcript;
}

const texts = (t: Transcript) => t.segments.map((s) => s.words.map((w) => w.text));

describe("the raw editor", () => {
  it("shows a word to a line, without what is worked out from the words", () => {
    const text = formatTranscript(sample);
    assert.ok(text.includes('{ "text": "un", "start": 0.5, "end": 0.9, "confidence": 1 }'));
    assert.equal(text.split("\n").filter((l) => l.includes('"text"')).length, 3);
    assert.ok(!text.includes('"un deux"'), "the segment's text is rebuilt, not edited");
  });

  it("round-trips: what is shown comes back as the same transcript", () => {
    assert.deepEqual(ok(parseTranscript(formatTranscript(sample), base)), sample);
  });

  it("rebuilds a segment's span and text from its words after an edit", () => {
    const edited = formatTranscript(sample)
      .replace('"un"', '"UN  bis"')
      .replace('"start": 0.5', '"start": 0.25');
    const [first] = ok(parseTranscript(edited, base)).segments;
    assert.equal(first?.text, "UN bis deux");
    assert.equal(first?.start, 0.25);
  });

  it("names the segment and word that are wrong", () => {
    const bad = (mutate: (t: Transcript) => void) => {
      const copy = structuredClone(sample);
      mutate(copy);
      return parseTranscript(JSON.stringify(copy), base);
    };
    const end = bad((t) => {
      const w = t.segments[1]?.words[0];
      if (w) w.end = 1;
    });
    assert.deepEqual(end, { ok: false, code: "word", segment: 2, word: 1 });
    const order = bad((t) => {
      const w = t.segments[1]?.words[0];
      if (w) w.start = 0.1;
    });
    assert.deepEqual(order, { ok: false, code: "order", segment: 2, word: 1 });
    const blank = bad((t) => {
      const w = t.segments[0]?.words[1];
      if (w) w.text = "  ";
    });
    assert.deepEqual(blank, { ok: false, code: "word", segment: 1, word: 2 });
  });

  it("refuses what is not JSON, not a transcript, or has no words", () => {
    const json = parseTranscript("{ nope", base);
    assert.ok(!json.ok && json.code === "json");
    assert.deepEqual(parseTranscript("[]", base), { ok: false, code: "shape" });
    assert.deepEqual(parseTranscript('{"segments":[{"words":3}]}', base), {
      ok: false,
      code: "shape",
    });
    assert.deepEqual(parseTranscript('{"segments":[]}', base), { ok: false, code: "empty" });
  });

  it("gives a new segment an id, and keeps the video's length when the words end sooner", () => {
    const t = ok(
      parseTranscript('{"segments":[{"words":[{"text":"a","start":1,"end":2}]}]}', base),
    );
    assert.ok((t.segments[0]?.id.length ?? 0) > 8);
    assert.equal(t.duration, 10);
    assert.equal(t.language, "fr");
    const long = ok(
      parseTranscript('{"segments":[{"words":[{"text":"a","start":1,"end":30}]}]}', base),
    );
    assert.equal(long.duration, 30);
  });
});

describe("importing subtitles", () => {
  const srt = `1
00:00:01,000 --> 00:00:03,000
Bonjour <i>tout</i> le monde

2
00:00:04,500 --> 00:00:05,000
Ça va ?
`;

  it("reads SRT: one segment a cue, the words spread over it", () => {
    const t = ok(importSubtitles(srt, base));
    assert.deepEqual(texts(t), [
      ["Bonjour", "tout", "le", "monde"],
      ["Ça", "va", "?"],
    ]);
    const [first, second] = t.segments;
    assert.equal(first?.start, 1);
    assert.equal(first?.end, 3);
    assert.equal(second?.start, 4.5);
    assert.equal(t.language_detection, "manual");
    // The longer word takes longer than the short one.
    const w = first?.words ?? [];
    assert.ok((w[0]?.end ?? 0) - (w[0]?.start ?? 0) > (w[2]?.end ?? 0) - (w[2]?.start ?? 0));
  });

  it("reads WebVTT: the header, notes, cue settings, identifiers and short times", () => {
    const vtt = `WEBVTT - a title

NOTE this is skipped

intro
00:01.000 --> 00:02.000 align:start position:0%
<v Anna>Hello there</v>

00:00:02.500 --> 00:00:03.000
Bye
`;
    const t = ok(importSubtitles(vtt, base));
    assert.deepEqual(texts(t), [["Hello", "there"], ["Bye"]]);
    assert.equal(t.segments[0]?.start, 1);
  });

  it("reads the per-word times our own WebVTT export writes", () => {
    const vtt = `WEBVTT

00:00:00.500 --> 00:00:01.300
<00:00:00.500>un <00:00:00.900>deux
`;
    const words = ok(importSubtitles(vtt, base)).segments[0]?.words ?? [];
    assert.deepEqual(
      words.map((w) => [w.text, w.start, w.end]),
      [
        ["un", 0.5, 0.9],
        ["deux", 0.9, 1.3],
      ],
    );
  });

  it("copes with a byte order mark, Windows line ends and dots in SRT times", () => {
    const text =
      "﻿1\r\n00:00:01.000 --> 00:00:02.000\r\nHi\r\n\r\n2\r\n00:00:03.000 --> 00:00:04.000\r\nYou\r\n";
    assert.deepEqual(texts(ok(importSubtitles(text, base))), [["Hi"], ["You"]]);
  });

  it("keeps cues in order and words from overlapping", () => {
    const text = `00:00:05,000 --> 00:00:06,000
second

00:00:01,000 --> 00:00:05,500
first one
`;
    const t = ok(importSubtitles(text, base));
    assert.deepEqual(texts(t), [["first", "one"], ["second"]]);
    const all = t.segments.flatMap((s) => s.words);
    for (const [i, w] of all.entries()) {
      assert.ok(w.end >= w.start);
      const next = all[i + 1];
      if (next) assert.ok(w.end <= next.start + 1e-9, "no overlap");
    }
  });

  it("gives a cue with no length enough room for its words", () => {
    const t = ok(importSubtitles("00:00:01,000 --> 00:00:01,000\none two three\n", base));
    const words = t.segments[0]?.words ?? [];
    assert.ok(words.every((w) => w.end > w.start));
  });

  it("takes our JSON export as it is", () => {
    assert.deepEqual(ok(importSubtitles(JSON.stringify(sample), base)), sample);
  });

  it("says when a file is no subtitle format", () => {
    assert.deepEqual(importSubtitles("hello\nworld", base), { ok: false, code: "format" });
    assert.deepEqual(importSubtitles("", base), { ok: false, code: "format" });
  });

  it("skips a cue that has no words", () => {
    const text = "00:00:01,000 --> 00:00:02,000\n<i></i>\n\n00:00:03,000 --> 00:00:04,000\nHi\n";
    assert.deepEqual(texts(ok(importSubtitles(text, base))), [["Hi"]]);
  });
});
