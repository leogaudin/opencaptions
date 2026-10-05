/**
 * The editing timeline under the preview: one block per on-screen caption line
 * on a scrolling time axis, with a playhead synced to the video. Click a block
 * to select it, drag its edges to retime it; click or drag empty track to seek.
 * Words are edited on the preview, not here. The edits themselves are the engine's
 * (`CaptionEditor`), the same code the phone app calls; this is only the UI.
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { type CaptionLine, useCaptionEditor } from "@/lib/engine";
import { useVideoClock } from "@/lib/playback";
import { cn } from "@/lib/utils";
import type { Transcript } from "@/types";

/** Horizontal scale; a track shorter than its box stretches to fill it. */
const PX_PER_S = 60;
/** How far one arrow key moves a selected edge, in seconds. */
const NUDGE_S = 0.05;

type Edge = "start" | "end";
type Edit = (f: (t: Transcript) => Transcript) => void;

export function Timeline({
  video,
  transcript,
  offsetMs,
  wordsPerLine,
  duration,
  onEdit,
}: {
  video: HTMLVideoElement | null;
  /** Transcript as stored; the engine shows it shifted and writes edits back unshifted. */
  transcript: Transcript;
  /** Caption offset in ms, applied by the engine to every time shown. */
  offsetMs: number;
  wordsPerLine: number;
  duration: number;
  onEdit: Edit;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const track = useRef<HTMLDivElement>(null);
  const playhead = useRef<HTMLDivElement>(null);
  const [selected, setSelected] = useState<number | null>(null);
  // A positive offset shows the last captions past the video's end; keep them reachable.
  const span = Math.max(duration + Math.max(0, offsetMs / 1000), 0.001);
  const editor = useCaptionEditor();
  const lines = useMemo(
    () => editor?.lines(transcript, wordsPerLine, offsetMs) ?? [],
    [editor, transcript, wordsPerLine, offsetMs],
  );
  const pct = (s: number): string => `${(s / span) * 100}%`;

  // The playhead follows the video every frame while it plays, without a React
  // render per frame, and scrolls the track to stay in view.
  useVideoClock(video, (time) => {
    const head = playhead.current;
    const box = scroller.current;
    if (!head || !box) return;
    const fraction = Math.min(1, time / span);
    head.style.left = `${fraction * 100}%`;
    const x = fraction * box.scrollWidth;
    if (!video?.paused && (x < box.scrollLeft || x > box.scrollLeft + box.clientWidth)) {
      box.scrollLeft = x - box.clientWidth / 4;
    }
  });

  const timeAt = (clientX: number): number => {
    const box = track.current?.getBoundingClientRect();
    if (!box) return 0;
    return Math.min(1, Math.max(0, (clientX - box.left) / box.width)) * span;
  };
  const seek = (time: number): void => {
    if (video) video.currentTime = time;
  };

  // Edge drags commit at most once per frame: each commit re-lays-out the scene.
  const pending = useRef<{ index: number; edge: Edge; time: number } | null>(null);
  const commitFrame = useRef(0);
  const retime = (index: number, edge: Edge, time: number): void => {
    pending.current = { index, edge, time };
    if (commitFrame.current) return;
    commitFrame.current = requestAnimationFrame(() => {
      commitFrame.current = 0;
      const p = pending.current;
      if (p && editor) onEdit((t) => editor.retimeWord(t, p.index, p.edge, p.time, offsetMs));
    });
  };
  useEffect(() => () => cancelAnimationFrame(commitFrame.current), []);

  const edgeWord = (line: CaptionLine, edge: Edge): number =>
    edge === "start" ? line.from : line.from + line.count - 1;

  return (
    <div
      ref={scroller}
      className="mt-2 w-full overflow-x-auto overflow-y-hidden rounded-md border border-border bg-card"
    >
      <div
        ref={track}
        data-testid="timeline"
        onPointerDown={(e) => {
          e.currentTarget.setPointerCapture(e.pointerId);
          setSelected(null);
          seek(timeAt(e.clientX));
        }}
        onPointerMove={(e) => {
          if (e.currentTarget.hasPointerCapture(e.pointerId)) seek(timeAt(e.clientX));
        }}
        className="relative h-14 cursor-pointer touch-none"
        style={{ width: `max(100%, ${span * PX_PER_S}px)` }}
      >
        {lines.map((line) => {
          const isSelected = selected === line.from;
          const left = line.start;
          return (
            <div
              key={line.from}
              className="absolute top-1.5 bottom-1.5"
              style={{ left: pct(left), width: pct(Math.max(line.end - left, 0)) }}
            >
              <button
                type="button"
                data-testid="timeline-line"
                title={line.text}
                onPointerDown={(e) => e.stopPropagation()}
                onClick={(e) => {
                  setSelected(line.from);
                  // detail is 0 for a keyboard activation: seek to the line, not a pixel.
                  seek(e.detail ? timeAt(e.clientX) : left);
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
                    onPointerDown={(e) => {
                      e.stopPropagation();
                      e.currentTarget.setPointerCapture(e.pointerId);
                    }}
                    onPointerMove={(e) => {
                      if (!e.currentTarget.hasPointerCapture(e.pointerId)) return;
                      const time = timeAt(e.clientX);
                      seek(time);
                      retime(edgeWord(line, edge), edge, time);
                    }}
                    onKeyDown={(e) => {
                      const step = { ArrowLeft: -NUDGE_S, ArrowRight: NUDGE_S }[e.key];
                      if (!step) return;
                      e.preventDefault();
                      const at = (edge === "start" ? line.start : line.end) + step;
                      seek(at);
                      retime(edgeWord(line, edge), edge, at);
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
        <div
          ref={playhead}
          className="pointer-events-none absolute inset-y-0 z-20 w-0.5 -translate-x-1/2 bg-primary"
        />
      </div>
    </div>
  );
}
