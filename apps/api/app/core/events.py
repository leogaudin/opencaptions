"""Publishing a project's events (job progress and outcome) to its WebSocket channel.

Workers are blocking code and use :func:`publish_sync`; the API's own handlers use
:func:`publish`. Both reuse one connection pool per process: a progress event used
to open and close a connection of its own, per segment of a transcription.

The channel lives here, not in the WebSocket router, so a worker publishing an event
does not import the web layer.
"""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID

import redis

from app.core.config import settings
from app.core.redis import get_redis


def channel_for_project(project_id: UUID) -> str:
    return f"opencaptions:project:{project_id}"


def _encode(message: dict[str, Any]) -> str:
    return json.dumps(message, default=str)


_sync_client: redis.Redis | None = None


def _sync() -> redis.Redis:
    global _sync_client
    if _sync_client is None:
        # Created on first use, so a forked worker child opens its own pool.
        _sync_client = redis.Redis.from_url(settings.redis_url)
    return _sync_client


def publish_sync(project_id: UUID, message: dict[str, Any]) -> None:
    """For Celery tasks: ``{"type": "job_progress", "payload": {...}}``."""
    _sync().publish(channel_for_project(project_id), _encode(message))


async def publish(project_id: UUID, message: dict[str, Any]) -> None:
    """For the API's handlers, without blocking the event loop."""
    await get_redis().publish(channel_for_project(project_id), _encode(message))
