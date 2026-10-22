"""The engine reads the fallback fonts of a render with the job's token."""

from __future__ import annotations

from typing import Any
from uuid import UUID

import pytest
from httpx import AsyncClient

from app.core import redis as redis_module
from app.core.job_tokens import job_token_key
from app.models import Job, Project
from app.services import fonts


async def _job(user_a: tuple[AsyncClient, UUID], db_factory: Any) -> UUID:
    _client, owner = user_a
    async with db_factory() as s:
        proj = Project(title="p", owner_id=owner, status="draft")
        s.add(proj)
        await s.flush()
        job = Job(project_id=proj.id, type="rendering", status="running")
        s.add(job)
        await s.commit()
        job_id: UUID = job.id
    await redis_module.get_redis().set(job_token_key(str(job_id)), "tok")
    return job_id


@pytest.mark.asyncio
async def test_the_engine_reads_a_font_with_its_job_token(
    user_a: tuple[AsyncClient, UUID],
    db_factory: Any,
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    asked: list[str] = []
    monkeypatch.setattr(fonts, "file_key", lambda family: asked.append(family) or f"k/{family}")
    monkeypatch.setattr("app.api.jobs.s3.get_object_bytes", lambda key: f"bytes of {key}".encode())
    job_id = await _job(user_a, db_factory)
    r = await client.get(
        f"/api/v1/jobs/{job_id}/fonts/Noto%20Sans%20JP", headers={"X-Job-Token": "tok"}
    )
    assert r.status_code == 200, r.text
    assert r.content == b"bytes of k/Noto Sans JP"
    assert r.headers["content-type"] == fonts.FONT_TYPE
    assert asked == ["Noto Sans JP"]


@pytest.mark.asyncio
@pytest.mark.parametrize("token", [None, "not-the-token"])
async def test_a_font_is_refused_without_the_jobs_token(
    user_a: tuple[AsyncClient, UUID], db_factory: Any, client: AsyncClient, token: str | None
) -> None:
    job_id = await _job(user_a, db_factory)
    headers = {"X-Job-Token": token} if token else {}
    r = await client.get(f"/api/v1/jobs/{job_id}/fonts/Inter", headers=headers)
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_an_unavailable_font_is_a_404(
    user_a: tuple[AsyncClient, UUID],
    db_factory: Any,
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def unavailable(_family: str) -> str:
        raise fonts.FontUnavailableError("no such family")

    monkeypatch.setattr(fonts, "file_key", unavailable)
    job_id = await _job(user_a, db_factory)
    r = await client.get(f"/api/v1/jobs/{job_id}/fonts/Nope", headers={"X-Job-Token": "tok"})
    assert r.status_code == 404 and r.json()["error"] == "font_unavailable"
