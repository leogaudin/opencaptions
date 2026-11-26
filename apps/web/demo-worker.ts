/**
 * The public demo's Worker (opencaptions.app; `wrangler.jsonc`). Cloudflare's static assets
 * answer a Range request with the whole file and a 200, and Safari will not play a video it
 * cannot ask for in parts: on an iPhone the sample clip stays black. The Worker runs only for
 * the clips (`run_worker_first`) and answers their Range requests with the bytes asked for (206).
 */

export interface Assets {
  fetch(request: Request): Promise<Response>;
}

/**
 * The bytes a Range header asks for in a body of `size` bytes: a range, "unsatisfiable" when it
 * asks for bytes the body does not have, or null when it is not a single byte range (several
 * ranges, another unit), which a server may answer with the whole body.
 */
export function byteRange(
  header: string,
  size: number,
): { start: number; end: number } | "unsatisfiable" | null {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match || (match[1] === "" && match[2] === "")) return null;
  if (match[1] === "") {
    // A suffix: the last n bytes.
    const n = Number(match[2]);
    return n === 0 || size === 0
      ? "unsatisfiable"
      : { start: Math.max(0, size - n), end: size - 1 };
  }
  const start = Number(match[1]);
  const end = match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
  return start < size && start <= end ? { start, end } : "unsatisfiable";
}

export async function serve(request: Request, assets: Assets): Promise<Response> {
  const response = await assets.fetch(request);
  if (response.status !== 200) return response;
  const headers = new Headers(response.headers);
  headers.set("Accept-Ranges", "bytes");
  const header = request.headers.get("Range");
  const body = await response.arrayBuffer();
  const range = header ? byteRange(header, body.byteLength) : null;
  if (range === null) return new Response(body, { status: 200, headers });
  if (range === "unsatisfiable") {
    headers.set("Content-Range", `bytes */${body.byteLength}`);
    headers.delete("Content-Length");
    return new Response(null, { status: 416, headers });
  }
  headers.set("Content-Range", `bytes ${range.start}-${range.end}/${body.byteLength}`);
  headers.set("Content-Length", String(range.end - range.start + 1));
  const part = request.method === "HEAD" ? null : body.slice(range.start, range.end + 1);
  return new Response(part, { status: 206, headers });
}

export default {
  fetch: (request: Request, env: { ASSETS: Assets }) => serve(request, env.ASSETS),
};
