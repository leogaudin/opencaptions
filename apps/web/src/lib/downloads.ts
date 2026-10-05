/**
 * Downloads that wait for a render. A requested video is often not ready yet;
 * the render runs on the server whatever page the user is on, so the wait is
 * kept here, outside any page, and remembered across reloads in sessionStorage.
 * It polls the job rather than following a project's WebSocket, which only
 * exists while that project's editor is open.
 */
import { useSyncExternalStore } from "react";
import { ApiException, getDownloadUrl, getJob } from "@/lib/api";

interface Pending {
  projectId: string;
  format: string;
}

const KEY = "opencaptions:pending-downloads";
const POLL_MS = 1500;
const EXTENSIONS: Record<string, string> = { mov: "mov", webm: "webm" };

const read = (): Record<string, Pending> => {
  try {
    return JSON.parse(sessionStorage.getItem(KEY) ?? "{}") as Record<string, Pending>;
  } catch {
    return {};
  }
};

let pending: Record<string, Pending> = read();
const listeners = new Set<() => void>();
let timer: ReturnType<typeof setInterval> | undefined;

function commit(next: Record<string, Pending>): void {
  pending = next;
  sessionStorage.setItem(KEY, JSON.stringify(next));
  for (const l of listeners) l();
  if (Object.keys(next).length === 0) {
    clearInterval(timer);
    timer = undefined;
  } else {
    timer ??= setInterval(poll, POLL_MS);
  }
}

const without = (jobId: string) =>
  Object.fromEntries(Object.entries(pending).filter(([id]) => id !== jobId));

/** Save a ready video through the browser. */
export function saveVideo(projectId: string, format: string): void {
  const a = document.createElement("a");
  a.href = getDownloadUrl(projectId, format);
  a.download = `opencaptions-${projectId}.${EXTENSIONS[format] ?? "mp4"}`;
  // Firefox ignores a click on an anchor that is not in the document.
  document.body.append(a);
  a.click();
  a.remove();
}

async function poll(): Promise<void> {
  // A hidden tab cannot start a download; the next visible tick does it.
  if (document.visibilityState !== "visible") return;
  await Promise.all(
    Object.entries(pending).map(async ([jobId, { projectId, format }]) => {
      // Only a verdict ends the wait: a dropped request or an API restart must
      // not lose a render that is still running.
      const job = await getJob(jobId).catch((e: unknown) =>
        e instanceof ApiException && e.status === 404 ? null : undefined,
      );
      if (job === undefined) return;
      if (job === null || job.status === "failed" || job.status === "cancelled") {
        commit(without(jobId));
      } else if (job.status === "completed" && pending[jobId]) {
        commit(without(jobId));
        saveVideo(projectId, format);
      }
    }),
  );
}

/** Download `format` of `projectId` once render `jobId` finishes. */
export function downloadWhenReady(jobId: string, projectId: string, format: string): void {
  commit({ ...pending, [jobId]: { projectId, format } });
}

/** Stop waiting for a render, e.g. after cancelling it. */
export function forgetDownload(jobId: string): void {
  if (pending[jobId]) commit(without(jobId));
}

/** Pick up downloads a reload interrupted. */
export function resumeDownloads(): void {
  commit(pending);
  document.addEventListener("visibilitychange", () => void poll());
}

const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => listeners.delete(l);
};

/** The format a project is waiting to download, if any. */
export function usePendingDownload(projectId: string | undefined): string | null {
  return useSyncExternalStore(
    subscribe,
    () => Object.values(pending).find((p) => p.projectId === projectId)?.format ?? null,
  );
}
