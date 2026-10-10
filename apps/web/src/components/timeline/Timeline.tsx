/**
 * The editing timeline: a ruler over a video track and a caption track, on a time
 * axis that zooms and scrolls, with a playhead synced to the video. It is where
 * captions are worked on over time: click a block to select it, drag its edges to
 * retime it; click or drag the ruler or a track to seek. Ctrl/⌘ + wheel or a
 * trackpad pinch zooms around the pointer. Words are edited on the preview.
 *
 * The edits themselves are the engine's (`CaptionEditor`), the same code the phone
 * app calls, and the engine applies the caption offset; this is only the UI.
 */
import { Maximize2, Redo2, Undo2, ZoomIn, ZoomOut } from "lucide-react";
import { type PointerEvent, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Transport } from "@/components/Transport";
import { CaptionTrack } from "@/components/timeline/CaptionTrack";
import { Ruler } from "@/components/timeline/Ruler";
import { useCaptionEditor } from "@/lib/engine";
import { useT } from "@/lib/i18n";
import { useVideoClock } from "@/lib/playback";
import { clampZoom } from "@/lib/timelineScale";
import type { Transcript } from "@/types";

type Edge = "start" | "end";
/** An edit of the transcript; edits of one `group` made close together undo as one step. */
type Edit = (f: (t: Transcript) => Transcript, group?: string) => void;

/** What one wheel-delta unit does to the zoom (a pinch sends small deltas, a notch ~100). */
const WHEEL_ZOOM = 0.0025;
/** One press of a zoom button. */
const ZOOM_STEP = 1.5;
const BUTTON =
  "inline-flex h-8 w-8 items-center justify-center rounded-full text-foreground transition-colors hover:bg-muted disabled:opacity-40";

export function Timeline({
  video,
  transcript,
  offsetMs,
  wordsPerLine,
  duration,
  fps,
  title,
  onEdit,
  canUndo,
  canRedo,
  onUndo,
  onRedo,
}: {
  video: HTMLVideoElement | null;
  /** Transcript as stored; the engine shows it shifted and writes edits back unshifted. */
  transcript: Transcript;
  /** Caption offset in ms, applied by the engine to every time shown. */
  offsetMs: number;
  wordsPerLine: number;
  /** The video's length in seconds. */
  duration: number;
  fps: number;
  title: string;
  onEdit: Edit;
  canUndo: boolean;
  canRedo: boolean;
  onUndo: () => void;
  onRedo: () => void;
}) {
  const t = useT();
  const scroller = useRef<HTMLDivElement>(null);
  const content = useRef<HTMLDivElement>(null);
  const playhead = useRef<HTMLDivElement>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const editor = useCaptionEditor();
  // A positive offset shows the last captions past the video's end; keep them reachable.
  const span = Math.max(duration + Math.max(0, offsetMs / 1000), 0.001);
  const lines = useMemo(
    () => editor?.lines(transcript, wordsPerLine, offsetMs) ?? [],
    [editor, transcript, wordsPerLine, offsetMs],
  );

  // The part of the track in view, kept current as it scrolls or the dock resizes.
  const [view, setView] = useState({ left: 0, width: 0 });
  useEffect(() => {
    const box = scroller.current;
    if (!box) return;
    let frame = 0;
    const read = (): void => {
      frame = 0;
      setView((v) =>
        v.left === box.scrollLeft && v.width === box.clientWidth
          ? v
          : { left: box.scrollLeft, width: box.clientWidth },
      );
    };
    const schedule = (): void => {
      if (!frame) frame = requestAnimationFrame(read);
    };
    read();
    box.addEventListener("scroll", schedule, { passive: true });
    const ro = new ResizeObserver(schedule);
    ro.observe(box);
    return () => {
      cancelAnimationFrame(frame);
      box.removeEventListener("scroll", schedule);
      ro.disconnect();
    };
  }, []);

  // Pixels per second. `null` is "fit": the whole video across the dock.
  const fit = view.width > 0 ? view.width / span : 1;
  const [zoom, setZoom] = useState<number | null>(null);
  const px = zoom === null ? fit : clampZoom(zoom, fit);
  const width = zoom === null ? view.width : span * px;

  // Zooming keeps the time under the anchor (the pointer) where it was: remember it,
  // and once the new scale is laid out, scroll to put it back.
  const anchor = useRef<{ time: number; offset: number } | null>(null);
  const zoomTo = (next: number, clientX: number): void => {
    const box = scroller.current;
    const track = content.current;
    if (!box || !track) return;
    const target = clampZoom(next, fit);
    if (Math.abs(target - px) < 1e-6) return;
    anchor.current = {
      time: (clientX - track.getBoundingClientRect().left) / px,
      offset: clientX - box.getBoundingClientRect().left,
    };
    setZoom(target <= fit * 1.001 ? null : target);
  };
  useLayoutEffect(() => {
    const a = anchor.current;
    const box = scroller.current;
    anchor.current = null;
    if (a && box) box.scrollLeft = a.time * px - a.offset;
  }, [px]);

  // The wheel listener is native and not passive, so it can stop the page zooming too.
  const zoomByWheel = useRef((_factor: number, _clientX: number) => {});
  zoomByWheel.current = (factor, clientX) => zoomTo(px * factor, clientX);
  useEffect(() => {
    const box = scroller.current;
    if (!box) return;
    const onWheel = (e: WheelEvent): void => {
      if (!e.ctrlKey && !e.metaKey) return;
      e.preventDefault();
      zoomByWheel.current(Math.exp(-e.deltaY * WHEEL_ZOOM), e.clientX);
    };
    box.addEventListener("wheel", onWheel, { passive: false });
    return () => box.removeEventListener("wheel", onWheel);
  }, []);

  /** Zoom buttons act around the playhead, or the middle of the view if it is out of sight. */
  const zoomButton = (factor: number): void => {
    const box = scroller.current;
    const track = content.current;
    if (!box || !track) return;
    const rect = box.getBoundingClientRect();
    const head = track.getBoundingClientRect().left + (video?.currentTime ?? 0) * px;
    zoomTo(
      px * factor,
      head >= rect.left && head <= rect.right ? head : rect.left + rect.width / 2,
    );
  };

  // The playhead follows the video every frame while it plays, without a React
  // render per frame, and scrolls the track to stay in view.
  const pxNow = useRef(px);
  pxNow.current = px;
  const place = (time: number, follow: boolean): void => {
    const head = playhead.current;
    const box = scroller.current;
    if (!head || !box) return;
    const x = time * pxNow.current;
    head.style.transform = `translateX(${x}px)`;
    if (follow && (x < box.scrollLeft || x > box.scrollLeft + box.clientWidth)) {
      box.scrollLeft = x - box.clientWidth / 4;
    }
  };
  useVideoClock(video, (time) => place(time, !!video && !video.paused));
  // biome-ignore lint/correctness/useExhaustiveDependencies: re-place the playhead on a new scale
  useLayoutEffect(() => place(video?.currentTime ?? 0, false), [px, video]);

  const timeAt = (clientX: number): number => {
    const box = content.current?.getBoundingClientRect();
    if (!box) return 0;
    return Math.min(span, Math.max(0, (clientX - box.left) / px));
  };
  const seek = (time: number): void => {
    if (video) video.currentTime = time;
  };

  /** Click or drag to seek: the ruler and both tracks. */
  const scrub = {
    onPointerDown: (e: PointerEvent<HTMLElement>) => {
      e.currentTarget.setPointerCapture(e.pointerId);
      seek(timeAt(e.clientX));
    },
    onPointerMove: (e: PointerEvent<HTMLElement>) => {
      if (e.currentTarget.hasPointerCapture(e.pointerId)) seek(timeAt(e.clientX));
    },
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
      if (p && editor) {
        onEdit(
          (t) => editor.retimeWord(t, p.index, p.edge, p.time, offsetMs),
          `retime:${p.index}:${p.edge}`,
        );
      }
    });
  };
  useEffect(() => () => cancelAnimationFrame(commitFrame.current), []);

  const rowLabel = "flex items-center px-3 text-[11px] font-semibold text-muted-foreground";
  return (
    <div className="flex h-full min-h-0 flex-col">
      <Transport duration={duration} fps={fps}>
        <button
          type="button"
          data-testid="undo"
          aria-label={t("Undo")}
          title={t("Undo")}
          disabled={!canUndo}
          onClick={onUndo}
          className={BUTTON}
        >
          <Undo2 className="h-4 w-4" aria-hidden />
        </button>
        <button
          type="button"
          data-testid="redo"
          aria-label={t("Redo")}
          title={t("Redo")}
          disabled={!canRedo}
          onClick={onRedo}
          className={BUTTON}
        >
          <Redo2 className="h-4 w-4" aria-hidden />
        </button>
        <button
          type="button"
          data-testid="zoom-out"
          aria-label={t("Zoom out")}
          disabled={zoom === null}
          onClick={() => zoomButton(1 / ZOOM_STEP)}
          className={BUTTON}
        >
          <ZoomOut className="h-4 w-4" aria-hidden />
        </button>
        <button
          type="button"
          data-testid="zoom-in"
          aria-label={t("Zoom in")}
          disabled={px >= Math.max(fit, 400) - 1e-6}
          onClick={() => zoomButton(ZOOM_STEP)}
          className={BUTTON}
        >
          <ZoomIn className="h-4 w-4" aria-hidden />
        </button>
        <button
          type="button"
          data-testid="zoom-fit"
          aria-label={t("Fit the whole video")}
          disabled={zoom === null}
          onClick={() => setZoom(null)}
          className={BUTTON}
        >
          <Maximize2 className="h-4 w-4" aria-hidden />
        </button>
      </Transport>
      <div className="flex min-h-0 flex-1 overflow-y-auto">
        <div className="w-20 shrink-0">
          <div className="h-6" />
          <div className={`${rowLabel} h-9`}>{t("Video")}</div>
          <div className={`${rowLabel} h-12`}>{t("Captions")}</div>
        </div>
        <div ref={scroller} className="relative min-w-0 flex-1 overflow-x-auto overflow-y-hidden">
          <div ref={content} className="relative" style={{ width }}>
            <div
              data-testid="timeline-ruler"
              className="relative h-6 cursor-pointer touch-none"
              {...scrub}
            >
              <Ruler pxPerSecond={px} span={span} from={view.left} to={view.left + view.width} />
            </div>
            <div
              data-testid="timeline-video"
              className="relative h-9 cursor-pointer touch-none py-1"
              {...scrub}
            >
              <div
                className="h-full overflow-hidden rounded-lg bg-muted px-2.5 text-[11px] font-semibold leading-7 text-muted-foreground"
                style={{ width: duration * px }}
              >
                <span className="pointer-events-none whitespace-nowrap">{title}</span>
              </div>
            </div>
            <div
              data-testid="timeline"
              className="relative h-12 cursor-pointer touch-none"
              onPointerDown={(e) => {
                setSelected(null);
                scrub.onPointerDown(e);
              }}
              onPointerMove={scrub.onPointerMove}
            >
              <CaptionTrack
                lines={lines}
                pxPerSecond={px}
                selected={selected}
                onSelect={setSelected}
                seek={seek}
                timeAt={timeAt}
                onRetime={retime}
              />
            </div>
            <div
              ref={playhead}
              data-testid="timeline-playhead"
              className="pointer-events-none absolute inset-y-0 left-0 z-20 w-0.5 -translate-x-1/2 bg-foreground will-change-transform"
            />
          </div>
        </div>
      </div>
    </div>
  );
}
