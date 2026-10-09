"""Taking a video into a project: from an upload or a URL, probed, stored, with a poster.

Not a router; `POST /projects` calls it. Both sources end in :func:`ingest_video`.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import pathlib
import tempfile

from fastapi import UploadFile

from app.api.deps import http_error
from app.core.config import settings
from app.models import Project
from app.services.upload import UploadTooLargeError, copy_capped
from app.storage import s3

logger = logging.getLogger(__name__)


def extension(filename: str | None) -> str:
    if not filename or "." not in filename:
        return ".mp4"
    return "." + filename.rsplit(".", 1)[-1].lower()


async def ingest_video(
    project: Project,
    tmp_path: str,
    ext: str,
    content_type: str | None,
) -> None:
    """Probe metadata, upload to S3, set the storage key.

    Both the upload and URL paths converge here. The caller writes the bytes.
    """
    from app.services.audio import probe_video_metadata

    key = f"projects/{project.id}/source{ext}"
    project.video_size_bytes = os.path.getsize(tmp_path)

    # Probe before upload, best-effort, never fail the upload over it.
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

    # The poster is cut from the local file while it is still here, beside the upload
    # of the video itself: neither waits for the other. A failed poster never fails the
    # upload (see generate_and_store_thumbnail).
    await asyncio.gather(
        asyncio.to_thread(s3.upload_file, key, tmp_path, content_type),
        generate_and_store_thumbnail(project, tmp_path),
    )
    project.video_storage_key = key


async def generate_and_store_thumbnail(project: Project, video_path: str) -> None:
    """Store a poster frame at projects/{id}/thumbnail.jpg.

    Every failure is swallowed: a missing thumbnail must never break an upload.
    """
    from app.services.thumbnails import extract_thumbnail

    fd, thumb_path = tempfile.mkstemp(prefix="opencaptions-thumb-", suffix=".jpg")
    os.close(fd)
    try:
        await asyncio.to_thread(extract_thumbnail, video_path, thumb_path, project.video_duration)
        await asyncio.to_thread(
            s3.upload_file, f"projects/{project.id}/thumbnail.jpg", thumb_path, "image/jpeg"
        )
    except Exception as e:  # noqa: BLE001
        # Never fatal, a missing thumbnail is cosmetic, a lost video is not.
        logger.warning("thumbnail generation skipped for project %s: %s", project.id, e)
    finally:
        with contextlib.suppress(OSError):
            pathlib.Path(thumb_path).unlink(missing_ok=True)


def reject_ambiguous_source(has_video: bool, has_url: bool) -> None:
    """Exactly one of the file part or video_url must be supplied."""
    if has_video == has_url:
        detail = (
            "Provide either a file upload or a video_url, not both"
            if has_video
            else "Provide either a file upload (video) or a video_url"
        )
        raise http_error(400, "missing_video_source", detail)


async def ingest_uploaded_file(project: Project, video: UploadFile) -> None:
    """Write an uploaded file to disk, then ingest it.

    The upload is written to a temp file first so ffprobe can read metadata. The
    double-write cost is bounded by MAX_UPLOAD_SIZE_MB.
    """
    max_bytes = settings.max_upload_size_mb * 1024 * 1024
    too_large = http_error(
        413, "upload_too_large", f"Upload exceeds {settings.max_upload_size_mb} MB"
    )
    if video.size and video.size > max_bytes:
        raise too_large

    ext = extension(video.filename)
    fd, tmp_path = tempfile.mkstemp(prefix="opencaptions-upload-", suffix=ext)
    os.close(fd)
    try:
        try:
            await asyncio.to_thread(copy_capped, video.file, tmp_path, max_bytes)
        except UploadTooLargeError:
            raise too_large from None
        await ingest_video(project, tmp_path, ext, video.content_type)
    finally:
        with contextlib.suppress(OSError):
            pathlib.Path(tmp_path).unlink(missing_ok=True)


async def ingest_remote_url(project: Project, video_url: str) -> None:
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
        logger.warning("video_url rejected (%s): %s, %s", error, url, e)
        raise http_error(status_code, error, str(e)) from e

    try:
        # Content-Type is not reliably known from the remote, pass None and
        # let storage default to application/octet-stream.
        await ingest_video(project, tmp_path, ext, None)
    finally:
        with contextlib.suppress(OSError):
            pathlib.Path(tmp_path).unlink(missing_ok=True)
