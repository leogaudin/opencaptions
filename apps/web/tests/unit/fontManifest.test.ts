import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { parseFontManifest } from "../../src/lib/fontManifest.ts";

describe("the bundled fonts the browser fetches", () => {
  const manifest = parseFontManifest({
    fonts: ["Inter.ttf", "Montserrat-Black.ttf", "Poppins-ExtraBold.ttf"],
    scripts: ["NotoSansArabic.ttf", "NotoSansThai.ttf"],
  });

  test("the script faces are not among those fetched up front", () => {
    assert.deepEqual(manifest.fonts, [
      "Inter.ttf",
      "Montserrat-Black.ttf",
      "Poppins-ExtraBold.ttf",
    ]);
    assert.deepEqual(manifest.scripts, ["NotoSansArabic.ttf", "NotoSansThai.ttf"]);
  });

  test("a file's rank is its place among all of them, by name, whenever it is fetched", () => {
    assert.equal(manifest.rank("Inter.ttf"), 0);
    assert.equal(manifest.rank("Montserrat-Black.ttf"), 1);
    assert.equal(manifest.rank("NotoSansArabic.ttf"), 2, "a script face stands before Poppins");
    assert.equal(manifest.rank("NotoSansThai.ttf"), 3);
    assert.equal(manifest.rank("Poppins-ExtraBold.ttf"), 4);
  });

  test("an older flat list is all fetched up front", () => {
    const flat = parseFontManifest(["Inter.ttf", "NotoSansArabic.ttf"]);
    assert.deepEqual(flat.fonts, ["Inter.ttf", "NotoSansArabic.ttf"]);
    assert.deepEqual(flat.scripts, []);
    assert.equal(flat.rank("NotoSansArabic.ttf"), 1);
  });

  test("a file that is not listed has no rank", () => {
    assert.equal(manifest.rank("Other.ttf"), -1);
  });
});
