/**
 * Built-in style presets shown in the Editor's preset picker. They are data, in
 * `presets.json`, so the iOS app offers the same ones.
 *
 * The first, Purple Punch, is the application default and equals the API's `StyleConfig()`.
 * The rest are looks of the kind short-form editors offer (a boxed word, a coral pill, a
 * monospace terminal...). Presets using `highlight_box` or `highlight_slide` mark the
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
 * A preset's look: its config without where the caption is, how big it is and how many words
 * a line holds, which belong to the video and the user, so applying a preset must not move,
 * resize or re-break it.
 */
export function presetLook(
  config: StyleConfig,
  current?: Pick<StyleConfig, "align">,
): Partial<StyleConfig> {
  const { position_x, position_y, font_size, words_per_line, ...look } = config;
  void position_x;
  void position_y;
  void font_size;
  void words_per_line;
  // A look aligned to an edge needs the block there: its place is that edge, not the centre.
  return current && current.align !== config.align
    ? { ...look, position_x: positionOnAlign(current.align, config.align, position_x) }
    : look;
}

/** Where `position_x` puts the block's edge, for a caption aligned left or right (a margin). */
export const EDGE_MARGIN = 0.06;

/** Which part of a caption block `position_x` holds, for an alignment: its start, its middle or its end. */
export function blockAnchor(align: StyleConfig["align"]): 0 | 0.5 | 1 {
  return align === "left" ? 0 : align === "right" ? 1 : 0.5;
}

/**
 * The place across the frame that goes with an alignment. A left- or right-aligned block is held by
 * its edge, so changing to or from one moves the block to that edge (or back to the middle);
 * between the centred alignments it stays where the user put it. The iOS app has the same rule in
 * `StyleConfig.positionX(afterAligning:)`.
 */
export function positionOnAlign(
  from: StyleConfig["align"],
  to: StyleConfig["align"],
  x: number,
): number {
  const edge = (a: StyleConfig["align"]) => a === "left" || a === "right";
  if (from === to || !(edge(from) || edge(to))) return x;
  if (to === "left") return EDGE_MARGIN;
  if (to === "right") return 1 - EDGE_MARGIN;
  return 0.5;
}

/**
 * Whether a preset's config is the style currently applied, so the picker can
 * highlight it. Compares only the fields a preset defines as its identity,
 * stroke, shadow, size, place and words per line are tweakable without leaving the preset.
 */
export function presetMatches(a: StyleConfig, b: StyleConfig): boolean {
  return (
    a.font === b.font &&
    a.text_color === b.text_color &&
    a.highlight_colors.join() === b.highlight_colors.join() &&
    a.background === b.background &&
    a.background_color === b.background_color &&
    Math.abs(a.background_opacity - b.background_opacity) < 0.001 &&
    a.animation === b.animation
  );
}
