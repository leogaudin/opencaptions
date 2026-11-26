import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { type Assets, byteRange, serve } from "../../demo-worker.ts";

/** The demo's Worker: the clips answer Range requests, which Safari needs to play a video. */
const BYTES = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
const assets = (status = 200): Assets => ({
  fetch: async () =>
    new Response(status === 200 ? BYTES : "missing", {
      status,
      headers: { "Content-Type": "video/mp4", "Cache-Control": "public, max-age=3600" },
    }),
});
const get = (range?: string, method = "GET") =>
  new Request("https://opencaptions.app/demo/clips/sprite_fright.mp4", {
    method,
    headers: range ? { Range: range } : {},
  });
const bytes = async (response: Response) => [...new Uint8Array(await response.arrayBuffer())];

describe("byteRange", () => {
  test("reads a start and an end, an open end and a suffix", () => {
    assert.deepEqual(byteRange("bytes=0-1", 10), { start: 0, end: 1 });
    assert.deepEqual(byteRange("bytes=5-", 10), { start: 5, end: 9 });
    assert.deepEqual(byteRange("bytes=-3", 10), { start: 7, end: 9 });
    assert.deepEqual(byteRange("bytes=8-50", 10), { start: 8, end: 9 });
    assert.deepEqual(byteRange("bytes=-50", 10), { start: 0, end: 9 });
  });

  test("bytes past the end cannot be served", () => {
    assert.equal(byteRange("bytes=10-12", 10), "unsatisfiable");
    assert.equal(byteRange("bytes=4-2", 10), "unsatisfiable");
    assert.equal(byteRange("bytes=-0", 10), "unsatisfiable");
  });

  test("anything but one byte range is left for the whole body", () => {
    assert.equal(byteRange("bytes=0-1,4-5", 10), null);
    assert.equal(byteRange("items=0-1", 10), null);
    assert.equal(byteRange("bytes=-", 10), null);
  });
});

describe("serve", () => {
  test("Safari's first probe gets the two bytes it asks for", async () => {
    const response = await serve(get("bytes=0-1"), assets());
    assert.equal(response.status, 206);
    assert.equal(response.headers.get("Content-Range"), "bytes 0-1/10");
    assert.equal(response.headers.get("Content-Length"), "2");
    assert.equal(response.headers.get("Accept-Ranges"), "bytes");
    assert.equal(response.headers.get("Content-Type"), "video/mp4");
    assert.equal(response.headers.get("Cache-Control"), "public, max-age=3600");
    assert.deepEqual(await bytes(response), [0, 1]);
  });

  test("a later part of the file", async () => {
    const response = await serve(get("bytes=6-"), assets());
    assert.equal(response.status, 206);
    assert.equal(response.headers.get("Content-Range"), "bytes 6-9/10");
    assert.deepEqual(await bytes(response), [6, 7, 8, 9]);
  });

  test("without a Range the whole file, saying ranges are accepted", async () => {
    const response = await serve(get(), assets());
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Accept-Ranges"), "bytes");
    assert.deepEqual(await bytes(response), [...BYTES]);
  });

  test("a range past the end is refused with the file's size", async () => {
    const response = await serve(get("bytes=20-30"), assets());
    assert.equal(response.status, 416);
    assert.equal(response.headers.get("Content-Range"), "bytes */10");
  });

  test("a HEAD with a Range describes the part without sending it", async () => {
    const response = await serve(get("bytes=0-1", "HEAD"), assets());
    assert.equal(response.status, 206);
    assert.equal(response.headers.get("Content-Length"), "2");
    assert.equal((await response.arrayBuffer()).byteLength, 0);
  });

  test("a missing file passes through untouched", async () => {
    const response = await serve(get("bytes=0-1"), assets(404));
    assert.equal(response.status, 404);
  });
});
