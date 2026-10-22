"""Every error the API answers with, in one place.

An error is a status, a code the clients match on (the web and the iPhone app) and a default
message. It is raised with ``raise ApiError.NO_VIDEO.exc()`` (the message can be replaced with
``exc("...")`` where the text depends on the request) and documented, for the OpenAPI schema, with
``responses=ApiError.docs(ApiError.NO_VIDEO, ...)``: the text a route documents and the text it
raises cannot be written apart.
"""

from __future__ import annotations

from enum import Enum
from typing import Any

from fastapi import HTTPException

from app.models.schemas import ErrorResponse


class ApiError(Enum):
    """(status, code, default message). The code never changes: clients depend on it."""

    # Sessions and keys
    NOT_AUTHENTICATED = (401, "not_authenticated", "Authentication required")
    INVALID_JOB_TOKEN = (401, "not_authenticated", "Invalid or missing job token")
    INVALID_CREDENTIALS = (401, "invalid_credentials", "Invalid email or password")
    REGISTRATION_DISABLED = (403, "registration_disabled", "Self-service registration is disabled")
    EMAIL_TAKEN = (409, "email_taken", "Email already registered")
    RATE_LIMITED = (429, "rate_limited", "Too many attempts. Please try again later.")
    RESET_UNAVAILABLE = (
        404,
        "reset_unavailable",
        "Password reset is not available on this instance",
    )
    INVALID_RESET_TOKEN = (
        400,
        "invalid_reset_token",
        "This password reset link is invalid or has expired",
    )
    API_KEY_NOT_FOUND = (404, "api_key_not_found", "No such key")

    # Projects and jobs
    PROJECT_NOT_FOUND = (404, "project_not_found", "No such project")
    JOB_NOT_FOUND = (404, "job_not_found", "No such job")
    NO_VIDEO = (400, "no_video", "Project has no uploaded video")
    SOURCE_VIDEO_MISSING = (404, "no_video", "Project has no source video")
    NO_TRANSCRIPT = (400, "no_transcript", "Project has no transcript yet")
    NO_THUMBNAIL = (404, "no_thumbnail", "Project has no thumbnail")
    MISSING_VIDEO_SOURCE = (
        400,
        "missing_video_source",
        "Provide either a file upload (video) or a video_url, not both or neither",
    )
    INVALID_VIDEO_URL = (
        400,
        "invalid_video_url",
        "Video URL rejected (not a safe http(s) address)",
    )
    VIDEO_FETCH_FAILED = (400, "video_fetch_failed", "Failed to fetch the video from its URL")
    UNSUPPORTED_MEDIA = (415, "unsupported_media", "The URL points to an unsupported media type")
    UPLOAD_TOO_LARGE = (413, "upload_too_large", "Upload exceeds the maximum size")
    VIDEO_TOO_LONG = (400, "video_too_long", "The video is longer than this instance accepts")
    RANGE_NOT_SATISFIABLE = (416, "range_not_satisfiable", "Requested range not satisfiable")
    FONT_UNAVAILABLE = (
        404,
        "font_unavailable",
        "Unknown family, or Google Fonts unreachable",
    )

    # Rendering and files
    UNKNOWN_FORMAT = (400, "unknown_format", "Unknown render format")
    FORMAT_NOT_FOUND = (404, "unknown_format", "Unknown render format")
    NOT_RENDERED = (404, "not_rendered", "Render not available for this format and content")
    ENGINE_UNAVAILABLE = (503, "engine_unavailable", "The caption engine did not answer")

    # Transcription
    UNSUPPORTED_LANGUAGE = (
        400,
        "unsupported_language",
        "Language code not recognized: use 'auto' or an ISO 639-1 code",
    )
    UNKNOWN_MODEL = (400, "unknown_model", "The model is not one this instance lists")
    NOT_ENTITLED = (403, "not_entitled", "The entitlement policy denied the work")
    TRANSCRIPTION_CHOICE_DISABLED = (
        403,
        "transcription_choice_disabled",
        "This instance runs a fixed transcription provider and model.",
    )
    TRANSCRIPTION_LOOP = (
        508,
        "transcription_loop",
        "This instance forwards transcription elsewhere, and the request came from a forwarding "
        "instance: it would go round in a circle.",
    )
    TOO_MANY_TRANSCRIPTIONS = (
        429,
        "too_many_transcriptions",
        "Too many transcriptions are already running; wait for one to finish.",
    )
    TRANSCRIPTION_NOT_READY = (409, "transcription_not_ready", "The transcription is not finished")
    TRANSCRIPTION_FAILED = (409, "transcription_failed", "The transcription failed")

    @property
    def status(self) -> int:
        return int(self.value[0])

    @property
    def code(self) -> str:
        return str(self.value[1])

    @property
    def message(self) -> str:
        return str(self.value[2])

    def exc(self, detail: str | None = None, *, field: str | None = None) -> HTTPException:
        """The exception to raise, in the standard body (`ErrorResponse`). `detail` replaces the
        default message where the text depends on the request."""
        return HTTPException(
            status_code=self.status,
            detail=ErrorResponse(
                error=self.code, detail=detail or self.message, code=self.status, field=field
            ).model_dump(),
        )

    @classmethod
    def docs(cls, *errors: ApiError) -> dict[int | str, dict[str, Any]]:
        """The `responses=` of a route that may raise `errors`: one entry per status, naming each
        code it can carry."""
        by_status: dict[int, list[ApiError]] = {}
        for error in errors:
            by_status.setdefault(error.status, []).append(error)
        return {
            status: {
                "model": ErrorResponse,
                "description": "; ".join(
                    f"{e.message} (`error: {e.code}`)" for e in dict.fromkeys(group)
                ),
            }
            for status, group in by_status.items()
        }
