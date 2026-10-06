/**
 * A range input in the app's own look. The native one, given `accent-color` yellow, is
 * darkened by the browser to keep contrast on a light page, which turns the app's yellow
 * a muddy brown; this paints the track and thumb in exactly the accent.
 */
import type { CSSProperties } from "react";

export function RangeInput({
  value,
  min,
  max,
  step,
  onChange,
  ...rest
}: {
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
  id?: string;
  "aria-label"?: string;
  "data-testid"?: string;
}) {
  // How far along the track the thumb is: the filled part of the track.
  const fill = max > min ? ((value - min) / (max - min)) * 100 : 0;
  return (
    <input
      {...rest}
      type="range"
      min={min}
      max={max}
      step={step}
      value={value}
      onChange={(e) => onChange(Number(e.target.value))}
      className="oc-range"
      style={{ "--fill": `${fill}%` } as CSSProperties}
    />
  );
}
