"""Failure handling: stale-job recovery, job status that stays final, the task limits."""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

import pytest
from sqlalchemy import select
from sqlalchemy.orm import sessionmaker

from app.core import task_limits
from app.models import Job, Project, User
from app.services.recovery import recover_orphan_jobs
from app.tasks.common import TaskContext


async def _user(session: Any) -> UUID:
    user = User(email="r@example.com", password_hash="x", is_active=True)
    session.add(user)
    await session.flush()
    return user.id


@pytest.mark.asyncio
async def test_recovery_fails_only_jobs_nothing_can_be_working_on(db_factory: Any) -> None:
    now = datetime.now(UTC)
    async with db_factory() as s:
        owner = await _user(s)
        busy = Project(title="busy", owner_id=owner, status="rendering")
        dead = Project(title="dead", owner_id=owner, status="transcribing")
        s.add_all([busy, dead])
        await s.flush()
        fresh = Job(project_id=busy.id, type="rendering", status="running")
        queued = Job(project_id=busy.id, type="rendering", status="pending")
        stale = Job(project_id=dead.id, type="transcription", status="running")
        lost = Job(project_id=dead.id, type="transcription", status="pending")
        s.add_all([fresh, queued, stale, lost])
        await s.flush()
        stale.updated_at = now - timedelta(seconds=task_limits.STALE_AFTER_S + 60)
        lost.created_at = now - timedelta(days=2)
        await s.flush()

        failed = await recover_orphan_jobs(s, now=now)
        await s.commit()

        assert failed == 2
        status = {j.id: j.status for j in (await s.execute(select(Job))).scalars()}
        assert status[fresh.id] == "running", "a restart must not fail a live job"
        assert status[queued.id] == "pending", "a waiting job is still in the queue"
        assert status[stale.id] == "failed"
        assert status[lost.id] == "failed"
        await s.refresh(busy)
        await s.refresh(dead)
        assert busy.status == "rendering"
        assert dead.status == "draft"


def test_the_limits_cover_what_the_product_allows() -> None:
    assert task_limits.RENDER_SOFT_LIMIT_S > task_limits.RENDER_REQUEST_TIMEOUT_S
    assert task_limits.RENDER_HARD_LIMIT_S > task_limits.RENDER_SOFT_LIMIT_S
    assert task_limits.TRANSCRIBE_HARD_LIMIT_S > task_limits.TRANSCRIBE_SOFT_LIMIT_S
    assert (
        max(task_limits.RENDER_HARD_LIMIT_S, task_limits.TRANSCRIBE_HARD_LIMIT_S)
        < task_limits.STALE_AFTER_S
    )


def test_a_task_carries_its_own_limits() -> None:
    from app.tasks.render import render_video
    from app.tasks.transcribe import transcribe_upload, transcribe_video

    assert render_video.soft_time_limit == task_limits.RENDER_SOFT_LIMIT_S
    assert render_video.time_limit == task_limits.RENDER_HARD_LIMIT_S
    for task in (transcribe_video, transcribe_upload):
        assert task.soft_time_limit == task_limits.TRANSCRIBE_SOFT_LIMIT_S
        assert task.time_limit == task_limits.TRANSCRIBE_HARD_LIMIT_S


@pytest.mark.parametrize("final", ["cancelled", "failed", "completed"])
def test_a_finished_job_is_not_brought_back_by_its_task(final: str) -> None:
    """A task that was cancelled still reports 'running' and 'completed' as it winds down."""
    from sqlalchemy import create_engine
    from sqlalchemy.pool import StaticPool

    from app.models import Base

    engine = create_engine(
        "sqlite://", poolclass=StaticPool, connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(engine)
    sessions = sessionmaker(engine, expire_on_commit=False)
    with sessions() as s:
        job = Job(type="rendering", status=final)
        s.add(job)
        s.commit()
        job_id = str(job.id)

    task = TaskContext(job_id, None, sessions, logging.getLogger("test"))
    task.set_job_status("running", progress=0.5)
    task.set_job_status("completed")
    with sessions() as s:
        again = s.get(Job, UUID(job_id))
        assert again is not None
        assert again.status == final
        assert again.progress == 0.0


# --- Uploads, storage and deletion -------------------------------------------------------


@pytest.mark.asyncio
async def test_an_upload_is_capped_by_what_is_written_not_by_what_it_claims(
    first_client: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A chunked body declares no size; the limit must still hold."""
    from app.core.config import settings

    monkeypatch.setattr(settings, "max_upload_size_mb", 1)

    async def body() -> Any:
        for _ in range(3):
            yield b"x" * (512 * 1024)

    boundary = "oc"
    head = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="title"\r\n\r\nclip\r\n'
        f'--{boundary}\r\nContent-Disposition: form-data; name="video"; filename="a.mp4"\r\n'
        "Content-Type: video/mp4\r\n\r\n"
    ).encode()

    async def stream() -> Any:
        yield head
        async for chunk in body():
            yield chunk
        yield f"\r\n--{boundary}--\r\n".encode()

    r = await first_client.post(
        "/api/v1/projects",
        content=stream(),
        headers={"content-type": f"multipart/form-data; boundary={boundary}"},
    )
    assert r.status_code == 413, r.text
    assert r.json()["error"] == "upload_too_large"


def test_copy_capped_stops_at_the_limit(tmp_path: Any) -> None:
    import io

    from app.services.upload import UploadTooLargeError, copy_capped

    assert copy_capped(io.BytesIO(b"abc"), str(tmp_path / "ok"), 3) == 3
    with pytest.raises(UploadTooLargeError):
        copy_capped(io.BytesIO(b"abcd"), str(tmp_path / "big"), 3)


@pytest.mark.asyncio
async def test_a_project_is_deleted_even_when_its_files_cannot_be(
    user_a: Any, seed_project: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The row goes first: a storage outage must not leave a project with no video."""
    from app.storage import s3

    client, owner = user_a
    project_id = await seed_project(owner)

    def broken(_prefix: str) -> int:
        raise s3.StorageError("down")

    monkeypatch.setattr(s3, "delete_prefix", broken)
    assert (await client.delete(f"/api/v1/projects/{project_id}")).status_code == 204
    assert (await client.get(f"/api/v1/projects/{project_id}")).status_code == 404


@pytest.mark.asyncio
async def test_a_missing_source_is_a_404_and_a_bad_range_a_416(
    user_a: Any, seed_project: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.storage import s3

    client, owner = user_a
    project_id = await seed_project(owner)

    def missing(key: str, byte_range: str | None = None) -> dict[str, Any]:
        raise s3.ObjectNotFoundError(key)

    monkeypatch.setattr(s3, "open_object", missing)
    r = await client.get(f"/api/v1/projects/{project_id}/source")
    assert r.status_code == 404
    assert r.json()["error"] == "no_video"

    def out_of_range(key: str, byte_range: str | None = None) -> dict[str, Any]:
        raise s3.RangeNotSatisfiableError(key)

    monkeypatch.setattr(s3, "open_object", out_of_range)
    r = await client.get(
        f"/api/v1/projects/{project_id}/source", headers={"range": "bytes=999999-"}
    )
    assert r.status_code == 416


@pytest.mark.asyncio
async def test_a_source_streams_with_its_range(
    user_a: Any, seed_project: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    import io

    from app.storage import s3

    client, owner = user_a
    project_id = await seed_project(owner)
    asked: list[str | None] = []

    def served(key: str, byte_range: str | None = None) -> dict[str, Any]:
        asked.append(byte_range)
        return {
            "Body": io.BytesIO(b"cde"),
            "ContentType": "video/mp4",
            "ContentLength": 3,
            "ContentRange": "bytes 2-4/10",
        }

    monkeypatch.setattr(s3, "open_object", served)
    r = await client.get(f"/api/v1/projects/{project_id}/source", headers={"range": "bytes=2-4"})
    assert r.status_code == 206
    assert r.content == b"cde"
    assert r.headers["content-range"] == "bytes 2-4/10"
    assert asked == ["bytes=2-4"]


@pytest.mark.asyncio
async def test_the_light_loaders_leave_the_transcript_in_the_table(
    user_a: Any, seed_project: Any, db_factory: Any
) -> None:
    from sqlalchemy import inspect

    from app.api.deps import get_owned_project_light

    client, owner = user_a
    project_id = await seed_project(owner)
    del client
    async with db_factory() as s:
        user = await s.get(User, owner)
        assert user is not None
        proj = await get_owned_project_light(project_id, user, s)
        assert "transcript" in inspect(proj).unloaded


@pytest.mark.asyncio
async def test_the_project_list_does_not_carry_transcripts(user_a: Any, seed_project: Any) -> None:
    client, owner = user_a
    await seed_project(owner)
    items = (await client.get("/api/v1/projects")).json()["items"]
    assert len(items) == 1
    assert set(items[0]) == {
        "id",
        "title",
        "status",
        "video_size_bytes",
        "created_at",
        "updated_at",
    }


@pytest.mark.asyncio
async def test_a_registration_that_loses_the_race_for_an_address_is_a_409(
    client: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Two requests pass the 'is it taken' check together; the unique index decides."""
    from sqlalchemy.ext.asyncio import AsyncSession

    from app.core.config import settings

    first = await client.post(
        "/api/v1/auth/register", json={"email": "a@example.com", "password": "password12345"}
    )
    assert first.status_code == 201

    original = AsyncSession.scalar

    async def not_seen(self: Any, statement: Any, *a: Any, **kw: Any) -> Any:
        if "users.email" in str(statement):
            return None
        return await original(self, statement, *a, **kw)

    monkeypatch.setattr(AsyncSession, "scalar", not_seen)
    monkeypatch.setattr(settings, "registration_enabled", True)
    clash = await client.post(
        "/api/v1/auth/register", json={"email": "a@example.com", "password": "password12345"}
    )
    assert clash.status_code == 409, clash.text
    assert clash.json()["error"] == "email_taken"


@pytest.mark.asyncio
async def test_a_session_slides_its_idle_window_on_read(fake_redis: Any) -> None:
    from app.core import sessions

    session_id, _csrf = await sessions.create_session(UUID(int=7))
    key = f"{sessions._SESSION_PREFIX}{session_id}"
    await fake_redis.expire(key, 5)
    assert (await sessions.get_session(session_id)) is not None
    assert await fake_redis.ttl(key) > 5, "reading a session pushes its expiry out"


def test_events_reuse_one_connection_pool(monkeypatch: pytest.MonkeyPatch) -> None:
    import fakeredis

    from app.core import events

    made: list[Any] = []

    def from_url(_url: str) -> Any:
        client = fakeredis.FakeRedis()
        made.append(client)
        return client

    monkeypatch.setattr(events, "_sync_client", None)
    monkeypatch.setattr(events.redis.Redis, "from_url", staticmethod(from_url))
    for _ in range(3):
        events.publish_sync(UUID(int=1), {"type": "job_progress", "payload": {}})
    assert len(made) == 1, "a progress event used to open a connection of its own"
    monkeypatch.setattr(events, "_sync_client", None)
