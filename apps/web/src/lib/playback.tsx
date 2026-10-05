/**
 * The editor's one <video>, shared by components that are not nested in one
 * another: the preview attaches it, and the timeline and transport read it.
 *
 * Only the element is shared. The playing time never goes through React state or
 * the store: each reader follows the element itself (a frame loop writing to a
 * ref'd node), so a playing video does not re-render the editor.
 */
import { createContext, type ReactNode, type RefObject, useContext, useRef } from "react";

const PlaybackContext = createContext<RefObject<HTMLVideoElement | null> | null>(null);

export function PlaybackProvider({ children }: { children: ReactNode }) {
  const video = useRef<HTMLVideoElement>(null);
  return <PlaybackContext.Provider value={video}>{children}</PlaybackContext.Provider>;
}

/** The editor's video element, once the preview has mounted it. */
export function useVideoRef(): RefObject<HTMLVideoElement | null> {
  const video = useContext(PlaybackContext);
  if (!video) throw new Error("useVideoRef needs a PlaybackProvider");
  return video;
}
