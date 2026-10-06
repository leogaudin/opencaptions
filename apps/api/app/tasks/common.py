"""Shared infrastructure for synchronous Celery task implementations."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import settings
from app.models import Job
from app.services.progress import Stage

SyncSessionFactory = sessionmaker[Session]


def sync_session_factory() -> SyncSessionFactory:
    engine = create_engine(settings.database_url_sync, pool_pre_ping=True, future=True)
    return sessionmaker(engine, expire_on_commit=False)


@dataclass(frozen=True)
class TaskContext:
    """Status and notification operations shared by render/transcribe tasks."""

    job_id: str
    # None for a transcription asked for through the transcription API: nothing to notify
    # over a project's channel, and no project to mark.
    project_id: str | None
    sessions: SyncSessionFactory
    logger: logging.Logger

    def set_job_status(self, status: str, **fields: object) -> None:
        with self.sessions() as session:
            job = session.get(Job, UUID(self.job_id))
            if job is None:
                return
            job.status = status
            for name, value in fields.items():
                setattr(job, name, value)
            session.commit()

    def publish(self, message_type: str, payload: dict[str, object]) -> None:
        # Local import keeps rendering-only workers from opening Redis at module
        # import and keeps the function patchable in task tests.
        from app.api.websocket import publish_to_project

        if self.project_id is None:
            return
        try:
            publish_to_project(UUID(self.project_id), {"type": message_type, "payload": payload})
        except Exception as exc:  # noqa: BLE001
            self.logger.warning("WS publish failed (non-fatal): %s", exc)

    def enter_stage(self, stage: Stage, source: str, **payload: object) -> None:
        """Enter ``stage``: reset the bar and show its message, recording and
        broadcasting once. The long step inside the stage then fills the bar.

        Both halves used to be written per step, which let the stored message and
        the broadcast one drift apart.
        """
        self.set_job_status("running", progress=0.0, message=stage.message)
        self.report_progress(0.0, stage.message, source, **payload)

    def report_progress(
        self, progress: float, message: str, source: str, **payload: object
    ) -> None:
        """Broadcast progress without writing it, for updates inside a stage."""
        self.publish(
            "job_progress",
            {
                "job_id": self.job_id,
                "progress": progress,
                "message": message,
                "stage": source,
                **payload,
            },
        )

    def record_usage(self, unit: str, amount: float) -> None:
        """Best-effort accounting after successful work has completed."""
        from app.services.usage import record_job_usage

        try:
            with self.sessions() as session:
                record_job_usage(session, self.job_id, unit, amount)
        except Exception as exc:  # noqa: BLE001
            self.logger.warning("usage accounting skipped for job %s: %s", self.job_id, exc)

    def mark_failed(self, reason: str, message: str, stage: str) -> None:
        self.set_job_status("failed", error=reason, message=message)
        if self.project_id is not None:
            with self.sessions() as session:
                session.execute(
                    text("UPDATE projects SET status='error', error=:e WHERE id=:id"),
                    {"e": reason, "id": self.project_id},
                )
                session.commit()
        self.publish(
            "job_failed",
            {"job_id": self.job_id, "error": reason, "stage": stage},
        )
