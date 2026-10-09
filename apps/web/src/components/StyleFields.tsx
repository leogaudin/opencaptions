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

/** Colours to start a new highlight colour from: the next one not yet taken, as far as they go. */
const ADDED_COLORS = ["#FFE600", "#22D3EE", "#FF4D8D", "#22E06B"];

/**
 * An ordered list of colours, the first being the primary. A colour change is a drag on a picker
 * (so it arrives throttled); adding or removing one is a single step.
 */
export function ColorListField({
  label,
  value,
  max,
  addLabel,
  removeLabel,
  testId,
  onChange,
  onResize,
}: {
  label: string;
  value: string[];
  max: number;
  addLabel: string;
  removeLabel: string;
  testId: string;
  onChange: (v: string[]) => void;
  onResize: (v: string[]) => void;
}) {
  return (
    <Field label={label}>
      <div className="flex flex-wrap items-center gap-2" data-testid={testId}>
        {value.map((color, i) => (
          // The list is edited in place and has no ids: the position is the identity.
          // biome-ignore lint/suspicious/noArrayIndexKey: see above.
          <div key={i} className="flex items-center gap-1">
            <input
              type="color"
              value={color}
              data-testid={`${testId}-${i}`}
              aria-label={`${label} ${i + 1}`}
              onChange={(e) =>
                onChange(value.map((c, j) => (j === i ? e.target.value.toUpperCase() : c)))
              }
              className="h-7 w-10 cursor-pointer rounded border border-border bg-background"
            />
            {i > 0 && (
              <button
                type="button"
                aria-label={removeLabel}
                data-testid={`${testId}-remove-${i}`}
                onClick={() => onResize(value.filter((_, j) => j !== i))}
                className="rounded px-1 text-sm leading-none text-muted-foreground hover:text-foreground"
              >
                ×
              </button>
            )}
          </div>
        ))}
        {value.length < max && (
          <button
            type="button"
            aria-label={addLabel}
            data-testid={`${testId}-add`}
            onClick={() =>
              onResize([...value, ADDED_COLORS[value.length % ADDED_COLORS.length] ?? "#FFFFFF"])
            }
            className="h-7 w-7 rounded border border-dashed border-border text-sm leading-none text-muted-foreground hover:text-foreground"
          >
            +
          </button>
        )}
      </div>
      <code className="mt-1 block rounded bg-background/60 px-1.5 py-0.5 text-[11px] text-muted-foreground">
        {value.join("  ")}
      </code>
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
              background: config.highlight_colors[0],
              padding: "1px 3px",
              borderRadius: 3,
              marginLeft: 1,
            }}
          >
            a
          </span>
        ) : (
          <span style={{ color: config.highlight_colors[0] }}>a</span>
        )}
      </span>
    </span>
  );
}
