import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { describe, test } from "node:test";

/** The demo's sample clips: what the manifest says is there, and a transcript the engine can draw. */
const DIR = new URL("../../demo-public/demo/", import.meta.url);
const read = (name: string) => JSON.parse(readFileSync(new URL(name, DIR), "utf8"));

interface Word {
  text: string;
  start: number;
  end: number;
}

const manifest = read("clips.json") as {
  clips: {
    id: string;
    video: string;
    transcript: string;
    duration: number;
    language: string;
    credit?: Record<string, string>;
  }[];
};

describe("demo clips", () => {
  test("there are clips, with distinct ids", () => {
    assert.ok(manifest.clips.length >= 1);
    assert.equal(new Set(manifest.clips.map((c) => c.id)).size, manifest.clips.length);
  });

  for (const clip of manifest.clips) {
    describe(clip.id, () => {
      test("its files exist", () => {
        assert.ok(existsSync(new URL(`clips/${clip.video}`, DIR)), clip.video);
        assert.ok(existsSync(new URL(`clips/${clip.transcript}`, DIR)), clip.transcript);
      });

      test("its credit, when it has one, is complete", () => {
        for (const key of ["title", "author", "url", "license", "licenseUrl"]) {
          if (clip.credit) assert.ok(clip.credit[key], `credit.${key}`);
        }
      });

      test("its transcript is in order and inside the video", () => {
        const t = read(`clips/${clip.transcript}`) as {
          language: string;
          segments: { words: Word[] }[];
        };
        assert.equal(t.language, clip.language);
        const words = t.segments.flatMap((s) => s.words);
        assert.ok(words.length > 0);
        let previous = 0;
        for (const w of words) {
          assert.ok(w.text.trim() !== "", "an empty word");
          assert.ok(w.start >= previous && w.end > w.start, `${w.text} is out of order`);
          assert.ok(w.end <= clip.duration + 0.05, `${w.text} ends after the video`);
          previous = w.start;
        }
      });
    });
  }
});
