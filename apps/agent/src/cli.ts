#!/usr/bin/env node
/**
 * `opencaptions`: captions a video from the command line, or serves the same actions to an agent
 * over MCP (`opencaptions mcp`).
 */
import { readFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { captionerFromEnv } from "./captioner.ts";
import type { CaptionRequest, Progress } from "./captions.ts";
import { OpenCaptionsError, type Transcript } from "./client.ts";
import { describeLook, describeStyle, LOOKS } from "./looks.ts";
import { VERSION } from "./version.ts";

const HELP = `opencaptions ${VERSION}: animated captions for your videos.

  opencaptions caption <video or link> [options]   transcribe, style and save the captioned video
  opencaptions looks                                the built-in looks
  opencaptions style                                every style setting, for --style
  opencaptions mcp                                  serve these to an agent over MCP (stdio)

Options for caption:
  -o, --output <path>      where to write the video (default: <name>.captioned next to it)
  --look <name>            a built-in look (default: Purple Punch)
  --style <json>           style settings over the look, e.g. '{"position_y":0.7}'
  --language <code>        ISO 639-1, or auto (default)
  --model <id>             a speech model the server offers (without one: parakeet-ultra)
  --transcript <file>      use these captions (the API's Transcript JSON) instead of transcribing
  --format <id>            mp4 (default), mp4-hevc, webm or mov
  --resolution <side>      original (default), 2160, 1080 or 720
  --fps <rate>             original (default), 30 or 60
  --captions-only          the captions alone over green, no sound, to key out
  --subtitles <kinds>      also write subtitles: srt, vtt, json, comma separated

It runs on this computer, with FFmpeg installed; the speech model (700 MB) is downloaded on first
use. To use an OpenCaptions server instead, set OPENCAPTIONS_KEY (an API key from its Account
page) and OPENCAPTIONS_URL (default http://localhost:5173).`;

/** Progress on one line of the terminal, rewritten as it moves. */
const report: Progress = (fraction, message) => {
  if (process.stderr.isTTY) {
    process.stderr.write(`\r\x1b[2K${Math.round(fraction * 100)}% ${message}`);
  }
};

async function caption(args: string[]): Promise<void> {
  const { values, positionals } = parseArgs({
    args,
    allowPositionals: true,
    options: {
      output: { type: "string", short: "o" },
      look: { type: "string" },
      style: { type: "string" },
      language: { type: "string" },
      model: { type: "string" },
      transcript: { type: "string" },
      format: { type: "string" },
      resolution: { type: "string" },
      fps: { type: "string" },
      "captions-only": { type: "boolean" },
      subtitles: { type: "string" },
    },
  });
  const source = positionals[0];
  if (!source) throw new OpenCaptionsError("Which video? opencaptions caption <video or link>");
  const request: CaptionRequest = {
    source,
    output: values.output,
    look: values.look,
    style: values.style ? JSON.parse(values.style) : undefined,
    language: values.language,
    model: values.model,
    transcript: values.transcript
      ? (JSON.parse(await readFile(values.transcript, "utf8")) as Transcript)
      : undefined,
    format: values.format,
    resolution: values.resolution as CaptionRequest["resolution"],
    frame_rate: values.fps as CaptionRequest["frame_rate"],
    captions_only: values["captions-only"],
  };
  const captioner = await captionerFromEnv();
  const result = await captioner.caption(request, report);
  if (process.stderr.isTTY) process.stderr.write("\r\x1b[2K");
  if (!result.done) throw new OpenCaptionsError(result.message);
  console.log(result.output);
  for (const kind of (values.subtitles ?? "").split(",").filter(Boolean)) {
    if (kind !== "srt" && kind !== "vtt" && kind !== "json") {
      throw new OpenCaptionsError(`Subtitles are srt, vtt or json, not ${kind}.`);
    }
    console.log(
      await captioner.exportSubtitles(
        result.project_id,
        kind,
        result.output.replace(/\.[^.]+$/, ""),
      ),
    );
  }
}

async function main(argv: string[]): Promise<void> {
  const [command, ...rest] = argv;
  switch (command) {
    case "caption":
      return caption(rest);
    case "looks":
      console.log(LOOKS.map(describeLook).join("\n"));
      return;
    case "style":
      console.log(describeStyle());
      return;
    case "mcp": {
      const { serve } = await import("./mcp.ts");
      return serve();
    }
    case "--version":
    case "-v":
      console.log(VERSION);
      return;
    default:
      console.log(HELP);
      if (command && command !== "help" && command !== "--help" && command !== "-h") {
        process.exitCode = 2;
      }
  }
}

main(process.argv.slice(2)).catch((error: unknown) => {
  if (process.stderr.isTTY) process.stderr.write("\r\x1b[2K");
  console.error(error instanceof OpenCaptionsError ? error.message : error);
  process.exitCode = 1;
});
