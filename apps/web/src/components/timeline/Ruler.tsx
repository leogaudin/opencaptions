import { formatTick, tickStep } from "@/lib/timelineScale";

/** The time axis: a label and a tick at every step, for the part of the track in view. */
export function Ruler({
  pxPerSecond,
  span,
  from,
  to,
}: {
  pxPerSecond: number;
  span: number;
  /** The visible range, in pixels along the track. */
  from: number;
  to: number;
}) {
  const step = tickStep(pxPerSecond);
  // A little either side, so a label does not pop in at the edge.
  const first = Math.max(0, Math.floor((from - 80) / pxPerSecond / step));
  const last = Math.min(Math.floor(span / step), Math.ceil((to + 80) / pxPerSecond / step));
  const ticks: number[] = [];
  for (let i = first; i <= last; i++) ticks.push(i * step);
  return (
    <>
      {ticks.map((t) => (
        <div
          key={t}
          className="pointer-events-none absolute inset-y-0 border-l border-border pl-1 text-[10px] tabular-nums text-muted-foreground"
          style={{ left: t * pxPerSecond }}
        >
          {formatTick(t, step)}
        </div>
      ))}
    </>
  );
}
