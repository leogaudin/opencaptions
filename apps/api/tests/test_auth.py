"""Authentication, session, CSRF, and internal-callback behavior."""

from __future__ import annotations

from typing import Any
from uuid import UUID

import pytest
from httpx import AsyncClient

from app.core import redis as redis_module
from app.core.config import settings
from app.core.job_tokens import job_token_key
from app.models import Job, Project


@pytest.mark.asyncio
async def test_status_is_public_and_reports_setup(client: AsyncClient) -> None:
    r = await client.get("/api/v1/auth/status")
    assert r.status_code == 200
    body = r.json()
    assert body["setup_required"] is True
    # Open signup is the default: a fresh install accepts self-service accounts.
    assert body["registration_enabled"] is True


@pytest.mark.asyncio
async def test_first_account_bootstraps_a_closed_instance(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """With registration off, only the first account gets in — which is what lets
    an operator create their own account on an instance they deploy closed."""
    monkeypatch.setattr(settings, "registration_enabled", False)

    r = await client.post(
        "/api/v1/auth/register",
        json={"email": "first@example.com", "password": "password123"},
    )
    assert r.status_code == 201
    assert "password_hash" not in r.json()["user"]
    assert "role" not in r.json()["user"]
    status = await client.get("/api/v1/auth/status")
    assert status.json()["setup_required"] is False

    second = await client.post(
        "/api/v1/auth/register",
        json={"email": "second@example.com", "password": "password123"},
    )
    assert second.status_code == 403
    assert second.json()["error"] == "registration_disabled"


@pytest.mark.asyncio
async def test_second_registration_open_by_default(
    first_client: AsyncClient, make_client: Any
) -> None:
    # The core of open signup: once the first account exists, a second visitor
    # self-registers with NO privileged action — no setting toggled, no special
    # endpoint used — and is an ordinary account like any other.
    c = await make_client()
    r = await c.post(
        "/api/v1/auth/register",
        json={"email": "second@example.com", "password": "password123"},
    )
    assert r.status_code == 201, r.text
    # The instance keeps reporting open signup, and setup is done.
    status = (await c.get("/api/v1/auth/status")).json()
    assert status["registration_enabled"] is True
    assert status["setup_required"] is False


@pytest.mark.asyncio
async def test_second_registration_blocked_when_disabled(
    first_client: AsyncClient, make_client: Any, monkeypatch: Any
) -> None:
    # Open signup stays CLOSABLE: an operator who turns registration off (env
    # REGISTRATION_ENABLED=false) refuses every self-service signup after the
    # first account with a 403.
    monkeypatch.setattr(settings, "registration_enabled", False)
    c = await make_client()
    r = await c.post(
        "/api/v1/auth/register",
        json={"email": "second@example.com", "password": "password123"},
    )
    assert r.status_code == 403
    assert r.json()["error"] == "registration_disabled"


@pytest.mark.asyncio
async def test_login_wrong_password_is_generic_401(
    first_client: AsyncClient, make_client: Any
) -> None:
    c = await make_client()
    r = await c.post(
        "/api/v1/auth/login",
        json={"email": "admin@example.com", "password": "WRONGpassword"},
    )
    assert r.status_code == 401
    assert r.json()["error"] == "invalid_credentials"


@pytest.mark.asyncio
async def test_login_unknown_email_is_generic_401(
    first_client: AsyncClient, make_client: Any
) -> None:
    c = await make_client()
    r = await c.post(
        "/api/v1/auth/login",
        json={"email": "nobody@example.com", "password": "whatever12345"},
    )
    # Same shape/status as a wrong password — existence must not be disclosed.
    assert r.status_code == 401
    assert r.json()["error"] == "invalid_credentials"


@pytest.mark.asyncio
async def test_me_requires_authentication(client: AsyncClient) -> None:
    r = await client.get("/api/v1/auth/me")
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_unauthenticated_projects_returns_401(client: AsyncClient) -> None:
    r = await client.get("/api/v1/projects")
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_logout_invalidates_session_server_side(
    first_client: AsyncClient, make_client: Any
) -> None:
    # Capture the opaque session id before logging out.
    session_id = first_client.cookies.get("oc_session")
    assert session_id
    assert (await first_client.get("/api/v1/auth/me")).status_code == 200

    r = await first_client.post("/api/v1/auth/logout")
    assert r.status_code == 204

    # Replay the OLD cookie value on a fresh client: it must be dead server-side,
    # proving logout deleted the Redis session (not merely cleared the cookie).
    replay = await make_client()
    replay.cookies.set("oc_session", session_id)
    assert (await replay.get("/api/v1/auth/me")).status_code == 401


@pytest.mark.asyncio
async def test_unsafe_request_without_csrf_header_is_rejected(
    first_client: AsyncClient, make_client: Any
) -> None:
    # A client with the session cookie but WITHOUT the X-CSRF-Token header —
    # exactly the shape of a cross-site forged request.
    bare = await make_client()
    bare.cookies.update(first_client.cookies)
    r = await bare.post("/api/v1/auth/logout")
    assert r.status_code == 403
    assert r.json()["error"] == "csrf_failed"


@pytest.mark.asyncio
async def test_get_settings_requires_auth(client: AsyncClient) -> None:
    assert (await client.get("/api/v1/settings")).status_code == 401


@pytest.mark.asyncio
async def test_progress_callback_rejected_without_job_token(
    user_a: tuple[AsyncClient, UUID], db_factory: Any, client: AsyncClient
) -> None:
    _client_a, owner_id = user_a
    async with db_factory() as s:
        proj = Project(title="p", owner_id=owner_id, status="rendering")
        s.add(proj)
        await s.flush()
        job = Job(project_id=proj.id, type="rendering", status="running")
        s.add(job)
        await s.commit()
        job_id = job.id

    # No token → 401 (the callback is not world-open even though it needs no
    # user session). CSRF-exempt path, so a bare client is the right probe.
    r = await client.post(f"/api/v1/jobs/{job_id}/progress", json={"progress": 0.5})
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_progress_callback_accepts_valid_job_token(
    user_a: tuple[AsyncClient, UUID],
    db_factory: Any,
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Token validation uses the shared async fake Redis from conftest. Publishing
    # is a separate synchronous Redis boundary used by workers; isolate it here
    # and assert what would be broadcast instead of resolving the Docker-only
    # hostname `redis` from a unit-test runner.
    from app.api import jobs as jobs_api

    published: list[tuple[UUID, dict[str, Any]]] = []
    monkeypatch.setattr(
        jobs_api,
        "publish_to_project",
        lambda project_id, message: published.append((project_id, message)),
    )

    _client_a, owner_id = user_a
    async with db_factory() as s:
        proj = Project(title="p", owner_id=owner_id, status="rendering")
        s.add(proj)
        await s.flush()
        job = Job(project_id=proj.id, type="rendering", status="running")
        s.add(job)
        await s.commit()
        job_id = job.id
        project_id = proj.id

    # Seed the per-job token the way the render task would, then present it.
    await redis_module.get_redis().set(job_token_key(str(job_id)), "secret-token")
    r = await client.post(
        f"/api/v1/jobs/{job_id}/progress",
        json={"progress": 0.5},
        headers={"X-Job-Token": "secret-token"},
    )
    assert r.status_code == 204
    assert published == [
        (
            project_id,
            {
                "type": "job_progress",
                "payload": {
                    "job_id": str(job_id),
                    "progress": 0.5,
                    "message": "Rendering",
                    "stage": "rendering",
                },
            },
        )
    ]


@pytest.mark.asyncio
async def test_progress_callback_rejects_wrong_job_token(
    user_a: tuple[AsyncClient, UUID], db_factory: Any, client: AsyncClient
) -> None:
    _client_a, owner_id = user_a
    async with db_factory() as s:
        proj = Project(title="p", owner_id=owner_id, status="rendering")
        s.add(proj)
        await s.flush()
        job = Job(project_id=proj.id, type="rendering", status="running")
        s.add(job)
        await s.commit()
        job_id = job.id

    await redis_module.get_redis().set(job_token_key(str(job_id)), "the-real-token")
    r = await client.post(
        f"/api/v1/jobs/{job_id}/progress",
        json={"progress": 0.5},
        headers={"X-Job-Token": "not-the-token"},
    )
    assert r.status_code == 401
