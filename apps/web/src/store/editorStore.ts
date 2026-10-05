/**
 * Editor store: project, transcript, style, jobs.
 *
 * Edits are local until autosave persists them 800ms after the last change.
 * There is no Save button and none should be added.
 */
import { create } from "zustand";
import * as api from "@/lib/api";
import { createAutosave } from "@/lib/autosave";
import { clampCaptionOffsetMs } from "@/lib/captionOffset";
import { downloadWhenReady, forgetDownload, saveVideo } from "@/lib/downloads";
import { defaultStyle, type Job, type Project, type StyleConfig, type Transcript } from "@/types";

type AutosaveStatus = "idle" | "saving" | "saved" | "error";

interface EditorState {
  project: Project | null;
  transcript: Transcript | null;
  style: StyleConfig;
  /** Global caption timing offset in ms (positive = captions later). */
  captionOffsetMs: number;
  /** Newest first. */
  jobs: Job[];
  error: string | null;
  /** The transcription or render in progress, for progress bars. */
  activeJobId: string | null;
  autosaveStatus: AutosaveStatus;
  autosaveError: string | null;

  loadProject: (projectId: string) => Promise<void>;
  reloadProject: () => Promise<void>;
  setStyle: (s: Partial<StyleConfig>) => void;
  /** Clamped and autosaved. */
  setCaptionOffset: (ms: number) => void;
  /** Applies a pure edit to the transcript: the engine's edits, the only way it changes. */
  editTranscript: (f: (t: Transcript) => Transcript) => void;
  startTranscription: (body?: {
    provider?: "local" | "openai";
    model?: string;
    language?: string;
  }) => Promise<void>;
  /** Download now if ready, otherwise once the render it starts succeeds. */
  requestVideoDownload: (format: string) => Promise<void>;
  cancelActiveJob: () => Promise<void>;
  upsertJob: (j: Job) => void;
  reset: () => void;
}

const initialState = {
  project: null,
  transcript: null,
  style: defaultStyle,
  captionOffsetMs: 0,
  jobs: [],
  error: null,
  activeJobId: null,
  autosaveStatus: "idle",
  autosaveError: null,
} satisfies Partial<EditorState>;

const FINISHED = new Set<Job["status"]>(["completed", "failed", "cancelled"]);
const SAVED_INDICATOR_MS = 1500;
let savedIndicatorTimer: ReturnType<typeof setTimeout> | undefined;

/** A placeholder for a render the server has just accepted. */
function pendingRender(projectId: string, jobId: string): Job {
  const now = new Date().toISOString();
  return {
    id: jobId,
    project_id: projectId,
    type: "rendering",
    status: "running",
    progress: 0,
    message: null,
    error: null,
    created_at: now,
    updated_at: now,
  };
}

const message = (e: unknown) => (e as Error).message;

export const useEditorStore = create<EditorState>((set, get) => {
  const edit = (patch: Partial<EditorState>) => {
    set(patch);
    autosave.schedule();
  };

  const save = async (): Promise<boolean> => {
    const { project, transcript, style, captionOffsetMs } = get();
    if (!project) return false;
    set({ autosaveStatus: "saving", autosaveError: null });
    try {
      const updated = await api.updateProject(project.id, {
        transcript: transcript ?? undefined,
        style_config: style,
        caption_offset_ms: captionOffsetMs,
      });
      set({ project: updated, autosaveStatus: "saved" });
      clearTimeout(savedIndicatorTimer);
      savedIndicatorTimer = setTimeout(() => {
        if (get().autosaveStatus === "saved") set({ autosaveStatus: "idle" });
      }, SAVED_INDICATOR_MS);
      return true;
    } catch (e) {
      set({ autosaveStatus: "error", autosaveError: message(e), error: message(e) });
      return false;
    }
  };

  const autosave = createAutosave({
    delayMs: 800,
    read: () => {
      const { transcript, style, captionOffsetMs } = get();
      return { transcript, style, captionOffsetMs };
    },
    save,
    // A render hashes its inputs when it starts; editing them mid-render would
    // make the result describe a state nobody has anymore.
    isBlocked: () => get().jobs.find((j) => j.id === get().activeJobId)?.type === "rendering",
  });

  return {
    ...initialState,

    loadProject: async (projectId) => {
      set({ error: null });
      try {
        const project = await api.getProject(projectId);
        const active = project.active_job;
        set({
          project,
          transcript: project.transcript,
          style: project.style_config ?? defaultStyle,
          captionOffsetMs: project.caption_offset_ms ?? 0,
          // Restore live progress on refresh, before the WebSocket catches up.
          activeJobId: active?.id ?? null,
          jobs:
            active && !get().jobs.some((j) => j.id === active.id)
              ? [active, ...get().jobs]
              : get().jobs,
        });
        autosave.markSaved();
      } catch (e) {
        set({ error: message(e) });
      }
    },

    reloadProject: async () => {
      const id = get().project?.id;
      if (id) await get().loadProject(id);
    },

    setStyle: (s) => edit({ style: { ...get().style, ...s } }),

    setCaptionOffset: (ms) => {
      const clamped = clampCaptionOffsetMs(Math.round(ms));
      if (clamped !== get().captionOffsetMs) edit({ captionOffsetMs: clamped });
    },

    editTranscript: (f) => {
      const t = get().transcript;
      if (t) edit({ transcript: f(t) });
    },

    startTranscription: async (body = {}) => {
      const { project } = get();
      if (!project) return;
      const job = await api.startTranscription(project.id, body);
      set({ activeJobId: job.id, jobs: [job, ...get().jobs] });
    },

    requestVideoDownload: async (format) => {
      const { project } = get();
      if (!project) return;
      // The server hashes what it has stored, so pending edits must land first.
      await autosave.flush();
      try {
        const result = await api.requestDownload(project.id, format);
        if (result.ready || !result.job_id) {
          saveVideo(project.id, format);
          return;
        }
        downloadWhenReady(result.job_id, project.id, format);
        set({
          activeJobId: result.job_id,
          jobs: [pendingRender(project.id, result.job_id), ...get().jobs],
        });
      } catch (e) {
        set({ error: message(e) });
      }
    },

    cancelActiveJob: async () => {
      const id = get().activeJobId;
      if (!id) return;
      await api.cancelJob(id);
      forgetDownload(id);
      set({ activeJobId: null });
    },

    upsertJob: (j) => {
      const jobs = get().jobs;
      set({
        jobs: jobs.some((x) => x.id === j.id)
          ? jobs.map((x) => (x.id === j.id ? { ...x, ...j } : x))
          : [j, ...jobs],
      });
      if (FINISHED.has(j.status) && get().activeJobId === j.id) {
        set({ activeJobId: null });
        autosave.release();
      }
    },

    reset: () => {
      autosave.reset();
      clearTimeout(savedIndicatorTimer);
      set(initialState);
    },
  };
});
