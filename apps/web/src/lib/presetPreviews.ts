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
import { createCaptionRenderer } from "@/lib/engine";
import type { BuiltinPreset } from "@/lib/presets";
import type { Transcript } from "@/types";

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

async function draw(presets: readonly BuiltinPreset[]): Promise<Record<string, string>> {
  const renderer = await createCaptionRenderer();
  const transcript = sample();
  await Promise.all(presets.map((p) => renderer.loadFont(p.config.font)));
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
  for (const preset of presets) {
    renderer.setScene({
      transcript,
      style: {
        ...preset.config,
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
    const update = renderer.render(at);
    if (!update) continue;
    fullCtx.clearRect(0, 0, FRAME.width, FRAME.height);
    fullCtx.putImageData(update.image, 0, update.top);
    cropCtx.clearRect(0, 0, CROP.width, CROP.height);
    cropCtx.drawImage(full, CROP.x, CROP.y, CROP.width, CROP.height, 0, 0, CROP.width, CROP.height);
    out[preset.id] = crop.toDataURL("image/png");
  }
  return out;
}

let cached: Promise<Record<string, string>> | null = null;

/** The tiles, drawn once per page load. A failure is not remembered, so the next ask tries again. */
export function presetPreviews(presets: readonly BuiltinPreset[]): Promise<Record<string, string>> {
  cached ??= draw(presets);
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
