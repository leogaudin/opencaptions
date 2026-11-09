/**
 * The OpenCaptions server, reached through its API with a key. Every call is typed against the API's
 * generated types (`generated/api.ts`), so a route or a body that drifts from the server fails `tsc`.
 */
import createClient, { type Client } from "openapi-fetch";
import type { components, paths } from "./generated/api.ts";

export type StyleConfig = components["schemas"]["StyleConfig"];
export type Transcript = components["schemas"]["Transcript"];
export type Job = components["schemas"]["JobStatus"];
export type RenderRequest = components["schemas"]["RenderRequest"];
export type TranscribeRequest = components["schemas"]["TranscribeRequest"];

/** A failure in words a person (or an agent) can act on. */
export class OpenCaptionsError extends Error {}

export interface Connection {
  /** The server's web address, as a browser opens it. */
  url: string;
  /** An API key from the server's Account page. */
  key: string;
}

export const DEFAULT_URL = "http://localhost:5173";

/** The server named by OPENCAPTIONS_URL and OPENCAPTIONS_KEY. */
export function connectionFromEnv(env: NodeJS.ProcessEnv = process.env): Connection {
  const key = env.OPENCAPTIONS_KEY?.trim();
  if (!key) {
    throw new OpenCaptionsError(
      "OPENCAPTIONS_KEY is not set. Create an API key on your OpenCaptions server's Account page " +
        "and set it, with OPENCAPTIONS_URL if the server is not at " +
        `${DEFAULT_URL}.`,
    );
  }
  return { url: (env.OPENCAPTIONS_URL?.trim() || DEFAULT_URL).replace(/\/+$/, ""), key };
}

export type Api = Client<paths>;

export function api(connection: Connection): Api {
  const client = createClient<paths>({
    baseUrl: connection.url,
    headers: { Authorization: `Bearer ${connection.key}` },
  });
  client.use({
    async onError({ error }) {
      const cause = error instanceof Error ? error.message : String(error);
      return new OpenCaptionsError(
        `Cannot reach OpenCaptions at ${connection.url} (${cause}). Is the server running?`,
      );
    },
  });
  return client;
}

/** The value of a call, or what the server said was wrong with it. */
export function unwrap<T>(result: { data?: T; error?: unknown; response: Response }): T {
  const { data, error, response } = result;
  if (response.ok) return data as T;
  if (response.status === 401) {
    throw new OpenCaptionsError("The server refused the key: check OPENCAPTIONS_KEY.");
  }
  throw new OpenCaptionsError(describe(error) ?? `The server answered ${response.status}.`);
}

function describe(error: unknown): string | undefined {
  if (typeof error !== "object" || error === null || !("detail" in error)) return undefined;
  const { detail } = error as { detail: unknown };
  if (typeof detail === "string") return detail;
  // A validation error: each problem, and where it is.
  if (Array.isArray(detail)) {
    return detail
      .map(
        (d: { loc?: unknown[]; msg?: string }) => `${(d.loc ?? []).slice(1).join(".")}: ${d.msg}`,
      )
      .join("; ");
  }
  return JSON.stringify(detail);
}
