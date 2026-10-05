/**
 * The editor's one <video>, shared by components that are not nested in one
 * another: the preview attaches it, and the timeline and transport follow it.
 *
 * Only the element is shared, and held in state so a reader mounted before the
 * preview (the dock can be) picks it up when it appears. The playing time never
 * goes through React state or the store: each reader follows the element itself
 * (`useVideoClock` writing to a node), so a playing video does not re-render the
 * editor.
 */
import {
  createContext,
  type ReactNode,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

interface Playback {
  video: HTMLVideoElement | null;
  attach: (el: HTMLVideoElement | null) => void;
}

const PlaybackContext = createContext<Playback | null>(null);

export function PlaybackProvider({ children }: { children: ReactNode }) {
  const [video, attach] = useState<HTMLVideoElement | null>(null);
  const value = useMemo(() => ({ video, attach }), [video]);
  return <PlaybackContext.Provider value={value}>{children}</PlaybackContext.Provider>;
}

function usePlayback(): Playback {
  const playback = useContext(PlaybackContext);
  if (!playback) throw new Error("playback hooks need a PlaybackProvider");
  return playback;
}

/** The editor's video element, or null until the preview has mounted it. */
export function useVideo(): HTMLVideoElement | null {
  return usePlayback().video;
}

/** A ref callback for the one <video> that the preview renders. */
export function useAttachVideo(): (el: HTMLVideoElement | null) => void {
  return usePlayback().attach;
}

const CLOCK_EVENTS = [
  "play",
  "pause",
  "seeking",
  "seeked",
  "timeupdate",
  "loadedmetadata",
] as const;

/**
 * Calls `onTime` with the video's time on every screen refresh while it plays, and
 * once after each seek or pause, so a paused video is always shown where it is.
 */
export function useVideoClock(video: HTMLVideoElement | null, onTime: (t: number) => void): void {
  const latest = useRef(onTime);
  latest.current = onTime;
  useEffect(() => {
    if (!video) return;
    let frame = 0;
    const tick = (): void => {
      latest.current(video.currentTime);
      frame = video.paused ? 0 : requestAnimationFrame(tick);
    };
    const start = (): void => {
      if (!frame) tick();
    };
    start();
    for (const e of CLOCK_EVENTS) video.addEventListener(e, start);
    return () => {
      cancelAnimationFrame(frame);
      for (const e of CLOCK_EVENTS) video.removeEventListener(e, start);
    };
  }, [video]);
}
