import * as api from "@/lib/api";
import { stripExt } from "@/lib/utils";
import type { Project, TranscriptionProvider } from "@/types";

/** Transcription options for creating a project and starting its first job. */
export interface StartOptions {
  title?: string;
  provider?: TranscriptionProvider;
  model?: string;
  language?: string;
}

/**
 * The single "create a project from a local file, then start transcription"
 * path used by the /upload form. The caller navigates to the returned project.
 * Keeping project creation and transcription kickoff together prevents the file
 * and URL modes from drifting.
 *
 * Defaults mirror the upload form's out-of-the-box state: the privacy-first
 * local provider and auto language detection.
 */
export async function startProjectFromFile(file: File, opts: StartOptions = {}): Promise<Project> {
  const title = (opts.title ?? "").trim() || stripExt(file.name) || "Untitled";
  const project = await api.createProject(title, file);
  await api.startTranscription(project.id, {
    provider: opts.provider ?? "local",
    model: opts.model,
    language: opts.language ?? "auto",
  });
  return project;
}

/** URL counterpart of {@link startProjectFromFile}, used by /upload URL mode. */
export async function startProjectFromUrl(
  videoUrl: string,
  opts: StartOptions = {},
): Promise<Project> {
  const title = (opts.title ?? "").trim() || "Untitled";
  const project = await api.createProjectFromUrl(title, videoUrl);
  await api.startTranscription(project.id, {
    provider: opts.provider ?? "local",
    model: opts.model,
    language: opts.language ?? "auto",
  });
  return project;
}
