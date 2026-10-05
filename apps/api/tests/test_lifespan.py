"""Boot behaviour: a migration failure must fail the boot LOUDLY.

Before this fix the lifespan logged "Auto-migrate skipped" and continued, so the
API could come up against a half-migrated schema (e.g. no users table) and 500
every authenticated route while reporting itself started. The lifespan must now
re-raise so the container stops instead.
"""

from __future__ import annotations

from typing import Any

import pytest

from app.main import app, lifespan


@pytest.mark.asyncio
async def test_lifespan_reraises_when_migration_fails(monkeypatch: Any) -> None:
    import alembic.command

    def _boom(*_args: Any, **_kwargs: Any) -> None:
        raise RuntimeError("migration exploded")

    # The lifespan runs `alembic upgrade head` in a thread; make it fail.
    monkeypatch.setattr(alembic.command, "upgrade", _boom)

    with pytest.raises(RuntimeError, match="migration exploded"):
        async with lifespan(app):
            pass
