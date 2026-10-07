/**
 * Frontend types. Anything matching the API is DERIVED from api.generated.ts so
 * the compiler catches backend drift; run `npm run generate-types` after schema
 * changes. Hand-written types below are UI-only.
 */
import presets from "@/lib/presets.json";
import type { components } from "./api.generated";

// Codegen emits nullable fields as optional, but the API always sends them as
// explicit null, so make them required-but-nullable and drop the `?` guards.
/**
 * Given a type T, returns the same type but with every optional property
 * made required (preserving its `| null` union if present).
 */
type RequireAll<T> = {
  [K in keyof T]-?: T[K];
};

// API-derived types (single source of truth: apps/api/app/models/schemas.py)

export type StyleConfig = components["schemas"]["StyleConfig"];

export type Word = components["schemas"]["Word"];

export type TranscriptSegment = components["schemas"]["TranscriptSegment"];

export type Transcript = components["schemas"]["Transcript"];

export type FontFamily = components["schemas"]["FontFamily"];

export type ApiKey = components["schemas"]["ApiKeyRead"];
/** Where audio is transcribed: here, on OpenAI, or on another OpenCaptions server. */
export type TranscriptionProvider = NonNullable<
  components["schemas"]["TranscribeRequest"]["provider"]
>;

export type ApiKeyCreated = components["schemas"]["ApiKeyCreated"];

/** Job state, with `message` and `error` normalized to required-but-nullable. */
export type Job = RequireAll<components["schemas"]["JobStatus"]>;

/** Full project state, with nullable fields normalized to required-but-nullable. */
export type Project = Omit<RequireAll<components["schemas"]["ProjectStatus"]>, "active_job"> & {
  active_job: Job | null;
};

export type ProjectListItem = components["schemas"]["ProjectListItem"];

export type ProjectList = components["schemas"]["ProjectList"];

export type ApiError = components["schemas"]["ErrorResponse"];

// Derived from the generated schema rather than hand-declared, so a backend
// change that breaks a consumer fails the typecheck.
/** Liveness/readiness probe response (GET /health). */
export type HealthResponse = components["schemas"]["HealthResponse"];

/** Work an account has had done (GET /auth/me/usage). */
export type UsageRead = components["schemas"]["UsageRead"];

/** An account as the API returns it. */
export type UserRead = components["schemas"]["UserRead"];

/** Effective application settings (GET /settings). */
export type AppSettingsResponse = components["schemas"]["AppSettingsResponse"];

/** A transcription language entry. */
export type SupportedLanguage = components["schemas"]["LanguageOption"];

/** Local Whisper model entry advertised by GET /settings. */
export type WhisperModelOption = components["schemas"]["ModelOption"];

/** One video format entry from GET /projects/{id}/exports. */
export type VideoExportFormat = RequireAll<components["schemas"]["VideoExportOption"]>;

/** How a video is saved beside its format: size, quality and frame rate. */
export type RenderOptions = Omit<RequireAll<components["schemas"]["RenderRequest"]>, "format">;

/** The sizes and frame rates a project's video offers: its own, and lower ones. */
export type ExportChoices = components["schemas"]["ExportChoices"];

/** Available exports for a project (GET /projects/{id}/exports). */
export type ExportLinks = {
  video: VideoExportFormat[];
  choices: ExportChoices;
  subtitles: components["schemas"]["SubtitleExportLinks"];
};

/** Download response: `ready` discriminates download_url from job_id. */
export type DownloadResponse =
  | { ready: true; download_url: string; job_id?: null }
  | { ready: false; job_id: string; download_url?: null };

// UI-only, hand-maintained: the WebSocket protocol is not in OpenAPI and these
// unions are narrower than the API enums on purpose.
/** Caption animation style. */
export type Animation = "word_highlight" | "highlight_box" | "word_pop" | "word_fade";

/** Caption background style. */
export type CaptionBackground = "none" | "solid" | "pill";

/** The application default: the first preset (Purple Punch), which matches the API's defaults. */
export const defaultStyle = presets[0]!.config as StyleConfig;

/** WebSocket message envelope. Not part of the OpenAPI spec. */
export interface WSMessage {
  type:
    | "connected"
    | "ping"
    | "job_started"
    | "job_progress"
    | "job_succeeded"
    | "job_failed"
    | "job_cancelled"
    | "transcript_updated"
    | "error";
  payload: Record<string, unknown>;
}
