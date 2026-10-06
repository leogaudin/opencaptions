"""Record the size of the uploaded video.

Revision ID: 0004_video_size
Revises: 0003_projectless_jobs
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision: str = "0004_video_size"
down_revision: str | None = "0003_projectless_jobs"
branch_labels: str | None = None
depends_on: str | None = None


def upgrade() -> None:
    op.add_column("projects", sa.Column("video_size_bytes", sa.BigInteger(), nullable=True))


def downgrade() -> None:
    op.drop_column("projects", "video_size_bytes")
