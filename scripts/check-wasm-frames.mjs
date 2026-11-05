// Fail if the WebAssembly build draws anything but what the native build draws: the same scenes as
// apps/engine/testdata/frames.json, through the file the browser loads, compared byte for byte by
// fingerprint. The preview is only the export if this holds.
//   node scripts/check-wasm-frames.mjs <opencaptions_engine.wasm>
import { readFileSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const engine = instance.exports;
const bytes = (ptr, len) => new Uint8Array(engine.memory.buffer, ptr, len);

function put(data) {
  const ptr = engine.oc_alloc(data.length);
  bytes(ptr, data.length).set(data);
  return [ptr, data.length];
}

// The fonts the native test draws with, in its order.
for (const font of [
  "testdata/anton-subset.ttf",
  "fonts/Inter.ttf",
  "fonts/NotoSansArabic.ttf",
  "fonts/NotoSansHebrew.ttf",
  "fonts/NotoSansDevanagari.ttf",
  "fonts/NotoSansThai.ttf"
]) {
  if (engine.oc_add_font(...put(readFileSync(`${root}apps/engine/${font}`))) !== 1) {
    throw new Error(`the engine refused ${font}`);
  }
}

// FNV-1a over 64 bits, in four 16-bit parts: the prime is 2^40 + 0x1b3, and a BigInt would take minutes.
function fingerprint(data, h) {
  let [h0, h1, h2, h3] = h;
  for (let i = 0; i < data.length; i++) {
    h0 ^= data[i];
    const t0 = h0 * 0x1b3;
    const t1 = h1 * 0x1b3 + (t0 >>> 16);
    const t2 = h2 * 0x1b3 + (t1 >>> 16) + (h0 << 8);
    const t3 = h3 * 0x1b3 + (t2 >>> 16) + (h1 << 8);
    h0 = t0 & 0xffff;
    h1 = t1 & 0xffff;
    h2 = t2 & 0xffff;
    h3 = t3 & 0xffff;
  }
  return [h0, h1, h2, h3];
}

const hex = ([h0, h1, h2, h3]) =>
  [h3, h2, h1, h0].map((part) => part.toString(16).padStart(4, "0")).join("");

const { times, cases } = JSON.parse(
  readFileSync(`${root}apps/engine/testdata/frames.json`, "utf8")
);
const encoder = new TextEncoder();
const different = [];
for (const { name, input, fingerprint: want } of cases) {
  const scene = engine.oc_scene_new(...put(encoder.encode(JSON.stringify(input))));
  if (scene === 0) throw new Error(`the engine refused the scene ${name}`);
  let h = [0x2325, 0x8422, 0x9ce4, 0xcbf2];
  for (const t of times) {
    engine.oc_render(scene, t);
    const size = engine.oc_frame_width(scene) * engine.oc_frame_height(scene) * 4;
    h = fingerprint(bytes(engine.oc_frame_ptr(scene), size), h);
  }
  engine.oc_scene_free(scene);
  if (hex(h) !== want) different.push(`${name}: ${hex(h)}, native ${want}`);
}

if (different.length > 0) {
  console.error(`${different.length} of ${cases.length} looks differ from the native build:`);
  console.error(different.join("\n"));
  process.exit(1);
}
console.log(`${cases.length} looks, ${times.length} frames each: the same bytes as the native build`);
