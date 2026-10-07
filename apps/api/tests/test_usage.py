"""Tests for durable usage records + the per-owner usage summer.

Usage is written into ``Job.metadata['usage']`` at each task's completion point
and read back by ``app.services.usage.sum_usage_for_user``, which sums a user's
jobs and excludes other users' (jobs derive ownership from their parent project).
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

import pytest

from app.models import Job, Project, User
from app.services.usage import (
    UNIT_RENDER_FRAMES,
    UNIT_TRANSCRIPTION_SECONDS,
    build_usage_record,
    merge_usage_into_metadata,
    record_job_usage,
    sum_usage_for_user,
)


def test_build_usage_record_carries_unit_and_amount() -> None:
    """The record stores the unit alongside the number, no guessing later."""
    assert build_usage_record(UNIT_RENDER_FRAMES, 120.0) == {
        "unit": "render-frames",
        "amount": 120.0,
    }


def test_merge_preserves_existing_metadata() -> None:
    """Merging usage in never drops the render job's format_id / render_hash."""
    merged = merge_usage_into_metadata(
        {"format_id": "mp4", "render_hash": "abc"}, UNIT_RENDER_FRAMES, 90.0
    )
    assert merged["format_id"] == "mp4"
    assert merged["render_hash"] == "abc"
    assert merged["usage"] == {"unit": "render-frames", "amount": 90.0}


def test_merge_returns_new_dict_not_mutation() -> None:
    """A new dict is returned so SQLAlchemy detects the JSON column change."""
    original: dict[str, Any] = {"format_id": "mp4"}
    merged = merge_usage_into_metadata(original, UNIT_RENDER_FRAMES, 1.0)
    assert "usage" not in original
    assert merged is not original


def test_record_job_usage_merges_and_persists_via_sync_session() -> None:
    """Exercises the exact sync write path the Celery tasks use."""
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker

    from app.models import Base

    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    session_local = sessionmaker(engine)

    with session_local() as s:
        owner = User(email="u@example.com", password_hash="x", is_active=True)
        s.add(owner)
        s.flush()
        proj = Project(title="p", owner_id=owner.id, status="done")
        s.add(proj)
        s.flush()
        job = Job(
            project_id=proj.id,
            type="rendering",
            status="completed",
            metadata_json={"format_id": "mp4", "render_hash": "abc"},
        )
        s.add(job)
        s.commit()
        job_id = job.id

    with session_local() as s:
        record_job_usage(s, job_id, UNIT_RENDER_FRAMES, 150.0)

    with session_local() as s:
        stored = s.get(Job, job_id)
        assert stored is not None
        assert stored.metadata_json is not None
        assert stored.metadata_json["format_id"] == "mp4"  # preserved
        assert stored.metadata_json["usage"] == {"unit": "render-frames", "amount": 150.0}


def test_record_job_usage_missing_job_is_noop() -> None:
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker

    from app.models import Base

    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    session_local = sessionmaker(engine)
    with session_local() as s:
        # Should not raise for an unknown job id.
        record_job_usage(s, uuid4(), UNIT_RENDER_FRAMES, 1.0)


async def _make_user(factory: Any, email: str) -> UUID:
    async with factory() as s:
        user = User(email=email, password_hash="x")
        s.add(user)
        await s.commit()
        return user.id


async def _seed_job(
    factory: Any,
    owner_id: UUID | None,
    unit: str | None,
    amount: float,
    *,
    created_at: datetime | None = None,
) -> None:
    """Insert a completed job under a project owned by ``owner_id``.

    ``unit=None`` seeds a job with no usage record (should be ignored by sums).
    """
    async with factory() as s:
        proj = Project(title="p", owner_id=owner_id, status="done")
        s.add(proj)
        await s.flush()
        metadata = merge_usage_into_metadata(None, unit, amount) if unit else {"format_id": "mp4"}
        job = Job(
            project_id=proj.id,
            type="rendering",
            status="completed",
            metadata_json=metadata,
        )
        if created_at is not None:
            job.created_at = created_at
        s.add(job)
        await s.commit()


@pytest.mark.asyncio
async def test_sum_sums_one_user_and_excludes_another(db_factory: Any) -> None:
    user_a = await _make_user(db_factory, "a@example.com")
    user_b = await _make_user(db_factory, "b@example.com")

    await _seed_job(db_factory, user_a, UNIT_RENDER_FRAMES, 100.0)
    await _seed_job(db_factory, user_a, UNIT_RENDER_FRAMES, 50.0)
    await _seed_job(db_factory, user_b, UNIT_RENDER_FRAMES, 999.0)  # excluded

    async with db_factory() as s:
        total = await sum_usage_for_user(s, user_a, UNIT_RENDER_FRAMES)

    assert total == 150.0


@pytest.mark.asyncio
async def test_sum_filters_by_unit(db_factory: Any) -> None:
    user_a = await _make_user(db_factory, "a@example.com")
    await _seed_job(db_factory, user_a, UNIT_RENDER_FRAMES, 120.0)
    await _seed_job(db_factory, user_a, UNIT_TRANSCRIPTION_SECONDS, 42.0)

    async with db_factory() as s:
        frames = await sum_usage_for_user(s, user_a, UNIT_RENDER_FRAMES)
        seconds = await sum_usage_for_user(s, user_a, UNIT_TRANSCRIPTION_SECONDS)

    assert frames == 120.0
    assert seconds == 42.0


@pytest.mark.asyncio
async def test_sum_ignores_jobs_without_usage_record(db_factory: Any) -> None:
    user_a = await _make_user(db_factory, "a@example.com")
    await _seed_job(db_factory, user_a, UNIT_RENDER_FRAMES, 30.0)
    await _seed_job(db_factory, user_a, None, 0.0)  # no usage sub-document

    async with db_factory() as s:
        total = await sum_usage_for_user(s, user_a, UNIT_RENDER_FRAMES)

    assert total == 30.0


@pytest.mark.asyncio
async def test_sum_respects_period_window(db_factory: Any) -> None:
    user_a = await _make_user(db_factory, "a@example.com")
    now = datetime.now(UTC)
    await _seed_job(db_factory, user_a, UNIT_RENDER_FRAMES, 10.0, created_at=now)
    await _seed_job(
        db_factory, user_a, UNIT_RENDER_FRAMES, 999.0, created_at=now - timedelta(days=40)
    )

    async with db_factory() as s:
        recent = await sum_usage_for_user(
            s, user_a, UNIT_RENDER_FRAMES, since=now - timedelta(days=7)
        )
        everything = await sum_usage_for_user(s, user_a, UNIT_RENDER_FRAMES)

    assert recent == 10.0
    assert everything == 1009.0


@pytest.mark.asyncio
async def test_sum_is_zero_for_user_with_no_jobs(db_factory: Any) -> None:
    user_a = await _make_user(db_factory, "a@example.com")
    async with db_factory() as s:
        assert await sum_usage_for_user(s, user_a, UNIT_RENDER_FRAMES) == 0.0
