import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, beforeEach, test } from "node:test";
import {
  captionVideo,
  exportSubtitles,
  fixWords,
  readTranscript,
  resume,
  setStyle,
} from "../src/captions.ts";
import { api, connectionFromEnv, OpenCaptionsError } from "../src/client.ts";
import { findLook } from "../src/looks.ts";
import { type Fake, KEY, startFake } from "./fake-server.ts";

process.env.OPENCAPTIONS_POLL_MS = "5";

let fake: Fake;
let folder: string;
let video: string;
const quiet = () => {};

before(async () => {
  fake = await startFake();
  folder = await mkdtemp(join(tmpdir(), "opencaptions-"));
  video = join(folder, "reel.mp4");
  await writeFile(video, "not really a video");
});
after(() => fake.close());
beforeEach(() => {
  fake.jobs.takes = 2;
  fake.jobs.fails = undefined;
});

const client = () => api({ url: fake.url, key: KEY });

test("a video is sent, transcribed, styled and saved next to itself", async () => {
  const seen: number[] = [];
  const result = await captionVideo(
    client(),
    { source: video, look: "Bold", style: { position_y: 0.7 }, language: "fr" },
    (fraction) => seen.push(fraction),
  );
  assert.equal(result.done, true);
  assert.ok(result.done);
  assert.equal(result.output, join(folder, "reel.captioned.mp4"));
  assert.match(
    await readFile(result.output, "utf8"),
    /^VIDEO mp4 \?resolution=original&frame_rate=original&green_screen=false/,
  );
  const project = fake.projects.get(result.project_id);
  assert.deepEqual(project?.upload, { name: "reel.mp4", size: 18 });
  assert.equal(project?.title, "reel");
  assert.deepEqual(project?.style_config, { ...findLook("bold").config, position_y: 0.7 });
  assert.ok(
    seen.some((f) => f > 0 && f < 1),
    "progress was reported along the way",
  );
});

test("captions only, in another format and at another size, go where they are asked to", async () => {
  const output = join(folder, "layer.mov");
  const result = await captionVideo(
    client(),
    { source: video, format: "mov", resolution: "1080", captions_only: true, output },
    quiet,
  );
  assert.ok(result.done);
  assert.equal(result.output, output);
  assert.match(
    await readFile(output, "utf8"),
    /^VIDEO mov \?resolution=1080&frame_rate=original&green_screen=true/,
  );
});

test("a given transcript is used instead of transcribing", async () => {
  fake.jobs.fails = "transcribing must not happen";
  fake.jobs.takes = 0;
  const transcript = {
    schema_version: 1,
    language: "en",
    language_detection: "manual" as const,
    duration: 1,
    segments: [],
  };
  await assert.rejects(
    captionVideo(client(), { source: video, transcript }, quiet),
    /must not happen/,
  );
  const sent = fake.patches.at(-1)?.body.transcript;
  assert.deepEqual(sent, transcript);
});

test("a link is sent as a link, and the video is saved in the working folder", async () => {
  const here = process.cwd();
  process.chdir(folder);
  try {
    const result = await captionVideo(
      client(),
      { source: "https://example.com/clips/talk.mp4" },
      quiet,
    );
    assert.ok(result.done);
    assert.equal(result.output, join(folder, "talk.captioned.mp4"));
    assert.equal(
      fake.projects.get(result.project_id)?.video_url,
      "https://example.com/clips/talk.mp4",
    );
  } finally {
    process.chdir(here);
  }
});

test("a job that outlasts the wait hands back a ticket, and the ticket finishes it", async () => {
  fake.jobs.takes = 50;
  const first = await captionVideo(client(), { source: video }, quiet, Date.now() + 30);
  assert.equal(first.done, false);
  assert.ok(!first.done);
  assert.equal(first.ticket.step, "transcribe");
  fake.jobs.takes = 0;
  const done = await resume(client(), JSON.parse(JSON.stringify(first.ticket)), quiet);
  assert.ok(done.done);
  assert.equal(done.output, join(folder, "reel.captioned.mp4"));
});

test("a job that fails says why", async () => {
  fake.jobs.fails = "The speech model could not be loaded";
  await assert.rejects(captionVideo(client(), { source: video }, quiet), {
    name: "Error",
    message: "The speech model could not be loaded",
  });
});

test("a refused key, a missing file and an unknown look are said plainly", async () => {
  const wrong = api({ url: fake.url, key: "oc_wrong" });
  await assert.rejects(captionVideo(wrong, { source: video }, quiet), /refused the key/);
  await assert.rejects(
    captionVideo(client(), { source: join(folder, "nope.mp4") }, quiet),
    /no video at/,
  );
  await assert.rejects(
    captionVideo(client(), { source: video, look: "Sparkly" }, quiet),
    /no look called "Sparkly".*Purple Punch/,
  );
});

test("a server that is not there is named", async () => {
  const gone = api({ url: "http://127.0.0.1:9", key: KEY });
  await assert.rejects(captionVideo(gone, { source: video }, quiet), (error: unknown) => {
    assert.ok(error instanceof OpenCaptionsError);
    assert.match(error.message, /Cannot reach OpenCaptions at http:\/\/127\.0\.0\.1:9/);
    return true;
  });
});

test("the key comes from the environment, and its absence says where to get one", () => {
  assert.deepEqual(connectionFromEnv({ OPENCAPTIONS_KEY: "oc_x" }), {
    url: "http://localhost:5173",
    key: "oc_x",
  });
  assert.deepEqual(
    connectionFromEnv({ OPENCAPTIONS_KEY: "oc_x", OPENCAPTIONS_URL: "https://c.example/" }).url,
    "https://c.example",
  );
  assert.throws(() => connectionFromEnv({}), /Account page/);
});

test("words are read as captioned, and fixed through the engine", async () => {
  const result = await captionVideo(client(), { source: video }, quiet);
  assert.ok(result.done);
  const { lines, words } = await readTranscript(client(), result.project_id);
  assert.deepEqual(
    words.map((w) => w.text),
    ["one", "two", "three", "four"],
  );
  assert.equal(lines.map((l) => l.text).join(" "), "one two three four");
  assert.equal(
    await fixWords(client(), result.project_id, [
      { index: 1, text: "TWO" },
      { index: 3, text: "" },
    ]),
    2,
  );
  const after = await readTranscript(client(), result.project_id);
  assert.deepEqual(
    after.words.map((w) => w.text),
    ["one", "TWO", "three"],
  );
});

test("a look with word looks deals them once there are words", async () => {
  const result = await captionVideo(client(), { source: video, look: "Editorial" }, quiet);
  assert.ok(result.done);
  const transcript = fake.projects.get(result.project_id)?.transcript as {
    segments: { words: { variant?: number | null }[] }[];
  };
  const variants = transcript.segments.flatMap((s) => s.words).map((w) => w.variant);
  assert.ok(
    variants.some((v) => typeof v === "number"),
    "some words were given a look",
  );
});

test("changes alone go over the style a project has", async () => {
  const result = await captionVideo(client(), { source: video, look: "Neon" }, quiet);
  assert.ok(result.done);
  const style = await setStyle(client(), result.project_id, undefined, { font_size: 90 });
  assert.equal(style.font, findLook("Neon").config.font);
  assert.equal(style.font_size, 90);
});

test("subtitles are written next to the video", async () => {
  const result = await captionVideo(client(), { source: video }, quiet);
  assert.ok(result.done);
  const path = await exportSubtitles(client(), result.project_id, "srt", join(folder, "reel"));
  assert.equal(path, join(folder, "reel.srt"));
  assert.match(await readFile(path, "utf8"), /one two/);
});
