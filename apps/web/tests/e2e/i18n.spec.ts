import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";

/**
 * Every text the interface shows through `t("...")`, `translate("...")` or `msg("...")` has a
 * translation in every language, with the same {placeholders}, and no translation is left for a text
 * that is gone. No browser: this reads the source.
 */
const SRC = fileURLToPath(new URL("../../src", import.meta.url));
const LANGUAGES = ["fr", "es", "de", "pl", "pt", "it", "ru", "tr", "ja", "ko", "zh", "id"];

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name === "locales" ? [] : sources(path);
    return /\.(ts|tsx)$/.test(name) && name !== "i18n.ts" && !name.includes("generated")
      ? [path]
      : [];
  });
}

function usedTexts(): Set<string> {
  const used = new Set<string>();
  const call = /(?<![\w.$])(?:t|translate|msg)\(\s*"((?:[^"\\]|\\.)*)"/g;
  for (const file of sources(SRC)) {
    for (const match of readFileSync(file, "utf8").matchAll(call)) {
      used.add(JSON.parse(`"${match[1]}"`) as string);
    }
  }
  return used;
}

const placeholders = (text: string): string[] => (text.match(/\{\w+\}/g) ?? []).sort();

test.describe("Translations", () => {
  const used = usedTexts();

  test("there are texts to translate", () => {
    expect(used.size).toBeGreaterThan(100);
  });

  for (const language of LANGUAGES) {
    test(`${language} has every text, with its placeholders, and nothing else`, () => {
      const table = JSON.parse(
        readFileSync(join(SRC, "locales", `${language}.json`), "utf8"),
      ) as Record<string, string>;
      const missing = [...used].filter((text) => !(text in table));
      expect(missing, "texts without a translation").toEqual([]);
      const stale = Object.keys(table).filter((text) => !used.has(text));
      expect(stale, "translations of texts that are gone").toEqual([]);
      for (const text of used) {
        expect(placeholders(table[text] ?? ""), `placeholders of “${text}”`).toEqual(
          placeholders(text),
        );
      }
    });
  }
});
