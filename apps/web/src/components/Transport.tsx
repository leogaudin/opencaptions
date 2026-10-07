/**
 * Transport: play/pause, the timecode and mute, over the editor's one video.
 *
 * The playing time is written straight into a node each frame (`useVideoClock`),
 * never into React state. Keys work wherever focus is not a text field: Space
 * plays or pauses, the arrows step a frame.
 */
import { Pause, Play, Volume2, VolumeX } from "lucide-react";
import { type ReactNode, useEffect, useRef, useState } from "react";
import { useT } from "@/lib/i18n";
import { useVideo, useVideoClock } from "@/lib/playback";
import { formatTimecode } from "@/lib/time";

const BUTTON =
  "inline-flex h-8 w-8 items-center justify-center rounded-full text-foreground transition-colors hover:bg-muted disabled:opacity-40";
/** Play is the one filled control: a solid disc, as in the iOS app. */
const PLAY =
  "inline-flex h-9 w-9 items-center justify-center rounded-full bg-foreground text-background transition-opacity hover:opacity-85 disabled:opacity-50";

/** Whether a key press belongs to the field or control that has focus. */
function typing(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLElement &&
    (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName))
  );
}

export function Transport({
  duration,
  fps,
  children,
}: {
  duration: number;
  fps: number;
  /** Controls kept at the right end of the bar (the timeline's zoom). */
  children?: ReactNode;
}) {
  const t = useT();
  const video = useVideo();
  const time = useRef<HTMLSpanElement>(null);
  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(false);

  useVideoClock(video, (t) => {
    if (time.current) time.current.textContent = formatTimecode(t);
  });

  useEffect(() => {
    if (!video) return;
    const sync = (): void => {
      setPlaying(!video.paused);
      setMuted(video.muted);
    };
    sync();
    const events = ["play", "pause", "volumechange"] as const;
    for (const e of events) video.addEventListener(e, sync);
    return () => {
      for (const e of events) video.removeEventListener(e, sync);
    };
  }, [video]);

  const toggle = (): void => {
    if (!video) return;
    if (video.paused) video.play().catch(() => undefined);
    else video.pause();
  };

  // Frame stepping lands on the next frame boundary, so repeated presses walk
  // frames instead of drifting by rounding.
  useEffect(() => {
    if (!video) return;
    const onKey = (e: KeyboardEvent): void => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || typing(e.target)) return;
      // A focused button or link activates itself on Space, and a dialog or menu
      // owns its keys.
      const control =
        e.target instanceof HTMLElement &&
        e.target.closest("button, a, [role=button], [role=dialog], [role=menu], [role=listbox]");
      if (e.key === " " && !control) {
        e.preventDefault();
        if (video.paused) video.play().catch(() => undefined);
        else video.pause();
      } else if ((e.key === "ArrowLeft" || e.key === "ArrowRight") && !control) {
        e.preventDefault();
        video.pause();
        const frame = Math.round(video.currentTime * fps) + (e.key === "ArrowLeft" ? -1 : 1);
        video.currentTime = Math.min(Math.max(0, frame / fps), video.duration || duration);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [video, fps, duration]);

  return (
    <div data-testid="transport" className="flex items-center gap-3 px-4 py-2">
      <button
        type="button"
        data-testid="transport-play"
        aria-label={playing ? t("Pause") : t("Play")}
        disabled={!video}
        onClick={toggle}
        className={PLAY}
      >
        {playing ? (
          <Pause className="h-4 w-4" aria-hidden />
        ) : (
          <Play className="h-4 w-4" aria-hidden />
        )}
      </button>
      <span
        data-testid="transport-time"
        aria-live="off"
        className="font-mono text-xs tabular-nums text-muted-foreground"
      >
        <span ref={time} className="text-foreground">
          {formatTimecode(0)}
        </span>{" "}
        / {formatTimecode(duration)}
      </span>
      <button
        type="button"
        aria-label={muted ? t("Unmute") : t("Mute")}
        disabled={!video}
        onClick={() => {
          if (video) video.muted = !video.muted;
        }}
        className={BUTTON}
      >
        {muted ? (
          <VolumeX className="h-4 w-4" aria-hidden />
        ) : (
          <Volume2 className="h-4 w-4" aria-hidden />
        )}
      </button>
      {children && <div className="ml-auto flex items-center gap-2">{children}</div>}
    </div>
  );
}
