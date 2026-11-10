/**
 * What the command line and the MCP server do, over the server's API: open a video as a project,
 * transcribe it, give it a look, fix words, and save the captioned video or its subtitles. The server
 * transcribes and draws. `local/` does the same on this computer, with the pieces here that do not
 * depend on where it runs (`styled`, `applyFixes`, `viewTranscript`).
 */
import { createWriteStream, openAsBlob } from "node:fs";
import { rename, rm, stat, writeFile } from "node:fs/promises";
import { basename, dirname, extname, join, resolve } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { ReadableStream as WebStream } from "node:stream/web";
import {
  type Api,
  type Job,
  OpenCaptionsError,
  type RenderRequest,
  type StyleConfig,
  type TranscribeRequest,
  type Transcript,
  unwrap,
} from "./client.ts";
import { type CaptionLine, captionLines, mergeWords, setWord, shuffleVariants } from "./engine.ts";
import { findLook, LOOKS } from "./looks.ts";

/** How far a job has got, from 0 to 1, and what it is doing. */
export type Progress = (fraction: number, message: string) => void;

export interface SaveOptions {
  format?: string;
  resolution?: RenderRequest["resolution"];
  frame_rate?: RenderRequest["frame_rate"];
  /** The captions alone, over green, with no sound: for compositing in an editor or Remotion. */
  captions_only?: boolean;
  /** Where the video goes; next to the source (or in the working folder) when left out. */
  output?: string;
}

export interface CaptionRequest extends SaveOptions {
  /** A video file on this computer, or a direct http(s) link to one. */
  source: string;
  look?: string;
  /** Style settings over the look. */
  style?: Partial<StyleConfig>;
  language?: string;
  model?: string;
  provider?: TranscribeRequest["provider"];
  /** Captions to use instead of transcribing (the API's Transcript). */
  transcript?: Transcript;
}

/** Save options with where the file goes by default: `stem`, given the format's extension. */
export type Destination = SaveOptions & { stem: string };

/**
 * Where a job that outlived the wait was left: hand it back to `resume` to carry on. Everything it
 * needs is in it, so nothing is kept between calls.
 */
export interface Ticket {
  project_id: string;
  job_id: string;
  step: "transcribe" | "save";
  save: Destination;
}

export type Outcome =
  | { done: true; project_id: string; output: string }
  | { done: false; ticket: Ticket; message: string };

/** How often a job is asked about, in milliseconds. */
const pollMs = () => Number(process.env.OPENCAPTIONS_POLL_MS) || 1000;

const isUrl = (source: string) => /^https?:\/\//i.test(source);

/**
 * Where a save writes when no output is given: next to the source, marked as captioned, without
 * the extension, which is the format's.
 */
export function defaultOutput(source: string, captionsOnly = false): string {
  const name = isUrl(source)
    ? basename(new URL(source).pathname) || "video"
    : basename(source, extname(source));
  const stem = name.replace(extname(name), "") || "video";
  const folder = isUrl(source) ? process.cwd() : dirname(resolve(source));
  return join(folder, `${stem}.${captionsOnly ? "captions" : "captioned"}`);
}

export async function openProject(client: Api, source: string): Promise<string> {
  if (isUrl(source)) {
    const title = basename(new URL(source).pathname) || "Video";
    return unwrap(
      await client.POST("/api/v1/projects", {
        body: { title, video_url: source },
        bodySerializer: (body) => form({ title: body.title, video_url: source }),
      }),
    ).id;
  }
  const path = resolve(source);
  const file = await stat(path).catch(() => undefined);
  if (!file?.isFile()) throw new OpenCaptionsError(`There is no video at ${path}.`);
  const video = await openAsBlob(path);
  return unwrap(
    await client.POST("/api/v1/projects", {
      body: { title: basename(path, extname(path)) },
      bodySerializer: (body) => form({ title: body.title }, ["video", video, basename(path)]),
    }),
  ).id;
}

function form(fields: Record<string, string>, file?: [string, Blob, string]): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(fields)) data.append(key, value);
  if (file) data.append(...file);
  return data;
}

export async function getProject(client: Api, projectId: string) {
  return unwrap(
    await client.GET("/api/v1/projects/{project_id}", {
      params: { path: { project_id: projectId } },
    }),
  );
}

async function update(
  client: Api,
  projectId: string,
  body: { transcript?: Transcript; style_config?: StyleConfig },
) {
  return unwrap(
    await client.PATCH("/api/v1/projects/{project_id}", {
      params: { path: { project_id: projectId } },
      body,
    }),
  );
}

export async function startTranscription(
  client: Api,
  projectId: string,
  request: Pick<CaptionRequest, "language" | "model" | "provider">,
): Promise<Job> {
  return unwrap(
    await client.POST("/api/v1/projects/{project_id}/transcribe", {
      params: { path: { project_id: projectId } },
      body: {
        language: request.language ?? "auto",
        model: request.model ?? null,
        provider: request.provider ?? null,
      },
    }),
  );
}

/**
 * Waits for a job, reporting as it goes. True once it has finished; false when `deadline` (a time
 * in milliseconds) came first and it is still going. A job that failed or was cancelled throws.
 */
export async function waitForJob(
  client: Api,
  jobId: string,
  progress: Progress,
  deadline = Number.POSITIVE_INFINITY,
): Promise<boolean> {
  for (;;) {
    const job = unwrap(
      await client.GET("/api/v1/jobs/{job_id}", { params: { path: { job_id: jobId } } }),
    );
    if (job.status === "completed") return true;
    if (job.status === "failed") {
      throw new OpenCaptionsError(job.error ?? job.message ?? "The job failed on the server.");
    }
    if (job.status === "cancelled") throw new OpenCaptionsError("The job was cancelled.");
    progress(
      job.progress,
      job.message ?? (job.type === "transcription" ? "Transcribing" : "Saving"),
    );
    if (Date.now() + pollMs() > deadline) return false;
    await new Promise((done) => setTimeout(done, pollMs()));
  }
}

/**
 * The project's style set to a look, with changes over it; without a look the changes go over the
 * style it has. A look with word variants deals them to the words, as picking it in an editor does.
 */
export async function setStyle(
  client: Api,
  projectId: string,
  look: string | undefined,
  changes: Partial<StyleConfig> = {},
): Promise<StyleConfig> {
  const project = await getProject(client, projectId);
  const style = styled(project.style_config, look, changes);
  const transcript = look ? await dealt(project.transcript ?? undefined, style) : undefined;
  return (
    (await update(client, projectId, { style_config: style, ...(transcript && { transcript }) }))
      .style_config ?? style
  );
}

/** A look with changes over it; without a look the changes go over `current`. */
export function styled(
  current: StyleConfig | null | undefined,
  look: string | undefined,
  changes: Partial<StyleConfig> = {},
): StyleConfig {
  // A project never styled draws as the first look, so changes alone go over that.
  const base = look ? findLook(look).config : (current ?? LOOKS[0]?.config);
  return { ...base, ...changes } as StyleConfig;
}

export async function dealt(transcript: Transcript | undefined, style: StyleConfig) {
  const count = style.variants?.length ?? 0;
  return transcript && count > 0 ? shuffleVariants(transcript, count) : undefined;
}

/** A transcript's captions as they show, and every word with its index. */
export interface TranscriptView {
  lines: CaptionLine[];
  words: { index: number; text: string; start: number }[];
}

/** The words with their place in the captions, for checking names and spelling. */
export async function viewTranscript(
  transcript: Transcript | null | undefined,
  style: StyleConfig | null | undefined,
  offsetMs: number,
): Promise<TranscriptView> {
  if (!transcript) throw new OpenCaptionsError("This project has no captions yet.");
  const words = transcript.segments
    .flatMap((s) => s.words)
    .map((w, index) => ({ index, text: w.text, start: w.start }));
  const lines = await captionLines(transcript, style?.words_per_line ?? 3, offsetMs);
  return { lines, words };
}

export async function readTranscript(client: Api, projectId: string): Promise<TranscriptView> {
  const project = await getProject(client, projectId);
  return viewTranscript(project.transcript, project.style_config, project.caption_offset_ms);
}

/** Word `index` given `text` (empty removes it), or with `count`, that many words joined into one. */
export interface WordFix {
  index: number;
  text: string;
  count?: number;
}

/** The fixes applied by the engine; the indices are the ones read before. */
export async function applyFixes(
  transcript: Transcript | null | undefined,
  fixes: WordFix[],
): Promise<Transcript> {
  if (!transcript) throw new OpenCaptionsError("This project has no captions yet.");
  // Last first: removing or joining words moves the ones after them, never the ones before.
  let fixed = transcript;
  for (const fix of [...fixes].sort((a, b) => b.index - a.index)) {
    fixed =
      (fix.count ?? 1) > 1
        ? await mergeWords(fixed, fix.index, fix.count ?? 1, fix.text)
        : await setWord(fixed, fix.index, fix.text);
  }
  return fixed;
}

export async function fixWords(client: Api, projectId: string, fixes: WordFix[]): Promise<number> {
  const project = await getProject(client, projectId);
  await update(client, projectId, { transcript: await applyFixes(project.transcript, fixes) });
  return fixes.length;
}

function renderRequest(save: SaveOptions): RenderRequest {
  return {
    format: save.format ?? "mp4",
    resolution: save.resolution ?? "original",
    frame_rate: save.frame_rate ?? "original",
    green_screen: save.captions_only ?? false,
  };
}

/** Asks for the video; it comes back at once when an identical one was made before. */
export async function requestVideo(
  client: Api,
  projectId: string,
  save: SaveOptions,
): Promise<string | undefined> {
  const answer = unwrap(
    await client.POST("/api/v1/projects/{project_id}/download", {
      params: { path: { project_id: projectId } },
      body: renderRequest(save),
    }),
  );
  return answer.ready ? undefined : (answer.job_id ?? undefined);
}

/**
 * Writes the finished video to `output`, or to `stem` with the extension of the format the server
 * made. Returns the path written.
 */
export async function downloadVideo(
  client: Api,
  projectId: string,
  save: Destination,
): Promise<string> {
  const request = renderRequest(save);
  const { data, response } = await client.GET(
    "/api/v1/projects/{project_id}/download/{format_id}",
    {
      params: {
        path: { project_id: projectId, format_id: request.format },
        query: {
          resolution: request.resolution,
          frame_rate: request.frame_rate,
          green_screen: request.green_screen,
        },
      },
      parseAs: "stream",
    },
  );
  if (!response.ok || !data) unwrap({ error: await response.json().catch(() => null), response });
  const named = /filename="[^"]*?(\.[a-z0-9]+)"/i.exec(
    response.headers.get("content-disposition") ?? "",
  );
  const output = save.output ?? `${save.stem}${named?.[1] ?? ".mp4"}`;
  const partial = `${output}.part`;
  try {
    await pipeline(Readable.fromWeb(data as WebStream<Uint8Array>), createWriteStream(partial));
    await rename(partial, output);
  } catch (error) {
    await rm(partial, { force: true });
    throw error;
  }
  return output;
}

/** Saves the captioned video, waiting for it up to `deadline`. */
export async function saveVideo(
  client: Api,
  projectId: string,
  save: Destination,
  progress: Progress,
  deadline?: number,
): Promise<Outcome> {
  const job = await requestVideo(client, projectId, save);
  if (job && !(await waitForJob(client, job, progress, deadline))) {
    return pending({ project_id: projectId, job_id: job, step: "save", save });
  }
  progress(1, "Writing the file");
  return {
    done: true,
    project_id: projectId,
    output: await downloadVideo(client, projectId, save),
  };
}

/** The captions as SRT or VTT, or the transcript as JSON, written next to `output`. */
export async function exportSubtitles(
  client: Api,
  projectId: string,
  kind: "srt" | "vtt" | "json",
  output: string,
): Promise<string> {
  const path = extname(output) === `.${kind}` ? output : `${output}.${kind}`;
  const options = { params: { path: { project_id: projectId } }, parseAs: "text" } as const;
  const { data, response } =
    kind === "srt"
      ? await client.GET("/api/v1/projects/{project_id}/export.srt", options)
      : kind === "vtt"
        ? await client.GET("/api/v1/projects/{project_id}/export.vtt", options)
        : await client.GET("/api/v1/projects/{project_id}/export.json", options);
  if (!response.ok || data === undefined) {
    unwrap({ error: await response.json().catch(() => null), response });
  }
  await writeFile(path, data ?? "");
  return path;
}

function pending(ticket: Ticket): Outcome {
  const what = ticket.step === "transcribe" ? "Transcribing" : "Saving the video";
  return { done: false, ticket, message: `${what} is still going on the server.` };
}

/** Opens, transcribes, styles and saves: the whole of "caption this video". */
export async function captionVideo(
  client: Api,
  request: CaptionRequest,
  progress: Progress,
  deadline?: number,
): Promise<Outcome> {
  progress(0, "Sending the video");
  const projectId = await openProject(client, request.source);
  const save = {
    ...request,
    stem: defaultOutput(request.source, request.captions_only),
  };
  if (request.look !== undefined || request.style !== undefined) {
    await setStyle(client, projectId, request.look, request.style);
  }
  if (request.transcript) {
    await update(client, projectId, { transcript: request.transcript });
  } else {
    const job = await startTranscription(client, projectId, request);
    if (!(await waitForJob(client, job.id, progress, deadline))) {
      return pending({
        project_id: projectId,
        job_id: job.id,
        step: "transcribe",
        save: saveOnly(save),
      });
    }
  }
  await afterTranscript(client, projectId);
  return saveVideo(client, projectId, saveOnly(save), progress, deadline);
}

/** A look's word variants go to the words once there are words to give them to. */
async function afterTranscript(client: Api, projectId: string): Promise<void> {
  const project = await getProject(client, projectId);
  const transcript =
    project.style_config && (await dealt(project.transcript ?? undefined, project.style_config));
  if (transcript) await update(client, projectId, { transcript });
}

export function saveOnly(save: Destination): Destination {
  const { format, resolution, frame_rate, captions_only, output, stem } = save;
  return { format, resolution, frame_rate, captions_only, output, stem };
}

/** Carries on from where a ticket was left. */
export async function resume(
  client: Api,
  ticket: Ticket,
  progress: Progress,
  deadline?: number,
): Promise<Outcome> {
  if (!(await waitForJob(client, ticket.job_id, progress, deadline))) return pending(ticket);
  if (ticket.step === "save") {
    progress(1, "Writing the file");
    const output = await downloadVideo(client, ticket.project_id, ticket.save);
    return { done: true, project_id: ticket.project_id, output };
  }
  await afterTranscript(client, ticket.project_id);
  return saveVideo(client, ticket.project_id, ticket.save, progress, deadline);
}
