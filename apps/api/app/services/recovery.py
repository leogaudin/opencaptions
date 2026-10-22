"""Clearing jobs that will never finish, at API start.

An API restart says nothing about the workers: they are other containers, they
keep their tasks, and a task a crashed worker held is handed to another (tasks
are acknowledged late). Failing every pending or running job at boot, as this
once did, failed work that was alive and let its late status updates bring the
job back. A job is only given up on when nothing could still be working on it.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, func, or_, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.task_limits import STALE_AFTER_S
from app.models import Job

# A job waits in the queue as long as the workers are busy, but not for a day: a
# message that old was lost (the broker's data was).
PENDING_ABANDONED_AFTER = timedelta(hours=24)

IN_PROGRESS = ("pending", "running")


async def recover_orphan_jobs(session: AsyncSession, *, now: datetime | None = None) -> int:
    """Fail the jobs nothing is working on; return how many. The caller commits."""
    now = now or datetime.now(UTC)
    result = await session.execute(
        update(Job)
        .where(
            or_(
                # Running longer than any task may run without a word.
                and_(
                    Job.status == "running", Job.updated_at < now - timedelta(seconds=STALE_AFTER_S)
                ),
                and_(Job.status == "pending", Job.created_at < now - PENDING_ABANDONED_AFTER),
            )
        )
        .values(
            status="failed",
            error=func.coalesce(Job.error, "abandoned: no worker finished it"),
            updated_at=now,
        )
        .returning(Job.id)
    )
    failed = len(result.all())

    return failed
