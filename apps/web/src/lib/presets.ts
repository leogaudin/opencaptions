/**
 * Built-in style presets shown in the Editor's preset picker. They are data, in
 * `presets.json`, so the iOS app offers the same ones.
 *
 * The first, Classic, is the application default and equals the API's `StyleConfig()`.
 * The rest are looks of the kind short-form editors offer (a boxed word, a coral pill, a
 * monospace terminal...). Presets using `highlight_box` mark the
 * active word with a filled box instead of recolouring it, so every word stays legible
 * at full contrast.
 */
import presets from "@/lib/presets.json";
import type { StyleConfig } from "@/types";

export interface BuiltinPreset {
  id: string;
  name: string;
  config: StyleConfig;
}

// The data is shared with the iOS app and checked against the API's `StyleConfig`
// by apps/api/tests/test_presets.py; JSON widens the literal unions to `string`.
export const BUILTIN_PRESETS = presets as BuiltinPreset[];

/**
 * Whether a preset's config is the style currently applied, so the picker can
 * highlight it. Compares only the fields a preset defines as its identity —
 * stroke and shadow are tweakable without leaving the preset.
 */
export function presetMatches(a: StyleConfig, b: StyleConfig): boolean {
  return (
    a.font === b.font &&
    a.font_size === b.font_size &&
    a.text_color === b.text_color &&
    a.highlight_color === b.highlight_color &&
    a.background === b.background &&
    a.background_color === b.background_color &&
    Math.abs(a.background_opacity - b.background_opacity) < 0.001 &&
    a.position_x === b.position_x &&
    a.position_y === b.position_y &&
    a.animation === b.animation &&
    a.words_per_line === b.words_per_line
  );
}
