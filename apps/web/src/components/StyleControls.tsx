/**
 * StyleControls: the caption's look, in tabs as on iOS so that no one page is long: the
 * presets, the text, the background and the animation (each a row of tiles the engine drew,
 * in the caption's current look), the outline and shadow, and the timing.
 *
 * Continuous controls (colours, most sliders) route through a rAF-throttled
 * setter so dragging re-lays out the preview at most once a frame.
 * Discrete controls dispatch immediately: there is nothing to coalesce.
 */

import { Clock, PenLine, Sparkles, Square, Type, Wand2 } from "lucide-react";
import { type ReactNode, useState } from "react";
import { CaptionOffsetControl } from "@/components/CaptionOffsetControl";
import { FontPicker } from "@/components/FontPicker";
import { PresetStrip, TileStrip } from "@/components/PresetStrip";
import {
  ColorField,
  ColorListField,
  Field,
  Segmented,
  SliderField,
} from "@/components/StyleFields";
import { msg, useT } from "@/lib/i18n";
import { useLookPreviews } from "@/lib/presetPreviews";
import { BUILTIN_PRESETS, presetLook, presetMatches } from "@/lib/presets";
import {
  ANIMATION_NAMES,
  ANIMATIONS,
  BACKGROUND_NAMES,
  BACKGROUNDS,
  CASE_NAMES,
  CASES,
  MAX_HIGHLIGHT_COLORS,
  withBackground,
} from "@/lib/styleLooks";
import { useThrottledPatch } from "@/lib/useThrottledPatch";
import { useEditorStore } from "@/store/editorStore";
import type { StyleConfig } from "@/types";

const TABS = [
  { id: "presets", label: msg("Presets"), icon: Sparkles },
  { id: "text", label: msg("Text"), icon: Type },
  { id: "background", label: msg("Background"), icon: Square },
  { id: "animation", label: msg("Animation"), icon: Wand2 },
  { id: "outline", label: msg("Outline"), icon: PenLine },
  { id: "timing", label: msg("Timing"), icon: Clock },
] as const;
type TabId = (typeof TABS)[number]["id"];

export function StyleControls() {
  const t = useT();
  const style = useEditorStore((s) => s.style);
  const setStyle = useEditorStore((s) => s.setStyle);
  const setStyleThrottled = useThrottledPatch<StyleConfig>(setStyle);
  const [tab, setTab] = useState<TabId>("presets");

  // The active preset is whichever built-in's config matches the current style,
  // so the picked one can be highlighted in the strip.
  const activePresetId = BUILTIN_PRESETS.find((p) => presetMatches(p.config, style))?.id;

  return (
    <div className="rounded-lg border border-border bg-card p-4 shadow-xs">
      <div
        role="tablist"
        aria-label={t("Caption style")}
        className="-mx-1 mb-4 flex gap-1 overflow-x-auto"
      >
        {TABS.map(({ id, label, icon: Icon }) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={tab === id}
            data-testid={`style-tab-${id}`}
            onClick={() => setTab(id)}
            className={`flex min-w-16 flex-1 flex-col items-center gap-1 rounded-xl px-2 py-2 text-[11px] font-semibold transition-colors ${
              tab === id ? "bg-muted text-foreground" : "text-muted-foreground hover:bg-muted/50"
            }`}
          >
            <Icon className="h-[18px] w-[18px]" aria-hidden />
            {t(label)}
          </button>
        ))}
      </div>

      {tab === "presets" && (
        <PresetStrip activeId={activePresetId} onPick={(config) => setStyle(presetLook(config))} />
      )}
      {tab === "text" && (
        <TextPanel style={style} setStyle={setStyle} throttled={setStyleThrottled} />
      )}
      {tab === "background" && (
        <BackgroundPanel style={style} setStyle={setStyle} throttled={setStyleThrottled} />
      )}
      {tab === "animation" && <AnimationPanel style={style} setStyle={setStyle} />}
      {tab === "outline" && <OutlinePanel style={style} throttled={setStyleThrottled} />}
      {tab === "timing" && <CaptionOffsetControl />}
    </div>
  );
}

type Setter = (s: Partial<StyleConfig>) => void;

const SLANTS = ["upright", "italic"] as const;
const SLANT_NAMES: Record<(typeof SLANTS)[number], string> = {
  upright: msg("Upright"),
  italic: msg("Italic"),
};

function Panel({ children }: { children: ReactNode }) {
  return <div className="space-y-4 text-xs">{children}</div>;
}

/** What the tiles of one setting depend on: the look, less the choice they offer and the place. */
function lookKey(style: StyleConfig, without: keyof StyleConfig): string {
  const { position_x, position_y, font_size, ...look } = style;
  void position_x;
  void position_y;
  void font_size;
  return JSON.stringify({ ...look, [without]: null });
}

function TextPanel({
  style,
  setStyle,
  throttled,
}: {
  style: StyleConfig;
  setStyle: Setter;
  throttled: Setter;
}) {
  const t = useT();
  return (
    <Panel>
      <FontPicker value={style.font} onChange={(font) => setStyle({ font })} />
      <SliderField
        label={t("Font size")}
        unit="px"
        value={style.font_size}
        min={20}
        max={300}
        step={1}
        onChange={(font_size) => throttled({ font_size })}
      />
      <Field label={t("Letter case")}>
        <Segmented
          options={CASES}
          value={style.text_case}
          label={(c) => t(CASE_NAMES[c])}
          onChange={(text_case) => setStyle({ text_case })}
        />
      </Field>
      <Field label={t("Slant")}>
        <Segmented
          options={SLANTS}
          value={style.italic ? "italic" : "upright"}
          label={(s) => t(SLANT_NAMES[s])}
          onChange={(slant) => setStyle({ italic: slant === "italic" })}
        />
      </Field>
      <ColorField
        label={t("Text color")}
        value={style.text_color}
        onChange={(text_color) => throttled({ text_color })}
      />
      <ColorListField
        label={t("Highlight colors")}
        value={style.highlight_colors}
        max={MAX_HIGHLIGHT_COLORS}
        addLabel={t("Add a highlight color")}
        removeLabel={t("Remove this highlight color")}
        testId="highlight-color"
        onChange={(highlight_colors) => throttled({ highlight_colors })}
        onResize={(highlight_colors) => setStyle({ highlight_colors })}
      />
      {/* Discrete: one dispatch per step, so it is not throttled. */}
      <SliderField
        label={t("Words per line")}
        value={style.words_per_line}
        min={1}
        max={10}
        step={1}
        onChange={(words_per_line) => setStyle({ words_per_line })}
      />
      <SliderField
        label={t("Word spacing")}
        value={style.word_spacing}
        min={0}
        max={0.6}
        step={0.02}
        decimals={2}
        onChange={(word_spacing) => throttled({ word_spacing })}
      />
    </Panel>
  );
}

function BackgroundPanel({
  style,
  setStyle,
  throttled,
}: {
  style: StyleConfig;
  setStyle: Setter;
  throttled: Setter;
}) {
  const t = useT();
  const tiles = useLookPreviews(
    BACKGROUNDS.map((b) => ({ id: b, config: withBackground(style, b) })),
    lookKey(style, "background"),
  );
  return (
    <Panel>
      <TileStrip
        testIdPrefix="background"
        tiles={BACKGROUNDS.map((b) => ({
          id: b,
          label: t(BACKGROUND_NAMES[b]),
          image: tiles?.[b],
          swatch: withBackground(style, b),
        }))}
        activeId={style.background}
        onPick={(id) => {
          const choice = BACKGROUNDS.find((b) => b === id);
          if (choice) setStyle(withBackground(style, choice));
        }}
      />
      {style.background !== "none" && (
        <>
          <ColorField
            label={t("Background color")}
            value={style.background_color}
            onChange={(background_color) => throttled({ background_color })}
          />
          <SliderField
            label={t("Background opacity")}
            value={style.background_opacity}
            min={0}
            max={1}
            step={0.05}
            decimals={2}
            onChange={(background_opacity) => throttled({ background_opacity })}
          />
        </>
      )}
    </Panel>
  );
}

function AnimationPanel({ style, setStyle }: { style: StyleConfig; setStyle: Setter }) {
  const t = useT();
  const tiles = useLookPreviews(
    ANIMATIONS.map((animation) => ({ id: animation, config: { ...style, animation } })),
    lookKey(style, "animation"),
  );
  return (
    <Panel>
      <TileStrip
        testIdPrefix="animation"
        tiles={ANIMATIONS.map((a) => ({
          id: a,
          label: t(ANIMATION_NAMES[a]),
          image: tiles?.[a],
          swatch: { ...style, animation: a },
        }))}
        activeId={style.animation}
        onPick={(id) => {
          const animation = ANIMATIONS.find((a) => a === id);
          if (animation) setStyle({ animation });
        }}
      />
    </Panel>
  );
}

function OutlinePanel({ style, throttled }: { style: StyleConfig; throttled: Setter }) {
  const t = useT();
  return (
    <Panel>
      <SliderField
        label={t("Stroke width")}
        value={style.stroke_width}
        min={0}
        max={10}
        step={0.5}
        decimals={1}
        onChange={(stroke_width) => throttled({ stroke_width })}
      />
      <SliderField
        label={t("Shadow blur")}
        value={style.shadow_blur}
        min={0}
        max={20}
        step={1}
        onChange={(shadow_blur) => throttled({ shadow_blur })}
      />
      <SliderField
        label={t("Shadow right")}
        value={style.shadow_offset_x}
        min={-20}
        max={20}
        step={1}
        onChange={(shadow_offset_x) => throttled({ shadow_offset_x })}
      />
      <SliderField
        label={t("Shadow down")}
        value={style.shadow_offset_y}
        min={-20}
        max={20}
        step={1}
        onChange={(shadow_offset_y) => throttled({ shadow_offset_y })}
      />
      <SliderField
        label={t("Glow")}
        value={style.glow_blur}
        min={0}
        max={40}
        step={1}
        onChange={(glow_blur) => throttled({ glow_blur })}
      />
      {style.glow_blur > 0 && (
        <ColorField
          label={t("Glow color")}
          value={style.glow_color}
          onChange={(glow_color) => throttled({ glow_color })}
        />
      )}
    </Panel>
  );
}
