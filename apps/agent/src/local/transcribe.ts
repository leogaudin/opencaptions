/**
 * Transcription on this computer: Parakeet Ultra, the server's own default model and the same
 * pinned files, run by sherpa-onnx. The audio is cut into windows and the model's pieces made into
 * timed words exactly as the server does it (`apps/api/app/transcription/chunking.py` and
 * `sherpa.py`); the Swift app has its own copy too, and all three pass the shared
 * `Fixtures/token-words.json`.
 */
import { createWriteStream } from "node:fs";
import { mkdir, rename, rm, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import { availableParallelism } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { ReadableStream as WebStream } from "node:stream/web";
import type { Progress } from "../captions.ts";
import { OpenCaptionsError, type Transcript } from "../client.ts";
import { cacheDir } from "./cache.ts";
import { audioSamples } from "./media.ts";

const SAMPLE_RATE = 16_000;
/** Loudness is judged on 50 ms frames. */
const FRAME = SAMPLE_RATE / 20;
/** The part of a window, from its start, in which the cut is looked for. */
const CUT_FROM = 0.6;
/** Below this mean level (dBFS) a window is silence for the retry's purposes. */
const QUIET_DB = -55;
/** The shortest piece an empty window is split into. */
const MIN_RETRY_S = 4;
const WINDOW_S = 20;
const SENTENCE_END = [".", "?", "!", "…", "。", "？", "！"];

/** The model, as `apps/api/app/services/asr_models.py` pins it. */
const MODEL = {
  id: "parakeet-ultra",
  repo: "leogaudin/sherpa-onnx-nemo-parakeet-ultra-int8",
  revision: "f7bc472677ff70be95cdb0ef9df509fee6f5ec0b",
  files: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
  languages: new Set(
    "bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro ru sk sl es sv uk".split(" "),
  ),
};

/** (text, start, end, confidence), times in seconds. */
export type Word = [string, number, number, number];

/**
 * SentencePiece pieces grouped into timed words: a leading space (or ▁) starts a word, and so does
 * a piece of nothing but that mark; empty and special pieces (`<blank>`) are skipped. A word's
 * confidence is the geometric mean of its pieces' probabilities.
 */
export function wordsFromTokens(
  tokens: string[],
  starts: number[],
  durations: number[],
  logProbs: number[],
): Word[] {
  const words: { text: string; start: number; end: number; probs: number[] }[] = [];
  let boundary = true;
  tokens.forEach((token, index) => {
    const piece = token.replaceAll("▁", " ");
    const text = piece.trim();
    if (!text || (text.startsWith("<") && text.endsWith(">"))) {
      boundary ||= piece.startsWith(" ");
      return;
    }
    const start = starts[index] ?? 0;
    const end = start + (durations[index] ?? 0);
    const logProb = logProbs[index] ?? 0;
    const last = words.at(-1);
    if (boundary || piece.startsWith(" ") || !last) {
      words.push({ text, start, end, probs: [logProb] });
      boundary = false;
    } else {
      last.text += text;
      last.end = end;
      last.probs.push(logProb);
    }
  });
  return words.map(({ text, start, end, probs }) => {
    const from = Math.max(0, start);
    const confidence = Math.exp(probs.reduce((a, b) => a + b, 0) / probs.length);
    return [text, from, Math.max(end, from), Math.min(1, Math.max(0, confidence))];
  });
}

/** Every word ends before the next one starts (windows can overlap by a piece). */
export function separate(words: Word[]): void {
  for (let i = 0; i + 1 < words.length; i++) {
    const [word, next] = [words[i] as Word, words[i + 1] as Word];
    if (word[2] > next[1]) word[2] = Math.max(word[1], next[1]);
  }
}

/** The level of every 50 ms frame, in dBFS. */
function frameLevels(samples: Float32Array): Float64Array {
  const levels = new Float64Array(Math.floor(samples.length / FRAME));
  for (let f = 0; f < levels.length; f++) {
    let sum = 0;
    for (let i = f * FRAME; i < (f + 1) * FRAME; i++) sum += (samples[i] ?? 0) ** 2;
    levels[f] = 10 * Math.log10(sum / FRAME + 1e-12);
  }
  return levels;
}

/** The frame in [first, last) with the lowest level; the latest one if several tie. */
function quietestCut(levels: Float64Array, first: number, last: number): number {
  let best = first;
  for (let f = first; f < last; f++) if ((levels[f] ?? 0) <= (levels[best] ?? 0)) best = f;
  return best;
}

/** Consecutive [start, end) sample ranges covering the audio, none longer than `maxS`. */
export function windows(samples: Float32Array, maxS: number): [number, number][] {
  const longest = Math.floor((maxS * SAMPLE_RATE) / FRAME);
  const levels = frameLevels(samples);
  const out: [number, number][] = [];
  let start = 0;
  while (start < samples.length) {
    const endFrame = Math.floor(start / FRAME) + longest;
    if (endFrame * FRAME >= samples.length) {
      out.push([start, samples.length]);
      break;
    }
    const first = Math.floor(start / FRAME) + Math.max(1, Math.floor(longest * CUT_FROM));
    const cut = quietestCut(levels, first, endFrame) * FRAME;
    out.push([start, cut]);
    start = cut;
  }
  return out;
}

function isQuiet(samples: Float32Array): boolean {
  const levels = frameLevels(samples);
  return levels.length === 0 || levels.reduce((a, b) => a + b, 0) / levels.length < QUIET_DB;
}

/**
 * Words for a window, timed from the start of the audio. A window that yields nothing though it
 * is not quiet is split at its quietest point near the middle and each half decoded alone.
 */
export function decodeWindow(
  decode: (samples: Float32Array) => Word[],
  samples: Float32Array,
  offset: number,
): Word[] {
  const words = decode(samples).map(
    ([text, start, end, confidence]): Word => [text, offset + start, offset + end, confidence],
  );
  if (words.length || samples.length < 2 * MIN_RETRY_S * SAMPLE_RATE || isQuiet(samples)) {
    return words;
  }
  const levels = frameLevels(samples);
  const middle = Math.floor(levels.length / 2);
  const spread = Math.max(1, Math.floor(levels.length / 5));
  const cut = quietestCut(levels, middle - spread, middle + spread) * FRAME;
  return [
    ...decodeWindow(decode, samples.subarray(0, cut), offset),
    ...decodeWindow(decode, samples.subarray(cut), offset + cut / SAMPLE_RATE),
  ];
}

/** Segments that end at a sentence's end; the rest of the words form the last one. */
export function segments(words: Word[]): Transcript["segments"] {
  const out: Transcript["segments"] = [];
  let current: Word[] = [];
  const close = () => {
    const first = current[0];
    const last = current.at(-1);
    if (!first || !last) return;
    out.push({
      id: crypto.randomUUID(),
      start: first[1],
      end: last[2],
      text: current.map((w) => w[0]).join(" "),
      words: current.map(([text, start, end, confidence]) => ({ text, start, end, confidence })),
    });
    current = [];
  };
  for (const word of words) {
    current.push(word);
    if (SENTENCE_END.some((mark) => word[0].endsWith(mark))) close();
  }
  close();
  return out;
}

/** The model's files in the cache, fetched once with progress. Returns the folder. */
async function modelFolder(progress: Progress): Promise<string> {
  const folder = join(cacheDir(), "models", MODEL.id, MODEL.revision);
  await mkdir(folder, { recursive: true });
  for (const [i, file] of MODEL.files.entries()) {
    const path = join(folder, file);
    if (await stat(path).catch(() => undefined)) continue;
    const url = `https://huggingface.co/${MODEL.repo}/resolve/${MODEL.revision}/${file}`;
    const response = await fetch(url);
    if (!response.ok || !response.body) {
      throw new OpenCaptionsError(`Could not download the speech model (${response.status}).`);
    }
    const size = Number(response.headers.get("content-length")) || 0;
    let got = 0;
    const counted = Readable.fromWeb(response.body as WebStream<Uint8Array>);
    counted.on("data", (chunk: Buffer) => {
      got += chunk.length;
      if (size) {
        progress(
          (i + got / size) / MODEL.files.length,
          `Downloading the speech model, once (${Math.round(got / 1e6)} of ${Math.round(size / 1e6)} MB)`,
        );
      }
    });
    try {
      await pipeline(counted, createWriteStream(`${path}.part`));
      await rename(`${path}.part`, path);
    } catch (error) {
      await rm(`${path}.part`, { force: true });
      throw error;
    }
  }
  return folder;
}

interface SherpaResult {
  tokens: string[];
  timestamps: number[];
  durations: number[];
  ys_log_probs: number[];
}

interface Recognizer {
  createStream(): {
    acceptWaveform(wave: { sampleRate: number; samples: Float32Array }): void;
  };
  decode(stream: unknown): void;
  getResult(stream: unknown): SherpaResult;
}

function recognizer(folder: string): Recognizer {
  let sherpa: { OfflineRecognizer: new (config: unknown) => Recognizer };
  try {
    sherpa = createRequire(import.meta.url)("sherpa-onnx-node");
  } catch (error) {
    const why = String(error instanceof Error ? error.message : error).split("\n")[0];
    throw new OpenCaptionsError(
      `sherpa-onnx, which runs the speech model, could not be loaded (${why}). Reinstall the ` +
        "package, or set OPENCAPTIONS_URL and OPENCAPTIONS_KEY to transcribe on an OpenCaptions server.",
    );
  }
  return new sherpa.OfflineRecognizer({
    featConfig: { sampleRate: SAMPLE_RATE, featureDim: 80 },
    modelConfig: {
      transducer: {
        encoder: join(folder, "encoder.int8.onnx"),
        decoder: join(folder, "decoder.int8.onnx"),
        joiner: join(folder, "joiner.int8.onnx"),
      },
      tokens: join(folder, "tokens.txt"),
      modelType: "nemo_transducer",
      numThreads: availableParallelism(),
    },
  });
}

export async function transcribe(
  source: string,
  request: { language?: string; model?: string },
  progress: Progress,
): Promise<Transcript> {
  if (request.model && request.model !== MODEL.id) {
    throw new OpenCaptionsError(
      `Without a server, the speech model is ${MODEL.id}. For ${request.model}, set ` +
        "OPENCAPTIONS_URL and OPENCAPTIONS_KEY to use an OpenCaptions server.",
    );
  }
  const language = request.language ?? "auto";
  if (language !== "auto" && !MODEL.languages.has(language)) {
    throw new OpenCaptionsError(
      `${MODEL.id} does not transcribe ${language}: it covers 25 European languages. Use an ` +
        "OpenCaptions server with a Whisper model for this one.",
    );
  }
  const folder = await modelFolder(progress);
  progress(0, "Reading the sound");
  const samples = await audioSamples(source);
  const model = recognizer(folder);
  const decode = (window: Float32Array): Word[] => {
    const stream = model.createStream();
    stream.acceptWaveform({ sampleRate: SAMPLE_RATE, samples: window });
    model.decode(stream);
    const r = model.getResult(stream);
    return wordsFromTokens(r.tokens, r.timestamps, r.durations, r.ys_log_probs);
  };
  const duration = samples.length / SAMPLE_RATE;
  const words: Word[] = [];
  for (const [start, end] of windows(samples, WINDOW_S)) {
    for (const word of decodeWindow(decode, samples.subarray(start, end), start / SAMPLE_RATE)) {
      words.push([word[0], word[1], Math.min(word[2], duration), word[3]]);
    }
    progress(
      end / samples.length,
      `Transcribed ${(end / SAMPLE_RATE).toFixed(1)}s of ${duration.toFixed(1)}s`,
    );
  }
  separate(words);
  return {
    schema_version: 1,
    language: language === "auto" ? "en" : language,
    language_detection: language === "auto" ? "auto" : "manual",
    duration,
    segments: segments(words),
  } as Transcript;
}
