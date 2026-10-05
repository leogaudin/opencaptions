import { type ClassValue, clsx } from "clsx";
import { twMerge } from "tailwind-merge";

/** Merge conditional Tailwind class names and resolve conflicting utilities. */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}

/** `#RRGGBB` as a CSS rgba() at `alpha`; black for anything unparseable. */
export function hexToRgba(hex: string, alpha: number): string {
  const [r = 0, g = 0, b = 0] = (hex.match(/^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i) ?? [])
    .slice(1)
    .map((pair) => Number.parseInt(pair, 16));
  return `rgba(${r},${g},${b},${alpha})`;
}

/** Strip a filename's extension ("clip.final.mp4" → "clip.final"). Used to
 *  derive a default project title from a dropped/picked file. */
export function stripExt(filename: string): string {
  const i = filename.lastIndexOf(".");
  return i > 0 ? filename.slice(0, i) : filename;
}
