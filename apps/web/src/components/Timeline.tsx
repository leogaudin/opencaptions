/**
 * The editing timeline under the preview: one block per on-screen caption line
 * on a scrolling time axis, with a playhead synced to the video. Click a block
 * to select it, drag its edges to retime it, double-click to edit its words;
 * click or drag empty track to seek. The edits themselves are the engine's
 * (`CaptionEditor`), the same code the phone app calls; this is only the UI.
 */
import { type RefObject, useEffect, useMemo, useRef, useState } from "react";
import { type CaptionLine, useCaptionEditor } from "@/lib/engine";
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
  offset,
  wordsPerLine,
  duration,
  onEdit,
}: {
  video: RefObject<HTMLVideoElement | null>;
  /** Unshifted transcript; edits are written back in its time base. */
  transcript: Transcript;
  /** Caption offset in seconds, added to every time shown. */
  offset: number;
  wordsPerLine: number;
  duration: number;
  onEdit: Edit;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const track = useRef<HTMLDivElement>(null);
  const playhead = useRef<HTMLDivElement>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const [editing, setEditing] = useState<{ line: CaptionLine; text: string } | null>(null);
  const resolved = useRef(false);
  // A positive offset shows the last captions past the video's end; keep them reachable.
  const span = Math.max(duration + Math.max(0, offset), 0.001);
  const editor = useCaptionEditor();
  const lines = useMemo(
    () => editor?.lines(transcript, wordsPerLine) ?? [],
    [editor, transcript, wordsPerLine],
  );
  const shown = (s: number): number => Math.max(0, s + offset);
  const pct = (s: number): string => `${(s / span) * 100}%`;

  // The playhead follows the video every frame while it plays, without a React
  // render per frame, and scrolls the track to stay in view.
  useEffect(() => {
    const v = video.current;
    const head = playhead.current;
    const box = scroller.current;
    if (!v || !head || !box) return;
    let frame = 0;
    const place = (): void => {
      const fraction = Math.min(1, v.currentTime / span);
      head.style.left = `${fraction * 100}%`;
      const x = fraction * box.scrollWidth;
      if (!v.paused && (x < box.scrollLeft || x > box.scrollLeft + box.clientWidth)) {
        box.scrollLeft = x - box.clientWidth / 4;
      }
    };
    const loop = (): void => {
      place();
      frame = v.paused ? 0 : requestAnimationFrame(loop);
    };
    const start = (): void => {
      if (!frame) loop();
    };
    place();
    const events = ["play", "seeked", "seeking", "pause", "timeupdate"] as const;
    for (const e of events) v.addEventListener(e, start);
    if (!v.paused) start();
    return () => {
      cancelAnimationFrame(frame);
      for (const e of events) v.removeEventListener(e, start);
    };
  }, [video, span]);

  const timeAt = (clientX: number): number => {
    const box = track.current?.getBoundingClientRect();
    if (!box) return 0;
    return Math.min(1, Math.max(0, (clientX - box.left) / box.width)) * span;
  };
  const seek = (time: number): void => {
    if (video.current) video.current.currentTime = time;
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
      if (p && editor) onEdit((t) => editor.retimeWord(t, p.index, p.edge, p.time - offset));
    });
  };
  useEffect(() => () => cancelAnimationFrame(commitFrame.current), []);

  const edgeWord = (line: CaptionLine, edge: Edge): number =>
    edge === "start" ? line.from : line.from + line.count - 1;

  function finishEdit(save: boolean): void {
    if (resolved.current) return;
    resolved.current = true;
    if (save && editing) {
      const { line, text } = editing;
      if (editor) onEdit((t) => editor.replaceWords(t, line.from, line.count, text));
    }
    setEditing(null);
  }

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
          const left = shown(line.start);
          return (
            <div
              key={line.from}
              className="absolute top-1.5 bottom-1.5"
              style={{ left: pct(left), width: pct(Math.max(shown(line.end) - left, 0)) }}
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
                onDoubleClick={() => {
                  video.current?.pause();
                  resolved.current = false;
                  setEditing({ line, text: line.text });
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
                      const at = shown(edge === "start" ? line.start : line.end) + step;
                      seek(at);
                      retime(edgeWord(line, edge), edge, at);
                    }}
                    className={cn(
                      "absolute inset-y-0 w-2 cursor-ew-resize rounded-sm bg-primary",
                      edge === "start" ? "left-0" : "right-0",
                    )}
                  />
                ))}
              {editing?.line.from === line.from && (
                <input
                  data-testid="timeline-edit"
                  // biome-ignore lint/a11y/noAutofocus: an inline edit takes focus as it opens
                  autoFocus
                  value={editing.text}
                  onChange={(e) => setEditing({ line, text: e.target.value })}
                  onPointerDown={(e) => e.stopPropagation()}
                  onBlur={() => finishEdit(true)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") finishEdit(true);
                    else if (e.key === "Escape") finishEdit(false);
                  }}
                  className="absolute inset-y-0 left-0 z-10 w-full min-w-40 rounded-sm border border-primary bg-background px-1.5 text-[11px] outline-none"
                />
              )}
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
