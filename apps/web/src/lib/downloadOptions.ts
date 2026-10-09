/**
 * The size, frame rate and background a viewer saves videos with, remembered in
 * this browser as a convenience. A choice a video cannot offer (a size above
 * its own) is resolved by the server to the video's own, so a remembered
 * choice never needs clearing.
 */
import { useSyncExternalStore } from "react";
import type { RenderOptions } from "@/types";

export const DEFAULT_RENDER_OPTIONS: RenderOptions = {
  resolution: "original",
  frame_rate: "original",
  green_screen: false,
};

const KEY = "opencaptions:download-options";

function read(): RenderOptions {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) ?? "{}") as Partial<RenderOptions>;
    return {
      resolution: saved.resolution ?? DEFAULT_RENDER_OPTIONS.resolution,
      frame_rate: saved.frame_rate ?? DEFAULT_RENDER_OPTIONS.frame_rate,
      // Never remembered: a forgotten green screen would turn a later download into captions only.
      green_screen: false,
    };
  } catch {
    return DEFAULT_RENDER_OPTIONS;
  }
}

let current = read();
const listeners = new Set<() => void>();

export function getDownloadOptions(): RenderOptions {
  return current;
}

export function setDownloadOptions(next: Partial<RenderOptions>): void {
  current = { ...current, ...next };
  try {
    localStorage.setItem(KEY, JSON.stringify(current));
  } catch {
    // Not remembered in a private window; still used for this visit.
  }
  for (const l of listeners) l();
}

const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => listeners.delete(l);
};

export function useDownloadOptions(): RenderOptions {
  return useSyncExternalStore(subscribe, getDownloadOptions);
}
