import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Page } from "@playwright/test";

export interface MockWord {
  text: string;
  start: number;
  end: number;
  confidence: number;
}
/** The transcript shape the API serves, as far as the tests read it. */
export interface Transcript {
  schema_version: number;
  language: string;
  language_detection: string;
  duration: number;
  segments: { id: string; start: number; end: number; text: string; words: MockWord[] }[];
}

const SOURCE_VIDEO = fileURLToPath(new URL("../fixtures/blank-4s.webm", import.meta.url));

export const MOCK_PROJECT_ID = "00000000-0000-4000-8000-000000000042";
const MOCK_JOB_ID = "00000000-0000-4000-8000-000000000043";

const HELLO: Transcript = {
  schema_version: 1,
  language: "en",
  language_detection: "auto",
  duration: 1,
  segments: [
    {
      id: "segment-1",
      start: 0,
      end: 1,
      text: "Hello",
      words: [{ text: "Hello", start: 0, end: 1, confidence: 1 }],
    },
  ],
};

/**
 * Serves a transcribed project from memory. Saves are merged into it, so the
 * returned getter reads back exactly what the editor last saved.
 */
export async function mockTranscribedProject(
  page: Page,
  title: string,
  {
    transcript = HELLO,
    captionOffsetMs = 0,
  }: { transcript?: Transcript; captionOffsetMs?: number } = {},
): Promise<() => Record<string, unknown>> {
  const now = new Date().toISOString();
  let project: Record<string, unknown> = {
    id: MOCK_PROJECT_ID,
    title,
    status: "transcribed",
    transcript,
    style_config: null,
    caption_offset_ms: captionOffsetMs,
    video_storage_key: `projects/${MOCK_PROJECT_ID}/source.mp4`,
    video_width: 1080,
    video_height: 1920,
    video_fps: 30,
    video_duration: transcript.duration,
    error: null,
    created_at: now,
    updated_at: now,
    active_job: null,
  };
  await page.route(`**/api/v1/projects/${MOCK_PROJECT_ID}`, async (route) => {
    const method = route.request().method();
    if (method === "PATCH") project = { ...project, ...route.request().postDataJSON() };
    else if (method !== "GET") return route.fallback();
    await route.fulfill({ json: project });
  });
  // A real (VP9, which Playwright's Chromium decodes) video, so the preview and
  // its timeline mount instead of the "cannot preview" note. Served with byte
  // ranges, as the API does: without them the browser cannot seek.
  const video = readFileSync(SOURCE_VIDEO);
  await page.route(`**/api/v1/projects/${MOCK_PROJECT_ID}/source`, (route) => {
    const range = route
      .request()
      .headers()
      .range?.match(/bytes=(\d+)-(\d*)/);
    const headers = { "accept-ranges": "bytes" };
    if (!range) return route.fulfill({ body: video, contentType: "video/webm", headers });
    const start = Number(range[1]);
    const end = range[2] ? Number(range[2]) : video.length - 1;
    return route.fulfill({
      status: 206,
      body: video.subarray(start, end + 1),
      contentType: "video/webm",
      headers: { ...headers, "content-range": `bytes ${start}-${end}/${video.length}` },
    });
  });
  await page.route(`**/api/v1/projects/${MOCK_PROJECT_ID}/exports`, (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        video: [],
        choices: { resolutions: ["original"], frame_rates: ["original"], source_fps: 30 },
        subtitles: { srt: "", vtt: "", json: "" },
      }),
    }),
  );
  return () => project;
}

export function completedTranscriptionJob() {
  const now = new Date().toISOString();
  return {
    id: MOCK_JOB_ID,
    project_id: MOCK_PROJECT_ID,
    type: "transcription",
    status: "completed",
    progress: 1,
    message: null,
    error: null,
    created_at: now,
    updated_at: now,
  };
}
