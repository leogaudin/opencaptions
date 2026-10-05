"""Shared test fixtures for the API suite.

There is deliberately one code path in the app, so the tests exercise the REAL
auth/session/ownership logic — they only swap the backing stores:

  * the DB is an in-memory SQLite bound to the ``db_session`` dependency, and
  * Redis is an in-memory fake wired into ``app.core.redis`` (sessions + job
    tokens go through it unchanged).

Two authenticated clients for DIFFERENT users are provided so cross-user
isolation can be asserted directly.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any
from uuid import UUID, uuid4

import fakeredis.aioredis
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import StaticPool

from app.api.deps import db_session
from app.core import redis as redis_module
from app.core.config import settings
from app.main import app
from app.models import Base, Project

_MINIMAL_TRANSCRIPT: dict[str, Any] = {
    "schema_version": 1,
    "language": "en",
    "language_detection": "auto",
    "duration": 1.0,
    "segments": [
        {
            "id": "s1",
            "words": [{"text": "hi", "start": 0.0, "end": 0.5, "confidence": 1.0}],
            "start": 0.0,
            "end": 0.5,
            "text": "hi",
        }
    ],
}


@pytest_asyncio.fixture
async def db_factory() -> Any:
    """In-memory SQLite bound to the db_session dependency for one test."""
    engine = create_async_engine(
        "sqlite+aiosqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)

    async def _override() -> Any:
        async with factory() as s:
            try:
                yield s
                await s.commit()
            except Exception:
                await s.rollback()
                raise

    app.dependency_overrides[db_session] = _override
    try:
        yield factory
    finally:
        app.dependency_overrides.pop(db_session, None)
        await engine.dispose()


@pytest_asyncio.fixture
async def fake_redis() -> Any:
    """Swap the shared async Redis client for an in-memory fake."""
    fake = fakeredis.aioredis.FakeRedis(decode_responses=True)
    redis_module._client = fake
    try:
        yield fake
    finally:
        redis_module._client = None


@pytest_asyncio.fixture
async def make_client(db_factory: Any, fake_redis: Any) -> Any:
    """Factory yielding fresh AsyncClients (each with its own cookie jar)."""
    clients: list[AsyncClient] = []

    async def _make() -> AsyncClient:
        c = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
        clients.append(c)
        return c

    try:
        yield _make
    finally:
        for c in clients:
            await c.aclose()


async def _register(c: AsyncClient, email: str, password: str) -> Any:
    r = await c.post("/api/v1/auth/register", json={"email": email, "password": password})
    if r.status_code == 201:
        # Hold the per-session CSRF token like the SPA would.
        c.headers["X-CSRF-Token"] = r.json()["csrf_token"]
    return r


async def _me_id(c: AsyncClient) -> UUID:
    r = await c.get("/api/v1/auth/me")
    return UUID(r.json()["user"]["id"])


@pytest_asyncio.fixture
async def client(make_client: Callable[[], Awaitable[AsyncClient]]) -> AsyncClient:
    """An unauthenticated client."""
    return await make_client()


@pytest_asyncio.fixture
async def first_client(make_client: Callable[[], Awaitable[AsyncClient]]) -> AsyncClient:
    """The first registered account (also 'user A' in isolation tests)."""
    c = await make_client()
    r = await _register(c, "admin@example.com", "adminpassword123")
    assert r.status_code == 201, r.text
    return c


@pytest_asyncio.fixture
async def user_a(first_client: AsyncClient) -> tuple[AsyncClient, UUID]:
    return first_client, await _me_id(first_client)


@pytest_asyncio.fixture
async def user_b_client(
    first_client: AsyncClient,
    make_client: Callable[[], Awaitable[AsyncClient]],
    monkeypatch: Any,
) -> AsyncClient:
    """A second, DIFFERENT account.

    Requires the first account to already exist. Registration is open by default
    now, but this fixture pins it on explicitly so the isolation tests it backs
    never silently depend on the config default.
    """
    monkeypatch.setattr(settings, "registration_enabled", True)
    c = await make_client()
    r = await _register(c, "userb@example.com", "userbpassword123")
    assert r.status_code == 201, r.text
    return c


@pytest_asyncio.fixture
async def seed_project(db_factory: Any) -> Callable[..., Awaitable[UUID]]:
    """Insert a project owned by owner_id directly, bypassing the upload/S3 path."""

    async def _seed(owner_id: UUID, *, with_transcript: bool = True) -> UUID:
        async with db_factory() as s:
            proj = Project(
                title="owned project",
                owner_id=owner_id,
                status="transcribed",
                video_storage_key=f"projects/{uuid4()}/source.mp4",
                transcript=_MINIMAL_TRANSCRIPT if with_transcript else None,
            )
            s.add(proj)
            await s.commit()
            return proj.id

    return _seed
