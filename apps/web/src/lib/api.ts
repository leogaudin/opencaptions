/**
 * Typed API client. Every call goes through `openapi-fetch` over the generated `paths`
 * (src/types/api.generated.ts), so the compiler checks each path, method, parameter, body and
 * response against the API's own schema. All paths are same-origin: nginx proxies /api and /ws.
 */
import createClient from "openapi-fetch";
import type {
  ApiError,
  ApiKey,
  ApiKeyCreated,
  AppSettingsResponse,
  DownloadResponse,
  ExportLinks,
  FontFamily,
  HealthResponse,
  Job,
  Project,
  ProjectList,
  RenderOptions,
  StyleConfig,
  Transcript,
  TranscriptionProvider,
  UsageRead,
  UserRead,
} from "@/types";
import type { components, paths } from "@/types/api.generated";
import type { AuthSession, AuthStatus } from "@/types/auth";

const API_BASE = "/api/v1";

/** HTTP methods that never mutate state and therefore need no CSRF token. */
const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

/**
 * CSRF token for non-safe requests. In memory only, never localStorage, the
 * session cookie is httpOnly, so this is the only client-visible half.
 */
let csrfToken: string | null = null;

/** Set or clear the in-memory CSRF token. Called by the auth flows. */
export function setCsrfToken(token: string | null): void {
  csrfToken = token;
}

/**
 * Clears auth state and redirects on an unexpected 401, in one place. The
 * bootstrap probe opts out via `quiet401` to avoid a redirect loop.
 */
let onUnauthorized: (() => void) | null = null;

/** Register (or clear with null) the handler invoked on a non-bootstrap 401. */
export function setUnauthorizedHandler(handler: (() => void) | null): void {
  onUnauthorized = handler;
}

class ApiException extends Error {
  status: number;
  body: ApiError | null;

  constructor(status: number, body: ApiError | null, message: string) {
    super(message);
    this.status = status;
    this.body = body;
  }
}

/** Marks a request whose 401 is expected (a bootstrap probe, a wrong password): the global handler skips it. */
const QUIET_401 = "x-oc-quiet-401";
const quiet = { headers: { [QUIET_401]: "1" } };

// Same-origin: the page's own origin, which is what a relative URL means in a browser (a request built
// outside one, as in the unit tests, needs it spelled out).
const origin = typeof location === "undefined" ? "" : location.origin;
const client = createClient<paths>({ baseUrl: origin, credentials: "same-origin" });

client.use({
  onRequest({ request }) {
    // CSRF: the API requires an X-CSRF-Token header on every state-changing method. Attached once,
    // here, for all callers. Safe GETs (and HEAD/OPTIONS) don't need it and are left untouched.
    if (csrfToken && !SAFE_METHODS.has(request.method.toUpperCase())) {
      request.headers.set("X-CSRF-Token", csrfToken);
    }
    return request;
  },
  async onResponse({ request, response }) {
    // A successful answer that is not JSON is not the API's (a dev server or a proxy answering with its
    // own page): fail here, in words, rather than hand a string to code expecting data.
    const json = (response.headers.get("content-type") ?? "").includes("application/json");
    if (response.ok && response.status !== 204 && !json) {
      if ((await response.clone().text()).trim() !== "") {
        throw new ApiException(response.status, null, "Unexpected response from the server");
      }
    }
    // Central 401 handling: a session that expires mid-use clears auth state and routes the user to
    // login. The bootstrap probe (GET /auth/me) is `quiet` so its EXPECTED logged-out 401 can't loop.
    if (response.status === 401 && !request.headers.has(QUIET_401)) onUnauthorized?.();
    return response;
  },
});

/** The value of a call, or the error it answered with, as an ApiException. The types come from the call. */
function unwrap<T>(result: { data?: T; error?: unknown; response: Response }): T {
  const { data, error, response } = result;
  if (!response.ok) {
    const body = typeof error === "object" && error ? (error as ApiError) : null;
    throw new ApiException(response.status, body, body?.detail ?? response.statusText);
  }
  return data as T;
}

// ---------- Auth ----------

/**
 * Public probe used on first load to decide what to render: `setup_required`
 * is true on an instance with no users yet (first run).
 */
export async function getAuthStatus(): Promise<AuthStatus> {
  return unwrap(await client.GET("/api/v1/auth/status"));
}

/** Register an account. Sets the session cookie and returns a CSRF token. */
export async function register(email: string, password: string): Promise<AuthSession> {
  const session = unwrap(await client.POST("/api/v1/auth/register", { body: { email, password } }));
  setCsrfToken(session.csrf_token);
  return session;
}

/**
 * Log in. Failure is deliberately generic on the server, callers must not
 * imply whether the email exists.
 */
export async function login(email: string, password: string): Promise<AuthSession> {
  const session = unwrap(await client.POST("/api/v1/auth/login", { body: { email, password } }));
  setCsrfToken(session.csrf_token);
  return session;
}

/**
 * Resolve the session from the cookie, or throw ApiException(401).
 * `quiet` keeps an expected bootstrap 401 out of the global redirect.
 */
export async function fetchMe(): Promise<AuthSession> {
  const session = unwrap(await client.GET("/api/v1/auth/me", quiet));
  setCsrfToken(session.csrf_token);
  return session;
}

/** Log out: clears the server session (204) and the in-memory CSRF token. */
export async function logout(): Promise<void> {
  try {
    unwrap(await client.POST("/api/v1/auth/logout"));
  } finally {
    setCsrfToken(null);
  }
}

/**
 * Request a reset link. The server answers identically for unknown emails, so
 * the caller must show the same neutral confirmation either way.
 */
export async function requestPasswordReset(email: string): Promise<void> {
  // Logged-out flow: an expected-401 elsewhere must not redirect us, and there is no session to clear.
  unwrap(await client.POST("/api/v1/auth/password-reset", { body: { email }, ...quiet }));
}

/**
 * Set a new password from a token. Every session is revoked and none created,
 * so send the user to sign in. Bad or used tokens come back as a generic 400.
 */
export async function confirmPasswordReset(token: string, password: string): Promise<void> {
  unwrap(
    await client.POST("/api/v1/auth/password-reset/confirm", {
      body: { token, password },
      ...quiet,
    }),
  );
}

// ---------- Projects ----------

export async function listProjects(page = 1, perPage = 20): Promise<ProjectList> {
  const list = unwrap(
    await client.GET("/api/v1/projects", { params: { query: { page, per_page: perPage } } }),
  );
  if (!Array.isArray(list?.items)) {
    throw new ApiException(200, null, "Unexpected response from the server");
  }
  return list;
}

export async function getProject(projectId: string): Promise<Project> {
  return unwrap(
    await client.GET("/api/v1/projects/{project_id}", {
      params: { path: { project_id: projectId } },
    }),
  ) as Project;
}

export interface UploadHooks {
  /** Bytes sent so far, of the total. */
  onProgress?: (sent: number, total: number) => void;
  /** Abort the upload with this. */
  signal?: AbortSignal;
}

/**
 * POST with progress and cancel, which `fetch` cannot give a request body: an XMLHttpRequest, with the
 * same CSRF header, cookie and error handling as the client.
 */
function upload<T>(path: string, body: FormData, hooks: UploadHooks): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", `${API_BASE}${path}`);
    xhr.withCredentials = true;
    if (csrfToken) xhr.setRequestHeader("X-CSRF-Token", csrfToken);
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) hooks.onProgress?.(e.loaded, e.total);
    };
    xhr.onload = () => {
      let parsed: unknown = null;
      try {
        parsed = JSON.parse(xhr.responseText);
      } catch {
        // Not JSON: reported below as what it is.
      }
      if (xhr.status >= 200 && xhr.status < 300 && parsed !== null) {
        resolve(parsed as T);
        return;
      }
      if (xhr.status === 401) onUnauthorized?.();
      const error = typeof parsed === "object" && parsed ? (parsed as ApiError) : null;
      reject(
        new ApiException(xhr.status, error, error?.detail ?? (xhr.statusText || "Upload failed")),
      );
    };
    xhr.onerror = () => reject(new Error("Network error"));
    xhr.onabort = () => reject(new DOMException("Upload cancelled", "AbortError"));
    const { signal } = hooks;
    if (signal) {
      if (signal.aborted) {
        reject(new DOMException("Upload cancelled", "AbortError"));
        return;
      }
      signal.addEventListener("abort", () => xhr.abort(), { once: true });
    }
    xhr.send(body);
  });
}

export function createProject(
  title: string,
  videoFile: File,
  hooks: UploadHooks = {},
): Promise<Project> {
  const fd = new FormData();
  fd.append("title", title);
  fd.append("video", videoFile);
  return upload<Project>("/projects", fd, hooks);
}

/** Create a project from a direct video URL. Page links (YouTube) are not supported. */
export async function createProjectFromUrl(title: string, videoUrl: string): Promise<Project> {
  return unwrap(
    await client.POST("/api/v1/projects", {
      body: { title, video_url: videoUrl },
      // A form, not JSON: the browser sets its own content type.
      bodySerializer: (body) => {
        const fd = new FormData();
        for (const [key, value] of Object.entries(body ?? {})) {
          if (typeof value === "string") fd.append(key, value);
        }
        return fd;
      },
    }),
  ) as Project;
}

export async function updateProject(
  projectId: string,
  body: {
    title?: string;
    transcript?: Transcript;
    style_config?: StyleConfig;
    caption_offset_ms?: number;
  },
): Promise<Project> {
  return unwrap(
    await client.PATCH("/api/v1/projects/{project_id}", {
      params: { path: { project_id: projectId } },
      body,
    }),
  ) as Project;
}

export async function deleteProject(projectId: string): Promise<void> {
  unwrap(
    await client.DELETE("/api/v1/projects/{project_id}", {
      params: { path: { project_id: projectId } },
    }),
  );
}

/** Poster-frame URL. Same-origin so the cookie authenticates it; 404 when absent. */
export function getThumbnailUrl(projectId: string): string {
  return `${API_BASE}/projects/${projectId}/thumbnail`;
}

export interface TranscribeBody {
  provider?: TranscriptionProvider;
  model?: string;
  language?: string;
}

export async function startTranscription(
  projectId: string,
  body: TranscribeBody = {},
): Promise<Job> {
  return unwrap(
    await client.POST("/api/v1/projects/{project_id}/transcribe", {
      params: { path: { project_id: projectId } },
      // Only what was chosen is sent: the API defaults the rest. Its generated type lists every field
      // that has a default as required, so the body is stated as that type here and nowhere else.
      body: body as components["schemas"]["TranscribeRequest"],
    }),
  ) as Job;
}

// ---------- Multi-format video download ----------

export async function getExportLinks(projectId: string): Promise<ExportLinks> {
  return unwrap(
    await client.GET("/api/v1/projects/{project_id}/exports", {
      params: { path: { project_id: projectId } },
    }),
  ) as ExportLinks;
}

/** Request a download: a URL when ready, otherwise a job_id to wait on. */
export async function requestDownload(
  projectId: string,
  format: string,
  options: RenderOptions,
): Promise<DownloadResponse> {
  return unwrap(
    await client.POST("/api/v1/projects/{project_id}/download", {
      params: { path: { project_id: projectId } },
      body: { format, ...options },
    }),
  ) as DownloadResponse;
}

/**
 * Direct download URL for a prepared format. Used for programmatic <a> clicks.
 */
export function getDownloadUrl(projectId: string, format: string, options: RenderOptions): string {
  // A wait saved before green screen existed has no such option, which is "off".
  const query = new URLSearchParams({
    resolution: options.resolution,
    frame_rate: options.frame_rate,
    green_screen: String(options.green_screen === true),
  }).toString();
  return `${API_BASE}/projects/${projectId}/download/${format}?${query}`;
}

// ---------- Jobs ----------

export async function getJob(jobId: string): Promise<Job> {
  return unwrap(
    await client.GET("/api/v1/jobs/{job_id}", { params: { path: { job_id: jobId } } }),
  ) as Job;
}

export async function cancelJob(jobId: string): Promise<void> {
  unwrap(await client.DELETE("/api/v1/jobs/{job_id}", { params: { path: { job_id: jobId } } }));
}

// ---------- API keys ----------

export async function listApiKeys(): Promise<ApiKey[]> {
  return unwrap(await client.GET("/api/v1/api-keys"));
}

export async function createApiKey(name: string): Promise<ApiKeyCreated> {
  return unwrap(await client.POST("/api/v1/api-keys", { body: { name } }));
}

export async function revokeApiKey(id: string): Promise<void> {
  unwrap(await client.DELETE("/api/v1/api-keys/{key_id}", { params: { path: { key_id: id } } }));
}

// ---------- Fonts ----------

/** Every Google Fonts family, most popular first. */
export async function listFonts(): Promise<FontFamily[]> {
  return unwrap(await client.GET("/api/v1/fonts"));
}

// ---------- Settings ----------

/** Work this account has had done, for the account page. */
export async function getMyUsage(): Promise<UsageRead> {
  return unwrap(await client.GET("/api/v1/auth/me/usage"));
}

/** Change the account's email. Requires the current password. */
export async function changeEmail(email: string, currentPassword: string): Promise<UserRead> {
  // A 401 here means the password was wrong, not that the session expired, so it must not reach the
  // global handler, which would log the user out for a typo and lose the form they were filling in.
  return unwrap(
    await client.PATCH("/api/v1/auth/me/email", {
      body: { email, current_password: currentPassword },
      ...quiet,
    }),
  );
}

/** Change the account's password. Every other session is revoked. */
export async function changePassword(currentPassword: string, newPassword: string): Promise<void> {
  // As above: a wrong current password is a form error, not a dead session.
  unwrap(
    await client.PATCH("/api/v1/auth/me/password", {
      body: { current_password: currentPassword, new_password: newPassword },
      ...quiet,
    }),
  );
}

export async function getSettings(): Promise<AppSettingsResponse> {
  return unwrap(await client.GET("/api/v1/settings"));
}

/** What the server says about the remote OpenCaptions instance it is set to transcribe on. */
export type RemoteTranscriptionTest =
  | {
      ok: true;
      instance_name?: string | null;
      api_version?: number;
      models: { id: string; label: string }[];
    }
  | { ok: false; error: string };

export async function testRemoteTranscription(): Promise<RemoteTranscriptionTest> {
  return unwrap(
    await client.POST("/api/v1/settings/transcription/test"),
  ) as RemoteTranscriptionTest;
}

// ---------- Health ----------

export async function getHealth(): Promise<HealthResponse> {
  return unwrap(await client.GET("/api/v1/health"));
}

// Re-export response types so consumers importing them from "@/lib/api" continue to work.
export type {
  AppSettingsResponse,
  DownloadResponse,
  ExportLinks,
  FontFamily,
  HealthResponse,
  VideoExportFormat,
} from "@/types";

// Re-export auth types so consumers importing them from "@/lib/api" work too.
export type { AuthSession, AuthStatus, AuthUser } from "@/types/auth";
export { ApiException };
