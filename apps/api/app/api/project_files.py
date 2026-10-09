"""/api/v1/projects/{id}: requesting and fetching the finished video, the source and poster, and the exports."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Iterator
from typing import Annotated
from urllib.parse import urlencode

from fastapi import APIRouter, Depends, Path, Query, Request, status
from fastapi.responses import JSONResponse, PlainTextResponse, Response, StreamingResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import (
    db_session,
    get_current_user,
    get_owned_project,
    get_owned_project_light,
    http_error,
)
from app.models import Job, Project, User
from app.models.schemas import (
    _400_NO_TRANSCRIPT,
    _400_NO_VIDEO,
    _400_UNKNOWN_FORMAT,
    _404_NOT_RENDERED,
    _404_PROJECT,
    _404_PROJECT_OR_THUMBNAIL,
    DownloadResponse,
    ErrorResponse,
    ExportChoices,
    ExportsResponse,
    RenderOptions,
    RenderRequest,
    SubtitleExportLinks,
    Transcript,
    VideoExportOption,
)
from app.services import captions_export
from app.services.caption_offset import apply_caption_offset
from app.services.entitlements import KIND_RENDER, resolve_policy
from app.services.render_formats import (
    all_formats,
    available_frame_rates,
    available_resolutions,
    get_format,
    render_object_key,
    resolve_render_inputs,
    source_short_side,
)
from app.storage import s3

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/projects", tags=["projects"])


@router.post(
    "/{project_id}/download",
    response_model=DownloadResponse,
    status_code=status.HTTP_200_OK,
    responses={
        202: {
            "model": DownloadResponse,
            "description": "Render job queued, `ready` is false, `job_id` is populated",
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
    options = RenderOptions.model_validate(body.model_dump(exclude={"format"}))
    inputs = resolve_render_inputs(proj, options)
    render_hash = inputs.hash_for(fmt.id)

    output_key = render_object_key(str(project_id), render_hash, fmt.extension)

    # Cache HIT: the content-addressed object already exists in storage.
    exists = await asyncio.to_thread(s3.object_exists, output_key)
    if exists:
        return DownloadResponse(
            ready=True,
            download_url=f"/api/v1/projects/{project_id}/download/{fmt.id}"
            f"?{urlencode(options.model_dump())}",
        )

    # Check if a render job for this exact output is already in flight
    # (deduplication: avoid enqueuing the same work twice).
    result = await session.execute(
        select(Job)
        .where(Job.project_id == proj.id)
        .where(Job.type == "rendering")
        .where(Job.status.in_(("pending", "running")))
        .order_by(Job.created_at.desc())
    )
    for existing_job in result.scalars().all():
        if (
            existing_job.metadata_json
            and existing_job.metadata_json.get("render_hash") == render_hash
        ):
            return JSONResponse(
                status_code=202,
                content=DownloadResponse(ready=False, job_id=str(existing_job.id)).model_dump(),
            )

    # Only where a NEW render is enqueued, not on a cache hit or a dedup, where
    # no fresh work begins.
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
        metadata_json={
            "format_id": fmt.id,
            "options": options.model_dump(),
            "render_hash": render_hash,
        },
    )
    session.add(job)
    await session.flush()

    from app.tasks.render import render_video

    async_result = render_video.delay(str(job.id), str(proj.id), body.format, options.model_dump())
    job.celery_task_id = async_result.id
    proj.status = "rendering"
    await session.flush()

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
    options: Annotated[RenderOptions, Query()],
    request: Request,
) -> StreamingResponse:
    """Stream a cached rendered video.

    Uses the content-addressed hash to locate the object. Returns 404 if
    the render has not been completed yet for this format + current content.
    """
    project_id = proj.id
    fmt = get_format(format_id)
    if fmt is None:
        raise http_error(404, "unknown_format", f"Unknown format '{format_id}'")

    if proj.transcript is None:
        raise http_error(404, "not_rendered", "No transcript, cannot have a render")

    render_hash = resolve_render_inputs(proj, options).hash_for(fmt.id)

    output_key = render_object_key(str(project_id), render_hash, fmt.extension)

    range_header = request.headers.get("range")
    try:
        response = await _stream_s3_object(output_key, range_header)
    except s3.ObjectNotFoundError:
        raise http_error(
            404,
            "not_rendered",
            f"Render not available for format '{format_id}' with current content",
        ) from None
    response.headers["Content-Disposition"] = (
        f'attachment; filename="opencaptions-{project_id}{fmt.extension}"'
    )
    # Override the generic content-type from S3 with the format's correct MIME
    response.media_type = fmt.mime
    return response


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
    proj: Annotated[Project, Depends(get_owned_project_light)],
    request: Request,
) -> StreamingResponse:
    """Stream the original uploaded video.

    Used by the editor preview. Honors HTTP Range so the
    `<video>` element can seek without downloading the whole file.
    """
    if not proj.video_storage_key:
        raise http_error(404, "no_video", "Project has no source video")

    try:
        return await _stream_s3_object(proj.video_storage_key, request.headers.get("range"))
    except s3.ObjectNotFoundError:
        raise http_error(404, "no_video", "Project has no source video") from None


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
    proj: Annotated[Project, Depends(get_owned_project_light)],
) -> Response:
    """Return the poster frame as a JPEG, or 404."""
    key = f"projects/{proj.id}/thumbnail.jpg"
    try:
        data = await asyncio.to_thread(s3.get_object_bytes, key)
    except s3.ObjectNotFoundError:
        raise http_error(404, "no_thumbnail", "Project has no thumbnail") from None
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
    project_id = proj.id
    if proj.transcript is None:
        raise http_error(400, "no_transcript", "Project has no transcript yet")

    base = f"/api/v1/projects/{project_id}"

    # Compute the render hash once (shared across formats except format_id)
    render_inputs = resolve_render_inputs(proj)

    # What is ready: one listing of the project's renders (pruning keeps about one per
    # format), not a request per format.
    stored = set(await asyncio.to_thread(s3.list_prefix, f"projects/{project_id}/renders/"))
    video_exports = []
    for fmt in all_formats():
        exists = render_inputs.object_key_for(str(project_id), fmt) in stored
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
        choices=ExportChoices(
            resolutions=available_resolutions(proj),
            source_resolution=source_short_side(proj),
            frame_rates=available_frame_rates(proj),
            source_fps=float(proj.video_fps) if proj.video_fps else None,
        ),
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


async def _stream_s3_object(key: str, range_header: str | None) -> StreamingResponse:
    """Stream an S3 object, optionally honoring an HTTP Range header.

    boto3's GetObject supports Range natively, which lets the browser seek. A missing
    key raises ObjectNotFoundError for the caller to name; a range outside the file is 416.
    """
    try:
        obj = await asyncio.to_thread(s3.open_object, key, range_header)
    except s3.RangeNotSatisfiableError:
        raise http_error(416, "range_not_satisfiable", "Requested range not satisfiable") from None

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
