/**
 * The MCP server: the same actions as the command line, as tools an agent calls over stdio. A tool
 * that waits for the server reports progress, and stops waiting before clients give up on a call:
 * it hands back a ticket instead, and `check_progress` carries on from it.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type Tool,
} from "@modelcontextprotocol/sdk/types.js";
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
} from "./captions.ts";
import { type Api, api, connectionFromEnv, OpenCaptionsError, type StyleConfig } from "./client.ts";
import { describeLook, describeStyle, LOOKS, SAVE_SCHEMA, STYLE_SCHEMA } from "./looks.ts";
import { VERSION } from "./version.ts";

/** How long a tool waits for the server before handing back a ticket, in seconds. */
const WAIT_S = Number(process.env.OPENCAPTIONS_WAIT_SECONDS) || 45;

const save = SAVE_SCHEMA.properties;
const saveProperties = {
  format: { type: "string", description: "mp4 (the default), mp4-hevc, webm or mov (ProRes)" },
  resolution: { ...save.resolution, description: "The short side in pixels, or the source's" },
  frame_rate: { ...save.frame_rate, description: "Frames per second, or the source's" },
  captions_only: {
    type: "boolean",
    description:
      "The captions alone over solid green, with no sound, to key out in Remotion or a video editor",
  },
  output: {
    type: "string",
    description: "Where to write the file. Default: next to the source, named <name>.captioned",
  },
};
const project = { type: "string", description: "The project id a caption_video call returned" };

const TOOLS: Tool[] = [
  {
    name: "caption_video",
    description:
      "Adds animated word-by-word captions to a video: transcribes the speech, styles it with a " +
      "look, and saves the captioned video next to the source. Returns its path and a project id " +
      "for follow-ups (get_transcript, fix_words, set_style, save_video). If it takes longer than " +
      "the call allows, it returns a ticket: pass it to check_progress.",
    inputSchema: {
      type: "object",
      properties: {
        source: {
          type: "string",
          description: "A video file path, or a direct http(s) link to one",
        },
        look: {
          type: "string",
          description: `A built-in look (list_looks): ${LOOKS.map((l) => l.name).join(", ")}`,
        },
        style: {
          ...STYLE_SCHEMA,
          description: "Style settings over the look (describe_style lists every one)",
        },
        language: { type: "string", description: "ISO 639-1 code, or auto (the default)" },
        model: {
          type: "string",
          description: "A speech model id the server offers; its default if left out",
        },
        ...saveProperties,
      },
      required: ["source"],
    },
  },
  {
    name: "check_progress",
    description: "Carries on with a caption_video or save_video that returned a ticket.",
    inputSchema: {
      type: "object",
      properties: { ticket: { type: "object", description: "The ticket, as it was returned" } },
      required: ["ticket"],
    },
  },
  {
    name: "list_looks",
    description: "The built-in caption looks, each with its animation, font and colours.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "describe_style",
    description:
      "Every style setting with its type, range, default and meaning, for caption_video's and " +
      "set_style's `style`.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "get_transcript",
    description:
      "A project's captions as they show on the video, and every word with its index, to check " +
      "names and spelling before fix_words.",
    inputSchema: { type: "object", properties: { project_id: project }, required: ["project_id"] },
  },
  {
    name: "fix_words",
    description:
      "Sets words by the index get_transcript gave them, keeping their timing; empty text removes " +
      "a word. Then save_video writes the video again.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: project,
        fixes: {
          type: "array",
          items: {
            type: "object",
            properties: { index: { type: "integer", minimum: 0 }, text: { type: "string" } },
            required: ["index", "text"],
          },
        },
      },
      required: ["project_id", "fixes"],
    },
  },
  {
    name: "set_style",
    description:
      "Changes a project's style: a look, settings over it, or settings alone over the style it " +
      "has. Then save_video writes the video again.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: project,
        look: { type: "string", description: "A built-in look (list_looks)" },
        style: { ...STYLE_SCHEMA, description: "Style settings (describe_style)" },
      },
      required: ["project_id"],
    },
  },
  {
    name: "save_video",
    description:
      "Saves a project's captioned video again, after fix_words or set_style, or in another " +
      "format, size or as captions only.",
    inputSchema: {
      type: "object",
      properties: { project_id: project, ...saveProperties },
      required: ["project_id"],
    },
  },
  {
    name: "export_subtitles",
    description: "Writes a project's captions as SRT or VTT subtitles, or its transcript as JSON.",
    inputSchema: {
      type: "object",
      properties: {
        project_id: project,
        format: { type: "string", enum: ["srt", "vtt", "json"] },
        output: { type: "string", description: "Where to write it; next to the video by default" },
      },
      required: ["project_id", "format"],
    },
  },
];

type Args = Record<string, unknown>;

/** What a tool says back: the outcome in words, with the details as JSON for the next call. */
function said(text: string, details?: unknown) {
  const body = details === undefined ? text : `${text}\n${JSON.stringify(details, null, 2)}`;
  return { content: [{ type: "text" as const, text: body }] };
}

function outcome(result: Outcome) {
  return result.done
    ? said(`Saved ${result.output}`, { project_id: result.project_id, output: result.output })
    : said(`${result.message} Call check_progress with this ticket.`, { ticket: result.ticket });
}

function saveArgs(args: Args): SaveOptions {
  return {
    format: args.format as string | undefined,
    resolution: args.resolution as SaveOptions["resolution"],
    frame_rate: args.frame_rate as SaveOptions["frame_rate"],
    captions_only: args.captions_only as boolean | undefined,
    output: args.output as string | undefined,
  };
}

async function call(client: Api, name: string, args: Args, progress: Progress) {
  const deadline = Date.now() + WAIT_S * 1000;
  const id = args.project_id as string;
  switch (name) {
    case "caption_video":
      return outcome(
        await captionVideo(
          client,
          { ...(args as unknown as CaptionRequest), ...saveArgs(args) },
          progress,
          deadline,
        ),
      );
    case "check_progress":
      return outcome(await resume(client, args.ticket as Ticket, progress, deadline));
    case "list_looks":
      return said(LOOKS.map(describeLook).join("\n"));
    case "describe_style":
      return said(describeStyle());
    case "get_transcript":
      return said(
        "Captions as shown, then each word with its index:",
        await readTranscript(client, id),
      );
    case "fix_words":
      return said(
        `Fixed ${await fixWords(client, id, args.fixes as { index: number; text: string }[])} words. Call save_video to write the video again.`,
      );
    case "set_style": {
      const style = await setStyle(
        client,
        id,
        args.look as string | undefined,
        args.style as Partial<StyleConfig>,
      );
      return said("The style is set. Call save_video to write the video again.", style);
    }
    case "save_video": {
      const options = saveArgs(args);
      const stem = defaultOutput((await getProject(client, id)).title, options.captions_only);
      return outcome(await saveVideo(client, id, { ...options, stem }, progress, deadline));
    }
    case "export_subtitles": {
      const kind = args.format as "srt" | "vtt" | "json";
      const output =
        (args.output as string | undefined) ?? defaultOutput((await getProject(client, id)).title);
      return said(`Wrote ${await exportSubtitles(client, id, kind, output)}`);
    }
    default:
      throw new OpenCaptionsError(`There is no tool called ${name}.`);
  }
}

export function createServer(connect: () => Api = () => api(connectionFromEnv())): Server {
  const server = new Server(
    { name: "opencaptions", version: VERSION },
    {
      capabilities: { tools: {} },
      instructions:
        "OpenCaptions adds animated word-by-word captions to videos, on the user's own OpenCaptions " +
        "server. caption_video does it in one call; the other tools adjust the result.",
    },
  );
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));
  server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
    const token = request.params._meta?.progressToken;
    const progress: Progress = (fraction, message) => {
      if (token === undefined) return;
      void extra.sendNotification({
        method: "notifications/progress",
        params: { progressToken: token, progress: fraction, total: 1, message },
      });
    };
    try {
      return await call(connect(), request.params.name, request.params.arguments ?? {}, progress);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return { ...said(message), isError: true };
    }
  });
  return server;
}

export async function serve(): Promise<void> {
  await createServer().connect(new StdioServerTransport());
}
