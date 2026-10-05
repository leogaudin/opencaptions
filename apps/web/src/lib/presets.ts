/**
 * Built-in style presets shown in the Editor's preset picker.
 *
 *   1. Soft Pill    — the application default: subtle, pill behind the line
 *   2. Purple Punch — white words, the spoken one boxed in violet
 *   3. Hot Take     — the same idea loud: display face, oversized, hot pink
 *
 * The last two use `highlight_box`, which marks the active word with a filled box
 * instead of recolouring it, so every word stays legible at full contrast.
 */
import { defaultStyle, type StyleConfig } from "@/types";

export interface BuiltinPreset {
  id: string;
  name: string;
  config: StyleConfig;
}

export const BUILTIN_PRESETS: BuiltinPreset[] = [
  {
    id: "builtin:soft-pill",
    name: "Soft Pill",
    config: defaultStyle,
  },
  {
    id: "builtin:purple-punch",
    name: "Purple Punch",
    config: {
      font: "Poppins",
      font_size: 64,
      text_color: "#FFFFFF",
      highlight_color: "#7C3AED",
      background: "none",
      background_color: "#000000",
      background_opacity: 0.0,
      position_x: 0.5,
      position_y: 0.84,
      animation: "highlight_box",
      words_per_line: 3,
      word_spacing: 0,
      stroke_width: 0,
      stroke_color: "#000000",
      shadow_blur: 10,
      shadow_color: "#000000A0",
    },
  },
  {
    id: "builtin:hot-take",
    name: "Hot Take",
    config: {
      font: "Anton",
      font_size: 104,
      text_color: "#FFFFFF",
      highlight_color: "#FF1F6B",
      background: "none",
      background_color: "#000000",
      background_opacity: 0.0,
      position_x: 0.5,
      position_y: 0.5,
      animation: "highlight_box",
      words_per_line: 2,
      word_spacing: 0,
      stroke_width: 6,
      stroke_color: "#000000",
      shadow_blur: 16,
      shadow_color: "#000000C0",
    },
  },
];

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
