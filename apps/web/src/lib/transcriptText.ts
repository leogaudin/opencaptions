/**
 * The transcript as text a person can edit, and subtitle files turned into one.
 *
 * `formatTranscript` and `parseTranscript` are the raw editor: JSON, one word to a line, with
 * what is worked out from the words (a segment's span and text) left out and rebuilt on the
 * way back. `importSubtitles` reads SRT, WebVTT (including the per-word times our own export
 * writes) and our JSON export into a transcript.
 *
 * Pure and free of the app's imports, so the unit tests run it as it is. A failure is a code
 * and its values, never a sentence: the screen words it in the user's language.
 */

export interface Word {
  text: string;
  start: number;
  end: number;
  confidence: number;
}

export interface Segment {
  id: string;
  words: Word[];
  start: number;
  end: number;
  text: string;
}

export interface Transcript {
  schema_version: number;
  language: string;
  language_detection: "auto" | "manual";
  duration: number;
  segments: Segment[];
}

export type TextError =
  | { code: "json"; message: string }
  | { code: "shape" }
  | { code: "word"; segment: number; word: number }
  | { code: "order"; segment: number; word: number }
  | { code: "empty" }
  | { code: "format" };

export type Parsed =
  | { ok: true; transcript: Transcript; words: number }
  | ({ ok: false } & TextError);

const fail = (error: TextError): Parsed => ({ ok: false, ...error });

const ms = (seconds: number): number => Math.round(seconds * 1000) / 1000;

/** The raw editor's text: the transcript as JSON, a word to a line. */
export function formatTranscript(t: Transcript): string {
  const word = (w: Word): string =>
    `        { "text": ${JSON.stringify(w.text)}, "start": ${w.start}, "end": ${w.end}, "confidence": ${w.confidence} }`;
  const segments = t.segments.map(
    (s) =>
      `    {\n      "id": ${JSON.stringify(s.id)},\n      "words": [\n${s.words.map(word).join(",\n")}\n      ]\n    }`,
  );
  return [
    "{",
    `  "schema_version": ${t.schema_version},`,
    `  "language": ${JSON.stringify(t.language)},`,
    `  "language_detection": ${JSON.stringify(t.language_detection)},`,
    `  "duration": ${t.duration},`,
    `  "segments": [\n${segments.join(",\n")}\n  ]`,
    "}",
  ].join("\n");
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

/** A word as typed, or null when it is not one: text, and a start and end in seconds. */
function readWord(raw: unknown): Word | null {
  if (!isRecord(raw)) return null;
  const { text, start, end, confidence } = raw;
  if (typeof text !== "string" || typeof start !== "number" || typeof end !== "number") return null;
  const clean = text.split(/\s+/).filter(Boolean).join(" ");
  if (!clean || !Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < start) {
    return null;
  }
  const sure = typeof confidence === "number" && confidence >= 0 && confidence <= 1;
  return { text: clean, start: ms(start), end: ms(end), confidence: sure ? confidence : 1 };
}

/** Segments from the words in each, with the span and the text every segment carries. */
function build(groups: { id?: string; words: Word[] }[], base: Transcript): Parsed {
  const used = new Set<string>();
  const segments: Segment[] = [];
  for (const group of groups) {
    const { words } = group;
    const first = words[0];
    const last = words[words.length - 1];
    if (!first || !last) continue;
    const id = group.id && !used.has(group.id) ? group.id : crypto.randomUUID();
    used.add(id);
    segments.push({
      id,
      words,
      start: first.start,
      end: last.end,
      text: words.map((w) => w.text).join(" "),
    });
  }
  const count = segments.reduce((n, s) => n + s.words.length, 0);
  if (count === 0) return fail({ code: "empty" });
  const end = segments[segments.length - 1]?.end ?? 0;
  return {
    ok: true,
    words: count,
    transcript: { ...base, duration: Math.max(base.duration, end), segments },
  };
}

/** The raw editor's text back into a transcript, or what is wrong with it and where. */
export function parseTranscript(text: string, base: Transcript): Parsed {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch (e) {
    return fail({ code: "json", message: (e as Error).message });
  }
  if (!isRecord(data) || !Array.isArray(data.segments)) return fail({ code: "shape" });

  const groups: { id?: string; words: Word[] }[] = [];
  let previous = 0;
  for (const [s, rawSegment] of data.segments.entries()) {
    if (!isRecord(rawSegment) || !Array.isArray(rawSegment.words)) return fail({ code: "shape" });
    const words: Word[] = [];
    for (const [w, rawWord] of rawSegment.words.entries()) {
      const word = readWord(rawWord);
      if (!word) return fail({ code: "word", segment: s + 1, word: w + 1 });
      if (word.start < previous) return fail({ code: "order", segment: s + 1, word: w + 1 });
      previous = word.start;
      words.push(word);
    }
    groups.push({ id: typeof rawSegment.id === "string" ? rawSegment.id : undefined, words });
  }
  const language =
    typeof data.language === "string" && data.language ? data.language : base.language;
  const manual = data.language_detection === "manual" || data.language_detection === "auto";
  return build(groups, {
    ...base,
    language,
    language_detection: manual
      ? (data.language_detection as "auto" | "manual")
      : base.language_detection,
  });
}

// ---- Subtitle files ------------------------------------------------------------------------

const TIME = String.raw`(?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3}`;
const CUE_LINE = new RegExp(`^\\s*(${TIME})\\s*-->\\s*(${TIME})`);
const INLINE_TIME = new RegExp(`<(${TIME})>`);

/** `01:02:03,450`, `02:03.45` and the like, in seconds. */
function seconds(stamp: string): number {
  const [clock = "", fraction = "0"] = stamp.split(/[.,]/);
  const parts = clock.split(":").map(Number);
  const [h, m, s] = parts.length === 3 ? parts : [0, ...parts];
  return (h ?? 0) * 3600 + (m ?? 0) * 60 + (s ?? 0) + Number(`0.${fraction}`);
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", nbsp: " ", quot: '"' };

/** A cue's text without styling: `<i>`, `<c.yellow>`, `{\an8}` and the entities. */
function plain(text: string): string {
  return text
    .replace(/<[^>]*>/g, "")
    .replace(/\{\\[^}]*\}/g, "")
    .replace(/&(amp|lt|gt|nbsp|quot);/g, (_, name: string) => ENTITIES[name] ?? "");
}

/** The words in `text` spread over a span, the longer ones taking longer. */
function spread(text: string, start: number, end: number): Word[] {
  const tokens = plain(text).split(/\s+/).filter(Boolean);
  const total = tokens.reduce((n, t) => n + Math.max(1, t.length), 0);
  let used = 0;
  return tokens.map((token) => {
    const from = start + ((end - start) * used) / total;
    used += Math.max(1, token.length);
    const to = start + ((end - start) * used) / total;
    return { text: token, start: ms(from), end: ms(to), confidence: 1 };
  });
}

/** A cue's words: at the times a WebVTT cue gives them inline, else spread over the cue. */
function cueWords(raw: string, start: number, end: number): Word[] {
  const pieces = raw.split(INLINE_TIME);
  if (pieces.length === 1) return spread(raw, start, end);
  // [text, time, text, time, text…]: each text runs from its time to the next one.
  const marks: { at: number; text: string }[] = [{ at: start, text: pieces[0] ?? "" }];
  for (let i = 1; i < pieces.length; i += 2) {
    marks.push({ at: seconds(pieces[i] ?? "0"), text: pieces[i + 1] ?? "" });
  }
  return marks.flatMap((mark, i) => {
    const next = marks[i + 1]?.at ?? end;
    return spread(mark.text, mark.at, Math.max(next, mark.at));
  });
}

interface Cue {
  start: number;
  end: number;
  text: string;
}

/** The cues of an SRT or WebVTT document; null when it has none. */
function readCues(body: string): Cue[] | null {
  const cues: Cue[] = [];
  for (const block of body.replace(/\r\n?/g, "\n").split(/\n{2,}/)) {
    const lines = block.split("\n");
    const at = lines.findIndex((l) => CUE_LINE.test(l));
    const match = at >= 0 ? CUE_LINE.exec(lines[at] ?? "") : null;
    if (!match) continue;
    cues.push({
      start: seconds(match[1] ?? "0"),
      end: seconds(match[2] ?? "0"),
      text: lines.slice(at + 1).join(" "),
    });
  }
  return cues.length > 0 ? cues : null;
}

/** The shortest a word is made when a file gives its cue no length. */
const MIN_WORD_S = 0.05;

/** Words for every cue, in order and never overlapping, as the engine's edits assume. */
function cueGroups(cues: Cue[]): { words: Word[] }[] {
  const groups: { words: Word[] }[] = [];
  let reach = 0;
  for (const cue of [...cues].sort((a, b) => a.start - b.start)) {
    const start = Math.max(cue.start, reach);
    const probe = spread(cue.text, 0, 1).length;
    const end = Math.max(cue.end, start + probe * MIN_WORD_S);
    const words = cueWords(cue.text, start, end).filter((w) => w.text);
    if (words.length === 0) continue;
    reach = words[words.length - 1]?.end ?? reach;
    groups.push({ words });
  }
  return groups;
}

/**
 * A subtitle file as a transcript, whichever kind it is: our JSON, WebVTT (starting with
 * WEBVTT) or SRT. A cue's words are spread over it unless WebVTT times them inline.
 */
export function importSubtitles(text: string, base: Transcript): Parsed {
  const body = text.replace(/^﻿/, "").trim();
  if (body.startsWith("{")) return parseTranscript(body, base);
  const cues = readCues(body);
  if (!cues) return fail({ code: "format" });
  return build(cueGroups(cues), { ...base, language_detection: "manual" });
}

export type Token = { kind: "key" | "string" | "number" | "punctuation" | "plain"; text: string };

/** The raw editor's JSON split into pieces to colour; the pieces join back to exactly `text`. */
export function highlight(text: string): Token[] {
  const pattern = /("(?:[^"\\\n]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|([{}[\],:])/g;
  const tokens: Token[] = [];
  let last = 0;
  for (const m of text.matchAll(pattern)) {
    if (m.index > last) tokens.push({ kind: "plain", text: text.slice(last, m.index) });
    if (m[1] !== undefined) {
      tokens.push({ kind: m[2] ? "key" : "string", text: m[1] });
      if (m[2]) tokens.push({ kind: "punctuation", text: m[2] });
    } else if (m[3] !== undefined) tokens.push({ kind: "number", text: m[3] });
    else tokens.push({ kind: "punctuation", text: m[4] ?? "" });
    last = m.index + m[0].length;
  }
  if (last < text.length) tokens.push({ kind: "plain", text: text.slice(last) });
  return tokens;
}
