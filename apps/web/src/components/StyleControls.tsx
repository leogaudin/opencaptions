/**
 * StyleControls: pick a preset, then optionally tweak it in a Customize panel.
 *
 * Continuous controls (colours, most sliders) route through a rAF-throttled
 * setter so dragging re-lays out the preview at most once a frame.
 * Discrete controls dispatch immediately — there is nothing to coalesce.
 */

import { CaptionOffsetControl } from "@/components/CaptionOffsetControl";
import { Disclosure } from "@/components/Disclosure";
import { FontPicker } from "@/components/FontPicker";
import { PresetStrip } from "@/components/PresetStrip";
import { ColorField, Field, Segmented, SelectField, SliderField } from "@/components/StyleFields";
import { BUILTIN_PRESETS, presetLook, presetMatches } from "@/lib/presets";
import { useThrottledPatch } from "@/lib/useThrottledPatch";
import { useEditorStore } from "@/store/editorStore";
import type { Animation, CaptionBackground, StyleConfig } from "@/types";

const BACKGROUNDS: CaptionBackground[] = ["none", "solid", "pill"];
const ANIMATIONS: Animation[] = ["word_highlight", "highlight_box", "word_pop", "word_fade"];

export function StyleControls() {
  const style = useEditorStore((s) => s.style);
  const setStyle = useEditorStore((s) => s.setStyle);
  const setStyleThrottled = useThrottledPatch<StyleConfig>(setStyle);

  // The active preset is whichever built-in's config matches the current style,
  // so the picked one can be highlighted in the strip.
  const activePresetId = BUILTIN_PRESETS.find((p) => presetMatches(p.config, style))?.id;

  return (
    <div className="rounded-lg border border-border bg-card p-4 shadow-xs">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-xs font-bold uppercase tracking-wider text-muted-foreground">
          Caption style
        </h2>
      </div>

      <PresetStrip activeId={activePresetId} onPick={(config) => setStyle(presetLook(config))} />

      <FontPicker value={style.font} onChange={(font) => setStyle({ font })} />

      <Disclosure
        label="Customize"
        openLabel="Hide custom controls"
        className="mt-3 border-t border-border pt-3"
      >
        <CustomPanel style={style} setStyle={setStyle} setStyleThrottled={setStyleThrottled} />
      </Disclosure>
    </div>
  );
}

function CustomPanel({
  style,
  setStyle,
  setStyleThrottled,
}: {
  style: StyleConfig;
  setStyle: (s: Partial<StyleConfig>) => void;
  setStyleThrottled: (s: Partial<StyleConfig>) => void;
}) {
  return (
    <div className="space-y-4 text-xs">
      <SliderField
        label="Font size"
        unit="px"
        value={style.font_size}
        min={20}
        max={120}
        step={1}
        onChange={(font_size) => setStyleThrottled({ font_size })}
      />

      <ColorField
        label="Text color"
        value={style.text_color}
        onChange={(text_color) => setStyleThrottled({ text_color })}
      />

      <ColorField
        label="Highlight color"
        value={style.highlight_color}
        onChange={(highlight_color) => setStyleThrottled({ highlight_color })}
      />

      <Field label="Background">
        <Segmented
          options={BACKGROUNDS}
          value={style.background}
          onChange={(background) => setStyle({ background })}
        />
      </Field>

      {style.background !== "none" && (
        <>
          <ColorField
            label="Background color"
            value={style.background_color}
            onChange={(background_color) => setStyleThrottled({ background_color })}
          />
          <SliderField
            label="Background opacity"
            value={style.background_opacity}
            min={0}
            max={1}
            step={0.05}
            decimals={2}
            onChange={(background_opacity) => setStyleThrottled({ background_opacity })}
          />
        </>
      )}

      <SelectField
        label="Animation"
        value={style.animation}
        options={ANIMATIONS}
        onChange={(animation) => setStyle({ animation })}
      />

      {/* Discrete: one dispatch per step, so it is not throttled. */}
      <SliderField
        label="Words per line"
        value={style.words_per_line}
        min={1}
        max={10}
        step={1}
        onChange={(words_per_line) => setStyle({ words_per_line })}
      />

      <SliderField
        label="Word spacing"
        value={style.word_spacing}
        min={0}
        max={0.6}
        step={0.02}
        decimals={2}
        onChange={(word_spacing) => setStyleThrottled({ word_spacing })}
      />

      <SliderField
        label="Stroke width"
        value={style.stroke_width}
        min={0}
        max={10}
        step={0.5}
        decimals={1}
        onChange={(stroke_width) => setStyleThrottled({ stroke_width })}
      />

      <SliderField
        label="Shadow blur"
        value={style.shadow_blur}
        min={0}
        max={20}
        step={1}
        onChange={(shadow_blur) => setStyleThrottled({ shadow_blur })}
      />

      <CaptionOffsetControl />
    </div>
  );
}
