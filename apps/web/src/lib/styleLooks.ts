/**
 * The choices of the style panel's Background and Animation tabs, and how each is applied.
 * The iOS app's counterpart is `StyleConfig.withBackground` in OpenCaptionsKit.
 */
import type { Animation, CaptionBackground, StyleConfig } from "@/types";

export const BACKGROUNDS: readonly CaptionBackground[] = ["none", "solid", "pill"];
export const ANIMATIONS: readonly Animation[] = [
  "word_highlight",
  "highlight_box",
  "word_pop",
  "word_fade",
];

export const ANIMATION_NAMES: Record<Animation, string> = {
  word_highlight: "Highlight",
  highlight_box: "Box",
  word_pop: "Pop",
  word_fade: "Fade",
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
