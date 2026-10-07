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
import type { StyleConfig, Transcript } from "@/types";

/**
 * The plain card a tile sits on, the same dark in light and dark mode: captions are mostly white,
 * so they need a dark ground to be seen in both. (Paper, which has dark text, brings its own pill.)
 */
export const TILE_CARD = "#232736";

const FRAME = { width: 540, height: 960 };
const CROP = { x: 90, y: 380, width: 360, height: 200 };
const TILE_FONT_SIZE = 64;
const WORDS = ["Make", "it", "pop"];
const STEP = 0.4;

function sample(): Transcript {
  const words = WORDS.map((text, i) => ({
    text,
    start: i * STEP,
    end: (i + 1) * STEP,
    confidence: 1,
  }));
  const end = WORDS.length * STEP;
  return {
    schema_version: 1,
    language: "en",
    language_detection: "manual",
    duration: end,
    segments: [{ id: "sample", words, start: 0, end, text: WORDS.join(" ") }],
  };
}

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
}

/** Tiles for any looks, by id: a sample caption drawn in each by the engine. */
export async function drawLooks(looks: readonly Look[]): Promise<Record<string, string>> {
  const engine = await renderer();
  const transcript = sample();
  await Promise.all([...new Set(looks.map((l) => l.config.font))].map((f) => engine.loadFont(f)));
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
  // The middle word is being spoken: the highlight and the animation are in view.
  const at = STEP * 1.5;
  for (const look of looks) {
    engine.setScene({
      transcript,
      style: {
        ...look.config,
        font_size: TILE_FONT_SIZE,
        position_x: 0.5,
        position_y: 0.5,
        words_per_line: WORDS.length,
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
  cached ??= drawLooks(presets.map((p) => ({ id: p.id, config: p.config })));
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
