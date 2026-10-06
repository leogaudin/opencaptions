/**
 * The presets in a row that scrolls sideways, as on iOS: tiles the engine drew,
 * at the phone's size. At the start a fade and an arrow on the right edge say
 * there is more; they go once it has been scrolled. A mouse wheel scrolls it
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
        data-testid="preset-strip"
        className="flex snap-x gap-2.5 overflow-x-auto px-4 pb-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        {BUILTIN_PRESETS.map((p) => {
          const active = p.id === activeId;
          return (
            <button
              key={p.id}
              type="button"
              onClick={() => onPick(p.config)}
              data-testid={`preset-${p.id}`}
              aria-pressed={active}
              className={`shrink-0 snap-start rounded-[17px] p-1.5 text-xs font-semibold transition-shadow ${
                active ? "ring-[2.5px] ring-primary" : "hover:ring-1 hover:ring-border"
              }`}
            >
              <span
                className="flex h-[87px] w-[156px] items-center justify-center overflow-hidden rounded-xl border border-white/15"
                style={{ background: TILE_CARD }}
              >
                {previews?.[p.id] ? (
                  <img
                    src={previews[p.id]}
                    alt=""
                    draggable={false}
                    className="h-full w-full object-cover"
                  />
                ) : (
                  <PresetSwatch config={p.config} />
                )}
              </span>
              <span className="mt-1.5 block text-foreground">{p.name}</span>
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
