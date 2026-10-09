/** Typed API client. All paths are relative: nginx proxies /api and /ws. */
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
 * bootstrap probe opts out via `skipAuthRedirect` to avoid a redirect loop.
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

async function request<T>(
  path: string,
  init: RequestInit & { json?: unknown; skipAuthRedirect?: boolean } = {},
): Promise<T> {
  const { json, skipAuthRedirect, ...rest } = init;
  const headers = new Headers(rest.headers);
  if (json !== undefined) {
    headers.set("Content-Type", "application/json");
  }
  // CSRF: the API requires an X-CSRF-Token header on every state-changing
  // method. Attach the in-memory token once, here, for all callers. Safe GETs
  // (and HEAD/OPTIONS) don't need it and are left untouched.
  const method = (rest.method ?? "GET").toUpperCase();
  if (csrfToken && !SAFE_METHODS.has(method)) {
    headers.set("X-CSRF-Token", csrfToken);
  }
  const resp = await fetch(`${API_BASE}${path}`, {
    ...rest,
    headers,
    // Send the httpOnly session cookie. Everything is same-origin (Vite proxy
    // in dev, nginx in prod), so same-origin credentials suffice.
    credentials: "same-origin",
    body: json !== undefined ? JSON.stringify(json) : rest.body,
  });
  return settle<T>(resp, skipAuthRedirect);
}

/** The one place a response becomes a value or an error, for `fetch` and uploads alike. */
async function settle<T>(resp: Response, skipAuthRedirect = false): Promise<T> {
  if (resp.status === 204) {
    return undefined as T;
  }

  let body: unknown = null;
  const ct = resp.headers.get("content-type") ?? "";
  if (ct.includes("application/json")) {
    body = await resp.json();
  } else {
    body = await resp.text();
    // A successful answer that is not JSON is not the API's (a dev server or a proxy answering
    // with its own page): fail here, in words, rather than hand a string to code expecting data.
    if (resp.ok && typeof body === "string" && body.trim() !== "") {
      throw new ApiException(resp.status, null, "Unexpected response from the server");
    }
    if (resp.ok) return undefined as T;
  }

  if (!resp.ok) {
    // Central 401 handling: a session that expires mid-use clears auth state and
    // routes the user to login. The bootstrap probe (GET /auth/me) passes
    // skipAuthRedirect so its EXPECTED logged-out 401 can't loop.
    if (resp.status === 401 && !skipAuthRedirect) {
      onUnauthorized?.();
    }
    const apiError = typeof body === "object" && body ? (body as ApiError) : null;
    throw new ApiException(resp.status, apiError, apiError?.detail ?? resp.statusText);
  }
  return body as T;
}

// ---------- Auth ----------

/**
 * Public probe used on first load to decide what to render: `setup_required`
 * is true on an instance with no users yet (first run).
 */
export function getAuthStatus(): Promise<AuthStatus> {
  return request<AuthStatus>("/auth/status");
}

/** Register an account. Sets the session cookie and returns a CSRF token. */
export async function register(email: string, password: string): Promise<AuthSession> {
  const session = await request<AuthSession>("/auth/register", {
    method: "POST",
    json: { email, password },
  });
  setCsrfToken(session.csrf_token);
  return session;
}

/**
 * Log in. Failure is deliberately generic on the server, callers must not
 * imply whether the email exists.
 */
export async function login(email: string, password: string): Promise<AuthSession> {
  const session = await request<AuthSession>("/auth/login", {
    method: "POST",
    json: { email, password },
  });
  setCsrfToken(session.csrf_token);
  return session;
}

/**
 * Resolve the session from the cookie, or throw ApiException(401).
 * skipAuthRedirect keeps an expected bootstrap 401 out of the global redirect.
 */
export async function fetchMe(): Promise<AuthSession> {
  const session = await request<AuthSession>("/auth/me", { skipAuthRedirect: true });
  setCsrfToken(session.csrf_token);
  return session;
}

/** Log out: clears the server session (204) and the in-memory CSRF token. */
export async function logout(): Promise<void> {
  try {
    await request<void>("/auth/logout", { method: "POST" });
  } finally {
    setCsrfToken(null);
  }
}

/**
 * Request a reset link. The server answers identically for unknown emails, so
 * the caller must show the same neutral confirmation either way.
 */
export function requestPasswordReset(email: string): Promise<void> {
  return request<void>("/auth/password-reset", {
    method: "POST",
    json: { email },
    // Logged-out flow: an expected-401 elsewhere must not redirect us, and there
    // is no session to clear here anyway.
    skipAuthRedirect: true,
  });
}

/**
 * Set a new password from a token. Every session is revoked and none created,
 * so send the user to sign in. Bad or used tokens come back as a generic 400.
 */
export function confirmPasswordReset(token: string, password: string): Promise<void> {
  return request<void>("/auth/password-reset/confirm", {
    method: "POST",
    json: { token, password },
    skipAuthRedirect: true,
  });
}

// ---------- Projects ----------

export async function listProjects(page = 1, perPage = 20): Promise<ProjectList> {
  const list = await request<ProjectList>(`/projects?page=${page}&per_page=${perPage}`);
  if (!Array.isArray(list?.items)) {
    throw new ApiException(200, null, "Unexpected response from the server");
  }
  return list;
}

export function getProject(projectId: string): Promise<Project> {
  return request<Project>(`/projects/${projectId}`);
}

export interface UploadHooks {
  /** Bytes sent so far, of the total. */
  onProgress?: (sent: number, total: number) => void;
  /** Abort the upload with this. */
  signal?: AbortSignal;
}

/**
 * POST with progress and cancel, which `fetch` cannot give a request body.
 * Same CSRF header, cookie and error handling as {@link request}.
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
      const resp = new Response(xhr.status === 204 ? null : xhr.responseText, {
        status: xhr.status,
        statusText: xhr.statusText,
        headers: { "content-type": xhr.getResponseHeader("content-type") ?? "" },
      });
      settle<T>(resp).then(resolve, reject);
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
export function createProjectFromUrl(title: string, videoUrl: string): Promise<Project> {
  const fd = new FormData();
  fd.append("title", title);
  fd.append("video_url", videoUrl);
  return request<Project>("/projects", { method: "POST", body: fd });
}

export function updateProject(
  projectId: string,
  body: {
    title?: string;
    transcript?: Transcript;
    style_config?: StyleConfig;
    caption_offset_ms?: number;
  },
): Promise<Project> {
  return request<Project>(`/projects/${projectId}`, {
    method: "PATCH",
    json: body,
  });
}

export function deleteProject(projectId: string): Promise<void> {
  return request<void>(`/projects/${projectId}`, { method: "DELETE" });
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

export function startTranscription(projectId: string, body: TranscribeBody = {}): Promise<Job> {
  return request<Job>(`/projects/${projectId}/transcribe`, {
    method: "POST",
    json: body,
  });
}

// ---------- Multi-format video download ----------

export function getExportLinks(projectId: string): Promise<ExportLinks> {
  return request<ExportLinks>(`/projects/${projectId}/exports`);
}

/** Request a download: a URL when ready, otherwise a job_id to wait on. */
export function requestDownload(
  projectId: string,
  format: string,
  options: RenderOptions,
): Promise<DownloadResponse> {
  return request<DownloadResponse>(`/projects/${projectId}/download`, {
    method: "POST",
    json: { format, ...options },
  });
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

export function getJob(jobId: string): Promise<Job> {
  return request<Job>(`/jobs/${jobId}`);
}

export function cancelJob(jobId: string): Promise<void> {
  return request<void>(`/jobs/${jobId}`, { method: "DELETE" });
}

// ---------- API keys ----------

export function listApiKeys(): Promise<ApiKey[]> {
  return request<ApiKey[]>("/api-keys");
}

export function createApiKey(name: string): Promise<ApiKeyCreated> {
  return request<ApiKeyCreated>("/api-keys", { method: "POST", json: { name } });
}

export function revokeApiKey(id: string): Promise<void> {
  return request<void>(`/api-keys/${id}`, { method: "DELETE" });
}

// ---------- Fonts ----------

/** Every Google Fonts family, most popular first. */
export function listFonts(): Promise<FontFamily[]> {
  return request<FontFamily[]>("/fonts");
}

// ---------- Settings ----------

/** Work this account has had done, for the account page. */
export function getMyUsage(): Promise<UsageRead> {
  return request<UsageRead>("/auth/me/usage");
}

/** Change the account's email. Requires the current password. */
export function changeEmail(email: string, currentPassword: string): Promise<UserRead> {
  return request<UserRead>("/auth/me/email", {
    method: "PATCH",
    json: { email, current_password: currentPassword },
    // A 401 here means the password was wrong, not that the session expired, so
    // it must not reach the global handler, which would log the user out for a
    // typo and lose the form they were filling in.
    skipAuthRedirect: true,
  });
}

/** Change the account's password. Every other session is revoked. */
export function changePassword(currentPassword: string, newPassword: string): Promise<void> {
  return request<void>("/auth/me/password", {
    method: "PATCH",
    json: { current_password: currentPassword, new_password: newPassword },
    // As above: a wrong current password is a form error, not a dead session.
    skipAuthRedirect: true,
  });
}

export function getSettings(): Promise<AppSettingsResponse> {
  return request<AppSettingsResponse>("/settings");
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

export function testRemoteTranscription(): Promise<RemoteTranscriptionTest> {
  return request<RemoteTranscriptionTest>("/settings/transcription/test", { method: "POST" });
}

// ---------- Health ----------

export function getHealth(): Promise<HealthResponse> {
  return request<HealthResponse>("/health");
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
