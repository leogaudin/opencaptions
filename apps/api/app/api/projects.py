"""/api/v1/projects router — CRUD + transcribe + render endpoints."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import pathlib
import tempfile
from typing import Annotated

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    Path,
    Query,
    Request,
    UploadFile,
    status,
)
from fastapi.responses import PlainTextResponse, Response, StreamingResponse
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import db_session, get_current_user, get_owned_project, http_error
from app.core.config import settings
from app.models import Job, Project, User
from app.models.schemas import (
    _400_INVALID_VIDEO_URL,
    _400_MISSING_VIDEO_SOURCE,
    _400_NO_TRANSCRIPT,
    _400_NO_VIDEO,
    _400_UNKNOWN_FORMAT,
    _400_UNSUPPORTED_LANGUAGE,
    _400_VIDEO_FETCH_FAILED,
    _400_VIDEO_TOO_LONG,
    _403_TRANSCRIPTION_CHOICE,
    _404_NOT_RENDERED,
    _404_PROJECT,
    _404_PROJECT_OR_THUMBNAIL,
    _413_UPLOAD_TOO_LARGE,
    _415_UNSUPPORTED_MEDIA,
    DownloadResponse,
    ErrorResponse,
    ExportsResponse,
    JobStatus,
    ProjectList,
    ProjectListItem,
    ProjectStatus,
    ProjectUpdate,
    RenderRequest,
    SubtitleExportLinks,
    TranscribeRequest,
    Transcript,
    VideoExportOption,
)
from app.services import captions_export
from app.services.caption_offset import apply_caption_offset
from app.services.languages import is_valid_language
from app.storage import s3

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/projects", tags=["projects"])


async def _project_with_active_job(session: AsyncSession, proj: Project) -> ProjectStatus:
    """Build a ProjectStatus enriched with the latest non-terminal job, if any.

    Lets the editor restore the live progress bar after a page refresh without
    needing a separate /jobs query.
    """
    result = await session.execute(
        select(Job)
        .where(Job.project_id == proj.id)
        .where(Job.status.in_(("pending", "running")))
        .order_by(Job.created_at.desc())
        .limit(1)
    )
    active = result.scalars().first()
    payload = ProjectStatus.model_validate(proj)
    if active is not None:
        payload.active_job = JobStatus.model_validate(active)
    return payload


@router.get("", response_model=ProjectList, summary="List projects")
async def list_projects(
    session: Annotated[AsyncSession, Depends(db_session)],
    user: Annotated[User, Depends(get_current_user)],
    page: Annotated[int, Query(ge=1)] = 1,
    per_page: Annotated[int, Query(ge=1, le=100)] = 20,
) -> ProjectList:
    """Paginated project list for the current user, newest first.

    Scoped to the caller's own projects — never lists other users' projects.
    """
    offset = (page - 1) * per_page
    rows = (
        (
            await session.execute(
                select(Project)
                .where(Project.owner_id == user.id)
                .order_by(Project.created_at.desc())
                .offset(offset)
                .limit(per_page)
            )
        )
        .scalars()
        .all()
    )
    total = await session.scalar(
        select(func.count()).select_from(Project).where(Project.owner_id == user.id)
    )
    return ProjectList(
        items=[ProjectListItem.model_validate(r) for r in rows],
        total=int(total or 0),
        page=page,
        per_page=per_page,
    )


async def _ingest_video(
    project: Project,
    tmp_path: str,
    extension: str,
    content_type: str | None,
) -> None:
    """Probe metadata, upload to S3, set the storage key.

    Both the upload and URL paths converge here. The caller writes the bytes.
    """
    import asyncio

    from app.services.audio import probe_video_metadata

    key = f"projects/{project.id}/source{extension}"

    # Probe before upload — best-effort, never fail the upload over it.
    try:
        meta = await asyncio.to_thread(probe_video_metadata, tmp_path)
        project.video_width = meta["width"]
        project.video_height = meta["height"]
        project.video_fps = meta["fps"]
        project.video_duration = meta["duration"]
    except Exception:  # noqa: BLE001
        # Probe failures should never block the upload.
        pass

    # MAX_VIDEO_DURATION_S is advertised by GET /settings, so it has to mean
    # something. Enforced here because this is where the duration becomes known,
    # and before the upload, so an over-long video costs no storage. A video whose
    # duration could not be probed is admitted rather than guessed at.
    duration = project.video_duration
    if duration and duration > settings.max_video_duration_s:
        raise http_error(
            400,
            "video_too_long",
            f"Video is {duration / 60:.1f} min; this instance accepts up to "
            f"{settings.max_video_duration_s / 60:.0f} min",
        )

    # Upload to S3 from the temp file (boto3 sync, off the event loop).
    await asyncio.to_thread(s3.upload_file, key, tmp_path, content_type)
    project.video_storage_key = key

    # Generate a poster frame while the file is still local. Best-effort only:
    # see _generate_and_store_thumbnail — a failed thumbnail must never break
    # the upload.
    await _generate_and_store_thumbnail(project, tmp_path)


async def _generate_and_store_thumbnail(project: Project, video_path: str) -> None:
    """Store a poster frame at projects/{id}/thumbnail.jpg.

    Every failure is swallowed: a missing thumbnail must never break an upload.
    """
    import asyncio
    import logging as _logging
    import os
    import tempfile

    from app.services.thumbnails import extract_thumbnail

    _log = _logging.getLogger(__name__)

    fd, thumb_path = tempfile.mkstemp(prefix="opencaptions-thumb-", suffix=".jpg")
    os.close(fd)
    try:
        await asyncio.to_thread(extract_thumbnail, video_path, thumb_path, project.video_duration)
        await asyncio.to_thread(
            s3.upload_file, f"projects/{project.id}/thumbnail.jpg", thumb_path, "image/jpeg"
        )
    except Exception as e:  # noqa: BLE001
        # Never fatal — a missing thumbnail is cosmetic, a lost video is not.
        _log.warning("thumbnail generation skipped for project %s: %s", project.id, e)
    finally:
        with contextlib.suppress(OSError):
            pathlib.Path(thumb_path).unlink(missing_ok=True)


def _reject_ambiguous_source(has_video: bool, has_url: bool) -> None:
    """Exactly one of the file part or video_url must be supplied."""
    if has_video == has_url:
        detail = (
            "Provide either a file upload or a video_url, not both"
            if has_video
            else "Provide either a file upload (video) or a video_url"
        )
        raise http_error(400, "missing_video_source", detail)


async def _ingest_uploaded_file(project: Project, video: UploadFile) -> None:
    """Stream an uploaded file to disk, then ingest it.

    The upload is written to a temp file first so ffprobe can read metadata. The
    double-write cost is bounded by MAX_UPLOAD_SIZE_MB.
    """
    max_bytes = settings.max_upload_size_mb * 1024 * 1024
    if video.size and video.size > max_bytes:
        raise http_error(
            413, "upload_too_large", f"Upload exceeds {settings.max_upload_size_mb} MB"
        )

    ext = _extension(video.filename)
    fd, tmp_path = tempfile.mkstemp(prefix="opencaptions-upload-", suffix=ext)
    os.close(fd)
    try:
        with open(tmp_path, "wb") as out:
            while True:
                chunk = await video.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
        await _ingest_video(project, tmp_path, ext, video.content_type)
    finally:
        with contextlib.suppress(OSError):
            pathlib.Path(tmp_path).unlink(missing_ok=True)


async def _ingest_remote_url(project: Project, video_url: str) -> None:
    """Fetch a user-supplied URL through the SSRF guard, then ingest it."""
    from app.services.video_fetch import (
        FetchFailedError,
        FileTooLargeError,
        UnsafeURLError,
        UnsupportedMediaError,
        fetch_video_to_tempfile,
    )

    # Each fetch failure maps to one client-visible error; the guard's own
    # message is surfaced verbatim so a rejected URL explains itself.
    error_map: list[tuple[type[Exception], int, str]] = [
        (UnsafeURLError, 400, "invalid_video_url"),
        (FetchFailedError, 400, "video_fetch_failed"),
        (UnsupportedMediaError, 415, "unsupported_media"),
        (FileTooLargeError, 413, "upload_too_large"),
    ]

    url = video_url.strip()
    try:
        tmp_path, ext = await asyncio.to_thread(fetch_video_to_tempfile, url)
    except tuple(exc for exc, _, _ in error_map) as e:
        status_code, error = next(
            (code, name) for exc, code, name in error_map if isinstance(e, exc)
        )
        logger.warning("video_url rejected (%s): %s — %s", error, url, e)
        raise http_error(status_code, error, str(e)) from e

    try:
        # Content-Type is not reliably known from the remote — pass None and
        # let storage default to application/octet-stream.
        await _ingest_video(project, tmp_path, ext, None)
    finally:
        with contextlib.suppress(OSError):
            pathlib.Path(tmp_path).unlink(missing_ok=True)


@router.post(
    "",
    response_model=ProjectStatus,
    status_code=status.HTTP_201_CREATED,
    responses={
        **_400_MISSING_VIDEO_SOURCE,
        **_400_INVALID_VIDEO_URL,
        **_400_VIDEO_FETCH_FAILED,
        **_400_VIDEO_TOO_LONG,
        **_413_UPLOAD_TOO_LARGE,
        **_415_UNSUPPORTED_MEDIA,
    },
    summary="Create project",
)
async def create_project(
    session: Annotated[AsyncSession, Depends(db_session)],
    user: Annotated[User, Depends(get_current_user)],
    title: Annotated[str, Form(min_length=1, max_length=255)],
    video: Annotated[UploadFile | None, File()] = None,
    video_url: Annotated[str | None, Form()] = None,
) -> ProjectStatus:
    """Create a new project from a multipart file upload or a video URL.

    Exactly one of `video` (file part) or `video_url` (string) must be provided.
    """
    has_video = bool(video is not None and video.filename)  # empty file part = no upload
    has_url = bool(video_url is not None and video_url.strip())
    _reject_ambiguous_source(has_video, has_url)

    project = Project(title=title, owner_id=user.id)
    session.add(project)
    await session.flush()  # get project.id

    if has_video:
        assert video is not None  # type narrowing for mypy
        await _ingest_uploaded_file(project, video)
    else:
        assert video_url is not None  # type narrowing for mypy
        await _ingest_remote_url(project, video_url)

    await session.flush()
    return await _project_with_active_job(session, project)


@router.get(
    "/{project_id}", response_model=ProjectStatus, responses={**_404_PROJECT}, summary="Get project"
)
async def get_project(
    proj: Annotated[Project, Depends(get_owned_project)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ProjectStatus:
    """Retrieve a single project with its transcript, style config, and active job (if any)."""
    return await _project_with_active_job(session, proj)


@router.patch(
    "/{project_id}",
    response_model=ProjectStatus,
    responses={**_404_PROJECT},
    summary="Update project",
)
async def update_project(
    proj: Annotated[Project, Depends(get_owned_project)],
    body: ProjectUpdate,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ProjectStatus:
    """Partial update — set title, transcript, style_config, or caption offset independently."""
    if body.title is not None:
        proj.title = body.title
    if body.transcript is not None:
        proj.transcript = body.transcript.model_dump()
    if body.style_config is not None:
        proj.style_config = body.style_config.model_dump()
    if body.caption_offset_ms is not None:
        proj.caption_offset_ms = body.caption_offset_ms
    await session.flush()
    return await _project_with_active_job(session, proj)


@router.delete(
    "/{project_id}", status_code=204, responses={**_404_PROJECT}, summary="Delete project"
)
async def delete_project(
    proj: Annotated[Project, Depends(get_owned_project)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> None:
    """Delete the project, cancel its jobs, remove its objects."""
    # Cancel any in-progress Celery tasks for this project
    from app.core.celery_app import celery_app

    jobs_q = await session.execute(select(Job).where(Job.project_id == proj.id))
    for job in jobs_q.scalars().all():
        if job.celery_task_id and job.status in {"pending", "running"}:
            celery_app.control.revoke(job.celery_task_id, terminate=True)
            job.status = "cancelled"

    # Delete S3 objects under projects/{id}/
    import asyncio

    await asyncio.to_thread(s3.delete_prefix, f"projects/{proj.id}/")

    await session.delete(proj)


@router.post(
    "/{project_id}/transcribe",
    response_model=JobStatus,
    status_code=status.HTTP_202_ACCEPTED,
    responses={
        **_404_PROJECT,
        **_400_NO_VIDEO,
        **_400_UNSUPPORTED_LANGUAGE,
        **_403_TRANSCRIPTION_CHOICE,
    },
    summary="Start transcription",
)
async def start_transcription(
    proj: Annotated[Project, Depends(get_owned_project)],
    body: TranscribeRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
    user: Annotated[User, Depends(get_current_user)],
) -> JobStatus:
    """Enqueue a transcription job."""
    if proj.video_storage_key is None:
        raise http_error(400, "no_video", "Project has no uploaded video")

    # Validate language: accept "auto" or any known Whisper language code.
    if body.language != "auto" and not is_valid_language(body.language):
        raise http_error(
            400,
            "unsupported_language",
            f"Unsupported language code: '{body.language}'. "
            "Use 'auto' for automatic detection or a valid ISO 639-1 code.",
        )

    # Hosted posture: the operator pays for compute and answers for where audio
    # goes, so both the provider and the model are fixed to the deployment
    # defaults. Rejected here, not silently ignored, so a client that sends a
    # different value learns it was not honoured. Naming the defaults themselves
    # is allowed since it changes nothing.
    if settings.hosted_mode:
        provider_override = body.provider and body.provider != settings.transcription_provider
        model_override = body.model and body.model != settings.whisper_model
        if provider_override or model_override:
            raise http_error(
                status.HTTP_403_FORBIDDEN,
                "transcription_choice_disabled",
                "This instance runs a fixed transcription provider and model.",
            )

    # Checked before the work is enqueued. The default policy never denies, so
    # self-hosted behaviour is unchanged.
    from app.services.entitlements import KIND_TRANSCRIPTION, resolve_policy

    decision = resolve_policy().check(user, KIND_TRANSCRIPTION, float(proj.video_duration or 0.0))
    if not decision.allowed:
        raise http_error(status.HTTP_403_FORBIDDEN, "not_entitled", decision.reason)

    job = Job(project_id=proj.id, user_id=user.id, type="transcription", status="pending")
    session.add(job)
    await session.flush()

    # Enqueue the Celery task.
    from app.tasks.transcribe import transcribe_video

    async_result = transcribe_video.delay(
        str(job.id),
        str(proj.id),
        provider=body.provider or settings.transcription_provider,
        model=body.model or settings.whisper_model,
        language=body.language,
    )
    job.celery_task_id = async_result.id
    proj.status = "transcribing"
    await session.flush()
    return JobStatus.model_validate(job)


@router.post(
    "/{project_id}/download",
    response_model=DownloadResponse,
    status_code=status.HTTP_200_OK,
    responses={
        202: {
            "model": DownloadResponse,
            "description": "Render job queued — `ready` is false, `job_id` is populated",
        },
        **_404_PROJECT,
        **_400_UNKNOWN_FORMAT,
        **_400_NO_VIDEO,
        **_400_NO_TRANSCRIPT,
    },
    summary="Request video download",
)
async def request_download(
    proj: Annotated[Project, Depends(get_owned_project)],
    body: RenderRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
    user: Annotated[User, Depends(get_current_user)],
) -> DownloadResponse | Response:
    """Request a rendered video in a given format.

    Content-addressed: an existing object returns 200 with a URL, otherwise a job
    is enqueued and 202 returned. Concurrent requests for the same hash dedup
    onto the in-flight job.
    """
    import asyncio

    from app.services.render_formats import (
        all_formats,
        get_format,
        render_object_key,
        resolve_render_inputs,
    )

    project_id = proj.id

    # Validate format
    fmt = get_format(body.format)
    if fmt is None:
        raise http_error(
            400,
            "unknown_format",
            f"Unknown format '{body.format}'. Valid formats: {[f.id for f in all_formats()]}",
        )

    # Must have a video
    if not proj.video_storage_key:
        raise http_error(400, "no_video", "Project has no uploaded video")

    # Must have a transcript
    if proj.transcript is None:
        raise http_error(400, "no_transcript", "Cannot render: project has no transcript yet")

    # Compute the content-addressed hash for this render configuration
    inputs = resolve_render_inputs(proj)
    render_hash = inputs.hash_for(fmt.id)

    output_key = render_object_key(str(project_id), render_hash, fmt.extension)

    # Cache HIT: the content-addressed object already exists in storage.
    exists = await asyncio.to_thread(s3.object_exists, output_key)
    if exists:
        return DownloadResponse(
            ready=True,
            download_url=f"/api/v1/projects/{project_id}/download/{fmt.id}",
        )

    # Check if a render job for this project+format is already in flight
    # (deduplication: avoid enqueuing the same work twice).
    result = await session.execute(
        select(Job)
        .where(Job.project_id == proj.id)
        .where(Job.type == "rendering")
        .where(Job.status.in_(("pending", "running")))
        .order_by(Job.created_at.desc())
    )
    for existing_job in result.scalars().all():
        # Check if the job's metadata matches this format
        if existing_job.metadata_json and existing_job.metadata_json.get("format_id") == fmt.id:
            from starlette.responses import JSONResponse

            return JSONResponse(
                status_code=202,
                content=DownloadResponse(ready=False, job_id=str(existing_job.id)).model_dump(),
            )

    # Only where a NEW render is enqueued — not on a cache hit or a dedup, where
    # no fresh work begins.
    from app.services.entitlements import KIND_RENDER, resolve_policy

    estimated_frames = (
        float(round(float(proj.video_duration) * inputs.fps)) if proj.video_duration else 0.0
    )
    decision = resolve_policy().check(user, KIND_RENDER, estimated_frames)
    if not decision.allowed:
        raise http_error(status.HTTP_403_FORBIDDEN, "not_entitled", decision.reason)

    # Cache MISS: enqueue a new render job.
    job = Job(
        project_id=proj.id,
        user_id=user.id,
        type="rendering",
        status="pending",
        metadata_json={"format_id": fmt.id, "render_hash": render_hash},
    )
    session.add(job)
    await session.flush()

    from app.tasks.render import render_video

    async_result = render_video.delay(str(job.id), str(proj.id), body.format)
    job.celery_task_id = async_result.id
    proj.status = "rendering"
    await session.flush()

    from starlette.responses import JSONResponse

    return JSONResponse(
        status_code=202,
        content=DownloadResponse(ready=False, job_id=str(job.id)).model_dump(),
    )


@router.get(
    "/{project_id}/download/{format_id}",
    response_class=StreamingResponse,
    responses={
        200: {"content": {"video/*": {}}},
        **_404_NOT_RENDERED,
        **_404_PROJECT,
    },
    summary="Download rendered video",
)
async def download_render(
    proj: Annotated[Project, Depends(get_owned_project)],
    format_id: Annotated[str, Path()],
    request: Request,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> StreamingResponse:
    """Stream a cached rendered video.

    Uses the content-addressed hash to locate the object. Returns 404 if
    the render has not been completed yet for this format + current content.
    """
    import asyncio

    from app.services.render_formats import (
        get_format,
        render_object_key,
        resolve_render_inputs,
    )

    project_id = proj.id
    fmt = get_format(format_id)
    if fmt is None:
        raise http_error(404, "unknown_format", f"Unknown format '{format_id}'")

    if proj.transcript is None:
        raise http_error(404, "not_rendered", "No transcript — cannot have a render")

    render_hash = resolve_render_inputs(proj).hash_for(fmt.id)

    output_key = render_object_key(str(project_id), render_hash, fmt.extension)

    exists = await asyncio.to_thread(s3.object_exists, output_key)
    if not exists:
        raise http_error(
            404,
            "not_rendered",
            f"Render not available for format '{format_id}' with current content",
        )

    range_header = request.headers.get("range") or request.headers.get("Range")
    response = _stream_s3_object(output_key, range_header)
    response.headers["Content-Disposition"] = (
        f'attachment; filename="opencaptions-{project_id}{fmt.extension}"'
    )
    # Override the generic content-type from S3 with the format's correct MIME
    response.media_type = fmt.mime
    return response


def _extension(filename: str | None) -> str:
    if not filename or "." not in filename:
        return ".mp4"
    return "." + filename.rsplit(".", 1)[-1].lower()


# Source video proxy + export endpoints


@router.get(
    "/{project_id}/source",
    response_class=StreamingResponse,
    responses={
        200: {"content": {"video/*": {}}},
        404: {
            "model": ErrorResponse,
            "description": "Project not found (`error: project_not_found`) or has no source video (`error: no_video`)",
        },
    },
    summary="Stream source video",
)
async def get_project_source(
    proj: Annotated[Project, Depends(get_owned_project)],
    request: Request,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> StreamingResponse:
    """Stream the original uploaded video.

    Used by the editor preview. Honors HTTP Range so the
    `<video>` element can seek without downloading the whole file.
    """
    if not proj.video_storage_key:
        raise http_error(404, "no_video", "Project has no source video")

    range_header = request.headers.get("range") or request.headers.get("Range")
    return _stream_s3_object(proj.video_storage_key, range_header)


@router.get(
    "/{project_id}/thumbnail",
    response_class=Response,
    responses={
        200: {"content": {"image/jpeg": {}}, "description": "Project poster frame (JPEG)"},
        **_404_PROJECT_OR_THUMBNAIL,
    },
    summary="Get project thumbnail",
)
async def get_project_thumbnail(
    proj: Annotated[Project, Depends(get_owned_project)],
) -> Response:
    """Return the poster frame as a JPEG, or 404."""
    import asyncio

    key = f"projects/{proj.id}/thumbnail.jpg"
    if not await asyncio.to_thread(s3.object_exists, key):
        raise http_error(404, "no_thumbnail", "Project has no thumbnail")
    data = await asyncio.to_thread(s3.get_object_bytes, key)
    return Response(
        content=data,
        media_type="image/jpeg",
        headers={"Cache-Control": "private, max-age=300"},
    )


@router.get(
    "/{project_id}/exports",
    response_model=ExportsResponse,
    responses={**_404_PROJECT, **_400_NO_TRANSCRIPT},
    summary="List export options",
)
async def get_project_exports(
    proj: Annotated[Project, Depends(get_owned_project)],
) -> ExportsResponse:
    """Return ready-to-download links for every available export format.

    Video exports use content-addressed caching: `ready` reflects whether
    the hash-named object currently exists in storage for each format.
    """
    import asyncio

    from app.services.render_formats import all_formats, resolve_render_inputs

    project_id = proj.id
    if proj.transcript is None:
        raise http_error(400, "no_transcript", "Project has no transcript yet")

    base = f"/api/v1/projects/{project_id}"

    # Compute the render hash once (shared across formats except format_id)
    render_inputs = resolve_render_inputs(proj)

    # Check each format's existence in storage
    video_exports = []
    for fmt in all_formats():
        output_key = render_inputs.object_key_for(str(project_id), fmt)
        exists = await asyncio.to_thread(s3.object_exists, output_key)
        video_exports.append(
            VideoExportOption(
                format=fmt.id,
                label=fmt.label,
                ready=exists,
                download_url=f"{base}/download/{fmt.id}",
                note=fmt.note,
            )
        )

    return ExportsResponse(
        video=video_exports,
        subtitles=SubtitleExportLinks(
            srt=f"{base}/export.srt",
            vtt=f"{base}/export.vtt",
            json_url=f"{base}/export.json",
        ),
    )


@router.get(
    "/{project_id}/export.srt",
    response_class=PlainTextResponse,
    responses={**_404_PROJECT, **_400_NO_TRANSCRIPT},
    summary="Export SRT subtitles",
)
async def export_srt(
    proj: Annotated[Project, Depends(get_owned_project)],
) -> Response:
    """Download the transcript as an SRT subtitle file."""
    transcript = _require_transcript(proj, with_offset=True)
    body = captions_export.to_srt(transcript)
    return Response(
        content=body,
        media_type="application/x-subrip",
        headers={"Content-Disposition": f'attachment; filename="captions-{proj.id}.srt"'},
    )


@router.get(
    "/{project_id}/export.vtt",
    response_class=PlainTextResponse,
    responses={**_404_PROJECT, **_400_NO_TRANSCRIPT},
    summary="Export VTT subtitles",
)
async def export_vtt(
    proj: Annotated[Project, Depends(get_owned_project)],
) -> Response:
    """Download the transcript as a WebVTT subtitle file."""
    transcript = _require_transcript(proj, with_offset=True)
    body = captions_export.to_vtt(transcript)
    return Response(
        content=body,
        media_type="text/vtt",
        headers={"Content-Disposition": f'attachment; filename="captions-{proj.id}.vtt"'},
    )


@router.get(
    "/{project_id}/export.json",
    responses={**_404_PROJECT, **_400_NO_TRANSCRIPT},
    summary="Export JSON transcript",
)
async def export_json(
    proj: Annotated[Project, Depends(get_owned_project)],
) -> Response:
    """Download the full transcript as a structured JSON file."""
    transcript = _require_transcript(proj)
    body = captions_export.to_json(transcript)
    return Response(
        content=body,
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="transcript-{proj.id}.json"'},
    )


def _require_transcript(proj: Project, *, with_offset: bool = False) -> Transcript:
    """The project's transcript; `with_offset` shifts every time by the caption offset.

    Timed files (SRT, VTT) take the offset so they line up with the video, which
    the engine shifts the same way. The JSON export is the data and stays as stored.
    """
    if proj.transcript is None:
        raise http_error(400, "no_transcript", "Project has no transcript yet")
    stored = dict(proj.transcript)
    if with_offset:
        stored = apply_caption_offset(stored, proj.caption_offset_ms)
    return Transcript.model_validate(stored)


def _stream_s3_object(key: str, range_header: str | None) -> StreamingResponse:
    """Stream an S3 object, optionally honoring an HTTP Range header.

    boto3's GetObject supports Range natively, which lets the browser seek.
    """
    from collections.abc import Iterator

    from app.storage.s3 import _client

    extra: dict[str, str] = {}
    if range_header:
        extra["Range"] = range_header
    obj = _client.get_object(Bucket=settings.s3_bucket, Key=key, **extra)

    body = obj["Body"]
    content_type = obj.get("ContentType") or "application/octet-stream"
    content_length = obj.get("ContentLength")

    headers: dict[str, str] = {"Accept-Ranges": "bytes"}
    if "ContentRange" in obj:
        headers["Content-Range"] = obj["ContentRange"]
    if content_length is not None:
        headers["Content-Length"] = str(content_length)

    status_code = 206 if range_header and "ContentRange" in obj else 200

    def _iter() -> Iterator[bytes]:
        try:
            while True:
                chunk = body.read(64 * 1024)
                if not chunk:
                    return
                yield chunk
        finally:
            body.close()

    return StreamingResponse(
        _iter(),
        status_code=status_code,
        media_type=content_type,
        headers=headers,
    )
