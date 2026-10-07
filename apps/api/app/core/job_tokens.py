"""Per-job progress tokens for the engine -> API callback.

The engine must POST progress to ``/jobs/{id}/progress`` WITHOUT a user session
(it is a service, not a browser), yet that endpoint must not be world-open.
Rather than shipping one shared static secret to every install (weak, and needs
manual setup), the API mints a random token scoped to a SINGLE job when it
dispatches that job's render, stores it in Redis under a short TTL, and passes it
to the engine alongside ``progress_url``. The engine echoes it back in the
``X-Job-Token`` header and the API checks it against the stored value. No
configuration, no manual step, and a leaked token is useless once the job's TTL
lapses.
"""

from __future__ import annotations

import secrets
from hmac import compare_digest

import redis as redis_sync

from app.core.config import settings
from app.core.redis import get_redis

_JOB_TOKEN_PREFIX = "opencaptions:jobtoken:"
_TOKEN_BYTES = 32
# Comfortably longer than the engine's 30-minute render ceiling.
JOB_TOKEN_TTL_SECONDS = 2 * 3600

JOB_TOKEN_HEADER = "X-Job-Token"


def job_token_key(job_id: str) -> str:
    return f"{_JOB_TOKEN_PREFIX}{job_id}"


def mint_job_token(job_id: str) -> str:
    """Mint + store a per-job token. Sync: called from the Celery render task."""
    token = secrets.token_urlsafe(_TOKEN_BYTES)
    client = redis_sync.Redis.from_url(settings.redis_url, decode_responses=True)
    try:
        client.set(job_token_key(job_id), token, ex=JOB_TOKEN_TTL_SECONDS)
    finally:
        client.close()
    return token


def delete_job_token(job_id: str) -> None:
    """Delete a per-job token once its job is terminal, instead of waiting out
    the TTL. Defense in depth: the progress callback already no-ops on a
    terminal job, so this just drops a still-valid token early."""
    client = redis_sync.Redis.from_url(settings.redis_url, decode_responses=True)
    try:
        client.delete(job_token_key(job_id))
    finally:
        client.close()


async def verify_job_token(job_id: str, token: str | None) -> bool:
    """Constant-time check of a presented token against the stored per-job one."""
    if not token:
        return False
    stored = await get_redis().get(job_token_key(job_id))
    if stored is None:
        return False
    return compare_digest(str(stored), token)
