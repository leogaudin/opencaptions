/**
 * Captioning on this computer, without a server: the word grouping and the window cutting held to
 * what the server does, the output size as the API decides it, and a real save through FFmpeg
 * with captions given (the speech model is not downloaded here).
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFile, mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { geometry, localCaptioner } from "../src/local/index.ts";
import { probe } from "../src/local/media.ts";
import {
  decodeWindow,
  segments,
  separate,
  type Word,
  windows,
  wordsFromTokens,
} from "../src/local/transcribe.ts";
import { TRANSCRIPT } from "./fake-server.ts";

const FIXTURES = new URL(
  "../../ios/OpenCaptionsKit/Tests/OpenCaptionsKitTests/Fixtures/",
  import.meta.url,
);
const CLIP = new URL("../../web/tests/e2e/fixtures/blank-4s.webm", import.meta.url);
const quiet = () => {};

interface TokenCase {
  name: string;
  tokens: { text: string; start: number; end: number; confidence: number }[];
  words: { text: string; start: number; end: number; confidence: number }[];
}

test("tokens make the words the shared cases say, as the server and the app make them", async () => {
  const { cases } = JSON.parse(await readFile(new URL("token-words.json", FIXTURES), "utf8")) as {
    cases: TokenCase[];
  };
  assert.ok(cases.length > 0);
  for (const c of cases) {
    const made = wordsFromTokens(
      c.tokens.map((t) => t.text),
      c.tokens.map((t) => t.start),
      c.tokens.map((t) => t.end - t.start),
      c.tokens.map((t) => Math.log(t.confidence)),
    );
    separate(made);
    assert.deepEqual(
      made.map((w) => w[0]),
      c.words.map((w) => w.text),
      c.name,
    );
    made.forEach(([, start, end, confidence], i) => {
      const want = c.words[i];
      assert.ok(want);
      for (const [got, expected] of [
        [start, want.start],
        [end, want.end],
        [confidence, want.confidence],
      ] as const) {
        assert.ok(Math.abs(got - expected) < 1e-4, `${c.name}: ${got} for ${expected}`);
      }
    });
  }
});

/** Speech-loud noise, with the quiet stretches given in seconds. */
function audio(seconds: number, quietAt: [number, number][]): Float32Array {
  const samples = new Float32Array(seconds * 16_000);
  for (let i = 0; i < samples.length; i++) {
    const t = i / 16_000;
    samples[i] = quietAt.some(([a, b]) => t >= a && t < b) ? 0 : Math.sin(i / 3) * 0.3;
  }
  return samples;
}

test("windows are cut at the quietest moment near their end, and cover everything", () => {
  const samples = audio(50, [[17, 17.5]]);
  const cuts = windows(samples, 20);
  assert.equal(cuts[0]?.[0], 0);
  assert.equal(cuts.at(-1)?.[1], samples.length);
  for (let i = 1; i < cuts.length; i++) assert.equal(cuts[i]?.[0], cuts[i - 1]?.[1]);
  const first = (cuts[0]?.[1] ?? 0) / 16_000;
  assert.ok(first >= 17 && first < 17.5, `cut in the pause, at ${first}s`);
  assert.ok(cuts.every(([a, b]) => b - a <= 20 * 16_000));
});

test("a window that comes back empty though it is not quiet is decoded again in halves", () => {
  const samples = audio(12, [[6, 6.2]]);
  const calls: number[] = [];
  const decode = (window: Float32Array): Word[] => {
    calls.push(window.length / 16_000);
    return window.length === samples.length ? [] : [["word", 0.1, 0.4, 0.9]];
  };
  const words = decodeWindow(decode, samples, 10);
  assert.equal(calls.length, 3, "the window, then its halves");
  assert.equal(words.length, 2);
  assert.ok(Math.abs((words[0]?.[1] ?? 0) - 10.1) < 1e-6, "timed from the start of the audio");
  assert.ok((words[1]?.[1] ?? 0) > 15, "the second half's word after the cut");
  assert.deepEqual(
    decodeWindow(() => [], audio(12, [[0, 12]]), 0),
    [],
    "silence is not retried",
  );
});

test("segments end at a sentence's end", () => {
  const made = segments([
    ["Hello", 0, 0.4, 1],
    ["there.", 0.4, 0.8, 1],
    ["Again", 1, 1.4, 1],
  ]);
  assert.deepEqual(
    made.map((s) => [s.text, s.start, s.end]),
    [
      ["Hello there.", 0, 0.8],
      ["Again", 1, 1.4],
    ],
  );
});

test("the output's size and frame rate are decided as the API decides them", () => {
  const uhd = { width: 3840, height: 2160, fps: 59.94 };
  assert.deepEqual(geometry(uhd, { resolution: "1080" }), { width: 1920, height: 1080, fps: 60 });
  const vertical = { width: 1080, height: 1920, fps: 30 };
  assert.equal(geometry(vertical, { resolution: "720" }).width, 720);
  assert.deepEqual(geometry(vertical, { resolution: "2160" }), {
    width: 2160,
    height: 3840,
    fps: 30,
  });
  const odd = geometry({ width: 1001, height: 1335, fps: 30 }, { resolution: "720" });
  assert.ok(odd.width % 2 === 0 && odd.height % 2 === 0);
  assert.equal(geometry(uhd, { frame_rate: "30" }).fps, 30);
  assert.equal(geometry({ ...vertical, fps: 25 }, { frame_rate: "60" }).fps, 60);
  assert.deepEqual(geometry(vertical, {}), vertical, "original is the source's own");
});

test("a video is captioned on this computer, fixed and saved again, beside the source", async () => {
  const folder = await mkdtemp(join(tmpdir(), "opencaptions-local-"));
  const source = join(folder, "clip.webm");
  await copyFile(CLIP, source);
  const captioner = localCaptioner();
  const result = await captioner.caption(
    { source, look: "Bold", transcript: TRANSCRIPT, resolution: "720" },
    quiet,
  );
  assert.ok(result.done);
  assert.equal(result.project_id, join(folder, "clip.opencaptions.json"));
  assert.equal(result.output, join(folder, "clip.captioned.mp4"));
  const saved = await probe(result.output);
  assert.equal(Math.min(saved.width, saved.height), 720);
  assert.equal((await readFile(result.output)).subarray(4, 8).toString(), "ftyp");

  const { words } = await captioner.readTranscript(result.project_id);
  assert.deepEqual(
    words.map((w) => w.text),
    ["one", "two", "three", "four"],
  );
  await captioner.fixWords(result.project_id, [{ index: 2, count: 2, text: "threefour" }]);
  const style = await captioner.setStyle(result.project_id, undefined, { position_y: 0.5 });
  assert.equal(style.position_y, 0.5);
  assert.equal(style.font, "Montserrat", "the look's settings stay");

  const green = await captioner.save(
    result.project_id,
    { captions_only: true, format: "mov" },
    quiet,
  );
  assert.ok(green.done);
  assert.equal(green.output, join(folder, "clip.captions.mov"));
  const streams = execFileSync("ffprobe", [
    "-v",
    "error",
    "-show_entries",
    "stream=codec_name",
    "-of",
    "csv=p=0",
    green.output,
  ])
    .toString()
    .trim();
  assert.equal(streams, "prores", "the captions alone, with no sound");

  const srt = await captioner.exportSubtitles(result.project_id, "srt");
  assert.equal(srt, join(folder, "clip.captioned.srt"), "named as the server names it");
  assert.match(await readFile(srt, "utf8"), /threefour/);
});

test("without a server a link is refused, and a model it does not have is named", async () => {
  await assert.rejects(
    localCaptioner().caption({ source: "https://example.com/v.mp4" }, quiet),
    /download it first/,
  );
  const folder = await mkdtemp(join(tmpdir(), "opencaptions-local-"));
  const source = join(folder, "clip.webm");
  await copyFile(CLIP, source);
  await assert.rejects(
    localCaptioner().caption({ source, model: "large-v3-turbo" }, quiet),
    /parakeet-ultra/,
  );
});
