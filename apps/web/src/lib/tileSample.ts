/** The sample caption a tile is drawn from. Plain data, so it is tested without the engine. */

/** The transcript a tile is drawn from, as far as it goes: the API's `Transcript` accepts it. */
export interface SampleTranscript {
  schema_version: number;
  language: string;
  language_detection: "manual";
  duration: number;
  segments: {
    id: string;
    words: {
      text: string;
      start: number;
      end: number;
      confidence: number;
      variant: number | null;
    }[];
    start: number;
    end: number;
    text: string;
  }[];
}

export const WORDS = ["Make", "it", "pop"];
export const STEP = 0.4;

/**
 * A sample caption: `words`, each in the look of the same place in `variants` (null or none for the
 * style's own), so a tile can show a preset's mixed looks, or one word in one look.
 */
export function sample(
  words: readonly string[] = WORDS,
  variants: readonly (number | null)[] = [],
): SampleTranscript {
  const timed = words.map((text, i) => ({
    text,
    start: i * STEP,
    end: (i + 1) * STEP,
    confidence: 1,
    variant: variants[i] ?? null,
  }));
  const end = words.length * STEP;
  return {
    schema_version: 1,
    language: "en",
    language_detection: "manual",
    duration: end,
    segments: [{ id: "sample", words: timed, start: 0, end, text: words.join(" ") }],
  };
}
