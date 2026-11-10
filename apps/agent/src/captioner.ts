/**
 * The actions the command line and the MCP server offer, on a server or on this computer. With
 * neither OPENCAPTIONS_URL nor OPENCAPTIONS_KEY set, the work is done here (`local/`); otherwise on
 * the server they name. A project is an id on a server and a file beside the video here.
 */
import {
  type CaptionRequest,
  captionVideo,
  defaultOutput,
  exportSubtitles,
  fixWords,
  getProject,
  type Outcome,
  type Progress,
  readTranscript,
  resume,
  type SaveOptions,
  saveVideo,
  setStyle,
  type Ticket,
  type TranscriptView,
  type WordFix,
} from "./captions.ts";
import { type Api, api, connectionFromEnv, type StyleConfig } from "./client.ts";

export interface Captioner {
  caption(request: CaptionRequest, progress: Progress, deadline?: number): Promise<Outcome>;
  resume(ticket: Ticket, progress: Progress, deadline?: number): Promise<Outcome>;
  setStyle(
    projectId: string,
    look: string | undefined,
    changes?: Partial<StyleConfig>,
  ): Promise<StyleConfig>;
  readTranscript(projectId: string): Promise<TranscriptView>;
  fixWords(projectId: string, fixes: WordFix[]): Promise<number>;
  save(
    projectId: string,
    options: SaveOptions,
    progress: Progress,
    deadline?: number,
  ): Promise<Outcome>;
  /** Next to the video unless `output` is given. Returns the path written. */
  exportSubtitles(
    projectId: string,
    kind: "srt" | "vtt" | "json",
    output?: string,
  ): Promise<string>;
}

export function serverCaptioner(client: Api): Captioner {
  return {
    caption: (request, progress, deadline) => captionVideo(client, request, progress, deadline),
    resume: (ticket, progress, deadline) => resume(client, ticket, progress, deadline),
    setStyle: (id, look, changes) => setStyle(client, id, look, changes),
    readTranscript: (id) => readTranscript(client, id),
    fixWords: (id, fixes) => fixWords(client, id, fixes),
    save: async (id, options, progress, deadline) => {
      const stem = defaultOutput((await getProject(client, id)).title, options.captions_only);
      return saveVideo(client, id, { ...options, stem }, progress, deadline);
    },
    exportSubtitles: async (id, kind, output) =>
      exportSubtitles(
        client,
        id,
        kind,
        output ?? defaultOutput((await getProject(client, id)).title),
      ),
  };
}

/** Whether the environment names a server; without one, the work is done on this computer. */
export function wantsServer(env: NodeJS.ProcessEnv = process.env): boolean {
  return Boolean(env.OPENCAPTIONS_URL?.trim() || env.OPENCAPTIONS_KEY?.trim());
}

export async function captionerFromEnv(env: NodeJS.ProcessEnv = process.env): Promise<Captioner> {
  if (wantsServer(env)) return serverCaptioner(api(connectionFromEnv(env)));
  const { localCaptioner } = await import("./local/index.ts");
  return localCaptioner();
}
