/**
 * Shared UI class fragments — single source of truth so the header and the page
 * content below it can't drift apart.
 */

/**
 * App-shell horizontal rhythm: full-bleed width with responsive side padding.
 * Applied identically to the header's inner row and to every page's outer
 * wrapper, so their left/right edges align at every viewport width AND the nav
 * cluster sits a deliberate, constant inset from the viewport edge — instead of
 * drifting inward behind the old centred `container` max-width cap.
 */
export const shellX = "px-4 sm:px-6 lg:px-8";

/**
 * Non-accent icon button: a round control on the muted surface, as in the iOS app. Only the
 * primary action keeps the filled yellow accent.
 */
export const iconButtonClass =
  "inline-flex h-9 w-9 items-center justify-center rounded-full bg-muted text-foreground transition-colors hover:bg-muted/70 disabled:opacity-50";
