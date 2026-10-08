"""SQLAlchemy 2 declarative base + ORM models."""

from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import JSON, BigInteger, DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, MappedColumn, mapped_column, relationship


class Base(DeclarativeBase):
    """Base class for all ORM models."""

    type_annotation_map = {
        dict[str, Any]: JSON().with_variant(JSONB(), "postgresql"),
    }


def _now() -> datetime:
    return datetime.now(UTC)


class User(Base):
    """An account.

    Ownership is per-user: a user sees only their own projects, never another
    account's.
    """

    __tablename__ = "users"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    # Stored normalised lowercase (see schemas.RegisterRequest) so A@x and a@x
    # are the same account. Never expose password_hash via the API.
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    is_active: Mapped[bool] = mapped_column(default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Project(Base):
    """A project = uploaded video + its transcript + its style + render outputs."""

    __tablename__ = "projects"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(255))
    status: Mapped[str] = mapped_column(
        String(32),
        default="draft",
        # 'draft' | 'transcribing' | 'transcribed' | 'rendering' | 'done' | 'error'
    )
    transcript: Mapped[dict[str, Any] | None] = mapped_column(
        JSONB().with_variant(JSON, "sqlite"), nullable=True
    )
    style_config: Mapped[dict[str, Any] | None] = mapped_column(
        JSONB().with_variant(JSON, "sqlite"), nullable=True
    )
    # Positive shows captions later. Reaches the render hash through the shifted
    # transcript timings; see app.services.caption_offset.
    caption_offset_ms: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    video_storage_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    # Probed at upload; drives preview and render dimensions. Null when the probe
    # failed, which must never block an upload.
    video_width: Mapped[int | None] = mapped_column(Integer, nullable=True)
    video_height: Mapped[int | None] = mapped_column(Integer, nullable=True)
    video_fps: Mapped[float | None] = mapped_column(Float, nullable=True)
    video_duration: Mapped[float | None] = mapped_column(Float, nullable=True)
    # What the uploaded file weighs, for the project list. Null for a project made before it was
    # recorded.
    video_size_bytes: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )

    jobs: Mapped[list["Job"]] = relationship(
        "Job", back_populates="project", cascade="all, delete-orphan"
    )


class Job(Base):
    """A unit of background work (transcription or rendering) attached to a project."""

    __tablename__ = "jobs"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    # Null for a transcription asked for through the transcription API, which has no project.
    project_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("projects.id", ondelete="CASCADE"), index=True, nullable=True
    )
    # Who asked, for a job with no project to say it. Null where the project says it.
    user_id: Mapped[UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=True
    )
    type: Mapped[str] = mapped_column(String(32))  # 'transcription' | 'rendering'
    status: Mapped[str] = mapped_column(
        String(32), default="pending"
    )  # 'pending' | 'running' | 'completed' | 'failed' | 'cancelled' | 'deleted'
    celery_task_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    progress: Mapped[float] = mapped_column(Float, default=0.0)
    message: Mapped[str | None] = mapped_column(String(255), nullable=True)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    metadata_json: Mapped[dict[str, Any] | None] = mapped_column(
        "metadata", JSONB().with_variant(JSON, "sqlite"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )

    project: Mapped[Project | None] = relationship("Project", back_populates="jobs")


class ApiKey(Base):
    """A key a user mints to call the API from scripts.

    Only a SHA-256 of the key is stored: the key itself is shown once, at
    creation. A high-entropy random token needs no slow hash, unlike a password.
    """

    __tablename__ = "api_keys"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(100))
    # The first characters of the key, so a user can tell their keys apart.
    prefix: Mapped[str] = mapped_column(String(16))
    key_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


__all__ = ["ApiKey", "Base", "Job", "Project", "User"]


# Re-export for `from app.models import Base` (used by alembic env.py)
del MappedColumn  # avoid stray re-export
