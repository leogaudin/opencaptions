/**
 * Tiles the engine drew in a row that scrolls sideways, as on iOS: the presets, and the
 * choices of the Background and Animation tabs. At the start a fade and an arrow on the
 * right edge say there is more; they go once it has been scrolled. A mouse wheel scrolls it
 * sideways too, since a desktop mouse only scrolls up and down.
 */
import { ChevronRight } from "lucide-react";
import { useEffect, useRef, useState } from "react";
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
  const strip = useRef<HTMLDivElement>(null);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const el = strip.current;
    if (!el) return;
    const onScroll = (): void => setScrolled(el.scrollLeft > 12);
    // Not passive: a vertical wheel over the strip moves it instead of the panel.
    const onWheel = (e: WheelEvent): void => {
      if (Math.abs(e.deltaY) <= Math.abs(e.deltaX) || el.scrollWidth <= el.clientWidth) return;
      e.preventDefault();
      el.scrollLeft += e.deltaY;
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => {
      el.removeEventListener("scroll", onScroll);
      el.removeEventListener("wheel", onWheel);
    };
  }, []);

  return (
    <div className="relative -mx-4 mb-3">
      <div
        ref={strip}
        data-testid={`${testIdPrefix}-strip`}
        className="flex snap-x scroll-px-4 gap-2.5 overflow-x-auto px-4 pt-1 pb-1.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
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
              className={`shrink-0 snap-start rounded-[17px] p-1.5 text-xs font-semibold transition-shadow ${
                active ? "ring-[2.5px] ring-primary" : "hover:ring-1 hover:ring-border"
              }`}
            >
              <span
                className="flex h-[87px] w-[156px] items-center justify-center overflow-hidden rounded-xl border border-white/15"
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
      {!scrolled && (
        <div
          aria-hidden
          className="pointer-events-none absolute inset-y-0 right-0 flex w-14 items-center justify-end bg-gradient-to-r from-transparent to-card pr-2"
        >
          <span className="flex h-[26px] w-[26px] items-center justify-center rounded-full border border-border bg-muted text-foreground">
            <ChevronRight className="h-3 w-3" strokeWidth={3} />
          </span>
        </div>
      )}
    </div>
  );
}
