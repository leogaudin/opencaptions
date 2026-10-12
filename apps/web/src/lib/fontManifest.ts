/**
 * Which of the engine's bundled font files the browser fetches up front and which it fetches only
 * when a caption needs them, and the place each file has among them all. The engine tries the
 * bundled faces in the order of their file names (as the render server does), whenever each
 * arrived, so a face fetched late is registered at its rank.
 *
 * `fonts.json` is written by the web Dockerfile and `scripts/demo-engine.sh`: the files the
 * engine says are script faces (those named `NotoSans*`, which a test in the engine holds to its
 * own table) under `scripts`, the rest under `fonts`. An older flat list is all fetched up front.
 */
export type FontManifestFile = string[] | { fonts: string[]; scripts: string[] };

export interface FontManifest {
  /** Fetched with the engine. */
  fonts: string[];
  /** Fetched when a caption has letters of their script. */
  scripts: string[];
  /** The place of `file` among all the files, in the order of their names. */
  rank(file: string): number;
}

export function parseFontManifest(raw: FontManifestFile): FontManifest {
  const { fonts, scripts } = Array.isArray(raw) ? { fonts: raw, scripts: [] } : raw;
  const all = [...fonts, ...scripts].sort();
  return { fonts, scripts, rank: (file) => all.indexOf(file) };
}
