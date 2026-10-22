"""Every job has an owner.

Revision ID: 0006_job_owner_required
Revises: 0005_highlight_colors

Every route that makes a job sets `user_id`, and 0003 filled it in for the jobs that predate it, so
what is still null cannot be owned by anyone: those rows are removed, and the column made required.
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision: str = "0006_job_owner_required"
down_revision: str | None = "0005_highlight_colors"
branch_labels: str | None = None
depends_on: str | None = None


def upgrade() -> None:
    # What a project can still say, then what nothing can.
    op.execute(
        "UPDATE jobs SET user_id = (SELECT owner_id FROM projects WHERE projects.id = jobs.project_id) "
        "WHERE user_id IS NULL AND project_id IS NOT NULL"
    )
    op.execute("DELETE FROM jobs WHERE user_id IS NULL")
    with op.batch_alter_table("jobs") as batch:
        batch.alter_column("user_id", existing_type=sa.Uuid(), nullable=False)


def downgrade() -> None:
    with op.batch_alter_table("jobs") as batch:
        batch.alter_column("user_id", existing_type=sa.Uuid(), nullable=True)
