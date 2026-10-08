"""The transcription API: audio in, a Transcript out, with no project in between.

What another OpenCaptions component (the iOS app, or another instance whose provider is
``opencaptions``) calls to have speech transcribed here. The result is the same
``Transcript`` the rest of the system uses, so a caller maps nothing.

  GET    /transcription/capabilities   what this instance offers and accepts
  POST   /transcriptions               audio file + language [+ model] -> a job (202)
  GET    /jobs/{id}                    progress (the existing endpoint)
  GET    /transcriptions/{id}          the Transcript, once the job is completed
  DELETE /transcriptions/{id}          cancel and delete everything of it

The audio is deleted when its job ends. The result is kept for ``transcription_result_ttl_h``
so a client that was suspended can still fetch it, then deleted: the first request after
the time has passed removes what has expired, so no separate janitor runs.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import pathlib
import tempfile
from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, File, Form, Header, UploadFile, status
from fastapi.responses import JSONResponse, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import db_session, get_current_user, get_owned_job, http_error
from app.core.celery_app import celery_app
from app.core.config import settings
from app.models import Job, User
from app.models.schemas import (
    _404_JOB,
    ErrorResponse,
    LanguageOption,
    ModelOption,
    TranscriptionCapabilities,
    TranscriptionCreated,
)
from app.services.languages import all_languages, is_valid_language
from app.services.usage import USAGE_METADATA_KEY
from app.services.whisper_models import all_models
from app.storage import s3

router = APIRouter(tags=["transcription"])

# Bumped only for a change a client built against the last version cannot cope with.
TRANSCRIPTION_API_VERSION = 1
# Set by the `opencaptions` provider on the requests it forwards, so an instance that
# itself forwards cannot be made to forward to itself in a loop.
HOP_HEADER = "X-OpenCaptions-Hop"
_ACTIVE = ("pending", "running")
_TERMINAL = ("completed", "failed", "cancelled")
_SWEEP_BATCH = 20


def audio_key(job_id: UUID) -> str:
    return f"transcriptions/{job_id}/audio.bin"


def result_key(job_id: UUID) -> str:
    return f"transcriptions/{job_id}/transcript.json"


def _transcription_prefix(job_id: UUID) -> str:
    return f"transcriptions/{job_id}/"


def _is_api_job(job: Job) -> bool:
    return job.type == "transcription" and job.project_id is None


@router.get(
    "/transcription/capabilities",
    response_model=TranscriptionCapabilities,
    summary="What this instance transcribes with and accepts",
)
async def capabilities(
    _user: Annotated[User, Depends(get_current_user)],
) -> TranscriptionCapabilities:
    """The models, languages and limits a client builds its choices from.

    Requires a key: it reveals nothing sensitive, but a 401 here is also how a client
    finds out its key was revoked. In hosted mode the model is fixed and not offered.
    """
    hosted = settings.hosted_mode
    return TranscriptionCapabilities(
        api_version=TRANSCRIPTION_API_VERSION,
        instance_name=settings.instance_name,
        models=[]
        if hosted
        else [ModelOption(id=m.id, label=m.label, note=m.note) for m in all_models()],
        default_model=None if hosted else settings.whisper_model,
        languages=[LanguageOption(code=lang.code, label=lang.label) for lang in all_languages()],
        max_upload_mb=settings.max_upload_size_mb,
        max_duration_s=settings.max_video_duration_s,
        result_ttl_h=settings.transcription_result_ttl_h,
        hosted_mode=hosted,
    )


async def _sweep_expired(session: AsyncSession) -> None:
    """Delete the transcripts whose time is up, a few at a time, as a request passes by."""
    cutoff = datetime.now(UTC) - timedelta(hours=settings.transcription_result_ttl_h)
    expired = (
        (
            await session.execute(
                select(Job)
                .where(
                    Job.type == "transcription",
                    Job.project_id.is_(None),
                    Job.status.in_(_TERMINAL),
                    Job.updated_at < cutoff,
                )
                .limit(_SWEEP_BATCH)
            )
        )
        .scalars()
        .all()
    )
    for job in expired:
        with contextlib.suppress(Exception):
            await asyncio.to_thread(s3.delete_prefix, _transcription_prefix(job.id))
        await session.delete(job)
    if expired:
        await session.flush()


async def _stage_upload(audio: UploadFile) -> tuple[str, float | None]:
    """Write the upload to a temp file within the size limit; return its path and duration."""
    from app.services.audio import probe_duration

    max_bytes = settings.max_upload_size_mb * 1024 * 1024
    if audio.size and audio.size > max_bytes:
        raise http_error(
            413, "upload_too_large", f"Upload exceeds {settings.max_upload_size_mb} MB"
        )
    fd, path = tempfile.mkstemp(prefix="opencaptions-transcription-")
    os.close(fd)
    try:
        written = 0
        with open(path, "wb") as out:
            while chunk := await audio.read(1024 * 1024):
                written += len(chunk)
                if written > max_bytes:
                    raise http_error(
                        413, "upload_too_large", f"Upload exceeds {settings.max_upload_size_mb} MB"
                    )
                out.write(chunk)
        try:
            duration: float | None = await asyncio.to_thread(probe_duration, path)
        except Exception:  # noqa: BLE001, a probe that fails is not a reason to refuse
            duration = None
    except BaseException:
        pathlib.Path(path).unlink(missing_ok=True)
        raise
    return path, duration


@router.post(
    "/transcriptions",
    response_model=TranscriptionCreated,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Transcribe an audio or video file",
)
async def create_transcription(
    audio: Annotated[UploadFile, File(description="Audio, or video: anything ffmpeg reads")],
    session: Annotated[AsyncSession, Depends(db_session)],
    user: Annotated[User, Depends(get_current_user)],
    language: Annotated[str, Form(description="'auto' or an ISO 639-1 code")] = "auto",
    model: Annotated[str | None, Form()] = None,
    hop: Annotated[str | None, Header(alias=HOP_HEADER)] = None,
) -> TranscriptionCreated:
    """Queue a transcription; watch it at ``GET /jobs/{job_id}``, fetch the result at
    ``GET /transcriptions/{job_id}``."""
    if language != "auto" and not is_valid_language(language):
        raise http_error(
            400,
            "unsupported_language",
            f"Unsupported language code: '{language}'. Use 'auto' or a valid ISO 639-1 code.",
        )
    if hop and settings.transcription_provider == "opencaptions":
        raise http_error(
            status.HTTP_508_LOOP_DETECTED,
            "transcription_loop",
            "This instance forwards transcription elsewhere, and the request came from a "
            "forwarding instance: it would go round in a circle.",
        )
    if settings.hosted_mode and model and model != settings.whisper_model:
        raise http_error(
            status.HTTP_403_FORBIDDEN,
            "transcription_choice_disabled",
            "This instance runs a fixed transcription provider and model.",
        )

    await _sweep_expired(session)
    running = await session.scalar(
        select(func.count())
        .select_from(Job)
        .where(
            Job.user_id == user.id,
            Job.type == "transcription",
            Job.project_id.is_(None),
            Job.status.in_(_ACTIVE),
        )
    )
    if (running or 0) >= settings.transcription_max_concurrent:
        raise http_error(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "too_many_transcriptions",
            f"{settings.transcription_max_concurrent} transcriptions are already running; "
            "wait for one to finish.",
        )

    path, duration = await _stage_upload(audio)
    try:
        if duration and duration > settings.max_video_duration_s:
            raise http_error(
                400,
                "video_too_long",
                f"The audio is {duration / 60:.1f} min; this instance accepts up to "
                f"{settings.max_video_duration_s / 60:.0f} min",
            )
        from app.services.entitlements import KIND_TRANSCRIPTION, resolve_policy

        decision = resolve_policy().check(user, KIND_TRANSCRIPTION, float(duration or 0.0))
        if not decision.allowed:
            raise http_error(status.HTTP_403_FORBIDDEN, "not_entitled", decision.reason)

        job = Job(user_id=user.id, type="transcription", status="pending")
        session.add(job)
        await session.flush()
        await asyncio.to_thread(s3.upload_file, audio_key(job.id), path, audio.content_type)
    finally:
        pathlib.Path(path).unlink(missing_ok=True)

    from app.tasks.transcribe import transcribe_upload

    async_result = transcribe_upload.delay(
        str(job.id),
        audio_key(job.id),
        result_key(job.id),
        provider=settings.transcription_provider,
        model=model or settings.whisper_model,
        language=language,
    )
    job.celery_task_id = async_result.id
    await session.flush()
    return TranscriptionCreated(job_id=job.id)


@router.get(
    "/transcriptions/{job_id}",
    responses={
        **_404_JOB,
        409: {
            "description": "Not finished (`transcription_not_ready`) or failed (`transcription_failed`)"
        },
    },
    summary="Get a finished transcript",
)
async def get_transcription(
    job: Annotated[Job, Depends(get_owned_job)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> Response:
    """The Transcript JSON (the schema of ``project.transcript``) of a completed job."""
    if not _is_api_job(job):
        raise http_error(404, "job_not_found", "Job not found")
    if job.status in _ACTIVE:
        raise http_error(409, "transcription_not_ready", "The transcription is not finished")
    if job.status == "deleted":
        return _expired()
    if job.status != "completed":
        raise http_error(
            409, "transcription_failed", job.error or f"The transcription {job.status}"
        )
    age = datetime.now(UTC) - job.updated_at.replace(tzinfo=job.updated_at.tzinfo or UTC)
    if age > timedelta(hours=settings.transcription_result_ttl_h):
        await _delete_everything(job, session)
        # Returned, not raised: an error would roll the deletion back with the request.
        return _expired()
    try:
        body = await asyncio.to_thread(s3.get_object_bytes, result_key(job.id))
    except Exception:  # noqa: BLE001
        return _expired()
    return Response(content=body, media_type="application/json")


def _expired() -> JSONResponse:
    return JSONResponse(
        status_code=404,
        content=ErrorResponse(
            error="transcription_expired", detail="The transcript has been deleted", code=404
        ).model_dump(),
    )


async def _delete_everything(job: Job, session: AsyncSession) -> None:
    """Delete the audio and the transcript. A job that did work keeps its row, marked
    ``deleted``, because that row is what the account's usage is summed from (a phone
    deletes its job as soon as it has the transcript)."""
    with contextlib.suppress(Exception):
        await asyncio.to_thread(s3.delete_prefix, _transcription_prefix(job.id))
    if USAGE_METADATA_KEY in (job.metadata_json or {}):
        job.status = "deleted"
    else:
        await session.delete(job)
    await session.flush()


@router.delete(
    "/transcriptions/{job_id}",
    status_code=204,
    responses={**_404_JOB},
    summary="Cancel a transcription and delete its audio and result",
)
async def delete_transcription(
    job: Annotated[Job, Depends(get_owned_job)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> None:
    if not _is_api_job(job):
        raise http_error(404, "job_not_found", "Job not found")
    if job.status in _ACTIVE and job.celery_task_id:
        celery_app.control.revoke(job.celery_task_id, terminate=True)
    await _delete_everything(job, session)
