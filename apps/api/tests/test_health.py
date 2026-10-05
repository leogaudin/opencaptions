"""Healthcheck + OpenAPI smoke tests: assert response structure against the in-memory app."""

from importlib.metadata import version

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.mark.asyncio
async def test_health_returns_structure() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        r = await client.get("/api/v1/health")
    assert r.status_code == 200
    body = r.json()
    # Status may be 'ok' or 'degraded' depending on whether external services are up.
    assert body["status"] in {"ok", "degraded"}
    # Consistency, not a pinned literal: the API must report exactly the version
    # its own installed metadata declares, so a reintroduced/stale literal drifts.
    assert body["version"] == version("opencaptions-api")
    assert set(body["services"].keys()) == {"database", "redis", "storage"}
    assert "transcription" in body
    assert body["transcription"]["device"] in {"cpu"} or body["transcription"]["device"].startswith(
        "cuda"
    )


@pytest.mark.asyncio
async def test_openapi_lists_v1_routes() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        r = await client.get("/api/v1/openapi.json")
    assert r.status_code == 200
    spec = r.json()
    paths = set(spec["paths"].keys())
    expected = {
        "/api/v1/health",
        "/api/v1/auth/status",
        "/api/v1/auth/register",
        "/api/v1/auth/login",
        "/api/v1/auth/logout",
        "/api/v1/auth/me",
        "/api/v1/auth/me/usage",
        "/api/v1/auth/me/email",
        "/api/v1/auth/me/password",
        "/api/v1/projects",
        "/api/v1/projects/{project_id}",
        "/api/v1/projects/{project_id}/transcribe",
        "/api/v1/projects/{project_id}/download",
        "/api/v1/projects/{project_id}/download/{format_id}",
        "/api/v1/jobs/{job_id}",
        "/api/v1/settings",
    }
    missing = expected - paths
    assert not missing, f"Missing routes: {missing}"
