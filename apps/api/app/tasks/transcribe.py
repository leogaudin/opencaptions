"""Celery task: transcribe a project's video end-to-end.

Pipeline:
  1. Load Job + Project from Postgres.
  2. Download the source video from object storage to a temp dir.
  3. ffmpeg extract audio (16 kHz mono WAV).
  4. Provider.transcribe(...) with progress callback publishing to Redis pub/sub.
  5. Persist Transcript JSON onto Project.transcript; mark project status='transcribed'.
  6. Mark Job status='completed' and publish job_succeeded.
"""

from __future__ import annotations

import logging
import tempfile
from pathlib import Path
from uuid import UUID

import celery

from app.core.celery_app import celery_app
from app.models import Project
from app.services import progress
from app.services.audio import AudioExtractionError, extract_audio, probe_duration
from app.tasks.common import TaskContext
from app.tasks.common import sync_session_factory as _sync_session_factory

# Names this pipeline in every event it publishes.
STAGE = "transcription"

logger = logging.getLogger(__name__)


@celery_app.task(name="app.tasks.transcribe.transcribe_video", bind=True)
def transcribe_video(
    self: celery.Task,
    job_id: str,
    project_id: str,
    *,
    provider: str = "local",
    model: str | None = None,
    language: str = "auto",
) -> dict[str, str]:
    """Run transcription against the project's uploaded video."""
    logger.info(
        "transcribe_video starting job=%s project=%s provider=%s model=%s lang=%s",
        job_id,
        project_id,
        provider,
        model,
        language,
    )

    # Defer heavy imports so module load doesn't pull torch/faster-whisper for
    # workers on the rendering queue (which won't import this file at all).
    from app.storage import s3
    from app.transcription import local as _local_provider  # noqa: F401 — registers
    from app.transcription.base import get_provider

    session_local = _sync_session_factory()
    task = TaskContext(job_id, project_id, session_local, logger)

    try:
        with session_local() as session:
            project = session.get(Project, UUID(project_id))
            if project is None:
                raise RuntimeError(f"Project {project_id} not found")
            if not project.video_storage_key:
                raise RuntimeError("Project has no video_storage_key")
            video_key = project.video_storage_key
            project.status = "transcribing"
            session.commit()

        task.set_job_status("running", celery_task_id=self.request.id, progress=0.0)
        task.enter_stage(progress.TRANSCRIBE_STARTING, STAGE)
        task.publish(
            "job_started",
            {"job_id": job_id, "project_id": project_id, "stage": STAGE},
        )

        with tempfile.TemporaryDirectory(prefix="opencaptions-") as tmpdir:
            tmp = Path(tmpdir)
            local_video = tmp / "source.bin"
            local_audio = tmp / "audio.wav"

            # 2. Download
            task.enter_stage(progress.TRANSCRIBE_DOWNLOADING, STAGE)
            s3.download_file(video_key, str(local_video))

            # 3. Extract audio
            task.enter_stage(progress.TRANSCRIBE_EXTRACTING, STAGE)
            try:
                extract_audio(local_video, local_audio)
            except AudioExtractionError as e:
                raise RuntimeError(f"Audio extraction failed: {e}") from e

            duration = probe_duration(local_audio)
            logger.info("Audio extracted, duration=%.2fs", duration)

            # 4. Run provider
            transcription_provider = get_provider(provider)

            # Loading blocks until the weights are on disk, which on first use means
            # fetching gigabytes. Say which is happening before it starts, or the bar
            # sits at the same number for minutes with no explanation.
            task.enter_stage(
                progress.TRANSCRIBE_LOADING_MODEL
                if transcription_provider.is_model_cached(model)
                else progress.TRANSCRIBE_FETCHING_MODEL,
                STAGE,
            )

            def _on_progress(fraction: float, message: str) -> None:
                task.report_progress(fraction, message, STAGE)

            transcript = transcription_provider.transcribe(
                str(local_audio),
                language=language,
                model=model,
                on_progress=_on_progress,
            )

        # 5. Persist transcript
        with session_local() as session:
            project = session.get(Project, UUID(project_id))
            if project is None:
                raise RuntimeError("Project disappeared during transcription")
            project.transcript = transcript.model_dump()
            project.status = "transcribed"
            project.error = None
            session.commit()

        # 6. Finalize
        task.set_job_status(
            "completed",
            progress=progress.DONE,
            message=f"Transcribed {len(transcript.segments)} segments",
        )
        from app.services.usage import UNIT_TRANSCRIPTION_SECONDS

        task.record_usage(UNIT_TRANSCRIPTION_SECONDS, float(duration))
        task.publish(
            "transcript_updated",
            {"project_id": project_id, "segments": len(transcript.segments)},
        )
        task.publish(
            "job_succeeded",
            {"job_id": job_id, "project_id": project_id, "stage": STAGE},
        )
        return {"status": "completed", "segments": str(len(transcript.segments))}

    except Exception as e:  # noqa: BLE001
        logger.exception("transcribe_video failed")
        reason = str(e)[:500]
        task.mark_failed(reason, "Transcription failed", STAGE)
        return {"status": "failed", "reason": reason}
