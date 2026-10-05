import type { PointerEvent } from "react";
import type { CaptionLine } from "@/lib/engine";
import { cn } from "@/lib/utils";

/** How far one arrow key moves a selected edge, in seconds. */
const NUDGE_S = 0.05;

type Edge = "start" | "end";

/** The word an edge of a caption belongs to: its first word's start, its last word's end. */
const edgeWord = (line: CaptionLine, edge: Edge): number =>
  edge === "start" ? line.from : line.from + line.count - 1;

/**
 * One block per on-screen caption line, at its shown time. A selected block has a
 * handle on each edge that retimes it; the engine decides how far an edge may go.
 * Times are as shown: the engine applies the caption offset.
 */
export function CaptionTrack({
  lines,
  pxPerSecond,
  selected,
  onSelect,
  seek,
  timeAt,
  onRetime,
}: {
  lines: CaptionLine[];
  pxPerSecond: number;
  /** `from` of the selected line. */
  selected: number | null;
  onSelect: (from: number) => void;
  seek: (time: number) => void;
  /** The time under a pointer, from its client x. */
  timeAt: (clientX: number) => number;
  onRetime: (index: number, edge: Edge, time: number) => void;
}) {
  return (
    <>
      {lines.map((line) => {
        const isSelected = selected === line.from;
        return (
          <div
            key={line.from}
            className="absolute top-1.5 bottom-1.5"
            style={{
              left: line.start * pxPerSecond,
              width: Math.max((line.end - line.start) * pxPerSecond, 0),
            }}
          >
            <button
              type="button"
              data-testid="timeline-line"
              title={line.text}
              onPointerDown={(e) => e.stopPropagation()}
              onClick={(e) => {
                onSelect(line.from);
                // detail is 0 for a keyboard activation: seek to the line, not a pixel.
                seek(e.detail ? timeAt(e.clientX) : line.start);
              }}
              className={cn(
                "h-full w-full min-w-1 overflow-hidden rounded-sm px-1.5 text-left text-[11px] text-foreground",
                isSelected
                  ? "bg-primary/45 ring-2 ring-primary"
                  : "bg-primary/20 ring-1 ring-primary/40 hover:bg-primary/30",
              )}
            >
              <span className="pointer-events-none whitespace-nowrap">{line.text}</span>
            </button>
            {isSelected &&
              (["start", "end"] as const).map((edge) => (
                <button
                  key={edge}
                  type="button"
                  data-testid={`timeline-${edge}`}
                  aria-label={edge === "start" ? "Caption start" : "Caption end"}
                  onPointerDown={(e: PointerEvent<HTMLButtonElement>) => {
                    e.stopPropagation();
                    e.currentTarget.setPointerCapture(e.pointerId);
                  }}
                  onPointerMove={(e) => {
                    if (!e.currentTarget.hasPointerCapture(e.pointerId)) return;
                    const time = timeAt(e.clientX);
                    seek(time);
                    onRetime(edgeWord(line, edge), edge, time);
                  }}
                  onKeyDown={(e) => {
                    const step = { ArrowLeft: -NUDGE_S, ArrowRight: NUDGE_S }[e.key];
                    if (!step) return;
                    e.preventDefault();
                    const at = (edge === "start" ? line.start : line.end) + step;
                    seek(at);
                    onRetime(edgeWord(line, edge), edge, at);
                  }}
                  className={cn(
                    "absolute inset-y-0 w-2 cursor-ew-resize rounded-sm bg-primary",
                    edge === "start" ? "left-0" : "right-0",
                  )}
                />
              ))}
          </div>
        );
      })}
    </>
  );
}
