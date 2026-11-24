/**
 * Starts a built .mcpb the way Claude Desktop does: unpacked, the server's command run with the
 * settings left empty, over stdio. It must answer `initialize` and list the tools the manifest
 * names, so a bundle that is missing a file or a dependency fails here and not on a user's Mac.
 *
 *   node mcpb/check-bundle.ts opencaptions-linux-test.mcpb
 */
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const MCPB = "@anthropic-ai/mcpb@2.1.2";
const bundle = resolve(process.argv[2] ?? "");
const folder = mkdtempSync(join(tmpdir(), "opencaptions-mcpb-"));
execFileSync("npx", ["-y", MCPB, "unpack", bundle, folder], { stdio: "ignore" });

interface Manifest {
  server: { mcp_config: { command: string; args: string[]; env: Record<string, string> } };
  tools: { name: string }[];
}
const manifest = JSON.parse(readFileSync(join(folder, "manifest.json"), "utf8")) as Manifest;
const { command, args, env } = manifest.server.mcp_config;

// What the desktop app substitutes for a setting nobody filled in.
const settings = Object.fromEntries(Object.keys(env).map((key) => [key, ""]));
const child = spawn(command, args.map((arg) => arg.replace("${__dirname}", folder)), {
  env: { ...process.env, ...settings },
  stdio: ["pipe", "pipe", "inherit"],
});

const lines: string[] = [];
let pending = "";
child.stdout.on("data", (chunk: Buffer) => {
  pending += chunk.toString();
  const parts = pending.split("\n");
  pending = parts.pop() ?? "";
  lines.push(...parts.filter(Boolean));
});

const send = (message: object) => child.stdin.write(`${JSON.stringify(message)}\n`);
const reply = async (id: number): Promise<{ result?: { tools?: { name: string }[] } }> => {
  for (let waited = 0; waited < 30_000; waited += 50) {
    const found = lines.map((line) => JSON.parse(line)).find((message) => message.id === id);
    if (found) return found;
    await new Promise((done) => setTimeout(done, 50));
  }
  throw new Error(`no answer to request ${id} within 30 seconds`);
};

try {
  send({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "check-bundle", version: "0" },
    },
  });
  await reply(1);
  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
  const listed = ((await reply(2)).result?.tools ?? []).map((tool) => tool.name).sort();
  const named = manifest.tools.map((tool) => tool.name).sort();
  assert.deepEqual(listed, named, "the manifest's tools are the server's tools");
  assert.equal(listed.length, 9);
  console.log(`The bundle starts and lists ${listed.length} tools: ${listed.join(", ")}`);
} finally {
  child.kill();
}
