/**
 * The demo's sample clips: a manifest (`/demo/clips.json`) naming each clip's video and its
 * transcript, in the API's own shapes. To change the clips, replace the files in
 * demo-public/demo/clips and edit the manifest; nothing else knows about them.
 */
import { defaultStyle, type Project, type Transcript } from "@/types";

export interface Clip {
  id: string;
  /** What the chip says, in English. */
  label: string;
  language: string;
  video: string;
  transcript: string;
  width: number;
  height: number;
  duration: number;
  fps: number;
  /** Where the film comes from, shown in the page's footer (CC BY asks for it). */
  credit?: { title: string; author: string; url: string; license: string; licenseUrl: string };
}

const BASE = "/demo";

let manifest: Promise<Clip[]> | undefined;

/** Fetched once: the demo and its footer both read it. */
export function loadManifest(): Promise<Clip[]> {
  manifest ??= fetch(`${BASE}/clips.json`).then(async (r) => {
    if (!r.ok) throw new Error(`clips.json: ${r.status}`);
    return ((await r.json()) as { clips: Clip[] }).clips;
  });
  manifest.catch(() => {
    manifest = undefined;
  });
  return manifest;
}

export const clipVideoUrl = (clip: Pick<Clip, "video">): string => `${BASE}/clips/${clip.video}`;

/** The project the editor's preview is given for a clip: one that exists nowhere but in the page. */
export async function loadClip(clip: Clip): Promise<{ project: Project; transcript: Transcript }> {
  const r = await fetch(`${BASE}/clips/${clip.transcript}`);
  if (!r.ok) throw new Error(`${clip.transcript}: ${r.status}`);
  const transcript = (await r.json()) as Transcript;
  const now = new Date().toISOString();
  const project: Project = {
    id: clip.id,
    title: clip.label,
    status: "transcribed",
    transcript,
    style_config: defaultStyle,
    caption_offset_ms: 0,
    video_storage_key: `demo/${clip.video}`,
    video_width: clip.width,
    video_height: clip.height,
    video_fps: clip.fps,
    video_duration: clip.duration,
    error: null,
    created_at: now,
    updated_at: now,
    active_job: null,
  };
  return { project, transcript };
}
