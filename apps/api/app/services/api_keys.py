"""API key minting and lookup hashing."""

from __future__ import annotations

import hashlib
import secrets

PREFIX = "oc_"
# Enough of the key to tell keys apart in a list, far too little to use.
SHOWN = 10


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


def mint() -> tuple[str, str, str]:
    """A new key, its displayable prefix, and the hash that is stored."""
    key = PREFIX + secrets.token_urlsafe(32)
    return key, key[:SHOWN], hash_key(key)
