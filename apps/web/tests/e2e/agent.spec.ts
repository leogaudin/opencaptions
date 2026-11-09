/**
 * The agent package (apps/agent) against the real stack: its command line sends a video with a key,
 * styles it, and gets a captioned MP4 back. The captions are given, so no speech model is needed.
 */
import { execFile } from "node:child_process";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { expect, test } from "@playwright/test";

const run = promisify(execFile);
const TRANSCRIPT = "../ios/OpenCaptionsKit/Tests/OpenCaptionsKitTests/Fixtures/transcript.json";

test("the agent's command line captions a video on the server", async ({ request, baseURL }) => {
  test.setTimeout(180_000);
  const { csrf_token } = await (await request.get("/api/v1/auth/me")).json();
  const created = await request.post("/api/v1/api-keys", {
    data: { name: "agent e2e" },
    headers: { "X-CSRF-Token": csrf_token },
  });
  expect(created.ok()).toBe(true);
  const { key } = await created.json();

  const output = join(await mkdtemp(join(tmpdir(), "agent-e2e-")), "captioned.mp4");
  const { stdout } = await run(
    "node",
    [
      "../agent/src/cli.ts",
      "caption",
      "tests/e2e/fixtures/blank-4s.webm",
      "--look",
      "Bold",
      "--transcript",
      TRANSCRIPT,
      "--output",
      output,
    ],
    { env: { ...process.env, OPENCAPTIONS_URL: baseURL, OPENCAPTIONS_KEY: key } },
  );
  expect(stdout.trim()).toBe(output);
  // An MP4 opens with its file-type box.
  const bytes = await readFile(output);
  expect(bytes.subarray(4, 8).toString("latin1")).toBe("ftyp");
  expect(bytes.length).toBeGreaterThan(1000);
});
