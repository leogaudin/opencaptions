"""Pydantic schemas for API I/O. Single source of truth for OpenAPI codegen."""

from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Transcript primitives


class Word(BaseModel):
    """One word with start/end timestamps."""

    text: str
    start: float = Field(ge=0.0, description="seconds from start of audio")
    end: float = Field(ge=0.0, description="seconds from start of audio")
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)


class TranscriptSegment(BaseModel):
    """A logical segment of words (typically a phrase or line)."""

    id: str
    words: list[Word]
    start: float = Field(ge=0.0)
    end: float = Field(ge=0.0)
    text: str


class Transcript(BaseModel):
    """A full transcript stored as JSONB on Project.transcript."""

    schema_version: int = 1
    language: str = Field(default="en", description="ISO 639-1 language code")
    language_detection: Literal["auto", "manual"] = "auto"
    duration: float = Field(ge=0.0)
    segments: list[TranscriptSegment]


# Auth & users


class UserRead(BaseModel):
    """Public user shape returned everywhere. NEVER includes password_hash."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    email: str
    created_at: datetime


class AuthStatus(BaseModel):
    """Unauthenticated bootstrap probe for the SPA (GET /auth/status)."""

    setup_required: bool = Field(
        description="True when no account exists yet — the SPA should offer first-run signup."
    )
    registration_enabled: bool = Field(
        description="Whether self-service signup is allowed beyond the first account."
    )
    hosted_mode: bool = Field(
        description="True when an operator runs this instance for other people. The SPA "
        "then hides self-hoster surfaces (runtime details, per-job model choice); the API "
        "enforces the same restrictions regardless of what the client shows."
    )
    reset_available: bool = Field(
        description="Whether self-service password reset is available (SMTP is configured). "
        "When false the SPA hides the flow and recovery is the host CLI script. Reveals no "
        "SMTP settings — only this boolean."
    )


class RegisterRequest(BaseModel):
    """POST /auth/register body."""

    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=8, max_length=1024)

    @field_validator("email")
    @classmethod
    def _normalize_email(cls, v: str) -> str:
        # Emails are stored and compared normalised to lowercase so that
        # A@x.com and a@x.com resolve to the same account.
        v = v.strip().lower()
        if "@" not in v or v.startswith("@") or v.endswith("@"):
            raise ValueError("Invalid email address")
        return v


class LoginRequest(BaseModel):
    """POST /auth/login body."""

    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=1, max_length=1024)

    @field_validator("email")
    @classmethod
    def _normalize_email(cls, v: str) -> str:
        return v.strip().lower()


class AuthResponse(BaseModel):
    """Returned by register/login/me: the user plus the session's CSRF token."""

    user: UserRead
    csrf_token: str = Field(description="Echo back as the X-CSRF-Token header on unsafe requests.")


class PasswordResetRequest(BaseModel):
    """POST /auth/password-reset body — request a reset link by email."""

    email: str = Field(min_length=3, max_length=320)

    @field_validator("email")
    @classmethod
    def _normalize_email(cls, v: str) -> str:
        # Normalise like login: lenient, since the response must never reveal
        # whether the address is valid or registered.
        return v.strip().lower()


class PasswordResetConfirm(BaseModel):
    """POST /auth/password-reset/confirm body.

    Password constraints mirror RegisterRequest, so a reset is held to the same bar.
    """

    token: str = Field(min_length=1, max_length=512)
    password: str = Field(min_length=8, max_length=1024)


# Style config


class StyleConfig(BaseModel):
    """Caption styling parameters."""

    font: str = "Inter"
    font_size: int = Field(default=48, ge=12, le=200)
    text_color: str = Field(default="#FFFFFF", pattern=r"^#[0-9A-Fa-f]{6}$")
    highlight_color: str = Field(default="#FFDD00", pattern=r"^#[0-9A-Fa-f]{6}$")
    background: Literal["none", "solid", "pill"] = "pill"
    background_color: str = Field(default="#000000", pattern=r"^#[0-9A-Fa-f]{6}$")
    background_opacity: float = Field(default=0.5, ge=0.0, le=1.0)
    # Normalised centre of the caption block, 0..1 across the frame. Default is
    # centred horizontally and low (the usual subtitle spot); the editor drags it.
    position_x: float = Field(default=0.5, ge=0.0, le=1.0)
    position_y: float = Field(default=0.84, ge=0.0, le=1.0)
    animation: Literal["word_highlight", "highlight_box", "word_pop", "word_fade"] = (
        "word_highlight"
    )
    words_per_line: int = Field(default=3, ge=1, le=10)
    # Gap between words, as a fraction of font size, so it scales with the text.
    word_spacing: float = Field(default=0.0, ge=0.0, le=1.0)
    stroke_width: float = Field(default=0.0, ge=0.0, le=10.0)
    stroke_color: str = Field(default="#000000", pattern=r"^#[0-9A-Fa-f]{6}$")
    shadow_blur: float = Field(default=0.0, ge=0.0, le=20.0)
    shadow_color: str = Field(
        default="#00000080",
        pattern=r"^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$",
        description="Optional alpha channel for shadow",
    )


# Project + Job


class JobStatus(BaseModel):
    """Job state surfaced to API clients."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    project_id: UUID | None = Field(
        default=None,
        description="The project the job works on; null for a transcription made through "
        "POST /transcriptions, which has none",
    )
    type: Literal["transcription", "rendering"]
    status: Literal["pending", "running", "completed", "failed", "cancelled"]
    progress: float = 0.0
    message: str | None = None
    error: str | None = None
    created_at: datetime
    updated_at: datetime


class ProjectStatus(BaseModel):
    """Project + nested transcript/style. Returned by GET /projects/{id}."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    title: str
    status: Literal["draft", "transcribing", "transcribed", "rendering", "done", "error"]
    transcript: Transcript | None = None
    style_config: StyleConfig | None = None
    caption_offset_ms: int = Field(
        default=0,
        ge=-2000,
        le=2000,
        description="Global caption timing offset in milliseconds (positive = captions "
        "shown later, negative = earlier). Applied to every caption timing against the "
        "fixed audio track; does not re-transcribe.",
    )
    video_storage_key: str | None = None
    # rendered_storage_key and rendered_at removed — render cache is now
    # content-addressed in storage; freshness is a HEAD request, not a DB column.
    # Source-video metadata, probed at upload.
    video_width: int | None = None
    video_height: int | None = None
    video_fps: float | None = None
    video_duration: float | None = None
    error: str | None = None
    created_at: datetime
    updated_at: datetime
    # Latest non-terminal job for this project (pending or running).
    # Lets the editor restore progress UI after a page refresh without a
    # separate /jobs query. Null when no job is in flight.
    active_job: "JobStatus | None" = None


class ProjectListItem(BaseModel):
    """Lighter project shape for list endpoints."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    title: str
    status: str
    video_size_bytes: int | None = None
    created_at: datetime
    updated_at: datetime


class ProjectList(BaseModel):
    items: list[ProjectListItem]
    total: int
    page: int
    per_page: int


# Request bodies


class ProjectUpdate(BaseModel):
    """PATCH /projects/{id} body. All fields optional."""

    title: str | None = Field(default=None, min_length=1, max_length=255)
    transcript: Transcript | None = None
    style_config: StyleConfig | None = None
    caption_offset_ms: int | None = Field(
        default=None,
        ge=-2000,
        le=2000,
        description="Global caption timing offset in milliseconds (positive = later, "
        "negative = earlier). Omit to leave unchanged.",
    )


class TranscribeRequest(BaseModel):
    """POST /projects/{id}/transcribe body."""

    provider: Literal["local", "openai", "opencaptions"] | None = None
    model: str | None = None
    language: str = Field(default="auto", description="'auto' or ISO 639-1 code")


class RenderRequest(BaseModel):
    """POST /projects/{id}/download body — request a render in a specific format."""

    format: str = Field(description="Format id from the format registry (mp4, mp4-hevc, webm, mov)")


# Health endpoint


class ServiceHealth(BaseModel):
    """Individual service health status."""

    database: Literal["ok", "down"]
    redis: Literal["ok", "down"]
    storage: Literal["ok", "down"]


class TranscriptionInfo(BaseModel):
    """Resolved transcription device and provider config."""

    device: str = Field(description="Resolved device actually in use (cpu, cuda:0)")
    compute_type: str = Field(
        description="Resolved compute type actually in use (int8, float16, float32)"
    )
    default_provider: str = Field(description="Transcription provider (local or openai)")
    default_model: str = Field(description="Whisper model size")
    requested_device: str = Field(
        description="Value of WHISPER_DEVICE before resolution (auto, cpu, cuda)"
    )
    requested_compute_type: str = Field(
        description="Value of WHISPER_COMPUTE_TYPE before resolution"
    )
    device_fallback_reason: str | None = Field(
        default=None, description="Why device differs from requested (null when they match)"
    )
    compute_type_fallback_reason: str | None = Field(
        default=None, description="Why compute type differs from requested (null when they match)"
    )


class HealthResponse(BaseModel):
    """Liveness and readiness probe. Always 200.

    Hosted mode withholds the per-service and transcription breakdowns (null),
    since they describe someone else's infrastructure.
    """

    status: Literal["ok", "degraded"] = Field(
        description="'ok' when all services are reachable, 'degraded' otherwise"
    )
    version: str
    services: ServiceHealth | None = Field(
        default=None, description="Per-service status. Null in hosted mode."
    )
    transcription: TranscriptionInfo | None = Field(
        default=None, description="Resolved transcription runtime. Null in hosted mode."
    )


# Settings endpoints


class LanguageOption(BaseModel):
    """A single supported transcription language."""

    code: str = Field(description="ISO 639-1 language code")
    label: str = Field(description="Human-readable English label")


class ModelOption(BaseModel):
    """A single selectable local Whisper model size."""

    id: str = Field(description="faster-whisper model identifier (e.g. large-v3-turbo)")
    label: str = Field(description="Human-readable label")
    note: str = Field(
        description="Size/speed tradeoff hint — a bigger model means a larger "
        "first-run download and slower CPU transcription."
    )


class TranscriptionCapabilities(BaseModel):
    """GET /transcription/capabilities: what this instance transcribes with and accepts."""

    api_version: int = Field(
        description="Version of the transcription API. A client refuses a major version it "
        "does not know."
    )
    instance_name: str = Field(description="A name to show for this instance")
    models: list[ModelOption] = Field(
        description="Models a request may name, ascending in size; empty when the instance "
        "fixes the model (hosted mode)"
    )
    default_model: str | None = Field(description="The model used when a request names none")
    languages: list[LanguageOption]
    max_upload_mb: int
    max_duration_s: int
    result_ttl_h: int = Field(
        description="Hours a finished transcript can be fetched before it is deleted"
    )
    hosted_mode: bool


class TranscriptionCreated(BaseModel):
    """POST /transcriptions: the job to watch, at GET /jobs/{job_id}."""

    job_id: UUID


class TranscriptionSettings(BaseModel):
    """Transcription configuration block."""

    provider: str = Field(
        description="Active transcription provider (local, openai or opencaptions)"
    )
    remote_url: str | None = Field(
        default=None,
        description="Where the `opencaptions` provider sends audio: another OpenCaptions "
        "backend's address. Null when none is configured, and in hosted mode.",
    )
    remote_configured: bool = Field(
        default=False,
        description="Whether a remote OpenCaptions backend is configured (its URL and key "
        "are both set), i.e. whether the `opencaptions` provider can be chosen. The key "
        "itself is never exposed.",
    )
    model: str | None = Field(
        description="Configured default Whisper model identifier. Matches one of "
        "`available_models[].id` unless overridden to a custom model path. Null in "
        "hosted mode, where the model is fixed and not the user's concern."
    )
    device: str | None = Field(
        description="Torch device (cpu, cuda, mps). Null in hosted mode: the hardware is "
        "the operator's business."
    )
    openai_configured: bool = Field(
        description="Whether an OpenAI API key is configured, i.e. whether the OpenAI "
        "provider can be chosen. The key itself is never exposed — only this boolean. "
        "Always false in hosted mode, where the provider is fixed and not selectable."
    )
    supported_languages: list[LanguageOption] = Field(
        description="Languages the transcription engine supports, sorted by label. "
        "Does not include 'auto' — that is a mode, not a language."
    )
    available_models: list[ModelOption] = Field(
        description="Local Whisper model sizes faster-whisper accepts, in ascending-size "
        "order. The `model` field above is the configured default and identifies which "
        "of these is currently in use. Empty in hosted mode, where the model is fixed."
    )


class LimitsSettings(BaseModel):
    """Upload and duration limits."""

    max_upload_size_mb: int
    max_video_duration_s: int


class ApiKeyCreate(BaseModel):
    """A name to tell the key apart by, such as where it is used."""

    name: str = Field(min_length=1, max_length=100)


class ApiKeyRead(BaseModel):
    """A key as listed: never the key itself, only its first characters."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    prefix: str
    created_at: datetime
    last_used_at: datetime | None


class ApiKeyCreated(ApiKeyRead):
    """A newly minted key. ``key`` is shown this once and cannot be recovered."""

    key: str


class AppSettingsResponse(BaseModel):
    """Application settings. Secrets are exposed only as booleans, never values."""

    transcription: TranscriptionSettings
    limits: LimitsSettings
    registration_enabled: bool = Field(
        description="Whether self-service signup is allowed beyond the first account. "
        "Environment configuration (REGISTRATION_ENABLED), read-only over the API."
    )
    hosted_mode: bool = Field(
        description="Whether this instance runs in hosted posture (HOSTED_MODE). "
        "Mirrors AuthStatus.hosted_mode for clients that already hold settings."
    )


# Export and download endpoints


class VideoExportOption(BaseModel):
    """One available video export format with cache status."""

    format: str = Field(description="Format id (mp4, mp4-hevc, webm, mov)")
    label: str = Field(description="Human-readable format label")
    ready: bool = Field(description="Whether the rendered file is already cached in storage")
    download_url: str = Field(description="Relative URL to download the rendered file")
    note: str | None = Field(default=None, description="Optional note about the format")


class SubtitleExportLinks(BaseModel):
    """URLs for subtitle export formats."""

    model_config = ConfigDict(populate_by_name=True)

    srt: str
    vtt: str
    json_url: str = Field(alias="json", serialization_alias="json")


class ExportsResponse(BaseModel):
    """Available exports: every video format with its cache status and subtitle links."""

    video: list[VideoExportOption]
    subtitles: SubtitleExportLinks


class DownloadResponse(BaseModel):
    """Response from POST /projects/{id}/download.

    ready=True gives download_url (200); ready=False gives job_id (202).
    """

    ready: bool = Field(description="True if the render is cached and available immediately")
    download_url: str | None = Field(
        default=None,
        description="Relative URL to download the rendered file (populated when ready=True)",
    )
    job_id: str | None = Field(
        default=None,
        description="UUID of the render job (populated when ready=False, status 202)",
    )


# Errors (RFC 9457 Problem Details)


class ChangeEmailRequest(BaseModel):
    """PATCH /auth/me/email. The current password is required, so a hijacked
    session cannot move the account to an address the attacker controls."""

    email: str = Field(min_length=3, max_length=320)
    current_password: str = Field(min_length=1)

    @field_validator("email")
    @classmethod
    def _normalize_email(cls, v: str) -> str:
        # Must match RegisterRequest exactly, or a changed address could fail to
        # match the account it was stored against.
        v = v.strip().lower()
        if "@" not in v or v.startswith("@") or v.endswith("@"):
            raise ValueError("Invalid email address")
        return v


class ChangePasswordRequest(BaseModel):
    """PATCH /auth/me/password. Same constraints as registration, so a change
    cannot weaken an account below the bar it was created under."""

    current_password: str = Field(min_length=1)
    new_password: str = Field(min_length=8, max_length=1024)


class UsageRead(BaseModel):
    """Work this account has had done, from the durable per-job records."""

    transcription_seconds: float = Field(description="seconds of audio transcribed")
    render_frames: float = Field(description="frames rendered")
    projects: int = Field(description="projects currently owned")


class ErrorResponse(BaseModel):
    """All non-2xx responses follow this shape."""

    error: str = Field(description="machine-readable code, e.g., 'project_not_found'")
    detail: str = Field(description="human-readable description")
    code: int = Field(description="HTTP status code")
    field: str | None = Field(default=None, description="for 422 validation errors")


# Error responses for FastAPI `responses={}`, composed per route with `**`.


def _err(status: int, description: str) -> dict[int | str, dict[str, Any]]:
    """One `responses=` entry, in the shape every non-2xx response takes."""
    return {status: {"model": ErrorResponse, "description": description}}


_404_PROJECT = _err(404, "Project not found (`error: project_not_found`)")

_401_UNAUTHENTICATED = _err(
    401, "Not authenticated (`error: not_authenticated` / `invalid_credentials`)"
)

_403_FORBIDDEN = _err(
    403, "Insufficient privileges or disabled (`error: forbidden` / `registration_disabled`)"
)

_409_EMAIL_TAKEN = _err(409, "Email already registered (`error: email_taken`)")

_429_RATE_LIMITED = _err(429, "Too many attempts; try again later (`error: rate_limited`)")

_404_RESET_UNAVAILABLE = _err(
    404, "Password reset is not available — SMTP is not configured (`error: reset_unavailable`)"
)

_400_INVALID_RESET_TOKEN = _err(
    400, "Reset token is invalid, expired, or already used (`error: invalid_reset_token`)"
)

_404_JOB = _err(404, "Job not found (`error: job_not_found`)")

_400_NO_VIDEO = _err(400, "Project has no uploaded video (`error: no_video`)")

_400_NO_TRANSCRIPT = _err(400, "Project has no transcript yet (`error: no_transcript`)")

_400_UNKNOWN_FORMAT = _err(400, "Unknown render format (`error: unknown_format`)")

_400_MISSING_VIDEO_SOURCE = _err(
    400,
    "Neither file upload nor video_url provided, or both provided (`error: missing_video_source`)",
)

_400_INVALID_VIDEO_URL = _err(
    400, "Video URL rejected (SSRF, invalid scheme) (`error: invalid_video_url`)"
)

_400_VIDEO_FETCH_FAILED = _err(400, "Failed to fetch video from URL (`error: video_fetch_failed`)")

_413_UPLOAD_TOO_LARGE = _err(413, "Upload exceeds max size (`error: upload_too_large`)")

_400_UNSUPPORTED_LANGUAGE = _err(
    400, "Language code not recognized (`error: unsupported_language`)"
)

_403_TRANSCRIPTION_CHOICE = _err(
    403,
    "Work refused: the entitlement policy denied it (`error: not_entitled`), "
    "or the instance runs in hosted mode and the request named a provider or model other "
    "than the deployment defaults (`error: transcription_choice_disabled`)",
)

_400_VIDEO_TOO_LONG = _err(
    400, "Video is longer than MAX_VIDEO_DURATION_S (`error: video_too_long`)"
)

_415_UNSUPPORTED_MEDIA = _err(
    415, "URL points to unsupported media type (`error: unsupported_media`)"
)

_404_NOT_RENDERED = _err(
    404,
    "Render not available for this format and content (`error: not_rendered` or `error: unknown_format`)",
)


_404_PROJECT_OR_THUMBNAIL = _err(
    404, "Project not found or has no thumbnail (`error: project_not_found` / `no_thumbnail`)"
)
