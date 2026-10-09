import * as api from "@/lib/api";
import { stripExt } from "@/lib/utils";
import type { Project, TranscriptionProvider } from "@/types";

/** A project that exists, and why its transcription did not start (null: it did). */
export interface Started {
  project: Project;
  transcriptionError: string | null;
}

/** Transcription options for creating a project and starting its first job. */
export interface StartOptions {
  title?: string;
  provider?: TranscriptionProvider;
  model?: string;
  language?: string;
}

/** What a file upload reports and takes: progress, and a way to cancel. */
export type { UploadHooks } from "@/lib/api";

/**
 * The single "create a project from a local file, then start transcription"
 * path used by the /upload form. The caller navigates to the returned project.
 * Keeping project creation and transcription kickoff together prevents the file
 * and URL modes from drifting.
 *
 * Defaults mirror the upload form's out-of-the-box state: the privacy-first
 * local provider and auto language detection.
 */
export async function startProjectFromFile(
  file: File,
  opts: StartOptions = {},
  hooks: api.UploadHooks = {},
): Promise<Started> {
  const title = (opts.title ?? "").trim() || stripExt(file.name) || "Untitled";
  return withTranscription(await api.createProject(title, file, hooks), opts);
}

/** URL counterpart of {@link startProjectFromFile}, used by /upload URL mode. */
export async function startProjectFromUrl(
  videoUrl: string,
  opts: StartOptions = {},
): Promise<Started> {
  const title = (opts.title ?? "").trim() || "Untitled";
  return withTranscription(await api.createProjectFromUrl(title, videoUrl), opts);
}

/**
 * Start the first transcription. The project exists whether or not this works,
 * so a failure is reported beside it: retrying the whole form would make a
 * second copy of the video.
 */
async function withTranscription(project: Project, opts: StartOptions): Promise<Started> {
  try {
    await api.startTranscription(project.id, {
      provider: opts.provider ?? "local",
      model: opts.model,
      language: opts.language ?? "auto",
    });
    return { project, transcriptionError: null };
  } catch (e) {
    return { project, transcriptionError: (e as Error).message };
  }
}
