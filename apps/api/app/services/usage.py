"""Durable per-job usage records, and a reader that sums them per owner.

Each job performs a countable amount of work, frames rendered, seconds
transcribed, recorded here so an entitlement policy can read history rather
than re-deriving it from job payloads.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Session

from app.models import Job, Project

# Sub-document key inside Job.metadata, plus the stable unit identifiers. The
# unit is stored next to the number so a future reader never has to guess what
# the amount counts.
USAGE_METADATA_KEY = "usage"
UNIT_RENDER_FRAMES = "render-frames"
UNIT_TRANSCRIPTION_SECONDS = "transcription-seconds"


def build_usage_record(unit: str, amount: float) -> dict[str, Any]:
    """The usage sub-document written under ``Job.metadata['usage']``."""
    return {"unit": unit, "amount": amount}


def merge_usage_into_metadata(
    existing: dict[str, Any] | None, unit: str, amount: float
) -> dict[str, Any]:
    """Return metadata with the usage record merged in, preserving other keys.

    Returns a NEW dict (never mutates ``existing`` in place) so SQLAlchemy's
    change detection reliably persists the reassignment on the JSON column.
    """
    merged: dict[str, Any] = dict(existing or {})
    merged[USAGE_METADATA_KEY] = build_usage_record(unit, amount)
    return merged


def record_job_usage(session: Session, job_id: str | UUID, unit: str, amount: float) -> None:
    """Persist a usage record onto a Job, preserving any existing metadata.

    Sync-session helper called from the Celery tasks at their completion points.
    A missing job is a no-op (the task may have been cancelled/cleaned up).
    """
    jid = job_id if isinstance(job_id, UUID) else UUID(str(job_id))
    job = session.get(Job, jid)
    if job is None:
        return
    job.metadata_json = merge_usage_into_metadata(job.metadata_json, unit, amount)
    session.commit()


async def sum_usage_for_user(
    session: AsyncSession,
    owner_id: UUID,
    unit: str,
    *,
    since: datetime | None = None,
    until: datetime | None = None,
) -> float:
    """Sum one unit of recorded usage across a user's jobs.

    A job is a user's by its own owner, or by its project's for one made before jobs
    had one. ``since`` is inclusive and ``until`` exclusive, so adjacent windows do
    not double-count.
    """
    # Only the metadata column: the rest of each job row is of no use here.
    stmt = (
        select(Job.metadata_json)
        .outerjoin(Project, Job.project_id == Project.id)
        .where(or_(Job.user_id == owner_id, Project.owner_id == owner_id))
    )
    if since is not None:
        stmt = stmt.where(Job.created_at >= since)
    if until is not None:
        stmt = stmt.where(Job.created_at < until)

    total = 0.0
    for metadata in (await session.execute(stmt)).scalars().all():
        record = (metadata or {}).get(USAGE_METADATA_KEY)
        if isinstance(record, dict) and record.get("unit") == unit:
            amount = record.get("amount")
            if isinstance(amount, (int, float)) and not isinstance(amount, bool):
                total += float(amount)
    return total
