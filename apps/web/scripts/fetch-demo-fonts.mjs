#!/usr/bin/env node
// Fetches the Google Fonts families the built-in presets use that the engine does not bundle, as
// TrueType at the weight nearest 800 (what the server and the iOS app ask for), into
// demo-public/demo/fonts/<slug>.ttf. They are committed: the demo build reads files, not Google.
// Run again, and commit, when a preset changes its font.
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "demo-public/demo/fonts");
mkdirSync(out, { recursive: true });

const presets = JSON.parse(readFileSync(join(root, "src/lib/presets.json"), "utf8"));
const bundled = new Set(["Inter", "Poppins", "Montserrat"]); // apps/engine/fonts
const families = [...new Set(presets.map((p) => p.config.font))].filter((f) => !bundled.has(f));
const WEIGHTS = [800, 900, 700, 600, 500, 400];

export const slug = (family) => family.replace(/[^A-Za-z0-9]+/g, "-");

async function fetchFamily(family) {
  for (const weight of WEIGHTS) {
    const css = await fetch(
      `https://fonts.googleapis.com/css2?family=${encodeURIComponent(`${family}:wght@${weight}`)}`,
      // Not a browser, so the answer is TrueType and not woff2.
      { headers: { "user-agent": "OpenCaptions" } },
    );
    if (!css.ok) continue;
    const url = /url\((https:\/\/fonts\.gstatic\.com\/[^)]+)\)/.exec(await css.text())?.[1];
    if (!url) continue;
    const font = await fetch(url);
    if (font.ok) return Buffer.from(await font.arrayBuffer());
  }
  throw new Error(`no TrueType found for ${family}`);
}

for (const family of families) {
  const data = await fetchFamily(family);
  writeFileSync(join(out, `${slug(family)}.ttf`), data);
  console.log(`${family}: ${(data.length / 1024).toFixed(0)} KB`);
}
console.log(`${readdirSync(out).length} files in ${out}`);
