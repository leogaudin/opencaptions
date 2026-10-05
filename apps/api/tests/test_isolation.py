"""Cross-user isolation: user B must never reach user A's project.

Every id-addressed route funnels through get_owned_project / get_owned_job, so a
project the caller does not own is a 404 — never 403 (which would disclose the id
exists) and never 200.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

import pytest
from httpx import AsyncClient


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("method", "suffix", "body"),
    [
        ("GET", "", None),  # read
        ("PATCH", "", {"title": "hijacked"}),  # update
        ("DELETE", "", None),  # delete
        ("POST", "/transcribe", {}),  # transcribe
        ("POST", "/download", {"format": "mp4"}),  # request render
        ("GET", "/download/mp4", None),  # stream rendered video
        ("GET", "/source", None),  # stream source video
        ("GET", "/thumbnail", None),  # poster-frame thumbnail
        ("GET", "/exports", None),  # list exports
        ("GET", "/export.srt", None),  # subtitle export
        ("GET", "/export.vtt", None),
        ("GET", "/export.json", None),
    ],
)
async def test_user_b_gets_404_on_user_a_project(
    user_a: tuple[AsyncClient, UUID],
    user_b_client: AsyncClient,
    seed_project: Any,
    method: str,
    suffix: str,
    body: Any,
) -> None:
    _client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    url = f"/api/v1/projects/{project_id}{suffix}"
    r = await user_b_client.request(method, url, json=body)
    assert r.status_code == 404, f"{method} {url} -> {r.status_code} (expected 404)"


@pytest.mark.asyncio
async def test_user_b_cannot_see_user_a_project_in_list(
    user_a: tuple[AsyncClient, UUID],
    user_b_client: AsyncClient,
    seed_project: Any,
) -> None:
    _client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    r = await user_b_client.get("/api/v1/projects")
    assert r.status_code == 200
    assert r.json()["total"] == 0
    assert str(project_id) not in [item["id"] for item in r.json()["items"]]


@pytest.mark.asyncio
async def test_user_a_can_read_and_list_own_project(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
) -> None:
    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    assert (await client_a.get(f"/api/v1/projects/{project_id}")).status_code == 200

    listed = await client_a.get("/api/v1/projects")
    assert str(project_id) in [item["id"] for item in listed.json()["items"]]


@pytest.mark.asyncio
async def test_user_b_gets_404_on_user_a_job(
    user_a: tuple[AsyncClient, UUID],
    user_b_client: AsyncClient,
    db_factory: Any,
) -> None:
    from app.models import Job, Project

    _client_a, owner_a = user_a
    async with db_factory() as s:
        proj = Project(title="a", owner_id=owner_a, status="rendering")
        s.add(proj)
        await s.flush()
        job = Job(project_id=proj.id, type="rendering", status="running")
        s.add(job)
        await s.commit()
        job_id = job.id

    assert (await user_b_client.get(f"/api/v1/jobs/{job_id}")).status_code == 404
    assert (await user_b_client.delete(f"/api/v1/jobs/{job_id}")).status_code == 404
