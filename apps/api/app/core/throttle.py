"""Redis-backed throttling for repeated failed auth attempts.

Three properties are load-bearing and easy to break:

* The counter is keyed per identifier, never global, so one identifier's budget
  cannot lock everyone out.
* The same counter is incremented whether or not the account exists, and the
  limit is checked before the lookup, so being throttled is no enumeration
  oracle.
* The window TTL is bound to the counter at creation in one round trip, so a
  counter can never exist without an expiry and wedge an identifier forever.

Two separate controls share these primitives: per-identifier failures, cleared
on success, and a coarser per-source-IP attempt ceiling that is not. Collapsing
them would let one caller's success clear another's abuse budget.
"""

from __future__ import annotations

import hashlib

from app.core.config import settings
from app.core.redis import get_redis

_PREFIX = "opencaptions:throttle:"


def _key(scope: str, identifier: str) -> str:
    digest = hashlib.sha256(identifier.strip().lower().encode("utf-8")).hexdigest()
    return f"{_PREFIX}{scope}:{digest}"


async def _bump(key: str, window_s: int) -> int:
    """Count one event under ``key``, creating it with its TTL in one round trip."""
    redis = get_redis()
    pipe = redis.pipeline(transaction=True)
    pipe.set(key, 0, ex=window_s, nx=True)
    pipe.incr(key)
    results = await pipe.execute()
    return int(results[-1])


async def is_rate_limited(scope: str, identifier: str, *, limit: int | None = None) -> bool:
    """True if ``identifier`` has reached ``limit``, or the per-identifier default."""
    ceiling = settings.auth_throttle_max_attempts if limit is None else limit
    raw = await get_redis().get(_key(scope, identifier))
    return raw is not None and int(raw) >= ceiling


async def record_failure(scope: str, identifier: str) -> int:
    """Count one credential-guessing failure. Returns the running count."""
    return await _bump(_key(scope, identifier), settings.auth_throttle_window_s)


async def record_attempt(scope: str, identifier: str, *, window_s: int) -> int:
    """Count one attempt against the per-source ceiling. Never cleared by a success."""
    return await _bump(_key(scope, identifier), window_s)


async def reset(scope: str, identifier: str) -> None:
    """Clear the counter for an identifier: called after a successful auth."""
    await get_redis().delete(_key(scope, identifier))
