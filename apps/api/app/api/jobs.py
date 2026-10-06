"""/api/v1/jobs router — get + cancel + internal progress callback."""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Path
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import db_session, get_owned_job, require_job_token
from app.api.websocket import publish_to_project
from app.core.celery_app import celery_app
from app.models import Job
from app.models.schemas import _404_JOB, JobStatus
from app.services.progress import RENDERING

router = APIRouter(prefix="/jobs", tags=["jobs"])


class ProgressUpdate(BaseModel):
    """Internal: posted by the engine during long renders."""

    progress: float = Field(ge=0.0, le=1.0)
    message: str | None = None


@router.get("/{job_id}", response_model=JobStatus, responses={**_404_JOB}, summary="Get job status")
async def get_job(
    job: Annotated[Job, Depends(get_owned_job)],
) -> JobStatus:
    """Retrieve the current status and progress of a transcription or render job.

    Owner-scoped via get_owned_job: a job the caller does not own (or does not
    exist) is a 404, so job ids are not enumerable across users.
    """
    return JobStatus.model_validate(job)


@router.delete("/{job_id}", status_code=204, responses={**_404_JOB}, summary="Cancel job")
async def cancel_job(
    job: Annotated[Job, Depends(get_owned_job)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> None:
    """Cancel a running or queued job. Idempotent: 204 if already terminal."""
    if job.status in {"completed", "failed", "cancelled"}:
        return  # already terminal

    if job.celery_task_id:
        celery_app.control.revoke(job.celery_task_id, terminate=True)

    job.status = "cancelled"
    await session.flush()


@router.post(
    "/{job_id}/progress",
    status_code=204,
    dependencies=[Depends(require_job_token)],
    summary="Report job progress (internal)",
)
async def report_progress(
    job_id: Annotated[UUID, Path()],
    body: ProgressUpdate,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> None:
    """Internal endpoint: the engine posts intermediate progress.

    Authorized by a per-job token (require_job_token / X-Job-Token header), NOT a
    user session — the engine is a service, and a static shared secret would
    ship the same weak credential to every install. Updates the job row in
    Postgres and broadcasts on the project's pub/sub channel so the WebSocket
    subscribers see the progress bar advance.
    """
    job = await session.get(Job, job_id)
    if job is None:
        # Idempotent — the engine might race with a cancellation/cleanup.
        return
    if job.status in {"completed", "failed", "cancelled"}:
        return

    # The engine already reports 0..1 for the whole render; store it as-is.
    job.progress = body.progress
    if body.message is not None:
        job.message = body.message[:255]
    await session.flush()

    if job.project_id is None:
        return  # a job with no project has no channel to broadcast on
    publish_to_project(
        job.project_id,
        {
            "type": "job_progress",
            "payload": {
                "job_id": str(job_id),
                "progress": job.progress,
                "message": body.message or RENDERING.message,
                "stage": "rendering",
            },
        },
    )
