import assert from "node:assert/strict";
import { describe, test } from "node:test";
import {
  languageFlag,
  languagesForModel,
  startingLanguage,
} from "../../src/lib/transcriptionLanguages.ts";

const all = [
  { code: "de", label: "German" },
  { code: "en", label: "English" },
  { code: "fr", label: "French" },
  { code: "ja", label: "Japanese" },
];
const models = [
  { id: "whisper", label: "Whisper", note: "", languages: null },
  { id: "parakeet", label: "Parakeet", note: "", languages: ["de", "en", "fr"] },
];

describe("the language step", () => {
  test("a model is offered its own languages, and Whisper (none named) all of them", () => {
    assert.deepEqual(
      languagesForModel(all, models, "parakeet").map((l) => l.code),
      ["de", "en", "fr"],
    );
    assert.equal(languagesForModel(all, models, "whisper").length, 4);
    assert.equal(
      languagesForModel(all, models, "unknown-model").length,
      4,
      "an unlisted model takes any",
    );
  });

  test("the choice starts at the remembered language, else the browser's, else the first", () => {
    assert.equal(startingLanguage(all, "fr", ["de-DE"]), "fr");
    assert.equal(startingLanguage(all, null, ["ja-JP", "en"]), "ja");
    assert.equal(
      startingLanguage(all, "auto", ["xx", "de"]),
      "de",
      "the old auto choice is dropped",
    );
    assert.equal(startingLanguage(all, "pl", ["es-ES"]), "de", "nothing matches: the first");
    assert.equal(startingLanguage([], null, ["es-ES"]), "es", "no list: the browser's language");
    assert.equal(startingLanguage([], null, []), "en");
  });

  test("a language has a flag, and the ones without a country a globe", () => {
    assert.equal(languageFlag("fr"), "🇫🇷");
    assert.equal(languageFlag("ja"), "🇯🇵");
    assert.equal(languageFlag("en"), "🇬🇧");
    assert.equal(languageFlag("la"), "🇻🇦");
    assert.equal(languageFlag("zz"), "🌐");
    assert.equal([...languageFlag("cy")].length, 7, "Wales is an emoji tag sequence");
  });
});
