/**
 * Where FFmpeg is found. A desktop app starts the server with a short PATH, so the folder can be
 * named, and a Mac's Homebrew folders are tried after PATH. Fake programs stand in for FFmpeg.
 */
import assert from "node:assert/strict";
import { chmod, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { ffmpegProgram } from "../src/local/media.ts";

async function folderWith(...names: string[]): Promise<string> {
  const folder = await mkdtemp(join(tmpdir(), "opencaptions-ffmpeg-"));
  for (const name of names) {
    await writeFile(join(folder, name), "#!/bin/sh\n");
    await chmod(join(folder, name), 0o755);
  }
  return folder;
}

test("the folder OPENCAPTIONS_FFMPEG names wins over the PATH", async () => {
  const named = await folderWith("ffmpeg", "ffprobe");
  const onPath = await folderWith("ffmpeg", "ffprobe");
  const env = { OPENCAPTIONS_FFMPEG: named, PATH: onPath };
  assert.equal(ffmpegProgram("ffmpeg", { env }), join(named, "ffmpeg"));
  assert.equal(ffmpegProgram("ffprobe", { env }), join(named, "ffprobe"));
});

test("a folder without the program is named in the error, not skipped", async () => {
  const named = await folderWith("ffmpeg");
  const env = { OPENCAPTIONS_FFMPEG: named, PATH: await folderWith("ffmpeg", "ffprobe") };
  assert.throws(
    () => ffmpegProgram("ffprobe", { env }),
    (error: Error) => error.message.includes(named) && /no ffprobe/.test(error.message),
  );
});

test("an empty OPENCAPTIONS_FFMPEG is the same as none", async () => {
  const onPath = await folderWith("ffmpeg");
  const env = { OPENCAPTIONS_FFMPEG: "  ", PATH: onPath };
  assert.equal(ffmpegProgram("ffmpeg", { env }), "ffmpeg");
});

test("a program on the PATH is started by its name", async () => {
  const onPath = await folderWith("ffmpeg");
  const homebrew = await folderWith("ffmpeg");
  const env = { PATH: onPath };
  assert.equal(ffmpegProgram("ffmpeg", { env, fallbacks: [homebrew] }), "ffmpeg");
});

test("without it on the PATH, the Homebrew folders are tried in order", async () => {
  const empty = await folderWith();
  const first = await folderWith("ffmpeg");
  const second = await folderWith("ffmpeg", "ffprobe");
  const env = { PATH: empty };
  const fallbacks = [await folderWith(), first, second];
  assert.equal(ffmpegProgram("ffmpeg", { env, fallbacks }), join(first, "ffmpeg"));
  assert.equal(ffmpegProgram("ffprobe", { env, fallbacks }), join(second, "ffprobe"));
});

test("with FFmpeg nowhere, the name is kept, so the install message is the error", async () => {
  const env = { PATH: await folderWith() };
  assert.equal(ffmpegProgram("ffmpeg", { env, fallbacks: [await folderWith()] }), "ffmpeg");
});

test("the Homebrew folders are tried on a Mac and nowhere else", async () => {
  const env = { PATH: await folderWith() };
  assert.equal(ffmpegProgram("ffmpeg", { env, platform: "linux" }), "ffmpeg");
});
