import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { serverCaptioner } from "../src/captioner.ts";
import { api } from "../src/client.ts";
import { createServer } from "../src/mcp.ts";
import { type Fake, KEY, startFake } from "./fake-server.ts";

process.env.OPENCAPTIONS_POLL_MS = "5";

let fake: Fake;
let client: Client;
let video: string;

before(async () => {
  fake = await startFake();
  const folder = await mkdtemp(join(tmpdir(), "opencaptions-mcp-"));
  video = join(folder, "clip.mp4");
  await writeFile(video, "frames");
  const [ours, theirs] = InMemoryTransport.createLinkedPair();
  await createServer(async () => serverCaptioner(api({ url: fake.url, key: KEY }))).connect(ours);
  client = new Client({ name: "test", version: "1" });
  await client.connect(theirs);
});
after(async () => {
  await client.close();
  await fake.close();
});

const text = (result: unknown) =>
  (result as { content: { text: string }[] }).content.map((c) => c.text).join("\n");

test("the tools are listed, each with a schema", async () => {
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map((t) => t.name).sort(), [
    "caption_video",
    "check_progress",
    "describe_style",
    "export_subtitles",
    "fix_words",
    "get_transcript",
    "list_looks",
    "save_video",
    "set_style",
  ]);
  const caption = tools.find((t) => t.name === "caption_video");
  assert.deepEqual(caption?.inputSchema.required, ["source"]);
  const style = caption?.inputSchema.properties?.style as { properties: object } | undefined;
  assert.ok(style && "font_size" in style.properties);
});

test("caption_video saves the video and reports progress", async () => {
  const progress: number[] = [];
  const result = await client.callTool(
    { name: "caption_video", arguments: { source: video, look: "Karaoke" } },
    undefined,
    { onprogress: (p) => progress.push(p.progress) },
  );
  assert.equal(result.isError, undefined);
  assert.match(text(result), /^Saved .*clip\.captioned\.mp4/);
  assert.ok(progress.length > 0);
});

test("no word says rendering", async () => {
  const { tools } = await client.listTools();
  assert.doesNotMatch(JSON.stringify(tools), /render/i);
});

test("a failure comes back as the tool's error, in words", async () => {
  const result = await client.callTool({
    name: "get_transcript",
    arguments: { project_id: "nope" },
  });
  assert.equal(result.isError, true);
  assert.equal(text(result), "Project not found");
});

test("list_looks names every look", async () => {
  const result = await client.callTool({ name: "list_looks", arguments: {} });
  assert.equal(text(result).split("\n").length, 19);
});
