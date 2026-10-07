/**
 * Tiles the engine drew, laid out as a grid that fills the width and wraps (the panel has the
 * room for it): the presets, and the choices of the Background and Animation tabs.
 */
import { PresetSwatch } from "@/components/StyleFields";
import { TILE_CARD, usePresetPreviews } from "@/lib/presetPreviews";
import { BUILTIN_PRESETS } from "@/lib/presets";
import type { StyleConfig } from "@/types";

export function PresetStrip({
  activeId,
  onPick,
}: {
  activeId: string | undefined;
  onPick: (config: StyleConfig) => void;
}) {
  const previews = usePresetPreviews(BUILTIN_PRESETS);
  return (
    <TileStrip
      tiles={BUILTIN_PRESETS.map((p) => ({
        id: p.id,
        label: p.name,
        image: previews?.[p.id],
        swatch: p.config,
      }))}
      activeId={activeId}
      onPick={(id) => {
        const preset = BUILTIN_PRESETS.find((p) => p.id === id);
        if (preset) onPick(preset.config);
      }}
    />
  );
}

export interface Tile {
  id: string;
  label: string;
  /** The engine's drawing, once there is one. */
  image: string | undefined;
  /** What to show until then. */
  swatch?: StyleConfig;
}

export function TileStrip({
  tiles,
  activeId,
  onPick,
  testIdPrefix = "preset",
}: {
  tiles: readonly Tile[];
  activeId: string | undefined;
  onPick: (id: string) => void;
  testIdPrefix?: string;
}) {
  return (
    <div
      data-testid={`${testIdPrefix}-strip`}
      className="grid grid-cols-[repeat(auto-fill,minmax(140px,1fr))] gap-2.5 p-1"
    >
      {tiles.map((p) => {
        const active = p.id === activeId;
        return (
          <button
            key={p.id}
            type="button"
            onClick={() => onPick(p.id)}
            data-testid={`${testIdPrefix}-${p.id}`}
            aria-pressed={active}
            className={`rounded-[17px] p-1.5 text-xs font-semibold transition-shadow ${
              active ? "ring-[2.5px] ring-primary" : "hover:ring-1 hover:ring-border"
            }`}
          >
            <span
              className="flex aspect-[156/87] w-full items-center justify-center overflow-hidden rounded-xl border border-white/15"
              style={{ background: TILE_CARD }}
            >
              {p.image ? (
                <img
                  src={p.image}
                  alt=""
                  draggable={false}
                  className="h-full w-full object-cover"
                />
              ) : p.swatch ? (
                <PresetSwatch config={p.swatch} />
              ) : null}
            </span>
            <span className="mt-1.5 block text-foreground">{p.label}</span>
          </button>
        );
      })}
    </div>
  );
}
