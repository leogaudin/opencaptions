/**
 * useProjectWebSocket: subscribe to /ws/v1/projects/{id} and surface messages.
 *
 * The hook auto-reconnects with jittered exponential backoff (max 10s).
 * Caller passes a handler invoked for every message except `ping`.
 */
import { useEffect, useRef } from "react";
import type { WSMessage } from "@/types";

export function useProjectWebSocket(
  projectId: string | null | undefined,
  onMessage: (msg: WSMessage) => void,
  /** Called when the socket is open again after a drop, so the caller can catch up on what it missed. */
  onResync?: () => void,
): void {
  const handlerRef = useRef(onMessage);
  handlerRef.current = onMessage;
  const resyncRef = useRef(onResync);
  resyncRef.current = onResync;

  useEffect(() => {
    if (!projectId) return;
    let attempt = 0;
    let stopped = false;
    let ws: WebSocket | null = null;
    let reconnectTimer: number | null = null;
    let reconnected = false;

    const connect = (): void => {
      if (stopped) return;
      const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
      const url = `${proto}//${window.location.host}/ws/v1/projects/${projectId}`;
      ws = new WebSocket(url);

      ws.onopen = () => {
        attempt = 0;
        if (reconnected) resyncRef.current?.();
      };
      ws.onmessage = (e) => {
        try {
          const msg = JSON.parse(e.data) as WSMessage;
          if (msg.type === "ping") return;
          handlerRef.current(msg);
        } catch {
          // ignore non-JSON / malformed messages
        }
      };
      ws.onclose = () => {
        if (stopped) return;
        attempt++;
        reconnected = true;
        // Jitter, so a restarted server is not hit by every tab at once.
        const delay =
          Math.min(10_000, 500 * 2 ** Math.min(attempt, 6)) * (0.75 + Math.random() / 2);
        reconnectTimer = window.setTimeout(connect, delay);
      };
      ws.onerror = () => {
        ws?.close();
      };
    };

    connect();

    return () => {
      stopped = true;
      if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
      ws?.close();
    };
  }, [projectId]);
}
