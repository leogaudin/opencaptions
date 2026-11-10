/**
 * The style's font, for captioning without a server: a bundled face when there is one, else the
 * family from Google Fonts at its weight nearest 800, fetched once into the cache. The same choice
 * as the API's (`apps/api/app/services/fonts.py`), so a look draws the same on both.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { addFont, hasFont } from "../engine.ts";
import { cacheDir } from "./cache.ts";

const CATALOG_URL = "https://fonts.google.com/metadata/fonts";
const CSS_URL = "https://fonts.googleapis.com/css2";
// The CSS API picks the format from the client: one it does not take for a browser gets
// TrueType, which the engine reads and woff2 is not.
const HEADERS = { "User-Agent": "OpenCaptions" };
const TARGET_WEIGHT = 800;

/** The family's upright weight nearest 800; ties go to the heavier one. */
export function nearestWeight(styles: Record<string, unknown>): number {
  const upright = Object.keys(styles)
    .filter((k) => /^\d+$/.test(k))
    .map(Number);
  if (upright.length === 0) return 400;
  return upright.reduce((best, w) => {
    const d = Math.abs(w - TARGET_WEIGHT) - Math.abs(best - TARGET_WEIGHT);
    return d < 0 || (d === 0 && w > best) ? w : best;
  });
}

async function weightOf(family: string): Promise<number | undefined> {
  const path = join(cacheDir(), "fonts", "catalog.json");
  let weights: Record<string, number>;
  try {
    weights = JSON.parse(await readFile(path, "utf8"));
  } catch {
    const response = await fetch(CATALOG_URL, { headers: HEADERS });
    if (!response.ok) return undefined;
    const data = JSON.parse((await response.text()).replace(/^\)\]\}'/, "")) as {
      familyMetadataList: { family: string; fonts?: Record<string, unknown> }[];
    };
    weights = Object.fromEntries(
      data.familyMetadataList.map((f) => [f.family, nearestWeight(f.fonts ?? {})]),
    );
    await mkdir(join(cacheDir(), "fonts"), { recursive: true });
    await writeFile(path, JSON.stringify(weights));
  }
  return weights[family];
}

async function download(family: string): Promise<Uint8Array | undefined> {
  const weight = await weightOf(family);
  if (weight === undefined) return undefined;
  const css = await fetch(`${CSS_URL}?family=${encodeURIComponent(`${family}:wght@${weight}`)}`, {
    headers: HEADERS,
  });
  if (!css.ok) return undefined;
  const url = /url\((https:\/\/fonts\.gstatic\.com\/[^)]+)\)/.exec(await css.text());
  if (!url?.[1]) return undefined;
  const font = await fetch(url[1], { headers: HEADERS });
  return font.ok ? new Uint8Array(await font.arrayBuffer()) : undefined;
}

/**
 * Makes `family` drawable. False when it is neither bundled nor to be had: the engine then draws
 * its default face, as the server does in the same case.
 */
export async function ensureFont(family: string): Promise<boolean> {
  if (await hasFont(family)) return true;
  const slug = family.replace(/[^A-Za-z0-9]+/g, "-");
  const path = join(cacheDir(), "fonts", `${slug}.ttf`);
  let bytes: Uint8Array | undefined;
  try {
    bytes = await readFile(path);
  } catch {
    bytes = await download(family).catch(() => undefined);
    if (bytes) {
      await mkdir(join(cacheDir(), "fonts"), { recursive: true });
      await writeFile(path, bytes);
    }
  }
  return bytes !== undefined && (await addFont(family, bytes));
}
