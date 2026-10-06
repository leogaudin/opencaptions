"""Jobs that belong to a user rather than a project.

Revision ID: 0003_projectless_jobs
Revises: 0002_api_keys

A transcription asked for through the transcription API has no project, so its job
needs an owner of its own. Existing jobs get theirs from their project.
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision: str = "0003_projectless_jobs"
down_revision: str | None = "0002_api_keys"
branch_labels: str | None = None
depends_on: str | None = None


def upgrade() -> None:
    with op.batch_alter_table("jobs") as batch:
        batch.add_column(sa.Column("user_id", sa.Uuid(), nullable=True))
        batch.create_foreign_key(
            "fk_jobs_user_id", "users", ["user_id"], ["id"], ondelete="CASCADE"
        )
        batch.alter_column("project_id", existing_type=sa.Uuid(), nullable=True)
    op.create_index("ix_jobs_user_id", "jobs", ["user_id"])
    op.execute(
        "UPDATE jobs SET user_id = (SELECT owner_id FROM projects WHERE projects.id = jobs.project_id)"
    )


def downgrade() -> None:
    op.drop_index("ix_jobs_user_id", table_name="jobs")
    op.execute("DELETE FROM jobs WHERE project_id IS NULL")
    with op.batch_alter_table("jobs") as batch:
        batch.alter_column("project_id", existing_type=sa.Uuid(), nullable=False)
        batch.drop_constraint("fk_jobs_user_id", type_="foreignkey")
        batch.drop_column("user_id")
