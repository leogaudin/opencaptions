/**
 * Picking a preset that has looks (`variants`) deals them to the words at random, so the caption
 * shows what the preset is for without the words being picked one by one; a word can still be given
 * another look from its card. The dealing is the engine's, the same code in the editor, the demo and
 * the app.
 */
import { useCaptionEditor } from "@/lib/engine";
import { presetLook } from "@/lib/presets";
import { useEditorStore } from "@/store/editorStore";
import type { StyleConfig } from "@/types";

function newSeed(): number {
  return crypto.getRandomValues(new Uint32Array(1))[0] ?? 0;
}

export function useApplyPreset(): {
  /** Sets the preset's look, and deals its looks to the words. */
  apply: (config: StyleConfig) => void;
  /** Deals the style's looks to the words again. */
  shuffle: () => void;
} {
  const style = useEditorStore((s) => s.style);
  const setStyle = useEditorStore((s) => s.setStyle);
  const editTranscript = useEditorStore((s) => s.editTranscript);
  const editor = useCaptionEditor();
  const deal = (count: number) => {
    if (editor && count > 0) editTranscript((t) => editor.shuffleVariants(t, count, newSeed()));
  };
  return {
    apply: (config) => {
      setStyle(presetLook(config, style));
      deal(config.variants?.length ?? 0);
    },
    shuffle: () => deal(style.variants?.length ?? 0),
  };
}
