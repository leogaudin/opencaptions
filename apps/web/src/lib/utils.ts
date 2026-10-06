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

/** A size for people: "980 B", "12.4 MB", "1.3 GB" (decimal, as the phone shows file sizes). */
export function formatBytes(bytes: number): string {
  if (bytes < 1000) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`;
}
