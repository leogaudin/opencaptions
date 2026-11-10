/**
 * Captioning on this computer, with no server: the speech model through sherpa-onnx, the engine's
 * WebAssembly to draw, FFmpeg to read and write video. A project is a file beside the video
 * (`<name>.opencaptions.json`: the transcript, the style and the offset), and its path is the
 * project id the tools pass around. Everything is done before a call returns, so there are no
 * tickets.
 */
import { readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { basename, dirname, extname, join, resolve } from "node:path";
import type { Captioner } from "../captioner.ts";
import {
  applyFixes,
  type CaptionRequest,
  dealt,
  defaultOutput,
  type Outcome,
  type Progress,
  type SaveOptions,
  styled,
  viewTranscript,
} from "../captions.ts";
import { OpenCaptionsError, type StyleConfig, type Transcript } from "../client.ts";
import { Scene, subtitles } from "../engine.ts";
import formats from "../generated/render_formats.json" with { type: "json" };
import { LOOKS } from "../looks.ts";
import { ensureFont } from "./fonts.ts";
import { encode, probe, type VideoInfo } from "./media.ts";
import { transcribe } from "./transcribe.ts";

interface Project {
  version: 1;
  /** The video, as an absolute path. */
  source: string;
  transcript: Transcript | null;
  style_config: StyleConfig | null;
  caption_offset_ms: number;
}

const SIDECAR = ".opencaptions.json";

async function read(id: string): Promise<Project> {
  try {
    return JSON.parse(await readFile(id, "utf8")) as Project;
  } catch {
    throw new OpenCaptionsError(`There is no OpenCaptions project at ${id}.`);
  }
}

async function write(id: string, project: Project): Promise<void> {
  await writeFile(id, `${JSON.stringify(project, null, 2)}\n`);
}

async function open(source: string): Promise<string> {
  if (/^https?:\/\//i.test(source)) {
    throw new OpenCaptionsError(
      "Without a server, the video has to be a file on this computer: download it first.",
    );
  }
  const path = resolve(source);
  if (!(await stat(path).catch(() => undefined))?.isFile()) {
    throw new OpenCaptionsError(`There is no video at ${path}.`);
  }
  const id = join(dirname(path), `${basename(path, extname(path))}${SIDECAR}`);
  const existing = await read(id).catch(() => undefined);
  await write(id, {
    version: 1,
    source: path,
    transcript: null,
    style_config: existing?.style_config ?? null,
    caption_offset_ms: 0,
  });
  return id;
}

// The output's size and frame rate from the source's, as the API decides them
// (`resolve_render_inputs` in apps/api/app/services/render_formats.py).
const SHORT_SIDES: Record<string, number> = { "2160": 2160, "1080": 1080, "720": 720 };
const FRAME_RATES: Record<string, number> = { "30": 30, "60": 60 };
/** Python's `round`: halves go to the even neighbour. */
const round = (value: number) => {
  const floor = Math.floor(value);
  const diff = value - floor;
  return diff > 0.5 || (diff === 0.5 && floor % 2 !== 0) ? floor + 1 : floor;
};
// Encoders need even dimensions in 4:2:0.
const even = (value: number) => Math.max(2, round(value) & ~1);

export function geometry(
  source: Pick<VideoInfo, "width" | "height" | "fps">,
  save: Pick<SaveOptions, "resolution" | "frame_rate">,
): { width: number; height: number; fps: number } {
  let { width, height } = source;
  const target = SHORT_SIDES[save.resolution ?? "original"];
  const short = Math.min(width, height);
  if (target && target !== short) {
    [width, height] = [even((width * target) / short), even((height * target) / short)];
  }
  const fps = FRAME_RATES[save.frame_rate ?? "original"] ?? Math.max(1, Math.min(60, source.fps));
  return { width, height, fps: round(fps) };
}

function format(id = "mp4") {
  const found = formats.find((f) => f.id === id);
  if (!found) {
    throw new OpenCaptionsError(
      `There is no format ${id}: ${formats.map((f) => f.id).join(", ")}.`,
    );
  }
  return found;
}

/** Every family the style draws with: its own, and its word looks'. */
function families(style: StyleConfig): string[] {
  const variants = (style.variants ?? []) as { font?: string | null }[];
  return [style.font, ...variants.map((v) => v.font ?? "")].filter(Boolean);
}

async function saveVideo(
  project: Project,
  options: SaveOptions,
  progress: Progress,
): Promise<string> {
  if (!project.transcript) throw new OpenCaptionsError("This project has no captions yet.");
  const fmt = format(options.format);
  const info = await probe(project.source);
  const { width, height, fps } = geometry(info, options);
  const style = project.style_config ?? (LOOKS[0]?.config as StyleConfig);
  for (const family of new Set(families(style))) await ensureFont(family);
  const output =
    options.output ?? `${defaultOutput(project.source, options.captions_only)}${fmt.extension}`;
  const partial = `${output}.part${fmt.extension}`;
  const scene = await Scene.create({
    transcript: project.transcript,
    style,
    width,
    height,
    caption_offset_ms: project.caption_offset_ms,
  });
  try {
    const plan = scene.plan({
      source: project.source,
      output: partial,
      source_transfer: info.transfer,
      duration: project.transcript.duration,
      fps,
      codec: fmt.codec,
      crf: fmt.crf,
      pro_res_profile: fmt.pro_res_profile,
      green_screen: options.captions_only ?? false,
    });
    const [, , bw, bh] = plan.band;
    await encode(plan.args, async (stdin) => {
      let reported = 0;
      // FFmpeg closes its input once it has the length it was asked for: that ends the writing.
      let closed = false;
      stdin.once("close", () => {
        closed = true;
      });
      const room = () =>
        new Promise<void>((done) => {
          const go = () => {
            stdin.off("drain", go);
            stdin.off("close", go);
            done();
          };
          stdin.on("drain", go);
          stdin.on("close", go);
        });
      for (let i = 0; i < plan.frames && !closed; i++) {
        const band = new Uint8Array(bw * bh * 4);
        scene.band(i / fps, plan.band, band);
        if (!stdin.write(band)) await room();
        const done = (i + 1) / plan.frames;
        if (done - reported >= 0.05) {
          reported = done;
          progress(done, `Saving ${Math.round(done * 100)}%`);
        }
      }
    });
    await rename(partial, output);
  } catch (error) {
    await rm(partial, { force: true });
    throw error;
  } finally {
    scene.free();
  }
  return output;
}

async function caption(request: CaptionRequest, progress: Progress): Promise<Outcome> {
  const id = await open(request.source);
  const project = await read(id);
  if (request.look !== undefined || request.style !== undefined) {
    project.style_config = styled(project.style_config, request.look, request.style);
  }
  project.transcript =
    request.transcript ??
    (await transcribe(
      project.source,
      { language: request.language, model: request.model },
      progress,
    ));
  if (project.style_config) {
    project.transcript =
      (await dealt(project.transcript, project.style_config)) ?? project.transcript;
  }
  await write(id, project);
  return { done: true, project_id: id, output: await saveVideo(project, request, progress) };
}

export function localCaptioner(): Captioner {
  return {
    caption: (request, progress) => caption(request, progress),
    resume: async () => {
      throw new OpenCaptionsError(
        "Without a server, every call finishes: there is nothing to resume.",
      );
    },
    setStyle: async (id, look, changes) => {
      const project = await read(id);
      project.style_config = styled(project.style_config, look, changes);
      if (look) {
        project.transcript =
          (await dealt(project.transcript ?? undefined, project.style_config)) ??
          project.transcript;
      }
      await write(id, project);
      return project.style_config;
    },
    readTranscript: async (id) => {
      const project = await read(id);
      return viewTranscript(project.transcript, project.style_config, project.caption_offset_ms);
    },
    fixWords: async (id, fixes) => {
      const project = await read(id);
      project.transcript = await applyFixes(project.transcript, fixes);
      await write(id, project);
      return fixes.length;
    },
    save: async (id, options, progress) => {
      const output = await saveVideo(await read(id), options, progress);
      return { done: true, project_id: id, output };
    },
    exportSubtitles: async (id, kind, output) => {
      const project = await read(id);
      if (!project.transcript) throw new OpenCaptionsError("This project has no captions yet.");
      const stem = output ?? defaultOutput(project.source);
      const path = extname(stem) === `.${kind}` ? stem : `${stem}.${kind}`;
      const body =
        kind === "json"
          ? `${JSON.stringify(project.transcript, null, 2)}\n`
          : await subtitles(
              project.transcript,
              project.style_config?.words_per_line ?? 3,
              project.caption_offset_ms,
              kind,
            );
      await writeFile(path, body);
      return path;
    },
  };
}
