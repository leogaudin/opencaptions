import type { PointerEvent } from "react";
import type { CaptionLine } from "@/lib/engine";
import { useT } from "@/lib/i18n";
import { cn } from "@/lib/utils";

/** How far one arrow key moves a selected edge, in seconds. */
const NUDGE_S = 0.05;

type Edge = "start" | "end";

/** The word an edge of a caption belongs to: its first word's start, its last word's end. */
const edgeWord = (line: CaptionLine, edge: Edge): number =>
  edge === "start" ? line.from : line.from + line.count - 1;

/** Always this much room between one clip and the next, so touching captions stay two clips. */
const GAP_PX = 1;
/** No clip is drawn narrower than this, however far the timeline is zoomed out. */
const MIN_PX = 2;
const HANDLE_PX = 6;

/**
 * One flat clip per on-screen caption line, at its shown time, as in a video editor's track:
 * square-ish, side by side with a hairline between, its text cut off at its edge. A selected
 * clip has a handle on each edge that retimes it; on a clip too narrow to grab, the handles
 * sit just outside it so they never cover each other. The engine decides how far an edge may
 * go. Times are as shown: the engine applies the caption offset.
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
  const t = useT();
  return (
    <>
      {lines.map((line) => {
        const isSelected = selected === line.from;
        const width = Math.max((line.end - line.start) * pxPerSecond - GAP_PX, MIN_PX);
        const tooNarrow = width < 4 * HANDLE_PX;
        return (
          <div
            key={line.from}
            className="absolute top-1.5 bottom-1.5"
            style={{ left: line.start * pxPerSecond, width }}
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
                "block h-full w-full overflow-hidden rounded-[3px] px-1.5 text-left text-[11px] font-semibold ring-1 ring-inset",
                isSelected
                  ? "bg-primary text-primary-foreground ring-foreground/30"
                  : "bg-muted text-foreground ring-foreground/15 hover:bg-foreground/15",
              )}
            >
              <span className="pointer-events-none block truncate">{line.text}</span>
            </button>
            {isSelected &&
              (["start", "end"] as const).map((edge) => (
                <button
                  key={edge}
                  type="button"
                  data-testid={`timeline-${edge}`}
                  aria-label={edge === "start" ? t("Caption start") : t("Caption end")}
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
                    "absolute inset-y-0 z-10 w-1.5 cursor-ew-resize rounded-[2px] bg-foreground ring-1 ring-background",
                    edge === "start"
                      ? tooNarrow
                        ? "-left-1.5"
                        : "left-0"
                      : tooNarrow
                        ? "-right-1.5"
                        : "right-0",
                  )}
                />
              ))}
          </div>
        );
      })}
    </>
  );
}
