import { useCallback, useEffect, useRef } from "react";

/**
 * Coalesce rapid partial updates into one dispatch per animation frame.
 *
 * Drag handlers (colour pickers, range inputs) fire input events at ~60Hz.
 * Dispatching each one re-renders the editor and re-lays out the preview, so
 * patches are merged and applied once per frame instead.
 * Pending work is cancelled on unmount.
 */
export function useThrottledPatch<T>(apply: (patch: Partial<T>) => void) {
  const pendingRef = useRef<Partial<T> | null>(null);
  const frameRef = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (frameRef.current !== null) cancelAnimationFrame(frameRef.current);
    },
    [],
  );

  return useCallback(
    (patch: Partial<T>) => {
      pendingRef.current = { ...(pendingRef.current ?? {}), ...patch };
      if (frameRef.current !== null) return;
      frameRef.current = requestAnimationFrame(() => {
        frameRef.current = null;
        const next = pendingRef.current;
        pendingRef.current = null;
        if (next) apply(next);
      });
    },
    [apply],
  );
}
