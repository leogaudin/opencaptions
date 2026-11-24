/**
 * FFmpeg on this computer, for captioning without a server: what a video is, its sound as the
 * speech model takes it, and the run that makes the captioned file (`encode::plan`'s command, with
 * the caption band piped in). The probe reads what `apps/api/app/services/audio.py` reads.
 */
import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { delimiter, join, parse } from "node:path";
import { OpenCaptionsError } from "../client.ts";

const INSTALL =
  "FFmpeg is needed to caption without a server. Install it (macOS: brew install ffmpeg; " +
  "Debian or Ubuntu: sudo apt install ffmpeg; Windows: winget install ffmpeg). If it is " +
  "installed but not found, set OPENCAPTIONS_FFMPEG to the folder holding ffmpeg and ffprobe. " +
  "Or set OPENCAPTIONS_URL and OPENCAPTIONS_KEY to use an OpenCaptions server.";

/** Where Homebrew puts FFmpeg: Apple silicon, then Intel. */
const HOMEBREW = ["/opt/homebrew/bin", "/usr/local/bin"];

const isProgram = (folder: string, name: string, platform: NodeJS.Platform): boolean => {
  try {
    accessSync(join(folder, platform === "win32" ? `${name}.exe` : name), constants.X_OK);
    return true;
  } catch {
    return false;
  }
};

interface Lookup {
  env?: NodeJS.ProcessEnv;
  /** Folders tried when the program is not on PATH. */
  fallbacks?: string[];
  platform?: NodeJS.Platform;
}

/**
 * The program to start for `name`: in the folder OPENCAPTIONS_FFMPEG names, else by its name on
 * PATH, else (on a Mac) in Homebrew's folders. A desktop app starts the server with a short PATH
 * that leaves those out, though FFmpeg is installed.
 */
export function ffmpegProgram(
  name: "ffmpeg" | "ffprobe",
  {
    env = process.env,
    platform = process.platform,
    fallbacks = platform === "darwin" ? HOMEBREW : [],
  }: Lookup = {},
): string {
  const folder = env.OPENCAPTIONS_FFMPEG?.trim();
  if (folder) {
    if (!isProgram(folder, name, platform)) {
      throw new OpenCaptionsError(
        `OPENCAPTIONS_FFMPEG is ${folder}, but there is no ${name} in it. Set it to the folder ` +
          "holding ffmpeg and ffprobe, or empty it to look for them on the PATH.",
      );
    }
    return join(folder, name);
  }
  const onPath = (env.PATH ?? "")
    .split(delimiter)
    .some((dir) => dir && isProgram(dir, name, platform));
  if (onPath) return name;
  const found = fallbacks.find((dir) => isProgram(dir, name, platform));
  return found ? join(found, name) : name;
}

/** A program's output, or a clear error when it cannot be started or fails. */
function run(
  program: string,
  args: string[],
  input?: (stdin: NodeJS.WritableStream) => Promise<void>,
) {
  return new Promise<Buffer>((done, fail) => {
    const child = spawn(program, args, { stdio: [input ? "pipe" : "ignore", "pipe", "pipe"] });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout?.on("data", (chunk: Buffer) => out.push(chunk));
    child.stderr?.on("data", (chunk: Buffer) => err.push(chunk));
    child.on("error", (error: NodeJS.ErrnoException) =>
      fail(error.code === "ENOENT" ? new OpenCaptionsError(INSTALL) : error),
    );
    child.on("close", (code) => {
      if (code === 0) return done(Buffer.concat(out));
      const why = Buffer.concat(err).toString().trim().split("\n").slice(-3).join(" ");
      fail(new OpenCaptionsError(`${parse(program).name} failed: ${why || `exit code ${code}`}`));
    });
    if (input && child.stdin) {
      // FFmpeg closes its input once it has the length it was asked for: that ends the writing.
      child.stdin.on("error", () => {});
      input(child.stdin).then(
        () => child.stdin?.end(),
        (error: unknown) => {
          child.kill();
          fail(error);
        },
      );
    }
  });
}

export interface VideoInfo {
  /** As it is shown: a quarter-turn swaps the stored axes. */
  width: number;
  height: number;
  fps: number;
  duration: number;
  /** The transfer function as ffprobe names it, empty when unknown (`encode::Output`). */
  transfer: string;
}

const rate = (value: unknown): number | undefined => {
  const [n, d = "1"] = String(value ?? "").split("/");
  const fps = Number(n) / Number(d);
  return Number.isFinite(fps) && fps > 0 ? fps : undefined;
};

interface ProbedStream {
  width?: number;
  height?: number;
  avg_frame_rate?: string;
  r_frame_rate?: string;
  duration?: string;
  color_transfer?: string;
  tags?: { rotate?: string };
  side_data_list?: { side_data_type?: string; rotation?: number }[];
}

export async function probe(path: string): Promise<VideoInfo> {
  const raw = await run(ffmpegProgram("ffprobe"), [
    "-v",
    "error",
    "-print_format",
    "json",
    "-show_streams",
    "-show_format",
    "-select_streams",
    "v:0",
    path,
  ]);
  const data = JSON.parse(raw.toString()) as {
    streams?: ProbedStream[];
    format?: { duration?: string };
  };
  const stream = data.streams?.[0];
  if (!stream?.width || !stream.height) {
    throw new OpenCaptionsError(`${path} has no picture FFmpeg can read.`);
  }
  const matrix = stream.side_data_list?.find((s) => s.side_data_type === "Display Matrix");
  const turn = ((Number(matrix?.rotation ?? stream.tags?.rotate ?? 0) % 360) + 360) % 360 || 0;
  const [width, height] =
    turn === 90 || turn === 270 ? [stream.height, stream.width] : [stream.width, stream.height];
  return {
    width,
    height,
    fps: rate(stream.avg_frame_rate) ?? rate(stream.r_frame_rate) ?? 30,
    duration: Number(stream.duration ?? data.format?.duration ?? 0),
    transfer: stream.color_transfer ?? "",
  };
}

/** The sound as 16 kHz mono samples between -1 and 1, what the speech model takes. */
export async function audioSamples(path: string): Promise<Float32Array> {
  const raw = await run(ffmpegProgram("ffmpeg"), [
    "-v",
    "error",
    "-i",
    path,
    "-vn",
    "-ac",
    "1",
    "-ar",
    "16000",
    "-f",
    "f32le",
    "pipe:1",
  ]);
  return new Float32Array(raw.buffer, raw.byteOffset, Math.floor(raw.byteLength / 4));
}

/** Runs FFmpeg with `args`, writing what `frames` gives to its input. */
export async function encode(
  args: string[],
  frames: (stdin: NodeJS.WritableStream) => Promise<void>,
): Promise<void> {
  await run(ffmpegProgram("ffmpeg"), args, frames);
}
