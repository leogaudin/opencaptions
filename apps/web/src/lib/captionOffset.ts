/**
 * Supported caption-offset range in milliseconds. A modest +/-2s window covers
 * real word-alignment drift (which is well under a second in practice, even
 * from a smaller/faster Whisper model) while rejecting nonsensical values.
 * Mirrors the backend bounds on `caption_offset_ms`. The offset itself is applied
 * by the caption engine, for the preview and the export alike.
 */
export const CAPTION_OFFSET_MIN_MS = -2000;
export const CAPTION_OFFSET_MAX_MS = 2000;

/** Clamp an offset (ms) to the supported range. */
export function clampCaptionOffsetMs(offsetMs: number): number {
  return Math.max(CAPTION_OFFSET_MIN_MS, Math.min(CAPTION_OFFSET_MAX_MS, offsetMs));
}
