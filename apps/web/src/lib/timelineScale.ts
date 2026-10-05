/** The timeline's scale: how far apart ruler ticks fall, and how far it may zoom. */

/** The most the timeline zooms in, in pixels per second. */
export const MAX_PX_PER_S = 400;

/** Seconds between ruler ticks, from the finest to the coarsest. */
const TICK_STEPS = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600];

/** The finest tick step whose labels stay at least `minSpacing` px apart. */
export function tickStep(pxPerSecond: number, minSpacing = 70): number {
  const step = TICK_STEPS.find((s) => s * pxPerSecond >= minSpacing);
  return step ?? TICK_STEPS[TICK_STEPS.length - 1] ?? 3600;
}

/** A tick's label: whole seconds as `m:ss`, finer steps with a tenth. */
export function formatTick(seconds: number, step: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds - m * 60;
  return step < 1
    ? `${m}:${s.toFixed(1).padStart(4, "0")}`
    : `${m}:${String(Math.round(s)).padStart(2, "0")}`;
}

/** A zoom (pixels per second) kept between "fit" and the most the timeline may zoom. */
export function clampZoom(pxPerSecond: number, fit: number): number {
  return Math.min(Math.max(pxPerSecond, fit), Math.max(fit, MAX_PX_PER_S));
}
