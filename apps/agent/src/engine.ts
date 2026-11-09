/**
 * The caption engine's edits (apps/engine/src/edit.rs), through the same WebAssembly file the web
 * editor loads: a word is fixed, and a look's word variants dealt, by the code every editor uses,
 * never by a second implementation here.
 */
import { readFile } from "node:fs/promises";
import type { Transcript } from "./client.ts";

interface Exports {
  memory: WebAssembly.Memory;
  oc_alloc(len: number): number;
  oc_result_ptr(): number;
  oc_result_len(): number;
  oc_caption_lines(ptr: number, len: number, wordsPerLine: number, offsetMs: number): number;
  oc_set_word(ptr: number, len: number, index: number, textPtr: number, textLen: number): number;
  oc_shuffle_variants(ptr: number, len: number, count: number, seed: number): number;
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
  if (!ok) throw new Error(`the caption engine refused the edit: ${text}`);
  return JSON.parse(text) as T;
}

const json = (x: Exports, t: Transcript) => copyIn(x, encoder.encode(JSON.stringify(t)));

export async function captionLines(
  t: Transcript,
  wordsPerLine: number,
  offsetMs: number,
): Promise<CaptionLine[]> {
  const x = await exports();
  return result(x, x.oc_caption_lines(...json(x, t), wordsPerLine, offsetMs));
}

/** Word `index` (counted across segments) given `text`; empty text removes it. */
export async function setWord(t: Transcript, index: number, text: string): Promise<Transcript> {
  const x = await exports();
  return result(x, x.oc_set_word(...json(x, t), index, ...copyIn(x, encoder.encode(text))));
}

/** Deals every word one of `count` looks, or the style's own, as picking such a look does. */
export async function shuffleVariants(t: Transcript, count: number): Promise<Transcript> {
  const x = await exports();
  const seed = crypto.getRandomValues(new Uint32Array(1))[0] ?? 0;
  return result(x, x.oc_shuffle_variants(...json(x, t), count, seed));
}
