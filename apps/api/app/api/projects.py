"""/api/v1/projects router: create, list, read, update, delete, and start a transcription.

The finished video, the source, the poster and the exports are in project_files.py;
taking a video in is in ingest.py.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, File, Form, Query, UploadFile, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import load_only

from app.api.deps import (
    db_session,
    get_current_user,
    get_owned_project,
    get_owned_project_light,
    http_error,
)
from app.api.ingest import ingest_remote_url, ingest_uploaded_file, reject_ambiguous_source
from app.core.config import settings
from app.models import Job, Project, User
from app.models.schemas import (
    _400_INVALID_VIDEO_URL,
    _400_MISSING_VIDEO_SOURCE,
    _400_NO_VIDEO,
    _400_UNSUPPORTED_LANGUAGE,
    _400_VIDEO_FETCH_FAILED,
    _400_VIDEO_TOO_LONG,
    _403_TRANSCRIPTION_CHOICE,
    _404_PROJECT,
    _413_UPLOAD_TOO_LARGE,
    _415_UNSUPPORTED_MEDIA,
    JobStatus,
    ProjectList,
    ProjectListItem,
    ProjectStatus,
    ProjectUpdate,
    TranscribeRequest,
)
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

    Scoped to the caller's own projects, never lists other users' projects.
    """
    offset = (page - 1) * per_page
    rows = (
        (
            await session.execute(
                select(Project)
                # The list shows none of the transcript or style; leave them in the table.
                .options(
                    load_only(
                        Project.id,
                        Project.title,
                        Project.status,
                        Project.video_size_bytes,
                        Project.created_at,
                        Project.updated_at,
                    )
                )
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
    reject_ambiguous_source(has_video, has_url)

    # Taking a video in lasts as long as the transfer. End the transaction that signing
    # in opened, so its pooled connection is free meanwhile (thirty slow uploads would
    # otherwise hold all of them), and write the row once the video is in.
    await session.commit()
    project = Project(id=uuid4(), title=title, owner_id=user.id)

    if has_video:
        assert video is not None  # type narrowing for mypy
        await ingest_uploaded_file(project, video)
    else:
        assert video_url is not None  # type narrowing for mypy
        await ingest_remote_url(project, video_url)

    session.add(project)
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
    """Partial update: set title, transcript, style_config, or caption offset independently."""
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
    proj: Annotated[Project, Depends(get_owned_project_light)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> None:
    """Delete the project, cancel its jobs, remove its objects."""
    # Cancel any in-progress Celery tasks for this project
    from app.core.celery_app import celery_app

    jobs_q = await session.execute(select(Job).where(Job.project_id == proj.id))
    for job in jobs_q.scalars().all():
        if job.celery_task_id and job.status in {"pending", "running"}:
            celery_app.control.revoke(job.celery_task_id, terminate=True)

    # The row first. Files left behind by a failed cleanup are an operator's chore (and
    # logged); a project whose video is gone but which still lists is the user's.
    project_id = proj.id
    await session.delete(proj)
    await session.commit()
    try:
        await asyncio.to_thread(s3.delete_prefix, f"projects/{project_id}/")
    except s3.StorageError:
        logger.exception("project %s deleted, but its files could not all be removed", project_id)


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
    proj: Annotated[Project, Depends(get_owned_project_light)],
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
