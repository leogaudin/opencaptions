import type { Transcript } from "@/types";

/**
 * Supported caption-offset range in milliseconds. A modest +/-2s window covers
 * real word-alignment drift (which is well under a second in practice, even
 * from a smaller/faster Whisper model) while rejecting nonsensical values.
 * Mirrors the backend bounds on `caption_offset_ms`.
 */
export const CAPTION_OFFSET_MIN_MS = -2000;
export const CAPTION_OFFSET_MAX_MS = 2000;

/** Clamp an offset (ms) to the supported range. */
export function clampCaptionOffsetMs(offsetMs: number): number {
  return Math.max(CAPTION_OFFSET_MIN_MS, Math.min(CAPTION_OFFSET_MAX_MS, offsetMs));
}

/**
 * Shift every caption timing by a global offset, so the in-browser preview
 * matches the exported video.
 *
 * This is the client-side twin of the backend's
 * `app.services.caption_offset.apply_caption_offset`. The render pipeline shifts
 * the transcript in Python before hashing and handing it to the engine; the
 * preview shifts it here before handing it to the engine's WebAssembly build.
 * The engine never learns about the offset, so both draw the same captions.
 *
 * A positive `offsetMs` delays captions (shows them later); a negative value
 * advances them. Shifted times are clamped to `>= 0` and `duration` is left
 * untouched (it is the fixed video length, not a caption time). `offsetMs === 0`
 * returns the input unchanged so nothing re-renders needlessly.
 */
export function applyCaptionOffset(transcript: Transcript, offsetMs: number): Transcript {
  if (offsetMs === 0) return transcript;
  const shift = offsetMs / 1000;
  const shiftTime = (value: number): number => Math.max(0, value + shift);
  return {
    ...transcript,
    segments: transcript.segments.map((seg) => ({
      ...seg,
      start: shiftTime(seg.start),
      end: shiftTime(seg.end),
      words: seg.words.map((w) => ({ ...w, start: shiftTime(w.start), end: shiftTime(w.end) })),
    })),
  };
}
