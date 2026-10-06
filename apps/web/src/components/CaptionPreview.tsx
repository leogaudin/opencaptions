/**
 * The editor preview: the source video with the caption engine drawing over it.
 *
 * Sized to fit its container, in width and height, keeping the video's aspect
 * ratio: a 9:16 video fills the height of its panel, a 16:9 one its width.
 */
import { type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import {
  type ActiveCaption,
  type CaptionRenderer,
  createCaptionRenderer,
  type SceneInput,
  useCaptionEditor,
} from "@/lib/engine";
import { previewQueryForSource, probePlaybackSupport } from "@/lib/mediaSupport";
import { useAttachVideo, useVideo } from "@/lib/playback";
import { useThrottledPatch } from "@/lib/useThrottledPatch";
import { useEditorStore } from "@/store/editorStore";
import type { StyleConfig, Transcript } from "@/types";

const FALLBACK_WIDTH = 1080;
const FALLBACK_HEIGHT = 1920;

const EMPTY: Transcript = {
  schema_version: 1,
  language: "en",
  language_detection: "auto",
  duration: 1,
  segments: [],
};

/** How close the caption's centre comes to a centre line of the video before it snaps, in screen pixels. */
const SNAP_PX = 8;

const clamp01 = (v: number): number => Math.min(1, Math.max(0, v));

function sameCaption(a: ActiveCaption | null, b: ActiveCaption | null): boolean {
  if (a === b) return true;
  if (!a || !b) return false;
  // Geometry is fixed per scene, so index + block rect identify it; the pop
  // animation changes neither.
  return (
    a.index === b.index &&
    a.bounds.x === b.bounds.x &&
    a.bounds.y === b.bounds.y &&
    a.bounds.w === b.bounds.w &&
    a.bounds.h === b.bounds.h
  );
}

interface Editing {
  /** The word's flat index across segments, as the engine counts lines. */
  index: number;
  text: string;
  left: number;
  top: number;
  width: number;
  height: number;
}

/**
 * Draws the engine's overlay for whatever frame the video is showing, and lets
 * the caption be dragged to reposition it and a word double-clicked to edit it
 * (several words split it; clearing it deletes the word).
 * Both read the engine's own geometry, so the hit targets match the pixels.
 */
function CaptionCanvas({
  video,
  scene,
  displayWidth,
  displayHeight,
}: {
  video: HTMLVideoElement | null;
  scene: SceneInput;
  displayWidth: number;
  displayHeight: number;
}) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [renderer, setRenderer] = useState<CaptionRenderer | null>(null);
  const [active, setActive] = useState<ActiveCaption | null>(null);
  const activeRef = useRef<ActiveCaption | null>(null);
  const [editing, setEditing] = useState<Editing | null>(null);
  // An edit resolves exactly once: Enter/Escape resolve it, and the blur that
  // fires as the input unmounts must then do nothing.
  const resolved = useRef(false);
  const [paused, setPaused] = useState(true);

  const transcript = useEditorStore((s) => s.transcript);
  const wordsPerLine = Math.max(1, scene.style.words_per_line);
  const setStyle = useEditorStore((s) => s.setStyle);
  const setStyleThrottled = useThrottledPatch<StyleConfig>(setStyle);
  const editTranscript = useEditorStore((s) => s.editTranscript);
  const editor = useCaptionEditor();

  // Frame pixels → on-screen pixels. Width and height share the ratio.
  const k = displayWidth / scene.width;

  useEffect(() => {
    let live = true;
    createCaptionRenderer().then(
      (r) => live && setRenderer(r),
      (e: unknown) => console.error("caption engine failed to load", e),
    );
    return () => {
      live = false;
    };
  }, []);

  useEffect(() => {
    const ctx = canvas.current?.getContext("2d");
    const v = video;
    if (!renderer || !ctx || !v) return;
    let live = true;
    let ready = false;
    const draw = (): void => {
      if (!ready) return;
      const image = renderer.render(v.currentTime);
      if (!image) return;
      if (ctx.canvas.width !== image.width || ctx.canvas.height !== image.height) {
        ctx.canvas.width = image.width;
        ctx.canvas.height = image.height;
      }
      ctx.putImageData(image, 0, 0);
      const next = renderer.activeCaption();
      if (!sameCaption(next, activeRef.current)) {
        activeRef.current = next;
        setActive(next);
      }
    };
    // A frame per screen refresh while playing; one draw per seek while paused.
    let frame = 0;
    const loop = (): void => {
      draw();
      frame = v.paused ? 0 : requestAnimationFrame(loop);
    };
    const start = (): void => {
      if (!frame) loop();
    };
    const sync = (): void => setPaused(v.paused);
    const events = ["play", "seeked", "seeking", "pause"] as const;
    for (const e of events) v.addEventListener(e, start);
    v.addEventListener("play", sync);
    v.addEventListener("pause", sync);
    sync();
    renderer.loadFont(scene.style.font).then(
      () => {
        if (!live) return;
        renderer.setScene(scene);
        ready = true;
        draw();
        if (!v.paused) start();
      },
      (e: unknown) => console.error(e),
    );
    return () => {
      live = false;
      cancelAnimationFrame(frame);
      for (const e of events) v.removeEventListener(e, start);
      v.removeEventListener("play", sync);
      v.removeEventListener("pause", sync);
    };
  }, [renderer, scene, video]);

  // Belongs to the gesture, not the scene: every move of a drag changes the style,
  // which rebuilds the scene and re-runs the drawing effect mid-drag.
  const dragFrom = useRef<{ x: number; y: number; px: number; py: number } | null>(null);
  // The centre guides shown while the caption is snapped to them.
  const [guides, setGuides] = useState({ x: false, y: false });

  function onPointerDown(e: React.PointerEvent): void {
    if (editing) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    dragFrom.current = {
      x: e.clientX,
      y: e.clientY,
      px: scene.style.position_x,
      py: scene.style.position_y,
    };
  }
  function onPointerMove(e: React.PointerEvent): void {
    const from = dragFrom.current;
    // No capture means a drag we never started (e.g. the overlay remounted under
    // the pointer after the caption reappeared); ignore it.
    if (!from || !e.currentTarget.hasPointerCapture(e.pointerId)) return;
    const raw = {
      x: clamp01(from.px + (e.clientX - from.x) / displayWidth),
      y: clamp01(from.py + (e.clientY - from.y) / displayHeight),
    };
    // The pull is the engine's, measured against the unsnapped pointer position, so the
    // caption lets go as soon as the pointer does.
    const snapped = editor?.snapPosition(
      raw,
      { width: displayWidth, height: displayHeight },
      SNAP_PX,
    ) ?? { ...raw, onX: false, onY: false };
    setStyleThrottled({ position_x: snapped.x, position_y: snapped.y });
    setGuides((g) =>
      g.x === snapped.onX && g.y === snapped.onY ? g : { x: snapped.onX, y: snapped.onY },
    );
  }
  function endDrag(e: React.PointerEvent): void {
    dragFrom.current = null;
    setGuides({ x: false, y: false });
    e.currentTarget.releasePointerCapture(e.pointerId);
  }

  function onDoubleClick(e: React.MouseEvent): void {
    if (!active || !transcript) return;
    video?.pause();
    const box = e.currentTarget.getBoundingClientRect();
    // Pointer → frame pixels (the overlay sits exactly on the caption block).
    const fx = active.bounds.x + (e.clientX - box.left) / k;
    const fy = active.bounds.y + (e.clientY - box.top) / k;
    const j = active.words.findIndex(
      (w) => fx >= w.x && fx <= w.x + w.w && fy >= w.y && fy <= w.y + w.h,
    );
    const word = active.words[j];
    if (!word) return;
    const index = active.index * wordsPerLine + j;
    const text = transcript.segments.flatMap((s) => s.words)[index]?.text;
    if (text === undefined) return;
    resolved.current = false;
    setEditing({
      index,
      text,
      left: word.x * k,
      top: word.y * k,
      width: word.w * k,
      height: word.h * k,
    });
  }

  function finishEdit(save: boolean): void {
    if (resolved.current) return;
    resolved.current = true;
    if (save && editing) {
      const { index, text } = editing;
      if (editor) editTranscript((t) => editor.setWord(t, index, text));
    }
    setEditing(null);
  }

  const bounds = active && {
    left: active.bounds.x * k,
    top: active.bounds.y * k,
    width: active.bounds.w * k,
    height: active.bounds.h * k,
  };

  return (
    <>
      <canvas ref={canvas} className="pointer-events-none absolute inset-0 h-full w-full" />
      {guides.x && (
        <div
          data-testid="caption-guide-x"
          className="pointer-events-none absolute inset-y-0 left-1/2 w-px bg-white/90 shadow-[0_0_0_1px_rgba(0,0,0,0.35)]"
        />
      )}
      {guides.y && (
        <div
          data-testid="caption-guide-y"
          className="pointer-events-none absolute inset-x-0 top-1/2 h-px bg-white/90 shadow-[0_0_0_1px_rgba(0,0,0,0.35)]"
        />
      )}
      {bounds && !editing && paused && (
        // Shown only while paused, over the caption alone, so a tap anywhere on the
        // playing video still pauses it.
        <button
          type="button"
          data-testid="caption-handle"
          aria-label="Move caption; double-click a word to edit"
          title="Drag to move · double-click a word to edit"
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={endDrag}
          onPointerCancel={endDrag}
          onDoubleClick={onDoubleClick}
          style={bounds}
          className="absolute cursor-move touch-none rounded-sm ring-1 ring-white/0 hover:ring-white/60"
        />
      )}
      {editing && (
        <input
          // biome-ignore lint/a11y/noAutofocus: the field replaces the word just double-clicked
          autoFocus
          data-testid="caption-word-edit"
          value={editing.text}
          // One word at a time: spaces (typed or pasted) are dropped, never split on.
          onChange={(e) => setEditing({ ...editing, text: e.target.value })}
          onBlur={() => finishEdit(true)}
          onKeyDown={(e) => {
            if (e.key === "Enter") finishEdit(true);
            else if (e.key === "Escape") finishEdit(false);
          }}
          style={{
            left: editing.left,
            top: editing.top,
            width: Math.max(editing.width, 60),
            height: editing.height,
          }}
          className="absolute rounded-sm bg-background px-1 text-center text-foreground outline-hidden ring-2 ring-primary"
        />
      )}
    </>
  );
}

export function CaptionPreview() {
  const project = useEditorStore((s) => s.project);
  const transcript = useEditorStore((s) => s.transcript);
  const style = useEditorStore((s) => s.style);
  const captionOffsetMs = useEditorStore((s) => s.captionOffsetMs);

  // Keyed on the id so unrelated store writes keep the same src and the <video>
  // is never reloaded.
  const projectId = project?.id;
  const videoSrc = projectId ? `/api/v1/projects/${projectId}/source` : "";
  const video = useVideo();
  const attachVideo = useAttachVideo();

  // Fallback for when the server-side probe failed at upload.
  const [clientDims, setClientDims] = useState<{ width: number; height: number } | null>(null);
  // Whether this browser cannot decode the source. Downloads are never gated on it.
  const [previewBlocked, setPreviewBlocked] = useState(false);
  // biome-ignore lint/correctness/useExhaustiveDependencies: reset when the project changes
  useEffect(() => setClientDims(null), [videoSrc]);

  const sourceKey = project?.video_storage_key ?? null;
  useEffect(() => {
    setPreviewBlocked(false);
    const query = previewQueryForSource(sourceKey);
    if (!query) return;
    let cancelled = false;
    probePlaybackSupport(query).then((support) => {
      if (!cancelled && support === "unsupported") setPreviewBlocked(true);
    });
    return () => {
      cancelled = true;
    };
  }, [sourceKey]);

  // The room the preview may fill. The container always renders, so this observer
  // is attached whatever the preview shows, and follows the panel as it is resized.
  const container = useRef<HTMLDivElement>(null);
  const [room, setRoom] = useState({ width: 0, height: 0 });
  useEffect(() => {
    const el = container.current;
    if (!el) return;
    const update = (): void =>
      setRoom((r) =>
        r.width === el.clientWidth && r.height === el.clientHeight
          ? r
          : { width: el.clientWidth, height: el.clientHeight },
      );
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const shown = transcript ?? EMPTY;

  const naturalWidth = project?.video_width ?? clientDims?.width ?? FALLBACK_WIDTH;
  const naturalHeight = project?.video_height ?? clientDims?.height ?? FALLBACK_HEIGHT;
  const ratio = naturalWidth / naturalHeight;
  const displayWidth = Math.min(room.width, room.height * ratio);
  const displayHeight = displayWidth / ratio;

  // Drawn at the resolution it is shown at, never above the export's: layout is
  // proportional to frame height, so this is the export's picture at screen size.
  const dpr = typeof window === "undefined" ? 1 : window.devicePixelRatio;
  const sceneHeight = Math.max(2, Math.round(Math.min(naturalHeight, displayHeight * dpr)));
  const scene = useMemo<SceneInput>(
    () => ({
      transcript: shown,
      style,
      width: Math.max(2, Math.round(sceneHeight * ratio)),
      height: sceneHeight,
      caption_offset_ms: captionOffsetMs,
    }),
    [shown, style, sceneHeight, ratio, captionOffsetMs],
  );

  if (!project) return null;

  const note = (body: ReactNode, testId?: string) => (
    <div
      data-testid={testId}
      className="max-w-md rounded-md border border-border bg-card p-6 text-sm text-muted-foreground"
    >
      {body}
    </div>
  );

  return (
    <div ref={container} className="flex h-full min-h-0 w-full items-center justify-center">
      {!project.video_storage_key ? (
        note("No video uploaded yet.")
      ) : shown.segments.length === 0 ? (
        note("Waiting for transcription to complete to show the preview…")
      ) : previewBlocked ? (
        note(
          <>
            <p className="font-medium text-foreground">This browser cannot preview this video.</p>
            <p className="mt-1">
              You can still download it from the toolbar above — the MP4 (H.264) download plays in
              every browser, or open any format in a desktop player like VLC.
            </p>
          </>,
          "preview-unsupported",
        )
      ) : displayWidth > 0 ? (
        <div
          data-testid="caption-preview"
          className="relative shrink-0 overflow-hidden rounded-md border border-border bg-black"
          style={{ width: displayWidth, height: displayHeight }}
        >
          <video
            ref={attachVideo}
            src={videoSrc}
            loop
            playsInline
            preload="metadata"
            className="h-full w-full cursor-pointer"
            // A tap on the picture plays or pauses, as on a phone.
            onClick={(e) => {
              const v = e.currentTarget;
              if (v.paused) v.play().catch(() => undefined);
              else v.pause();
            }}
            onLoadedMetadata={(e) => {
              const v = e.currentTarget;
              if (v.videoWidth && v.videoHeight) {
                setClientDims({ width: v.videoWidth, height: v.videoHeight });
              }
            }}
            onError={() => setPreviewBlocked(true)}
          >
            <track kind="captions" />
          </video>
          <CaptionCanvas
            video={video}
            scene={scene}
            displayWidth={displayWidth}
            displayHeight={displayHeight}
          />
        </div>
      ) : null}
    </div>
  );
}
