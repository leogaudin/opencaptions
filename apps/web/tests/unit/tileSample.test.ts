import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { STEP, sample } from "../../src/lib/tileSample.ts";

describe("the sample caption a tile is drawn from", () => {
  it("is three plain words by default", () => {
    const words = sample().segments[0]?.words ?? [];
    assert.deepEqual(
      words.map((w) => w.text),
      ["Make", "it", "pop"],
    );
    assert.ok(
      words.every((w) => w.variant === null),
      "every word in the style's own look",
    );
  });

  it("gives each word the look at its place, as a preset's tile_variants say", () => {
    const words = sample(undefined, [null, 0, 2]).segments[0]?.words ?? [];
    assert.deepEqual(
      words.map((w) => w.variant),
      [null, 0, 2],
    );
  });

  it("can be one word in one look, for the word card's tiles", () => {
    const t = sample(["Pourquoi"], [3]);
    assert.equal(t.segments[0]?.words.length, 1);
    assert.equal(t.segments[0]?.words[0]?.variant, 3);
    assert.equal(t.duration, STEP);
  });

  it("leaves out looks it was not given", () => {
    const words = sample(["a", "b", "c"], [1]).segments[0]?.words ?? [];
    assert.deepEqual(
      words.map((w) => w.variant),
      [1, null, null],
    );
  });
});
