import type { ReactNode } from "react";
import { RangeInput } from "@/components/RangeInput";
import { hexToRgba } from "@/lib/utils";
import type { StyleConfig } from "@/types";

/**
 * Presentational primitives for the caption style panel. No store access and no
 * style semantics: each one renders a labelled control and reports changes.
 */

export function Field({ label, children }: { label: ReactNode; children: ReactNode }) {
  return (
    <div>
      <div className="mb-1 text-muted-foreground">{label}</div>
      {children}
    </div>
  );
}

export function ColorField({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <Field label={label}>
      <div className="flex items-center gap-2">
        <input
          type="color"
          value={value}
          onChange={(e) => onChange(e.target.value.toUpperCase())}
          className="h-7 w-10 cursor-pointer rounded border border-border bg-background"
        />
        <code className="rounded bg-background/60 px-1.5 py-0.5 text-[11px] text-muted-foreground">
          {value}
        </code>
      </div>
    </Field>
  );
}

export function SliderField({
  label,
  unit,
  value,
  min,
  max,
  step,
  decimals = 0,
  onChange,
}: {
  label: string;
  unit?: string;
  value: number;
  min: number;
  max: number;
  step: number;
  decimals?: number;
  onChange: (v: number) => void;
}) {
  return (
    <Field
      label={
        <span className="flex items-center justify-between">
          <span>{label}</span>
          <span className="text-foreground">
            {value.toFixed(decimals)}
            {unit ?? ""}
          </span>
        </span>
      }
    >
      <RangeInput value={value} min={min} max={max} step={step} onChange={onChange} />
    </Field>
  );
}

export function Segmented<T extends string>({
  options,
  value,
  onChange,
  label = (v) => v,
}: {
  options: readonly T[];
  value: T;
  onChange: (v: T) => void;
  label?: (v: T) => string;
}) {
  return (
    <div className="inline-flex w-full rounded-full border border-border bg-background p-1">
      {options.map((opt) => {
        const active = opt === value;
        return (
          <button
            key={opt}
            type="button"
            onClick={() => onChange(opt)}
            className={`flex-1 rounded-full px-3 py-1.5 text-[11px] font-medium capitalize transition-colors ${
              active
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-accent/50"
            }`}
          >
            {label(opt)}
          </button>
        );
      })}
    </div>
  );
}

/** Miniature preview of a preset: the same paint order the engine uses. */
export function PresetSwatch({ config }: { config: StyleConfig }) {
  const bgRgba = hexToRgba(config.background_color, config.background_opacity);
  const padding = config.background === "none" ? 0 : 4;
  return (
    <span aria-hidden className="mx-auto flex h-7 w-full items-center justify-center">
      <span
        style={{
          background: config.background === "none" ? "transparent" : bgRgba,
          color: config.text_color,
          padding: `${padding}px ${padding * 2}px`,
          borderRadius: config.background === "pill" ? 9999 : 4,
          fontFamily: `"${config.font}", system-ui, sans-serif`,
          fontWeight: 800,
          fontSize: 14,
          lineHeight: 1,
          letterSpacing: "-0.02em",
          WebkitTextStroke:
            config.stroke_width > 0
              ? `${Math.min(1.2, config.stroke_width * 0.05)}px ${config.stroke_color}`
              : undefined,
          // Match the engine: stroke painted behind the fill so the swatch
          // previews the same non-clogging outline the caption renders.
          paintOrder: "stroke fill",
          textShadow:
            config.shadow_blur > 0
              ? `0 0 ${Math.min(4, config.shadow_blur * 0.4)}px ${config.shadow_color}`
              : undefined,
        }}
      >
        <span style={{ color: config.text_color }}>A</span>
        {config.animation === "highlight_box" || config.animation === "highlight_slide" ? (
          // Marked by a box, not a colour, so the swatch must show a box too.
          <span
            style={{
              color: config.text_color,
              background: config.highlight_color,
              padding: "1px 3px",
              borderRadius: 3,
              marginLeft: 1,
            }}
          >
            a
          </span>
        ) : (
          <span style={{ color: config.highlight_color }}>a</span>
        )}
      </span>
    </span>
  );
}
