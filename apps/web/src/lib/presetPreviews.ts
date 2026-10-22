/**
 * What each preset looks like, drawn by the engine: the code that draws the preview and the
 * export, so a tile cannot disagree with the result, in the preset's own font, colours and
 * highlight. The same approach as the iOS app's preset tiles.
 *
 * A sample caption is laid out in a phone-shaped frame (style sizes are tuned to a tall frame,
 * so a short one would make the text tiny) and the band around the caption is kept. Every tile
 * is drawn at one size: applying a preset keeps the user's own size, so the tiles compare looks.
 */
import { useEffect, useState } from "react";
import { type CaptionRenderer, createCaptionRenderer } from "@/lib/engine";
import type { BuiltinPreset } from "@/lib/presets";
import { STEP, sample, WORDS } from "@/lib/tileSample";
import type { StyleConfig } from "@/types";

/**
 * The plain card a tile sits on, the same dark in light and dark mode: captions are mostly white,
 * so they need a dark ground to be seen in both. (Paper, which has dark text, brings its own pill.)
 */
export const TILE_CARD = "#232736";

const FRAME = { width: 540, height: 960 };
const CROP = { x: 90, y: 380, width: 360, height: 200 };
const TILE_FONT_SIZE = 64;
let shared: Promise<CaptionRenderer> | null = null;

/** One engine for every tile; the scenes it draws are set and drawn without waiting in between. */
function renderer(): Promise<CaptionRenderer> {
  shared ??= createCaptionRenderer();
  shared.catch(() => {
    shared = null;
  });
  return shared;
}

/** A look to draw a tile of, by the id its tile is known by. */
export interface Look {
  id: string;
  config: StyleConfig;
  /** The sample words' own looks (see `sample`), and the words: the tile's three by default. */
  variants?: readonly (number | null)[];
  words?: readonly string[];
}

/** Tiles for any looks, by id: a sample caption drawn in each by the engine. */
export async function drawLooks(looks: readonly Look[]): Promise<Record<string, string>> {
  const engine = await renderer();
  // Every font a tile is drawn with: the style's, and those of the looks its words may wear.
  const fonts = looks.flatMap((l) => [
    l.config.font,
    ...(l.config.variants ?? []).flatMap((v) => (v.font ? [v.font] : [])),
  ]);
  await Promise.all([...new Set(fonts)].map((f) => engine.loadFont(f)));
  const full = document.createElement("canvas");
  full.width = FRAME.width;
  full.height = FRAME.height;
  const crop = document.createElement("canvas");
  crop.width = CROP.width;
  crop.height = CROP.height;
  const fullCtx = full.getContext("2d");
  const cropCtx = crop.getContext("2d");
  const out: Record<string, string> = {};
  if (!fullCtx || !cropCtx) return out;
  for (const look of looks) {
    const words = look.words ?? WORDS;
    // The middle word is being spoken: the highlight and the animation are in view.
    const at = STEP * (words.length / 2);
    engine.setScene({
      transcript: sample(words, look.variants),
      style: {
        ...look.config,
        font_size: TILE_FONT_SIZE,
        position_x: 0.5,
        position_y: 0.5,
        // A tile shows the look, centred in its frame: a block held by its left or right edge would
        // start at the middle of it and run off the side.
        align: look.config.align === "justify" ? "justify" : "center",
        words_per_line: words.length,
      },
      width: FRAME.width,
      height: FRAME.height,
      caption_offset_ms: 0,
    });
    // A new scene's first frame is the whole frame.
    const update = engine.render(at);
    if (!update) continue;
    fullCtx.clearRect(0, 0, FRAME.width, FRAME.height);
    fullCtx.putImageData(update.image, 0, update.top);
    cropCtx.clearRect(0, 0, CROP.width, CROP.height);
    cropCtx.drawImage(full, CROP.x, CROP.y, CROP.width, CROP.height, 0, 0, CROP.width, CROP.height);
    out[look.id] = crop.toDataURL("image/png");
  }
  return out;
}

let cached: Promise<Record<string, string>> | null = null;

/** The tiles, drawn once per page load. A failure is not remembered, so the next ask tries again. */
export function presetPreviews(presets: readonly BuiltinPreset[]): Promise<Record<string, string>> {
  cached ??= drawLooks(
    presets.map((p) => ({ id: p.id, config: p.config, variants: p.tile_variants })),
  );
  cached.catch(() => {
    cached = null;
  });
  return cached;
}

/** The tiles by preset id, or null until drawn (or if the engine could not be loaded). */
export function usePresetPreviews(
  presets: readonly BuiltinPreset[],
): Record<string, string> | null {
  const [previews, setPreviews] = useState<Record<string, string> | null>(null);
  useEffect(() => {
    let live = true;
    presetPreviews(presets).then(
      (p) => live && setPreviews(p),
      (e: unknown) => console.error("preset previews failed", e),
    );
    return () => {
      live = false;
    };
  }, [presets]);
  return previews;
}

/**
 * Tiles for looks that change as the style does (the choices of one setting, each in the
 * caption's current look). `key` names what the looks depend on, so they are drawn again only
 * when it changes. Null until drawn.
 */
export function useLookPreviews(
  looks: readonly Look[],
  key: string,
): Record<string, string> | null {
  const [previews, setPreviews] = useState<Record<string, string> | null>(null);
  // biome-ignore lint/correctness/useExhaustiveDependencies: `key` stands for the looks
  useEffect(() => {
    let live = true;
    drawLooks(looks).then(
      (tiles) => live && setPreviews(tiles),
      (e: unknown) => console.error("style previews failed", e),
    );
    return () => {
      live = false;
    };
  }, [key]);
  // The tiles of the last look stay until the new ones are drawn, so they do not blink.
  return previews;
}

/**
 * A word drawn in each look a style offers: the style's own, then each of its variants, one tile
 * each (keyed `base`, `0`, `1`...). Null until drawn. `key` names what they depend on.
 */
export function useWordLooks(
  config: StyleConfig,
  text: string | null,
  key: string,
): Record<string, string> | null {
  const looks: Look[] =
    text === null || !config.variants?.length
      ? []
      : [null, ...config.variants.keys()].map((variant) => ({
          id: variant === null ? "base" : String(variant),
          config,
          words: [text],
          variants: [variant],
        }));
  return useLookPreviews(looks, `${key}|${text}`);
}
