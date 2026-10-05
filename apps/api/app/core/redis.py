"""Shared async Redis client for server-side sessions and per-job tokens.

Isolated behind a factory so tests can swap in an in-memory fake without the
production code path changing: the same client interface serves both.
"""

from __future__ import annotations

import redis.asyncio as aioredis

from app.core.config import settings

_client: aioredis.Redis | None = None


def get_redis() -> aioredis.Redis:
    """Return a process-wide async Redis client (lazily created)."""
    global _client
    if _client is None:
        _client = aioredis.from_url(settings.redis_url, decode_responses=True)
    return _client
