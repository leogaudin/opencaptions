/**
 * The choices of the style panel's Background and Animation tabs, and how each is applied.
 * The iOS app's counterpart is `StyleConfig.withBackground` in OpenCaptionsKit.
 */
import { msg } from "@/lib/i18n";
import type { Animation, CaptionBackground, StyleConfig } from "@/types";

export const BACKGROUNDS: readonly CaptionBackground[] = ["none", "solid", "pill"];
export const ANIMATIONS: readonly Animation[] = [
  "word_highlight",
  "highlight_box",
  "word_pop",
  "word_fade",
  "word_sweep",
  "word_underline",
  "typewriter",
  "none",
  "word_bounce",
  "lyric_focus",
  "highlight_slide",
  "line_bar",
  "stickers",
];

export const BACKGROUND_NAMES: Record<CaptionBackground, string> = {
  none: msg("None"),
  solid: msg("Solid"),
  pill: msg("Pill"),
};

export const ANIMATION_NAMES: Record<Animation, string> = {
  word_highlight: msg("Highlight"),
  highlight_box: msg("Box"),
  word_pop: msg("Pop"),
  word_fade: msg("Fade"),
  word_sweep: msg("Karaoke"),
  word_underline: msg("Underline"),
  typewriter: msg("Typewriter"),
  none: msg("None"),
  word_bounce: msg("Bounce"),
  lyric_focus: msg("Focus"),
  highlight_slide: msg("Slide"),
  line_bar: msg("Progress"),
  stickers: msg("Stickers"),
};

/** How many highlight colours a style holds, the API's limit. */
export const MAX_HIGHLIGHT_COLORS = 4;

export const CASES: readonly StyleConfig["text_case"][] = ["none", "upper"];
export const CASE_NAMES: Record<StyleConfig["text_case"], string> = {
  none: msg("Normal"),
  upper: msg("Uppercase"),
};

/** A background with no opacity would show nothing, so choosing one gives it a visible opacity. */
export const VISIBLE_BACKGROUND_OPACITY = 0.7;

export function withBackground(style: StyleConfig, background: CaptionBackground): StyleConfig {
  const opacity =
    background !== "none" && style.background_opacity < 0.05
      ? VISIBLE_BACKGROUND_OPACITY
      : style.background_opacity;
  return { ...style, background, background_opacity: opacity };
}
