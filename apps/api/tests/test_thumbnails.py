"""Tests for the project thumbnail serve endpoint.

Thumbnail presence is answered by reading it (no DB column), so
these tests stub app.storage.s3 rather than touching real object storage. The
cross-user 404 case lives in test_isolation.py (the shared authorization
matrix); here we cover presence/absence and auth for the owner.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

import pytest
from httpx import AsyncClient


@pytest.mark.asyncio
async def test_thumbnail_404_when_absent(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Owner gets 404 (error: no_thumbnail) when no thumbnail object exists."""
    from app.storage import s3

    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    def _missing(key: str) -> bytes:
        raise s3.ObjectNotFoundError(key)

    monkeypatch.setattr(s3, "get_object_bytes", _missing)

    r = await client_a.get(f"/api/v1/projects/{project_id}/thumbnail")
    assert r.status_code == 404
    assert r.json()["error"] == "no_thumbnail"


@pytest.mark.asyncio
async def test_thumbnail_returns_image_when_present(
    user_a: tuple[AsyncClient, UUID],
    seed_project: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Owner gets the JPEG bytes with an image/jpeg content type when present."""
    from app.storage import s3

    client_a, owner_a = user_a
    project_id = await seed_project(owner_a)

    fake_jpeg = b"\xff\xd8\xff\xe0jpeg-bytes"
    captured: dict[str, str] = {}

    def _get_bytes(key: str) -> bytes:
        captured["get_key"] = key
        return fake_jpeg

    monkeypatch.setattr(s3, "get_object_bytes", _get_bytes)

    r = await client_a.get(f"/api/v1/projects/{project_id}/thumbnail")
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/jpeg"
    assert r.content == fake_jpeg
    # The route addresses the thumbnail by the project's own key convention.
    assert captured["get_key"] == f"projects/{project_id}/thumbnail.jpg"


@pytest.mark.asyncio
async def test_thumbnail_requires_authentication(
    client: AsyncClient,
    seed_project: Any,
) -> None:
    """An unauthenticated caller is rejected before any storage lookup."""
    from uuid import uuid4

    r = await client.get(f"/api/v1/projects/{uuid4()}/thumbnail")
    assert r.status_code == 401
