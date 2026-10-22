"""What a project is doing is read from its transcript and its jobs, not stored."""

from __future__ import annotations

from typing import Any
from uuid import UUID

import pytest
from httpx import AsyncClient

from app.models import Job, Project

_TRANSCRIPT = {
    "schema_version": 1,
    "language": "en",
    "language_detection": "auto",
    "duration": 1.0,
    "segments": [],
}


async def _project(
    db_factory: Any,
    owner: UUID,
    title: str,
    *,
    transcript: dict[str, Any] | None = None,
    jobs: tuple[tuple[str, str], ...] = (),
) -> None:
    async with db_factory() as s:
        proj = Project(title=title, owner_id=owner, transcript=transcript)
        s.add(proj)
        await s.flush()
        for kind, status in jobs:
            s.add(Job(project_id=proj.id, user_id=owner, type=kind, status=status))
            await s.flush()
        await s.commit()


async def _statuses(client: AsyncClient) -> dict[str, str]:
    r = await client.get("/api/v1/projects")
    assert r.status_code == 200, r.text
    return {item["title"]: item["status"] for item in r.json()["items"]}


@pytest.mark.asyncio
async def test_the_list_reads_each_projects_state_from_its_transcript_and_jobs(
    user_a: tuple[AsyncClient, UUID], db_factory: Any
) -> None:
    client, owner = user_a
    await _project(db_factory, owner, "draft")
    await _project(db_factory, owner, "transcribed", transcript=_TRANSCRIPT)
    await _project(db_factory, owner, "busy", jobs=(("transcription", "running"),))
    await _project(db_factory, owner, "queued", jobs=(("transcription", "pending"),))
    await _project(db_factory, owner, "failed", jobs=(("transcription", "failed"),))
    assert await _statuses(client) == {
        "draft": "draft",
        "transcribed": "transcribed",
        "busy": "transcribing",
        "queued": "transcribing",
        "failed": "failed",
    }


@pytest.mark.asyncio
async def test_a_retranscription_in_flight_is_transcribing_though_there_is_a_transcript(
    user_a: tuple[AsyncClient, UUID], db_factory: Any
) -> None:
    client, owner = user_a
    await _project(
        db_factory, owner, "again", transcript=_TRANSCRIPT, jobs=(("transcription", "running"),)
    )
    assert (await _statuses(client)) == {"again": "transcribing"}


@pytest.mark.asyncio
async def test_a_failed_render_does_not_make_a_project_an_error(
    user_a: tuple[AsyncClient, UUID], db_factory: Any
) -> None:
    client, owner = user_a
    await _project(
        db_factory,
        owner,
        "good",
        transcript=_TRANSCRIPT,
        jobs=(("transcription", "completed"), ("rendering", "failed")),
    )
    assert (await _statuses(client)) == {"good": "transcribed"}


@pytest.mark.asyncio
async def test_a_project_no_longer_carries_a_stored_status(
    user_a: tuple[AsyncClient, UUID], seed_project: Any
) -> None:
    client, owner = user_a
    pid = await seed_project(owner)
    body = (await client.get(f"/api/v1/projects/{pid}")).json()
    assert "status" not in body and "error" not in body
    assert body["transcript"] is not None and body["active_job"] is None
