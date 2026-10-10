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

import contextlib
import logging
import tempfile
import time
from pathlib import Path
from uuid import UUID

import celery

from app.core.celery_app import celery_app
from app.models import Project
from app.models.schemas import Transcript
from app.services import progress
from app.services.audio import AudioExtractionError, extract_audio, probe_duration
from app.tasks.common import TaskContext
from app.tasks.common import sync_session_factory as _sync_session_factory
from app.transcription.words import clean_transcript

# Names this pipeline in every event it publishes.
STAGE = "transcription"

# How often the progress of a running transcription is written down, not just broadcast. A
# page opened or refreshed mid-job reads it from the database, so it cannot be left at the
# stage's first message for the whole job.
PROGRESS_SAVE_EVERY_S = 2.0

logger = logging.getLogger(__name__)


def _transcribe_audio(
    task: TaskContext,
    audio_path: Path,
    *,
    provider: str,
    model: str | None,
    language: str,
) -> Transcript:
    """Turn an extracted audio file into a Transcript with the chosen provider.

    The one place that happens, for a project's video and for audio sent through the
    transcription API alike.
    """
    # Providers register themselves on import.
    import app.transcription  # noqa: F401
    from app.transcription.base import get_provider

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

    transcription_provider.prepare(model)
    # The weights are in; what follows is the work itself. Leaving the stage at "Loading
    # model" until the first segment came back made a long first stretch (the voice
    # detection pass and the first window) read as a model that would not load.
    task.enter_stage(progress.TRANSCRIBING, STAGE)

    saved_at = time.monotonic()

    def _on_progress(fraction: float, message: str) -> None:
        nonlocal saved_at
        task.report_progress(fraction, message, STAGE)
        if time.monotonic() - saved_at >= PROGRESS_SAVE_EVERY_S:
            saved_at = time.monotonic()
            task.set_job_status("running", progress=fraction, message=message)

    transcript = transcription_provider.transcribe(
        str(audio_path), language=language, model=model, on_progress=_on_progress
    )
    return clean_transcript(transcript)


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
            transcript = _transcribe_audio(
                task, local_audio, provider=provider, model=model, language=language
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


@celery_app.task(name="app.tasks.transcribe.transcribe_upload", bind=True)
def transcribe_upload(
    self: celery.Task,
    job_id: str,
    audio_key: str,
    result_key: str,
    *,
    provider: str = "local",
    model: str | None = None,
    language: str = "auto",
) -> dict[str, str]:
    """Transcribe audio sent through the transcription API: no project, just a result.

    The audio is fetched from storage, normalised, transcribed, and the Transcript JSON
    written to ``result_key`` for the client to fetch. The audio is deleted either way.
    """
    logger.info("transcribe_upload starting job=%s provider=%s model=%s", job_id, provider, model)
    from app.storage import s3

    task = TaskContext(job_id, None, _sync_session_factory(), logger)
    try:
        task.set_job_status("running", celery_task_id=self.request.id, progress=0.0)
        with tempfile.TemporaryDirectory(prefix="opencaptions-") as tmpdir:
            tmp = Path(tmpdir)
            local_media, local_audio = tmp / "upload.bin", tmp / "audio.wav"
            task.enter_stage(progress.TRANSCRIBE_DOWNLOADING, STAGE)
            s3.download_file(audio_key, str(local_media))
            task.enter_stage(progress.TRANSCRIBE_EXTRACTING, STAGE)
            try:
                extract_audio(local_media, local_audio)
            except AudioExtractionError as e:
                raise RuntimeError(f"Audio extraction failed: {e}") from e
            duration = probe_duration(local_audio)
            transcript = _transcribe_audio(
                task, local_audio, provider=provider, model=model, language=language
            )
        s3.put_object_bytes(result_key, transcript.model_dump_json().encode(), "application/json")
        task.set_job_status(
            "completed",
            progress=progress.DONE,
            message=f"Transcribed {len(transcript.segments)} segments",
        )
        from app.services.usage import UNIT_TRANSCRIPTION_SECONDS

        task.record_usage(UNIT_TRANSCRIPTION_SECONDS, float(duration))
        return {"status": "completed", "segments": str(len(transcript.segments))}
    except Exception as e:  # noqa: BLE001
        logger.exception("transcribe_upload failed")
        reason = str(e)[:500]
        task.mark_failed(reason, "Transcription failed", STAGE)
        return {"status": "failed", "reason": reason}
    finally:
        # The audio is only ever there to be transcribed.
        with contextlib.suppress(Exception):
            s3.delete_object(audio_key)
