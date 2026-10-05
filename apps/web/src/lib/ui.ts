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
 * Non-accent icon button per the owner's hierarchy: transparent background,
 * outlined, high-contrast foreground (black in light / white in dark), with the
 * accent-on-hover effect shared by the header's Info and dark-mode buttons.
 * Only the primary action keeps a filled accent — never these.
 */
export const iconButtonClass =
  "inline-flex h-8 w-8 items-center justify-center rounded-md border border-border text-foreground transition-colors hover:bg-accent hover:text-foreground disabled:opacity-50";
