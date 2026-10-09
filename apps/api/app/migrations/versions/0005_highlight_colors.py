"""A style's highlight colour becomes a list of highlight colours.

``highlight_color`` (one colour) and the short-lived ``highlight_color_end`` become
``highlight_colors``, the first being the primary. Only the stored project styles change.

Revision ID: 0005_highlight_colors
Revises: 0004_video_size
"""

from __future__ import annotations

from alembic import op

revision: str = "0005_highlight_colors"
down_revision: str | None = "0004_video_size"
branch_labels: str | None = None
depends_on: str | None = None


def upgrade() -> None:
    op.execute(
        """
        UPDATE projects
        SET style_config = (style_config - 'highlight_color' - 'highlight_color_end')
            || jsonb_build_object(
                'highlight_colors',
                CASE WHEN style_config ->> 'highlight_color_end' IS NOT NULL
                    THEN jsonb_build_array(
                        style_config -> 'highlight_color', style_config -> 'highlight_color_end')
                    ELSE jsonb_build_array(style_config -> 'highlight_color')
                END)
        WHERE style_config ? 'highlight_color'
        """
    )


def downgrade() -> None:
    op.execute(
        """
        UPDATE projects
        SET style_config = (style_config - 'highlight_colors')
            || jsonb_build_object('highlight_color', style_config -> 'highlight_colors' -> 0)
            || CASE WHEN jsonb_array_length(style_config -> 'highlight_colors') > 1
                THEN jsonb_build_object(
                    'highlight_color_end', style_config -> 'highlight_colors' -> 1)
                ELSE '{}'::jsonb END
        WHERE style_config ? 'highlight_colors'
        """
    )
