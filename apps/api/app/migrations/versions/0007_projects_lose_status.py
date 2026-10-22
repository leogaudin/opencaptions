"""A project no longer stores what it is doing.

Revision ID: 0007_projects_lose_status
Revises: 0006_job_owner_required

`projects.status` and `projects.error` copied what the jobs say (and a failed render marked a project
with a good transcript as an error). What a project is doing is read from its transcript and its jobs.
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision: str = "0007_projects_lose_status"
down_revision: str | None = "0006_job_owner_required"
branch_labels: str | None = None
depends_on: str | None = None


def upgrade() -> None:
    with op.batch_alter_table("projects") as batch:
        batch.drop_column("status")
        batch.drop_column("error")


def downgrade() -> None:
    with op.batch_alter_table("projects") as batch:
        batch.add_column(sa.Column("status", sa.String(32), nullable=False, server_default="draft"))
        batch.add_column(sa.Column("error", sa.Text(), nullable=True))
    op.execute("UPDATE projects SET status = 'transcribed' WHERE transcript IS NOT NULL")
