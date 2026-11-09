/**
 * A stand-in for the OpenCaptions API: the routes the package calls, with jobs that take a few polls
 * to finish, so the tests run without the stack. What it was sent is kept for the tests to check.
 */
import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";

export const KEY = "oc_test";

export const TRANSCRIPT = JSON.parse(
  readFileSync(
    new URL(
      "../../ios/OpenCaptionsKit/Tests/OpenCaptionsKitTests/Fixtures/transcript.json",
      import.meta.url,
    ),
    "utf8",
  ),
);

interface Project {
  id: string;
  title: string;
  transcript: unknown;
  style_config: unknown;
  caption_offset_ms: number;
  upload?: { name: string; size: number };
  video_url?: string;
}

interface Job {
  id: string;
  type: "transcription" | "rendering";
  project_id: string;
  polls: number;
  /** Polls before it finishes. */
  takes: number;
  fails?: string;
}

export interface Fake {
  url: string;
  projects: Map<string, Project>;
  patches: { id: string; body: Record<string, unknown> }[];
  /** How many polls a job takes (set before the call), and an error to fail them with. */
  jobs: { takes: number; fails?: string };
  close(): Promise<void>;
}

export async function startFake(): Promise<Fake> {
  const projects = new Map<string, Project>();
  const jobs = new Map<string, Job>();
  const patches: Fake["patches"] = [];
  const settings = { takes: 2 } as Fake["jobs"];
  let next = 0;

  const send = (res: ServerResponse, status: number, body: unknown, headers = {}) => {
    res.writeHead(status, { "content-type": "application/json", ...headers });
    res.end(JSON.stringify(body));
  };
  const body = async (req: IncomingMessage) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    return Buffer.concat(chunks);
  };
  const job = (type: Job["type"], projectId: string): Job => {
    const j = { id: `job-${++next}`, type, project_id: projectId, polls: 0, ...settings };
    jobs.set(j.id, j);
    return j;
  };
  const status = (j: Job) => ({
    id: j.id,
    project_id: j.project_id,
    type: j.type,
    status: j.polls >= j.takes ? (j.fails ? "failed" : "completed") : "running",
    progress: Math.min(1, j.polls / j.takes),
    message: j.type === "transcription" ? "Transcribing" : "Adding the captions",
    error: j.polls >= j.takes ? (j.fails ?? null) : null,
    created_at: new Date(0).toISOString(),
  });
  const view = (p: Project) => {
    const { upload: _upload, video_url: _url, ...rest } = p;
    return rest;
  };

  const server = createServer(async (req, res) => {
    if (req.headers.authorization !== `Bearer ${KEY}`) {
      return send(res, 401, { detail: "Not authenticated" });
    }
    const url = new URL(req.url ?? "/", "http://fake");
    const parts = url.pathname.replace(/^\/api\/v1\//, "").split("/");
    const project = parts[0] === "projects" && parts[1] ? projects.get(parts[1]) : undefined;

    if (req.method === "POST" && url.pathname === "/api/v1/projects") {
      const raw = await body(req);
      const form = await new Request("http://fake", {
        method: "POST",
        headers: { "content-type": req.headers["content-type"] ?? "" },
        body: raw,
      }).formData();
      const video = form.get("video");
      const p: Project = {
        id: `project-${++next}`,
        title: String(form.get("title")),
        transcript: null,
        style_config: null,
        caption_offset_ms: 0,
        ...(video instanceof Blob && { upload: { name: (video as File).name, size: video.size } }),
        ...(form.get("video_url") && { video_url: String(form.get("video_url")) }),
      };
      projects.set(p.id, p);
      return send(res, 201, view(p));
    }
    if (!project && parts[0] === "projects") return send(res, 404, { detail: "Project not found" });
    if (project && parts.length === 2 && req.method === "GET") return send(res, 200, view(project));
    if (project && parts.length === 2 && req.method === "PATCH") {
      const changes = JSON.parse((await body(req)).toString());
      patches.push({ id: project.id, body: changes });
      Object.assign(project, changes);
      return send(res, 200, view(project));
    }
    if (project && parts[2] === "transcribe") {
      await body(req);
      return send(res, 202, status(job("transcription", project.id)));
    }
    if (project && parts[2] === "download" && req.method === "POST") {
      await body(req);
      return send(res, 202, {
        ready: false,
        download_url: null,
        job_id: job("rendering", project.id).id,
      });
    }
    if (project && parts[2] === "download" && parts[3]) {
      res.writeHead(200, {
        "content-type": "video/mp4",
        "content-disposition": `attachment; filename="opencaptions-${project.id}.mp4"`,
      });
      return res.end(`VIDEO ${parts[3]} ${url.search}`);
    }
    if (project && parts[2] === "export.srt") {
      res.writeHead(200, { "content-type": "text/plain" });
      return res.end("1\n00:00:00,000 --> 00:00:01,000\none two\n");
    }
    if (parts[0] === "jobs" && parts[1]) {
      const j = jobs.get(parts[1]);
      if (!j) return send(res, 404, { detail: "Job not found" });
      j.polls += 1;
      const answer = status(j);
      // A finished transcription leaves its words on the project, as the worker does.
      if (j.type === "transcription" && answer.status === "completed") {
        const p = projects.get(j.project_id);
        if (p && !p.transcript) p.transcript = TRANSCRIPT;
      }
      return send(res, 200, answer);
    }
    return send(res, 404, { detail: `No route ${req.method} ${url.pathname}` });
  });
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    projects,
    patches,
    jobs: settings,
    close: () => new Promise((done) => server.close(() => done())),
  };
}
