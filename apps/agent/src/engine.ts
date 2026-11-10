/**
 * The caption engine, through the same WebAssembly file the web editor loads: a word is fixed, a
 * look's word variants dealt, a frame drawn and a file's FFmpeg command made by the code every
 * editor and the render server use, never by a second implementation here.
 */
import { readdir, readFile } from "node:fs/promises";
import type { StyleConfig, Transcript } from "./client.ts";

interface Exports {
  memory: WebAssembly.Memory;
  oc_alloc(len: number): number;
  oc_result_ptr(): number;
  oc_result_len(): number;
  oc_caption_lines(ptr: number, len: number, wordsPerLine: number, offsetMs: number): number;
  oc_set_word(ptr: number, len: number, index: number, textPtr: number, textLen: number): number;
  oc_merge_words(
    ptr: number,
    len: number,
    index: number,
    count: number,
    textPtr: number,
    textLen: number,
  ): number;
  oc_shuffle_variants(ptr: number, len: number, count: number, seed: number): number;
  oc_add_font(ptr: number, len: number): number;
  oc_has_font(namePtr: number, nameLen: number): number;
  oc_add_requested_font(namePtr: number, nameLen: number, ptr: number, len: number): number;
  oc_scene_new(ptr: number, len: number): number;
  oc_scene_free(scene: number): void;
  oc_render(scene: number, t: number): number;
  oc_frame_ptr(scene: number): number;
  oc_encode_plan(scene: number, ptr: number, len: number): number;
  oc_subtitles(
    ptr: number,
    len: number,
    wordsPerLine: number,
    offsetMs: number,
    format: number,
  ): number;
}

/** One caption as it shows on the video: `count` words from word `from`, times in seconds. */
export interface CaptionLine {
  from: number;
  count: number;
  start: number;
  end: number;
  text: string;
}

const WASM = new URL("../engine/opencaptions_engine.wasm", import.meta.url);
/** The faces the render server bundles (apps/engine/fonts), copied beside the WebAssembly. */
const FONTS = new URL("../engine/fonts/", import.meta.url);
const encoder = new TextEncoder();
const decoder = new TextDecoder();

let loaded: Promise<Exports> | undefined;

function exports(): Promise<Exports> {
  loaded ??= readFile(WASM).then(async (bytes) => {
    const { instance } = await WebAssembly.instantiate(bytes, {});
    return instance.exports as unknown as Exports;
  });
  return loaded;
}

function copyIn(x: Exports, bytes: Uint8Array): [number, number] {
  const ptr = x.oc_alloc(bytes.length);
  new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

function result<T>(x: Exports, ok: number): T {
  const text = decoder.decode(
    new Uint8Array(x.memory.buffer, x.oc_result_ptr(), x.oc_result_len()),
  );
  if (!ok) throw new Error(`the caption engine refused it: ${text}`);
  return JSON.parse(text) as T;
}

const json = (x: Exports, value: unknown) => copyIn(x, encoder.encode(JSON.stringify(value)));
const text = (x: Exports, value: string) => copyIn(x, encoder.encode(value));

export async function captionLines(
  t: Transcript,
  wordsPerLine: number,
  offsetMs: number,
): Promise<CaptionLine[]> {
  const x = await exports();
  return result(x, x.oc_caption_lines(...json(x, t), wordsPerLine, offsetMs));
}

/** Word `index` (counted across segments) given `text`; empty text removes it. */
export async function setWord(t: Transcript, index: number, word: string): Promise<Transcript> {
  const x = await exports();
  return result(x, x.oc_set_word(...json(x, t), index, ...text(x, word)));
}

/** `count` words from `index` replaced by one word `text`, spanning them all. */
export async function mergeWords(
  t: Transcript,
  index: number,
  count: number,
  word: string,
): Promise<Transcript> {
  const x = await exports();
  return result(x, x.oc_merge_words(...json(x, t), index, count, ...text(x, word)));
}

/** Deals every word one of `count` looks, or the style's own, as picking such a look does. */
export async function shuffleVariants(t: Transcript, count: number): Promise<Transcript> {
  const x = await exports();
  const seed = crypto.getRandomValues(new Uint32Array(1))[0] ?? 0;
  return result(x, x.oc_shuffle_variants(...json(x, t), count, seed));
}

/** The captions as SubRip or WebVTT, cue for cue the caption lines. */
export async function subtitles(
  t: Transcript,
  wordsPerLine: number,
  offsetMs: number,
  format: "srt" | "vtt",
): Promise<string> {
  const x = await exports();
  return result(x, x.oc_subtitles(...json(x, t), wordsPerLine, offsetMs, format === "srt" ? 0 : 1));
}

let bundled: Promise<void> | undefined;

/** The bundled faces, registered once, in name order as the render server loads them. */
function bundledFonts(x: Exports): Promise<void> {
  bundled ??= readdir(FONTS).then(async (files) => {
    for (const file of files.filter((f) => /\.(ttf|otf)$/i.test(f)).sort()) {
      x.oc_add_font(...copyIn(x, await readFile(new URL(file, FONTS))));
    }
  });
  return bundled;
}

/** Whether a family can be drawn without fetching it. */
export async function hasFont(family: string): Promise<boolean> {
  const x = await exports();
  await bundledFonts(x);
  return x.oc_has_font(...text(x, family)) === 1;
}

/** Registers a family fetched for the style (`fonts.ts`). False if it is not a usable font. */
export async function addFont(family: string, bytes: Uint8Array): Promise<boolean> {
  const x = await exports();
  await bundledFonts(x);
  return x.oc_add_requested_font(...text(x, family), ...copyIn(x, bytes)) === 1;
}

/** What `encode::plan` answers: FFmpeg's arguments, and the band of each frame to pipe in. */
export interface EncodePlan {
  args: string[];
  frames: number;
  band: [number, number, number, number];
  content_type: string;
}

/** `encode::Output`: the source, the file, and how it is encoded. */
export interface EncodeOutput {
  source: string;
  output: string;
  source_transfer: string;
  duration: number;
  fps: number;
  codec: string;
  crf: number | null;
  pro_res_profile: string | null;
  green_screen: boolean;
}

/** A scene laid out once and drawn frame by frame, as the render server draws an export. */
export class Scene {
  private readonly x: Exports;
  private readonly handle: number;
  private readonly width: number;

  private constructor(x: Exports, handle: number, width: number) {
    this.x = x;
    this.handle = handle;
    this.width = width;
  }

  static async create(input: {
    transcript: Transcript;
    style: StyleConfig;
    width: number;
    height: number;
    caption_offset_ms: number;
  }): Promise<Scene> {
    const x = await exports();
    await bundledFonts(x);
    const handle = x.oc_scene_new(...json(x, input));
    if (!handle) result(x, 0);
    return new Scene(x, handle, input.width);
  }

  plan(output: EncodeOutput): EncodePlan {
    return result(this.x, this.x.oc_encode_plan(this.handle, ...json(this.x, output)));
  }

  /** The `band` (x, y, w, h) of the frame at `t` seconds, as RGBA rows, into `into`. */
  band(t: number, [bx, by, bw, bh]: EncodePlan["band"], into: Uint8Array): void {
    this.x.oc_render(this.handle, t);
    const frame = new Uint8Array(this.x.memory.buffer, this.x.oc_frame_ptr(this.handle));
    const row = bw * 4;
    for (let y = 0; y < bh; y++) {
      const start = ((by + y) * this.width + bx) * 4;
      into.set(frame.subarray(start, start + row), y * row);
    }
  }

  free(): void {
    this.x.oc_scene_free(this.handle);
  }
}
