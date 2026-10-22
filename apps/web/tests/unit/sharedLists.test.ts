import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, test } from "node:test";
import { languageFlag } from "../../src/lib/transcriptionLanguages.ts";

// Lists every side holds, each written once in the engine's testdata and tested on every side.
const shared = <T>(file: string): T =>
  JSON.parse(readFileSync(new URL(`../../../engine/testdata/${file}`, import.meta.url), "utf8"));

describe("the lists shared with the API, the engine and the phone", () => {
  test("the animations the style panel lists are the shared list, in order", () => {
    // Read from the source: the module imports through the app's `@/` alias, which a node test cannot.
    const source = readFileSync(new URL("../../src/lib/styleLooks.ts", import.meta.url), "utf8");
    const names = source.slice(
      source.indexOf("ANIMATION_NAMES"),
      source.indexOf("};", source.indexOf("ANIMATION_NAMES")),
    );
    const listed = [...names.matchAll(/^\s+(\w+): msg\(/gm)].map((m) => m[1]);
    assert.deepEqual(listed, shared<string[]>("animations.json"));
  });

  test("a language's flag is its shared country's", () => {
    const regions = shared<Record<string, string>>("language-regions.json");
    for (const [code, region] of Object.entries(regions)) {
      const flag = String.fromCodePoint(
        ...[...region].map((c) => 0x1f1e6 + c.charCodeAt(0) - 0x41),
      );
      assert.equal(languageFlag(code), flag, code);
    }
    assert.equal(languageFlag("bo"), "\u{1F310}", "a language with no country gets a globe");
  });
});
