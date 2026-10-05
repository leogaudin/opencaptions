"""Password hashing with Argon2id (argon2-cffi).

argon2-cffi is actively maintained and its ``PasswordHasher()`` defaults already
exceed the OWASP floor (m=19456 KiB, t=2, p=1). We set those parameters
explicitly anyway so the cost is pinned and auditable, and call
``check_needs_rehash()`` on every successful login so hashes created under
older/weaker parameters are transparently upgraded.

Never log or persist the plaintext password or the raw hash beyond the users
table.
"""

from __future__ import annotations

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError

# OWASP-recommended Argon2id floor, set explicitly rather than relying on the
# library defaults so a future argon2-cffi default change cannot silently move
# our cost parameters.
_hasher = PasswordHasher(
    time_cost=2,
    memory_cost=19456,
    parallelism=1,
)

# A precomputed hash used to equalize response time when the email is unknown,
# so a missing account is not distinguishable by timing from a wrong password.
DUMMY_HASH = _hasher.hash("opencaptions-timing-equalizer")


def hash_password(password: str) -> str:
    """Hash a plaintext password with Argon2id."""
    return _hasher.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    """Return True iff the password matches the hash. Never raises on mismatch."""
    try:
        return _hasher.verify(password_hash, password)
    except (VerifyMismatchError, InvalidHashError):
        return False


def needs_rehash(password_hash: str) -> bool:
    """Return True if the hash should be recomputed under the current parameters."""
    try:
        return _hasher.check_needs_rehash(password_hash)
    except InvalidHashError:
        return False
