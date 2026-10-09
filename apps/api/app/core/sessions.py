"""Server-side session store backed by Redis.

Why server-side (rather than a signed client-side cookie / Starlette's
SessionMiddleware): the session id is an opaque cryptographically-random token,
and all state lives in Redis keyed by that id. That means a session can be
revoked instantly, logout REALLY logs out, and there is no signing secret to
generate or persist. A signed client cookie cannot be revoked per-session.

Each session carries a per-session CSRF token, returned to the SPA by
login/register/me and required in the X-CSRF-Token header on unsafe requests.

Two independent lifetimes: an IDLE timeout (the Redis TTL, slid forward on every
access) and an ABSOLUTE cap (checked against created_at), so a continuously
active session still cannot outlive the absolute maximum.
"""

from __future__ import annotations

import json
import secrets
import time
from dataclasses import dataclass
from uuid import UUID

from app.core.redis import get_redis

_SESSION_PREFIX = "opencaptions:session:"
_SESSION_ID_BYTES = 32  # 256 bits of entropy in the opaque id
_CSRF_BYTES = 32

IDLE_TTL_SECONDS = 7 * 24 * 3600  # slid forward on each access
ABSOLUTE_TTL_SECONDS = 30 * 24 * 3600  # hard cap regardless of activity


@dataclass(frozen=True)
class SessionData:
    user_id: UUID
    csrf_token: str
    created_at: float


def _key(session_id: str) -> str:
    return f"{_SESSION_PREFIX}{session_id}"


async def create_session(user_id: UUID) -> tuple[str, str]:
    """Create a fresh session. Returns (session_id, csrf_token)."""
    session_id = secrets.token_urlsafe(_SESSION_ID_BYTES)
    csrf_token = secrets.token_urlsafe(_CSRF_BYTES)
    payload = {
        "user_id": str(user_id),
        "csrf_token": csrf_token,
        "created_at": time.time(),
    }
    await get_redis().set(_key(session_id), json.dumps(payload), ex=IDLE_TTL_SECONDS)
    return session_id, csrf_token


async def get_session(session_id: str) -> SessionData | None:
    """Load a session, enforcing idle + absolute expiry. Slides the idle TTL."""
    if not session_id:
        return None
    redis = get_redis()
    # Read and slide the idle window in one round trip (Redis 6.2+).
    raw = await redis.getex(_key(session_id), ex=IDLE_TTL_SECONDS)
    if raw is None:
        return None
    data = json.loads(raw)
    created_at = float(data["created_at"])
    # Absolute cap: a long-lived but continuously active session still dies.
    if time.time() - created_at > ABSOLUTE_TTL_SECONDS:
        await redis.delete(_key(session_id))
        return None
    return SessionData(
        user_id=UUID(data["user_id"]),
        csrf_token=data["csrf_token"],
        created_at=created_at,
    )


async def delete_session(session_id: str) -> None:
    """Delete a session so its id can never be used again."""
    if session_id:
        await get_redis().delete(_key(session_id))


async def delete_user_sessions(user_id: UUID, *, keep: str | None = None) -> int:
    """Delete every server-side session belonging to ``user_id``. Returns count.

    Used when a user is deactivated, and when their password changes: their live
    sessions must die immediately (the opaque cookie stops working on the very next
    request), not merely be blocked at the next login. get_current_user already
    rejects an inactive user as defence in depth, but that leaves the session id
    valid in Redis; this actively revokes it.

    ``keep`` spares one session id, so a user changing their own password revokes
    every other session without logging themselves out of the tab they did it from.

    There is no reverse index from user to session ids (a session id is a random
    opaque token and the payload carries the user id, not vice-versa), so we scan
    the session keyspace and drop the entries whose payload names this user. The
    keyspace is small for a self-hosted install, and scan_iter never blocks Redis.
    """
    redis = get_redis()
    target = str(user_id)
    spared = _key(keep) if keep else None
    deleted = 0
    async for key in redis.scan_iter(match=f"{_SESSION_PREFIX}*"):
        if spared is not None and key == spared:
            continue
        raw = await redis.get(key)
        if raw is None:
            continue
        try:
            data = json.loads(raw)
        except (ValueError, TypeError):
            continue
        if data.get("user_id") == target:
            await redis.delete(key)
            deleted += 1
    return deleted
