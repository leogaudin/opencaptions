"""Celery task: render a transcript and style into a captioned video.

Hands the engine a presigned GET for the source video, uploads the result under
its content-addressed key, and reports progress over Redis pub/sub.
"""

from __future__ import annotations

import logging
from typing import Any
from uuid import UUID

import celery

from app.core.celery_app import celery_app
from app.core.job_tokens import delete_job_token, mint_job_token
from app.core.task_limits import RENDER_HARD_LIMIT_S, RENDER_SOFT_LIMIT_S
from app.models import Project
from app.services import fonts, progress
from app.services.render_backend import get_backend
from app.tasks.common import TaskContext
from app.tasks.common import sync_session_factory as _sync_session_factory

# Names this pipeline in every event it publishes.
STAGE = "rendering"

logger = logging.getLogger(__name__)


def _font_url(family: str) -> str | None:
    """A read of the style's font for the engine, which prefers a bundled copy.

    None when the family is unknown or Google is unreachable: the engine then
    draws its default face, exactly as the preview does in the same situation.
    """
    from app.storage import s3

    try:
        return s3.presigned_url(fonts.file_key(family), expires_in=3600)
    except fonts.FontUnavailableError as e:
        logger.warning("font unavailable, drawing the default face: %s", e)
        return None


def _fallback_fonts(transcript: dict[str, Any]) -> dict[str, str]:
    """Family -> read URL for the fonts the transcript's scripts need; one that is unavailable is left out."""
    from app.services.script_fonts import fallback_families, transcript_words

    families = fallback_families(transcript_words(transcript), str(transcript.get("language", "")))
    urls = {family: _font_url(family) for family in families}
    return {family: url for family, url in urls.items() if url}


@celery_app.task(
    name="app.tasks.render.render_video",
    bind=True,
    soft_time_limit=RENDER_SOFT_LIMIT_S,
    time_limit=RENDER_HARD_LIMIT_S,
)
# The suppression is load-bearing: this is a linear render pipeline whose steps
# share too much local state to split without passing a bag of variables around.
# It sits on the `def` line because that is where ruff anchors C901.
def render_video(  # noqa: C901
    self: celery.Task,
    job_id: str,
    project_id: str,
    format_id: str = "mp4",
    options: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Render a project into ``format_id`` (mp4, mp4-hevc, webm, mov) with ``options``."""
    logger.info("render_video starting job=%s project=%s format=%s", job_id, project_id, format_id)

    from app.models.schemas import RenderOptions
    from app.services.render_formats import get_format, render_object_key, resolve_render_inputs
    from app.storage import s3

    session_local = _sync_session_factory()
    task = TaskContext(job_id, project_id, session_local, logger)

    try:
        # Resolve the format from the registry
        fmt = get_format(format_id)
        if fmt is None:
            raise RuntimeError(f"Unknown format id: {format_id}")
        render_options = RenderOptions.model_validate(options or {})

        logger.info(
            "render format resolved: codec=%s crf=%s proResProfile=%s ext=%s",
            fmt.codec,
            fmt.crf,
            fmt.pro_res_profile,
            fmt.extension,
        )

        with session_local() as session:
            project = session.get(Project, UUID(project_id))
            if project is None:
                raise RuntimeError(f"Project {project_id} not found")
            if not project.video_storage_key:
                raise RuntimeError("Project has no video")
            if project.transcript is None:
                raise RuntimeError("Project has no transcript")
            video_key = project.video_storage_key
            # Resolved once, in the same place the API resolves it: geometry,
            # style fallback, transcript and offset all feed the
            # content-addressed hash, so any disagreement between the two would
            # present as a permanent cache miss.
            inputs = resolve_render_inputs(project, render_options)
            project.status = "rendering"
            session.commit()

        render_hash = inputs.hash_for(fmt.id)
        output_key = render_object_key(project_id, render_hash, fmt.extension)
        logger.info("content-addressed output_key=%s (hash=%s)", output_key, render_hash)

        task.set_job_status("running", celery_task_id=self.request.id, progress=0.0)
        task.enter_stage(progress.RENDER_PREPARING, STAGE, format=format_id)
        task.publish(
            "job_started",
            {
                "job_id": job_id,
                "project_id": project_id,
                "stage": STAGE,
                "format": format_id,
            },
        )

        # Step 2: presigned URL for the source video, valid for 1h.
        video_url = s3.presigned_url(video_key, expires_in=3600)
        font_url = _font_url(str(inputs.style_config.get("font", "")))
        fallbacks = _fallback_fonts(inputs.transcript)

        body: dict[str, Any] = {
            "video_url": video_url,
            "font_url": font_url,
            # The families the transcript's scripts need that the engine does not bundle (Chinese,
            # Japanese, Korean...), and where to read each: drawn with when the style's font lacks a letter.
            "fallback_fonts": list(fallbacks),
            "fallback_font_urls": fallbacks,
            "transcript": inputs.transcript,
            "style": inputs.style_config,
            "caption_offset_ms": inputs.caption_offset_ms,
            "output_key": output_key,
            "fps": inputs.fps,
            "width": inputs.width,
            "height": inputs.height,
            "codec": fmt.codec,
            # ProRes takes a profile instead of a CRF; the engine reads whichever is set.
            "crf": fmt.crf,
            "pro_res_profile": fmt.pro_res_profile,
            "green_screen": inputs.green_screen,
            # Lets the engine push live progress back while it renders.
            "progress_url": f"http://api:8000/api/v1/jobs/{job_id}/progress",
            # Per-job token authorizing that callback: the engine is a service
            # (no user session), and this avoids a shared static secret. Scoped
            # to this one job and short-lived, see app.core.job_tokens.
            "progress_token": mint_job_token(job_id),
        }

        task.enter_stage(progress.RENDERING, STAGE, format=format_id)

        # Step 3: hand it to the configured backend.
        result = get_backend().render(body)
        rendered_key = result.output_key
        frames = result.frames_rendered
        duration_ms = result.duration_ms
        logger.info(
            "render finished job=%s format=%s frames=%s duration_ms=%s key=%s",
            job_id,
            format_id,
            frames,
            duration_ms,
            rendered_key,
        )

        # Step 5: PRUNE stale renders, delete any object under
        # projects/{id}/renders/ that has the SAME format extension but a
        # different hash. This prevents unbounded storage growth as users
        # iterate on their transcript/style.
        renders_prefix = f"projects/{project_id}/renders/"
        existing_keys = s3.list_prefix(renders_prefix)
        for key in existing_keys:
            if key.endswith(fmt.extension) and key != rendered_key:
                logger.info("pruning stale render: %s", key)
                s3.delete_object(key)

        # Mark project status as done (no rendered_storage_key column, the
        # content-addressed object in storage IS the source of truth).
        with session_local() as session:
            project = session.get(Project, UUID(project_id))
            if project is None:
                raise RuntimeError("Project disappeared during render")
            project.status = "done"
            project.error = None
            session.commit()

        task.set_job_status(
            "completed",
            progress=progress.DONE,
            message=f"Rendered {frames} frames in {duration_ms} ms",
        )
        from app.services.usage import UNIT_RENDER_FRAMES

        task.record_usage(UNIT_RENDER_FRAMES, float(frames))
        task.publish(
            "job_succeeded",
            {
                "job_id": job_id,
                "project_id": project_id,
                "stage": STAGE,
                "format": format_id,
                "output_key": rendered_key,
            },
        )
        return {
            "status": "completed",
            "output_key": rendered_key,
            "format": format_id,
            "frames_rendered": frames,
            "duration_ms": duration_ms,
        }

    except Exception as e:  # noqa: BLE001
        logger.exception("render_video failed")
        reason = str(e)[:500]
        task.mark_failed(reason, "Render failed", STAGE)
        return {"status": "failed", "reason": reason}
    finally:
        # Terminal state reached (success or failure): drop the per-job callback
        # token now rather than leaving it valid until its TTL. Defense in depth
        # -- the progress endpoint already no-ops once the job is terminal.
        delete_job_token(job_id)
