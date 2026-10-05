"""Short-lived single-use password-reset tokens in Redis.

Redis rather than a table: these expire, and an expiry is what Redis does
natively. Only a hash of the secret half is stored, so a dump of the keyspace
does not yield usable tokens.
"""

from __future__ import annotations

import hashlib
import secrets
from hmac import compare_digest
from uuid import UUID

from app.core.redis import get_redis

_RESET_PREFIX = "opencaptions:reset:"
_SELECTOR_BYTES = 16  # non-secret lookup handle
_VERIFIER_BYTES = 32  # 256-bit secret, proven by hash comparison

# One hour is the conventional ceiling for a reset link. Enforced by the Redis
# key TTL, so an expired token is ABSENT at redemption rather than merely marked.
RESET_TOKEN_TTL_SECONDS = 3600


def _key(selector: str) -> str:
    return f"{_RESET_PREFIX}{selector}"


def _hash_verifier(verifier: str) -> str:
    return hashlib.sha256(verifier.encode("utf-8")).hexdigest()


async def issue(user_id: UUID) -> str:
    """Mint a token for ``user_id``. The returned value is the only copy."""
    selector = secrets.token_urlsafe(_SELECTOR_BYTES)
    verifier = secrets.token_urlsafe(_VERIFIER_BYTES)
    stored = f"{_hash_verifier(verifier)}:{user_id}"
    await get_redis().set(_key(selector), stored, ex=RESET_TOKEN_TTL_SECONDS)
    return f"{selector}.{verifier}"


async def redeem(token: str) -> UUID | None:
    """Consume a token, returning its user id, or None if unusable.

    Fetched and deleted in one atomic step, so it cannot be redeemed twice.
    """
    selector, _, verifier = token.partition(".")
    if not selector or not verifier:
        return None
    redis = get_redis()
    pipe = redis.pipeline(transaction=True)
    pipe.get(_key(selector))
    pipe.delete(_key(selector))
    stored, _deleted = await pipe.execute()
    if stored is None:
        return None
    stored_hash, _, user_id = str(stored).partition(":")
    if not compare_digest(_hash_verifier(verifier), stored_hash):
        return None
    try:
        return UUID(user_id)
    except ValueError:
        return None
